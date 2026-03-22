import Foundation

/// Reactive PR status checker for active sessions.
///
/// Triggered by `updateTargets()` (called when sessions change via `rebuildSessions()`).
/// Uses a 30s per-session debounce since PR status changes infrequently.
///
/// Persists cache to `~/.clawdboard/pr-status-cache.json` so PR status
/// is available immediately on app launch without waiting for `gh` fetches.
/// All `gh` commands run off the main thread on `.utility` QoS.
public class PRStatusProvider {
    /// Minimum seconds between PR status checks for the same session.
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
    }

    // MARK: - Serial queue protecting all mutable state

    private let queue = DispatchQueue(label: "clawdboard.pr-status-provider", qos: .utility)

    // MARK: - Cache (persisted to disk)

    /// Cached PR status keyed by session ID. Access only from `queue`.
    private var _prStatusCache: [String: PRStatus] = [:]

    /// Thread-safe snapshot of PR status cache.
    public var prStatusCache: [String: PRStatus] {
        queue.sync { _prStatusCache }
    }

    // MARK: - Session tracking

    private var targets: [PRStatusTarget] = []

    /// Tracks when PR status was last fetched per session (for debounce).
    private var lastFetch: [String: Date] = [:]

    /// Whether `gh` CLI is available. Checked once on first fetch.
    private var ghAvailable: Bool?

    // MARK: - gh CLI path

    /// Resolved path to `gh` binary. Cached after first lookup.
    private var ghPath: String?

    // MARK: - Init

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        loadCache()
    }

    /// Update session targets and trigger a debounced PR status refresh.
    public func updateTargets(_ newTargets: [PRStatusTarget]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.targets = newTargets

            // Clean up caches for sessions that are no longer active
            let activeIds = Set(newTargets.map(\.sessionId))
            self.lastFetch = self.lastFetch.filter { activeIds.contains($0.key) }
            let cacheChanged = self._prStatusCache.keys.contains(where: { !activeIds.contains($0) })
            self._prStatusCache = self._prStatusCache.filter { activeIds.contains($0.key) }
            if cacheChanged { self.saveCache() }

            let snapshot = self.targets
            guard !snapshot.isEmpty else { return }
            self.fetchAll(snapshot)
        }
    }

    // MARK: - Disk persistence

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheFile),
            let dict = try? JSONDecoder().decode([String: PRStatus].self, from: data)
        else { return }
        _prStatusCache = dict
    }

    /// Save cache to disk. Must be called from `queue`.
    private func saveCache() {
        guard let data = try? JSONEncoder().encode(_prStatusCache) else { return }
        try? data.write(to: Self.cacheFile, options: .atomic)
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

        for target in targets {
            // Debounce: skip if fetched recently
            if let last = lastFetch[target.sessionId],
                now.timeIntervalSince(last) < Self.prStatusDebounce
            {
                continue
            }

            guard let status = fetchPRStatus(repo: target.githubRepo, branch: target.gitBranch)
            else { continue }

            lastFetch[target.sessionId] = now

            if _prStatusCache[target.sessionId] != status {
                _prStatusCache[target.sessionId] = status
                anyChanged = true
            }
        }

        if anyChanged {
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

    /// Run `gh pr list --head <branch> --repo <repo> --json state --limit 1`.
    private func fetchPRStatus(repo: String, branch: String) -> PRStatus? {
        guard let gh = resolveGhPath() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = [
            "pr", "list",
            "--head", branch,
            "--repo", repo,
            "--json", "state",
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
            return .none
        }

        switch state {
        case "OPEN":
            return .open
        case "MERGED":
            return .merged
        case "CLOSED":
            return .closed
        default:
            return .none
        }
    }
}
