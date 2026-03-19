import Foundation

/// Polls `gh pr list` to discover open PRs for active sessions.
/// Runs on a 60-second timer. Only queries sessions that have
/// a `githubRepo` + `gitBranch` but no `prUrl` yet.
/// Stops polling a session once a PR is found.
public class GitHubPRPoller {
    private static let pollInterval: TimeInterval = 60
    private var timer: Timer?
    private let onChange: (String, PRInfo) -> Void

    /// PR info discovered by the poller.
    public struct PRInfo {
        public let number: Int
        public let url: String
        public let title: String
    }

    /// Closure receives (sessionId, PRInfo) when a PR is found.
    public init(onChange: @escaping (String, PRInfo) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval, repeats: true
        ) { [weak self] _ in
            self?.pollRequested()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Sessions to poll — set by AppState before each cycle.
    private var pendingSessions: [(id: String, repo: String, branch: String)] = []

    /// Update the list of sessions that need PR lookup.
    public func updateSessions(_ sessions: [(id: String, repo: String, branch: String)]) {
        pendingSessions = sessions
    }

    private func pollRequested() {
        let sessions = pendingSessions
        guard !sessions.isEmpty else { return }

        // Check gh CLI availability once per cycle
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard Self.isGHAvailable() else {
                debugLog("[PRPoller] gh CLI not available, skipping")
                return
            }

            for session in sessions {
                self?.fetchPR(
                    sessionId: session.id, repo: session.repo, branch: session.branch)
            }
        }
    }

    private func fetchPR(sessionId: String, repo: String, branch: String) {
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
            debugLog("[PRPoller] Failed to run gh: \(error)")
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
        debugLog("[PRPoller] Found PR #\(info.number) for \(repo):\(branch)")
        DispatchQueue.main.async { [weak self] in
            self?.onChange(sessionId, info)
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
