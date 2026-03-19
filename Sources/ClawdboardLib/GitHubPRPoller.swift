import Foundation

/// Polls git info for active sessions on a background timer.
///
/// Collects two kinds of data:
/// - **Diff stats**: `git diff --shortstat` every 5s (3s per-session debounce)
/// - **PR lookup**: `gh pr list` every 60s for sessions missing a PR URL
///
/// All git/gh commands run off the main thread. Results are delivered
/// on the main queue via callbacks.
///
/// Performance: `git diff --shortstat` completes in ~3ms on modern hardware,
/// and default branch detection (`symbolic-ref` / `rev-parse`) adds ~2-4ms.
/// The default branch is cached per-cwd to avoid repeated lookups.
public class GitInfoPoller {
    /// How often the timer fires (diff stats cadence).
    private static let tickInterval: TimeInterval = 5
    /// PR lookup runs every Nth tick (60s / 5s = 12).
    private static let prTickModulo = 12
    /// Minimum seconds between diff stats updates for the same session.
    private static let diffStatsDebounce: TimeInterval = 3

    private var timer: Timer?
    private var tickCount = 0

    // MARK: - Callbacks

    private let onDiffStats: (String, DiffStats) -> Void
    private let onPRInfo: (String, PRInfo) -> Void

    // MARK: - Types

    public struct DiffStats: Equatable {
        public let additions: Int
        public let deletions: Int
    }

    public struct PRInfo {
        public let number: Int
        public let url: String
        public let title: String
    }

    // MARK: - Session tracking

    /// Sessions eligible for diff stats polling.
    public struct DiffStatsTarget {
        public let sessionId: String
        public let cwd: String
    }

    /// Sessions eligible for PR lookup.
    public struct PRTarget {
        public let sessionId: String
        public let repo: String
        public let branch: String
    }

    private var diffStatsTargets: [DiffStatsTarget] = []
    private var prTargets: [PRTarget] = []

    /// Tracks when diff stats were last updated per session (for debounce).
    private var lastDiffStatsUpdate: [String: Date] = []

    /// Tracks last reported diff stats per session to avoid redundant callbacks.
    private var lastDiffStatsValue: [String: DiffStats] = [:]

    /// Cached default branch per cwd (stable for the lifetime of a session).
    private var defaultBranchCache: [String: String] = [:]

    /// Once `gh` is known to be missing, skip PR polling for this run.
    private var ghAvailable: Bool?

    // MARK: - Init / lifecycle

    public init(
        onDiffStats: @escaping (String, DiffStats) -> Void,
        onPRInfo: @escaping (String, PRInfo) -> Void
    ) {
        self.onDiffStats = onDiffStats
        self.onPRInfo = onPRInfo
    }

    public func start() {
        // Run once immediately for diff stats
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.pollDiffStats()
        }
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.tickInterval, repeats: true
        ) { [weak self] _ in
            self?.tick()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Update the session lists to poll.
    public func updateTargets(
        diffStats: [DiffStatsTarget],
        pr: [PRTarget]
    ) {
        diffStatsTargets = diffStats
        prTargets = pr

        // Clean up caches for sessions that are no longer active
        let activeSessionIds = Set(diffStats.map(\.sessionId))
        lastDiffStatsUpdate = lastDiffStatsUpdate.filter { activeSessionIds.contains($0.key) }
        lastDiffStatsValue = lastDiffStatsValue.filter { activeSessionIds.contains($0.key) }

        let activeCwds = Set(diffStats.map(\.cwd))
        defaultBranchCache = defaultBranchCache.filter { activeCwds.contains($0.key) }
    }

    // MARK: - Tick

    private func tick() {
        tickCount += 1

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.pollDiffStats()

            if self.tickCount % Self.prTickModulo == 0 {
                self.pollPRs()
            }
        }
    }

    // MARK: - Diff stats

    private func pollDiffStats() {
        let targets = diffStatsTargets
        let now = Date()
        for target in targets {
            // Debounce: skip if updated recently
            if let last = lastDiffStatsUpdate[target.sessionId],
                now.timeIntervalSince(last) < Self.diffStatsDebounce
            {
                continue
            }

            guard let stats = fetchDiffStats(cwd: target.cwd) else { continue }

            lastDiffStatsUpdate[target.sessionId] = now

            // Only fire callback if the value actually changed
            if lastDiffStatsValue[target.sessionId] == stats { continue }
            lastDiffStatsValue[target.sessionId] = stats

            DispatchQueue.main.async { [weak self] in
                self?.onDiffStats(target.sessionId, stats)
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
        // Try symbolic-ref first
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

        // Fallback: try main then master
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

    // MARK: - PR lookup

    private func pollPRs() {
        let targets = prTargets
        guard !targets.isEmpty else { return }

        // Cache gh availability per app session
        if ghAvailable == nil {
            ghAvailable = Self.isGHAvailable()
        }
        guard ghAvailable == true else {
            debugLog("[GitInfoPoller] gh CLI not available, skipping PR lookup")
            return
        }

        for target in targets {
            fetchPR(target: target)
        }
    }

    private func fetchPR(target: PRTarget) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "gh", "pr", "list",
            "--repo", target.repo,
            "--head", target.branch,
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
            return
        }

        guard process.terminationStatus == 0 else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return }

        struct GHPREntry: Decodable {
            let number: Int
            let url: String
            let title: String
        }

        guard let entries = try? JSONDecoder().decode([GHPREntry].self, from: data),
            let first = entries.first
        else { return }

        let info = PRInfo(number: first.number, url: first.url, title: first.title)
        debugLog("[GitInfoPoller] Found PR #\(info.number) for \(target.repo):\(target.branch)")
        DispatchQueue.main.async { [weak self] in
            self?.onPRInfo(target.sessionId, info)
        }
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
