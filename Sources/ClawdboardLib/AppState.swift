import Foundation
import Observation

/// Central app state — reads session state files written by hooks
/// and provides computed properties for the UI.
@Observable
public class AppState {
    // MARK: - Session Data

    public var sessions: [AgentSession] = []

    // MARK: - Remote Hosts

    public var remoteHosts: [RemoteHost] = []

    // MARK: - Usage Limits (Claude API)

    public var usageLimits: UsageLimitsData?
    public var usageLimitsError: String?

    // MARK: - UI State

    public var expandedSessionId: String?

    // MARK: - Dependencies

    private var stateWatcher: SessionStateWatcher?
    private var remoteWatcher: RemoteSessionWatcher?
    private var usageLimitsWatcher: UsageLimitsWatcher?

    /// Remote sessions keyed by host identifier
    private var remoteSessions: [String: [AgentSession]] = [:]

    /// Local sessions from the local watcher
    private var localSessions: [AgentSession] = []

    private static let remoteHostsKey = "remoteHosts"

    private let sessionsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawdboard/sessions")
    }()

    public init() {
        loadRemoteHosts()
    }

    // MARK: - Lifecycle

    public func start() {
        stateWatcher = SessionStateWatcher { [weak self] hookSessions in
            self?.localSessions = hookSessions
            self?.rebuildSessions()
        }
        stateWatcher?.start()

        startRemoteWatcher()
        startUsageLimitsWatcher()
    }

    public func stop() {
        stateWatcher?.stop()
        stateWatcher = nil
        remoteWatcher?.stop()
        remoteWatcher = nil
        usageLimitsWatcher?.stop()
        usageLimitsWatcher = nil
    }

    // MARK: - Remote Host Management

    public func addRemoteHost(host: String = "", label: String = "") {
        let entry = RemoteHost(host: host, label: label)
        remoteHosts.append(entry)
        saveRemoteHosts()
        if !host.isEmpty {
            remoteWatcher?.updateHosts(remoteHosts)
        }
    }

    public func updateRemoteHost(at index: Int, with host: RemoteHost) {
        guard remoteHosts.indices.contains(index) else { return }
        let oldId = remoteHosts[index].host
        remoteHosts[index] = host

        if oldId != host.host {
            remoteSessions.removeValue(forKey: oldId)
        }

        saveRemoteHosts()
        remoteWatcher?.updateHosts(remoteHosts)
        rebuildSessions()
    }

    public func removeRemoteHost(at index: Int) {
        guard remoteHosts.indices.contains(index) else { return }
        let hostId = remoteHosts[index].host
        remoteHosts.remove(at: index)
        remoteSessions.removeValue(forKey: hostId)
        saveRemoteHosts()
        remoteWatcher?.updateHosts(remoteHosts)
        rebuildSessions()
    }

    // MARK: - Session Deletion

    /// Delete a session's state file, removing it from the UI.
    public func deleteSession(_ sessionId: String) {
        let file = sessionsDir.appendingPathComponent("\(sessionId).json")
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Persistence

    private func saveRemoteHosts() {
        if let data = try? JSONEncoder().encode(remoteHosts) {
            UserDefaults.standard.set(data, forKey: Self.remoteHostsKey)
        }
    }

    private func loadRemoteHosts() {
        guard let data = UserDefaults.standard.data(forKey: Self.remoteHostsKey),
            let hosts = try? JSONDecoder().decode([RemoteHost].self, from: data)
        else { return }
        remoteHosts = hosts
    }

    // MARK: - Remote Watcher

    private func startRemoteWatcher() {
        remoteWatcher = RemoteSessionWatcher { [weak self] host, sessions in
            self?.remoteSessions[host] = sessions
            self?.rebuildSessions()
        }
        remoteWatcher?.updateHosts(remoteHosts)
    }

    // MARK: - Usage Limits Watcher

    private func startUsageLimitsWatcher() {
        guard usageLimitsWatcher == nil else { return }
        usageLimitsWatcher = UsageLimitsWatcher(
            onChange: { [weak self] data in
                self?.usageLimits = data
            },
            onError: { [weak self] error in
                self?.usageLimitsError = error
            }
        )
        usageLimitsWatcher?.start()
    }

    /// Manually refresh usage limits.
    public func refreshUsageLimits() {
        usageLimitsWatcher?.refresh()
    }

    // MARK: - Session Merging

    private func rebuildSessions() {
        let now = Date()

        let processedLocal = localSessions.compactMap { session -> AgentSession? in
            processSession(session, now: now)
        }

        let processedRemote = remoteSessions.values.flatMap { $0 }.compactMap {
            session -> AgentSession? in
            processSession(session, now: now)
        }

        var all = processedLocal + processedRemote

        // Auto-delete stale sessions if configured (0 = never)
        let autoDeleteHours = UserDefaults.standard.double(forKey: "autoDeleteHours")
        if autoDeleteHours > 0 {
            all.removeAll { session in
                guard let updated = session.updatedAt ?? session.startedAt else { return false }
                let age = now.timeIntervalSince(updated) / 3600.0
                if age >= autoDeleteHours {
                    deleteSession(session.sessionId)
                    return true
                }
                return false
            }
        }

        sessions = all
    }

    // MARK: - Session Processing

    /// Apply ghost filtering, debounce, staleness, and abandoned logic to a session.
    private func processSession(_ session: AgentSession, now: Date) -> AgentSession? {
        var s = session

        // Ghost session filter: no model means the session never produced output
        if s.model == nil {
            if let started = s.startedAt, let updated = s.updatedAt {
                let neverUpdated = abs(updated.timeIntervalSince(started)) < 1.0
                if neverUpdated, now.timeIntervalSince(started) > 30 {
                    return nil
                }
                if now.timeIntervalSince(updated) > 300 {
                    return nil
                }
            }
            guard let started = s.startedAt, now.timeIntervalSince(started) < 60 else {
                return nil
            }
        }

        if let updatedAt = s.updatedAt {
            let age = now.timeIntervalSince(updatedAt)
            if s.status == .pendingWaiting, age >= 1.5 {
                s.status = .waiting
            }
            if s.status == .working, age >= 15.0 {
                s.status = .waiting
            }
            if s.status == .waiting, age >= 600.0 {
                s.status = .abandoned
            }
        }
        return s
    }

    // MARK: - Computed Properties

    /// Sessions sorted by start time, newest first (stable order).
    public var sortedSessions: [AgentSession] {
        sessions.sorted { a, b in
            (a.startedAt ?? .distantPast) > (b.startedAt ?? .distantPast)
        }
    }

    /// Sessions that are actively doing something (working or waiting for input)
    public var activeSessions: [AgentSession] {
        sortedSessions.filter {
            $0.displayStatus != .unknown && $0.displayStatus != .abandoned
        }
    }

    public var needsApprovalCount: Int {
        sessions.count { $0.displayStatus == .needsApproval }
    }

    public var waitingCount: Int {
        sessions.count { $0.displayStatus == .waiting }
    }

    public var workingCount: Int {
        sessions.count { $0.displayStatus == .working }
    }

    // MARK: - Actions

    public func toggleExpanded(sessionId: String) {
        if expandedSessionId == sessionId {
            expandedSessionId = nil
        } else {
            expandedSessionId = sessionId
        }
    }

    public func focusITerm2Session(_ session: AgentSession) {
        guard let uuid = session.iterm2SessionId else { return }
        let focusScript = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawdboard/iterm2-focus.py")
        guard FileManager.default.fileExists(atPath: focusScript.path) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [focusScript.path, uuid]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async {
            try? task.run()
            task.waitUntilExit()
        }
    }
}

// MARK: - Display Status Helper

extension AgentSession {
    /// The status to show in the UI, accounting for debounce
    /// (pending_waiting shows as "working" until debounced to "waiting")
    public var displayStatus: AgentStatus {
        switch status {
        case .pendingWaiting: return .working
        default: return status
        }
    }
}
