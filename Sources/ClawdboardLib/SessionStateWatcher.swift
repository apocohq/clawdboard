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
                debugLog("[SessionWatcher] DispatchSource fired")
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

    /// Read all session + agent fact files from the sessions directory.
    /// Session metadata: {uuid}.json (no ".agent." in name)
    /// Agent facts: {uuid}.agent.{key}.json
    /// Merges agent facts into session objects.
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

        // Separate session files from agent fact files
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        let sessionFiles = jsonFiles.filter { !$0.lastPathComponent.contains(".agent.") }
        let agentFiles = jsonFiles.filter { $0.lastPathComponent.contains(".agent.") }

        // Index agent fact files by session ID
        var agentFactsBySession: [String: [(key: String, url: URL)]] = [:]
        for url in agentFiles {
            // Format: {session_id}.agent.{key}.json
            let name = url.deletingPathExtension().lastPathComponent
            guard let agentRange = name.range(of: ".agent.") else { continue }
            let sessionId = String(name[name.startIndex..<agentRange.lowerBound])
            let agentKey = String(name[agentRange.upperBound...])
            agentFactsBySession[sessionId, default: []].append((key: agentKey, url: url))
        }

        return sessionFiles.compactMap { url -> AgentSession? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard var session = try? decoder.decode(AgentSession.self, from: data) else {
                return nil
            }

            // Merge agent fact files into session
            if let agentEntries = agentFactsBySession[session.sessionId] {
                mergeAgentFacts(&session, from: agentEntries, decoder: decoder)
            }

            return session
        }
    }

    /// Merge agent fact files into a session.
    /// "main" agent populates mainAgentStatus and per-tool fields.
    /// Other agents become subagent entries.
    private func mergeAgentFacts(
        _ session: inout AgentSession,
        from entries: [(key: String, url: URL)],
        decoder: JSONDecoder
    ) {
        var subagents: [Subagent] = []

        for (key, url) in entries {
            guard let data = try? Data(contentsOf: url),
                let fact = try? decoder.decode(AgentFact.self, from: data)
            else { continue }

            // Extract pending tool info from the tools dict
            let (pendingToolId, pendingCommand) = Self.extractPendingTool(from: fact)

            if key == "main" {
                session.mainAgentStatus = fact.status
                session.mainPendingToolUseId = pendingToolId
                session.pendingToolCommand = pendingCommand
                // Use the most recent updatedAt between session and main agent
                if let factUpdated = fact.updatedAt {
                    if let sessionUpdated = session.updatedAt {
                        if factUpdated > sessionUpdated {
                            session.updatedAt = factUpdated
                        }
                    } else {
                        session.updatedAt = factUpdated
                    }
                }
            } else {
                // Subagent
                var sub = Subagent(
                    agentId: key,
                    agentType: fact.agentType ?? "unknown",
                    startedAt: fact.startedAt
                )
                sub.status = fact.status
                sub.pendingToolUseId = pendingToolId
                sub.pendingToolCommand = pendingCommand
                sub.transcriptPath = fact.transcriptPath
                subagents.append(sub)
            }
        }

        if !subagents.isEmpty {
            session.subagents = subagents
        }
    }

    /// Extract the first needs_approval tool's ID and command from a fact's tools dict.
    /// Falls back to any working tool's ID if none need approval.
    private static func extractPendingTool(from fact: AgentFact) -> (String?, String?) {
        guard let tools = fact.tools else { return (nil, nil) }
        // Prefer the tool that needs approval (for process inspection)
        for (toolId, tool) in tools {
            if tool.status == .needsApproval {
                return (toolId, tool.command)
            }
        }
        // Fall back to any working tool (for transcript resolution)
        for (toolId, tool) in tools {
            if tool.status == .working {
                return (toolId, nil)
            }
        }
        return (nil, nil)
    }

    deinit {
        stop()
    }
}
