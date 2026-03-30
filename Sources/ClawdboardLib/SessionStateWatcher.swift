import Foundation

/// Watches ~/.clawdboard/sessions/ for state file changes written by Claude hooks
/// and the Python watcher daemon. Uses DispatchSource file system monitoring for
/// instant detection. PID liveness cleanup is handled by the watcher daemon.
public class SessionStateWatcher {
    private let sessionsDir: URL
    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private let onChange: ([AgentSession]) -> Void
    private let ioQueue = DispatchQueue(label: "clawdboard.session-watcher", qos: .utility)

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

        // Initial read (on background queue to avoid blocking startup)
        ioQueue.async { [weak self] in
            self?.notifyChanges()
        }

        // Set up DispatchSource for directory monitoring — fires instantly on file writes
        fileDescriptor = open(sessionsDir.path, O_EVTONLY)
        if fileDescriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: [.write, .delete, .rename],
                queue: ioQueue
            )
            source.setEventHandler { [weak self] in
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
    }

    /// Stop watching
    public func stop() {
        dispatchSource?.cancel()
        dispatchSource = nil
    }

    /// Read all state files on background queue, then deliver results on main thread
    private func notifyChanges() {
        let start = CFAbsoluteTimeGetCurrent()
        let sessions = readAllSessions()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if elapsed > 50 {
            debugLog(
                "[SessionWatcher] notifyChanges took \(Int(elapsed))ms (\(sessions.count) sessions)"
            )
        }
        DispatchQueue.main.async { [weak self] in
            self?.onChange(sessions)
        }
    }

    /// Read all session state files from the sessions directory.
    /// Each session is a single {uuid}.json file containing all state including active_tools.
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

        // Only read session JSON files — skip .lock, .tmp, and legacy .agent. files
        let sessionFiles = files.filter { url in
            let name = url.lastPathComponent
            return url.pathExtension == "json"
                && !name.contains(".agent.")
                && !name.contains(".tmp.")
        }

        return sessionFiles.compactMap { url -> AgentSession? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(AgentSession.self, from: data)
        }
    }

    deinit {
        stop()
    }
}
