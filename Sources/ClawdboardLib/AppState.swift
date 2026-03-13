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

    // MARK: - UI State

    public var expandedSessionId: String?

    // MARK: - Dependencies

    private var stateWatcher: SessionStateWatcher?
    private var remoteWatcher: RemoteSessionWatcher?

    /// Remote sessions keyed by host identifier
    private var remoteSessions: [String: [AgentSession]] = [:]

    /// Local sessions from the local watcher
    private var localSessions: [AgentSession] = []

    private static let remoteHostsKey = "remoteHosts"

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
    }

    public func stop() {
        stateWatcher?.stop()
        stateWatcher = nil
        remoteWatcher?.stop()
        remoteWatcher = nil
    }

    // MARK: - Remote Host Management

    public func addRemoteHost() {
        let host = RemoteHost(host: "", label: "")
        remoteHosts.append(host)
        saveRemoteHosts()
    }

    public func updateRemoteHost(at index: Int, with host: RemoteHost) {
        guard remoteHosts.indices.contains(index) else { return }
        let oldId = remoteHosts[index].host
        remoteHosts[index] = host

        // If host identifier changed, clear old sessions
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

    // MARK: - Session Merging

    private func rebuildSessions() {
        let now = Date()

        // Process local sessions with debounce/staleness logic
        let processedLocal = localSessions.compactMap { session -> AgentSession? in
            var s = session
            if s.model == nil {
                guard let started = s.startedAt, now.timeIntervalSince(started) < 60 else {
                    return nil
                }
            }
            if let updatedAt = s.updatedAt {
                let age = now.timeIntervalSince(updatedAt)
                if s.status == .pendingWaiting, age >= 3.0 {
                    s.status = .waiting
                }
                if s.status == .working, age >= 30.0 {
                    s.status = .waiting
                }
            }
            return s
        }

        // Process remote sessions — apply same debounce/staleness but skip PID checks
        // (PID liveness was already skipped in RemoteSessionWatcher)
        let processedRemote = remoteSessions.values.flatMap { $0 }.compactMap {
            session -> AgentSession? in
            var s = session
            if s.model == nil {
                guard let started = s.startedAt, now.timeIntervalSince(started) < 60 else {
                    return nil
                }
            }
            if let updatedAt = s.updatedAt {
                let age = now.timeIntervalSince(updatedAt)
                if s.status == .pendingWaiting, age >= 3.0 {
                    s.status = .waiting
                }
                if s.status == .working, age >= 30.0 {
                    s.status = .waiting
                }
            }
            return s
        }

        sessions = processedLocal + processedRemote
    }

    // MARK: - Computed Properties

    /// Sessions sorted by urgency: waiting > working > unknown
    public var sortedSessions: [AgentSession] {
        sessions.sorted { a, b in
            let aOrder = a.displayStatus.sortOrder
            let bOrder = b.displayStatus.sortOrder
            if aOrder != bOrder { return aOrder < bOrder }
            // Within same status, sort by most recently updated
            return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
        }
    }

    /// Sessions that are actively doing something (working or waiting for input)
    public var activeSessions: [AgentSession] {
        sortedSessions.filter { $0.displayStatus != .unknown }
    }

    /// Number of sessions needing permission approval (most urgent)
    public var needsApprovalCount: Int {
        sessions.count { $0.displayStatus == .needsApproval }
    }

    /// Number of sessions waiting for user input
    public var waitingCount: Int {
        sessions.count { $0.displayStatus == .waiting }
    }

    /// Number of sessions actively working
    public var workingCount: Int {
        sessions.count { $0.displayStatus == .working }
    }

    /// Total cost across all sessions
    public var totalCost: Double {
        sessions.compactMap(\.costUsd).reduce(0, +)
    }

    public var formattedTotalCost: String {
        String(format: "$%.2f", totalCost)
    }

    // MARK: - Actions

    public func toggleExpanded(sessionId: String) {
        if expandedSessionId == sessionId {
            expandedSessionId = nil
        } else {
            expandedSessionId = sessionId
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
