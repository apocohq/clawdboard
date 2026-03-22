import Foundation

/// Reactive PR status checker for active sessions.
///
/// Triggered by `updateTargets()` (called when sessions change via `rebuildSessions()`).
/// Uses a 30s per-session debounce since PR status changes infrequently.
///
/// Persists cache to `~/.clawdboard/pr-status-cache.json` keyed by `repo:branch`
/// so PR status survives app restarts and is shared across sessions on the same branch.
/// All `gh` commands run off the main thread on `.utility` QoS.
public class PRStatusProvider {
    /// Minimum seconds between PR status checks for the same repo:branch.
    private static let prStatusDebounce: TimeInterval = 30

    private static let cacheFile: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawdboard/pr-status-cache.json")
    }()

    // MARK: - Callback

    /// Called on main queue when PR status changes.
    private let onChange: () -> Void

    // MARK: - Types

    public struct PRStatusTarget {
        public let sessionId: String
        public let githubRepo: String
        public let gitBranch: String

        /// Stable cache key independent of session ID.
        var cacheKey: String { "\(githubRepo):\(gitBranch)" }
    }

    // MARK: - Serial queue protecting all mutable state

    private let queue = DispatchQueue(label: "clawdboard.pr-status-provider", qos: .utility)

    // MARK: - Cache (persisted to disk)

    /// Cached PR info keyed by `repo:branch`. Access only from `queue`.
    private var _diskCache: [String: PRInfo] = [:]

    /// Resolved PR info keyed by session ID (derived from _diskCache + targets).
    /// Access only from `queue`.
    private var _sessionCache: [String: PRInfo] = [:]

    /// Thread-safe snapshot of PR info cache keyed by session ID.
    public var prInfoCache: [String: PRInfo] {
        queue.sync { _sessionCache }
    }

    /// Look up PR info from disk cache by repo:branch (bypasses session mapping).
    /// Useful for immediate cache hits before `updateTargets` has run.
    public func cachedInfo(repo: String, branch: String) -> PRInfo? {
        queue.sync { _diskCache["\(repo):\(branch)"] }
    }

    // MARK: - Session tracking

    private var targets: [PRStatusTarget] = []

    /// Tracks when PR status was last fetched per repo:branch (for debounce).
    private var lastFetch: [String: Date] = [:]

    /// Whether `gh` CLI is available. Checked once on first fetch.
    private var ghAvailable: Bool?

    // MARK: - gh CLI path

    /// Resolved path to `gh` binary. Cached after first lookup.
    private var ghPath: String?

    // MARK: - Init

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        queue.sync { loadCache() }
    }

    /// Update session targets and trigger a debounced PR status refresh.
    public func updateTargets(_ newTargets: [PRStatusTarget]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.targets = newTargets

            // Clean up debounce tracking for repo:branches no longer active
            let activeCacheKeys = Set(newTargets.map(\.cacheKey))
            self.lastFetch = self.lastFetch.filter { activeCacheKeys.contains($0.key) }

            // Rebuild session cache from disk cache + current targets
            self.rebuildSessionCache()

            let snapshot = self.targets
            guard !snapshot.isEmpty else { return }
            self.fetchAll(snapshot)
        }
    }

    // MARK: - Disk persistence

    /// Load disk cache. Must be called from `queue`.
    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheFile),
            let dict = try? JSONDecoder().decode([String: PRInfo].self, from: data)
        else { return }
        _diskCache = dict
    }

    /// Save disk cache. Must be called from `queue`.
    private func saveCache() {
        guard let data = try? JSONEncoder().encode(_diskCache) else { return }
        try? data.write(to: Self.cacheFile, options: .atomic)
    }

    /// Rebuild session ID → PRInfo mapping from disk cache + current targets.
    /// Must be called from `queue`.
    private func rebuildSessionCache() {
        var sessionCache: [String: PRInfo] = [:]
        for target in targets {
            if let info = _diskCache[target.cacheKey] {
                sessionCache[target.sessionId] = info
            }
        }
        _sessionCache = sessionCache
    }

    // MARK: - PR status fetching

    private func fetchAll(_ targets: [PRStatusTarget]) {
        // Check gh availability once
        if ghAvailable == nil {
            ghAvailable = resolveGhPath() != nil
        }
        guard ghAvailable == true else { return }

        let now = Date()
        var anyChanged = false

        // Deduplicate by cache key — multiple sessions may share the same repo:branch
        var seen = Set<String>()
        for target in targets {
            let key = target.cacheKey
            guard seen.insert(key).inserted else { continue }

            // Debounce: skip if fetched recently
            if let last = lastFetch[key],
                now.timeIntervalSince(last) < Self.prStatusDebounce
            {
                continue
            }

            guard let info = fetchPRInfo(repo: target.githubRepo, branch: target.gitBranch)
            else { continue }

            lastFetch[key] = now

            if _diskCache[key] != info {
                _diskCache[key] = info
                anyChanged = true
            }
        }

        if anyChanged {
            rebuildSessionCache()
            saveCache()
            DispatchQueue.main.async { [weak self] in
                self?.onChange()
            }
        }
    }

    /// Resolve `gh` binary path using /usr/bin/which.
    private func resolveGhPath() -> String? {
        if let cached = ghPath { return cached }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["gh"]
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
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        ghPath = path
        return path
    }

    /// Run `gh pr list --head <branch> --repo <repo> --json state,url --limit 1`.
    private func fetchPRInfo(repo: String, branch: String) -> PRInfo? {
        guard let gh = resolveGhPath() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = [
            "pr", "list",
            "--head", branch,
            "--repo", repo,
            "--json", "state,url",
            "--limit", "1",
            "--state", "all",
        ]
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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        guard let first = json.first, let state = first["state"] as? String else {
            return PRInfo(status: .none)
        }

        let prUrl = first["url"] as? String

        switch state {
        case "OPEN":
            return PRInfo(status: .open, url: prUrl)
        case "MERGED":
            return PRInfo(status: .merged, url: prUrl)
        case "CLOSED":
            return PRInfo(status: .closed, url: prUrl)
        default:
            return PRInfo(status: .none)
        }
    }
}
