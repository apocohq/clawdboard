import Foundation

/// Watches ~/.clawdboard/sessions/ for state file changes written by Claude hooks.
/// Uses DispatchSource file system monitoring for instant detection.
/// A separate low-frequency timer handles PID liveness cleanup for crashed sessions.
public class SessionStateWatcher {
    private let sessionsDir: URL
    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var cleanupTimer: Timer?
    private let onChange: ([AgentSession]) -> Void

    public init(sessionsDirectory: String? = nil, onChange: @escaping ([AgentSession]) -> Void) {
        let dir =
            sessionsDirectory
            ?? {
                let home = FileManager.default.homeDirectoryForCurrentUser
                return home.appendingPathComponent(".clawdboard/sessions").path
            }()
        self.sessionsDir = URL(fileURLWithPath: dir)
        self.onChange = onChange
    }

    /// Start watching for state file changes
    public func start() {
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        // Initial read
        notifyChanges()

        // Set up DispatchSource for directory monitoring — fires instantly on file writes
        fileDescriptor = open(sessionsDir.path, O_EVTONLY)
        if fileDescriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: [.write, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                NSLog("[SessionWatcher] DispatchSource fired")
                self?.notifyChanges()
            }
            source.setCancelHandler { [weak self] in
                if let fd = self?.fileDescriptor, fd >= 0 {
                    close(fd)
                }
            }
            source.resume()
            dispatchSource = source
        }

        // Short poll timer as backup for coalesced DispatchSource events.
        // DispatchSource may coalesce rapid writes (e.g. PreToolUse + Stop in quick succession),
        // so this ensures updates are picked up within a few seconds.
        // Also handles PID liveness cleanup for crashed sessions.
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) {
            [weak self] _ in
            self?.notifyChanges()
        }
    }

    /// Stop watching
    public func stop() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        dispatchSource?.cancel()
        dispatchSource = nil
    }

    /// Read all state files and notify
    private func notifyChanges() {
        let start = CFAbsoluteTimeGetCurrent()
        let sessions = readAllSessions()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if elapsed > 50 {
            NSLog("[SessionWatcher] notifyChanges took %.0fms (%d sessions)", elapsed, sessions.count)
        }
        onChange(sessions)
    }

    /// Read all .json state files from the sessions directory.
    /// Removes state files for processes that are no longer running.
    public func readAllSessions() -> [AgentSession] {
        let fm = FileManager.default
        guard
            let files = try? fm.contentsOfDirectory(
                at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey])
        else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files.compactMap { url -> AgentSession? in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard let session = try? decoder.decode(AgentSession.self, from: data) else {
                return nil
            }

            // Check if the Claude Code process is still alive
            if let pid = session.pid {
                if kill(pid_t(pid), 0) != 0 {
                    try? fm.removeItem(at: url)
                    return nil
                }
            } else if let updatedAt = session.updatedAt,
                Date().timeIntervalSince(updatedAt) > 120
            {
                // No PID (legacy state file) and stale for 2+ minutes — remove
                try? fm.removeItem(at: url)
                return nil
            }

            return session
        }
    }

    deinit {
        stop()
    }
}
