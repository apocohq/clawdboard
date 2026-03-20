import Foundation

/// Reactive diff stats collector for active sessions.
///
/// Triggered by `updateTargets()` (called when sessions change, i.e. on every
/// hook event via DispatchSource). Uses a 3s per-session debounce to avoid
/// redundant `git diff` calls during rapid hook bursts.
///
/// Results kept in memory — no state file writes, no rebuild loops.
/// All git commands run off the main thread on `.utility` QoS.
///
/// Performance: `git diff --shortstat` ~3ms, default branch resolve ~4ms
/// (cached per-cwd after first call).
public class GitInfoPoller {
    /// Minimum seconds between diff stats fetches for the same session.
    private static let diffStatsDebounce: TimeInterval = 3

    // MARK: - Callback

    /// Called on main queue when diff stats change.
    private let onChange: () -> Void

    // MARK: - Types

    public struct DiffStats: Equatable {
        public let additions: Int
        public let deletions: Int
    }

    // MARK: - Serial queue protecting all mutable state

    private let queue = DispatchQueue(label: "clawdboard.gitinfo-poller", qos: .utility)

    // MARK: - In-memory cache (read by AppState during mergeGitInfo)

    /// Cached diff stats keyed by session ID. Access only from `queue`.
    private var _diffStatsCache: [String: DiffStats] = [:]

    /// Thread-safe snapshot of diff stats cache.
    public var diffStatsCache: [String: DiffStats] {
        queue.sync { _diffStatsCache }
    }

    // MARK: - Session tracking

    public struct DiffStatsTarget {
        public let sessionId: String
        public let cwd: String
    }

    private var targets: [DiffStatsTarget] = []

    /// Tracks when diff stats were last fetched per session (for debounce).
    private var lastFetch: [String: Date] = [:]

    /// Cached default branch per cwd (stable for the lifetime of a session).
    private var defaultBranchCache: [String: String] = [:]

    // MARK: - Init

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Update session targets and trigger a debounced diff stats refresh.
    /// Called by AppState from rebuildSessions().
    public func updateTargets(_ newTargets: [DiffStatsTarget]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.targets = newTargets

            // Clean up caches for sessions that are no longer active
            let activeIds = Set(newTargets.map(\.sessionId))
            self.lastFetch = self.lastFetch.filter { activeIds.contains($0.key) }
            self._diffStatsCache = self._diffStatsCache.filter { activeIds.contains($0.key) }

            let activeCwds = Set(newTargets.map(\.cwd))
            self.defaultBranchCache = self.defaultBranchCache.filter {
                activeCwds.contains($0.key)
            }

            // Fetch inline (already on the serial queue)
            let snapshot = self.targets
            guard !snapshot.isEmpty else { return }
            self.fetchAll(snapshot)
        }
    }

    // MARK: - Diff stats

    private func fetchAll(_ targets: [DiffStatsTarget]) {
        let now = Date()
        var anyChanged = false

        for target in targets {
            // Debounce: skip if fetched recently
            if let last = lastFetch[target.sessionId],
                now.timeIntervalSince(last) < Self.diffStatsDebounce
            {
                continue
            }

            guard let stats = fetchDiffStats(cwd: target.cwd) else { continue }

            lastFetch[target.sessionId] = now

            // Only notify if the value actually changed
            if _diffStatsCache[target.sessionId] != stats {
                _diffStatsCache[target.sessionId] = stats
                anyChanged = true
            }
        }

        if anyChanged {
            DispatchQueue.main.async { [weak self] in
                self?.onChange()
            }
        }
    }

    /// Run `git diff --shortstat origin/<default>..HEAD` in the session's cwd.
    private func fetchDiffStats(cwd: String) -> DiffStats? {
        guard let defaultBranch = cachedDefaultBranch(cwd: cwd) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "--shortstat", "origin/\(defaultBranch)..HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let output =
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return Self.parseDiffShortstat(output)
    }

    /// Return the cached default branch for a cwd, resolving it on first access.
    private func cachedDefaultBranch(cwd: String) -> String? {
        if let cached = defaultBranchCache[cwd] {
            return cached
        }
        guard let branch = Self.resolveDefaultBranch(cwd: cwd) else { return nil }
        defaultBranchCache[cwd] = branch
        return branch
    }

    /// Detect the default branch (main/master) for the repo.
    private static func resolveDefaultBranch(cwd: String) -> String? {
        let symRef = Process()
        symRef.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        symRef.arguments = ["symbolic-ref", "refs/remotes/origin/HEAD"]
        symRef.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let symPipe = Pipe()
        symRef.standardOutput = symPipe
        symRef.standardError = FileHandle.nullDevice
        do {
            try symRef.run()
            symRef.waitUntilExit()
            if symRef.terminationStatus == 0 {
                let out =
                    String(
                        data: symPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                    ?? ""
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if let last = trimmed.split(separator: "/").last {
                    return String(last)
                }
            }
        } catch {}

        for branch in ["main", "master"] {
            let verify = Process()
            verify.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            verify.arguments = ["rev-parse", "--verify", "origin/\(branch)"]
            verify.currentDirectoryURL = URL(fileURLWithPath: cwd)
            verify.standardOutput = FileHandle.nullDevice
            verify.standardError = FileHandle.nullDevice
            do {
                try verify.run()
                verify.waitUntilExit()
                if verify.terminationStatus == 0 { return branch }
            } catch {}
        }
        return nil
    }

    /// Parse output like "3 files changed, 120 insertions(+), 47 deletions(-)"
    static func parseDiffShortstat(_ output: String) -> DiffStats? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return DiffStats(additions: 0, deletions: 0) }

        var additions = 0
        var deletions = 0

        let scanner = trimmed as NSString
        let insertRange = scanner.range(of: #"(\d+) insertion"#, options: .regularExpression)
        if insertRange.location != NSNotFound {
            let numRange = scanner.range(
                of: #"\d+"#, options: .regularExpression, range: insertRange)
            if numRange.location != NSNotFound {
                additions = Int(scanner.substring(with: numRange)) ?? 0
            }
        }
        let deleteRange = scanner.range(of: #"(\d+) deletion"#, options: .regularExpression)
        if deleteRange.location != NSNotFound {
            let numRange = scanner.range(
                of: #"\d+"#, options: .regularExpression, range: deleteRange)
            if numRange.location != NSNotFound {
                deletions = Int(scanner.substring(with: numRange)) ?? 0
            }
        }

        return DiffStats(additions: additions, deletions: deletions)
    }
}
