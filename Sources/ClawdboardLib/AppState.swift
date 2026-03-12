import Foundation
import Observation

/// Central app state — reads session state files written by hooks
/// and provides computed properties for the UI.
@Observable
public class AppState {
    // MARK: - Session Data

    public var sessions: [AgentSession] = []

    // MARK: - UI State

    public var expandedSessionId: String?

    // MARK: - Dependencies

    private var stateWatcher: SessionStateWatcher?

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        stateWatcher = SessionStateWatcher { [weak self] hookSessions in
            self?.updateSessions(hookSessions: hookSessions)
        }
        stateWatcher?.start()
    }

    public func stop() {
        stateWatcher?.stop()
        stateWatcher = nil
    }

    // MARK: - Session Updates

    private func updateSessions(hookSessions: [AgentSession]) {
        let now = Date()
        sessions = hookSessions.map { session -> AgentSession in
            var s = session
            // Debounce: pending_waiting → waiting after 3 seconds
            if s.status == .pendingWaiting,
                let updatedAt = s.updatedAt,
                now.timeIntervalSince(updatedAt) >= 3.0
            {
                s.status = .waiting
            }
            // Staleness heuristic: if "working" but no update in 30s,
            // the session likely finished (e.g. user interrupted, or agent stopped
            // without the Stop hook firing). Mark as waiting.
            if s.status == .working,
                let updatedAt = s.updatedAt,
                now.timeIntervalSince(updatedAt) >= 30.0
            {
                s.status = .waiting
            }
            return s
        }
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
