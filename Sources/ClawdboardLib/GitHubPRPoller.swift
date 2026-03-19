import Foundation

/// Reactive git info collector for active sessions.
///
/// - **Diff stats**: Triggered by `requestRefresh()` (called when sessions change)
///   with a 3s per-session debounce. Results kept in memory — no state file writes.
/// - **PR lookup**: 60s timer polling `gh pr list` for sessions missing a PR URL.
///   PR results are written to state files since they're expensive to re-fetch.
///
/// All git/gh commands run off the main thread. Results delivered on the main queue.
public class GitInfoPoller {
    /// Minimum seconds between diff stats fetches for the same session.
    private static let diffStatsDebounce: TimeInterval = 3
    /// PR lookup interval.
    private static let prPollInterval: TimeInterval = 60

    private var prTimer: Timer?

    // MARK: - Callbacks

    /// Called on main queue when diff stats or PR info change.
    /// AppState should call rebuildSessions() to merge the new data.
    private let onChange: () -> Void

    // MARK: - Types

    public struct DiffStats: Equatable {
        public let additions: Int
        public let deletions: Int
    }

    public struct PRInfo: Equatable {
        public let number: Int
        public let url: String
        public let title: String
    }

    // MARK: - In-memory caches (read by AppState during rebuildSessions)

    /// Cached diff stats keyed by session ID.
    public private(set) var diffStatsCache: [String: DiffStats] = [:]

    /// Cached PR info keyed by session ID.
    public private(set) var prInfoCache: [String: PRInfo] = [:]

    // MARK: - Session tracking

    public struct DiffStatsTarget {
        public let sessionId: String
        public let cwd: String
    }

    public struct PRTarget {
        public let sessionId: String
        public let repo: String
        public let branch: String
    }

    private var diffStatsTargets: [DiffStatsTarget] = []
    private var prTargets: [PRTarget] = []

    /// Tracks when diff stats were last fetched per session (for debounce).
    private var lastDiffStatsFetch: [String: Date] = [:]

    /// Cached default branch per cwd (stable for the lifetime of a session).
    private var defaultBranchCache: [String: String] = [:]

    /// Once `gh` is known to be missing, skip PR polling entirely.
    private var ghAvailable: Bool?

    // MARK: - Init / lifecycle

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    public func start() {
        prTimer = Timer.scheduledTimer(
            withTimeInterval: Self.prPollInterval, repeats: true
        ) { [weak self] _ in
            self?.pollPRs()
        }
    }

    public func stop() {
        prTimer?.invalidate()
        prTimer = nil
    }

    /// Update the session lists and trigger a diff stats refresh.
    /// Called by AppState from rebuildSessions().
    public func updateTargets(
        diffStats: [DiffStatsTarget],
        pr: [PRTarget]
    ) {
        diffStatsTargets = diffStats
        prTargets = pr

        // Clean up caches for sessions that are no longer active
        let activeSessionIds = Set(diffStats.map(\.sessionId))
        lastDiffStatsFetch = lastDiffStatsFetch.filter { activeSessionIds.contains($0.key) }
        diffStatsCache = diffStatsCache.filter { activeSessionIds.contains($0.key) }
        prInfoCache = prInfoCache.filter { activeSessionIds.contains($0.key) }

        let activeCwds = Set(diffStats.map(\.cwd))
        defaultBranchCache = defaultBranchCache.filter { activeCwds.contains($0.key) }

        // Reactively fetch diff stats for sessions that need it
        requestRefresh()
    }

    /// Trigger a debounced diff stats refresh for all active sessions.
    public func requestRefresh() {
        let targets = diffStatsTargets
        guard !targets.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.fetchDiffStatsForTargets(targets)
        }
    }

    // MARK: - Diff stats

    private func fetchDiffStatsForTargets(_ targets: [DiffStatsTarget]) {
        let now = Date()
        var anyChanged = false

        for target in targets {
            // Debounce: skip if fetched recently
            if let last = lastDiffStatsFetch[target.sessionId],
                now.timeIntervalSince(last) < Self.diffStatsDebounce
            {
                continue
            }

            guard let stats = fetchDiffStats(cwd: target.cwd) else { continue }

            lastDiffStatsFetch[target.sessionId] = now

            // Only notify if the value actually changed
            if diffStatsCache[target.sessionId] != stats {
                diffStatsCache[target.sessionId] = stats
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

    // MARK: - PR lookup (timer-based, writes to state files)

    private func pollPRs() {
        let targets = prTargets
        guard !targets.isEmpty else { return }

        if ghAvailable == nil {
            ghAvailable = Self.isGHAvailable()
        }
        guard ghAvailable == true else {
            debugLog("[GitInfoPoller] gh CLI not available, skipping PR lookup")
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var anyChanged = false

            for target in targets {
                if let info = Self.fetchPR(repo: target.repo, branch: target.branch) {
                    debugLog(
                        "[GitInfoPoller] Found PR #\(info.number) for \(target.repo):\(target.branch)"
                    )
                    self.prInfoCache[target.sessionId] = info
                    anyChanged = true
                }
            }

            if anyChanged {
                DispatchQueue.main.async { [weak self] in
                    self?.onChange()
                }
            }
        }
    }

    private static func fetchPR(repo: String, branch: String) -> PRInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "gh", "pr", "list",
            "--repo", repo,
            "--head", branch,
            "--json", "number,url,title",
            "--limit", "1",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            debugLog("[GitInfoPoller] Failed to run gh: \(error)")
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }

        struct GHPREntry: Decodable {
            let number: Int
            let url: String
            let title: String
        }

        guard let entries = try? JSONDecoder().decode([GHPREntry].self, from: data),
            let first = entries.first
        else { return nil }

        return PRInfo(number: first.number, url: first.url, title: first.title)
    }

    private static func isGHAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    deinit {
        stop()
    }
}
