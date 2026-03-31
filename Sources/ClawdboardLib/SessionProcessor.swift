import Foundation

/// Single source of truth for session state computation.
///
/// Python hook + watcher daemon manage all state in session JSON files.
/// This processor derives display status and applies lifecycle rules.
public struct SessionProcessor {

    // MARK: - Public API

    /// Process a raw session from state files into a display-ready session.
    /// Returns nil if the session should be filtered out (ghost).
    public func process(_ session: AgentSession, now: Date) -> AgentSession? {
        var s = session

        if isGhost(s, now: now) { return nil }

        s.status = deriveStatus(s)

        // Abandoned: waiting for 10+ minutes
        if s.status == .waiting, let updatedAt = s.updatedAt,
            now.timeIntervalSince(updatedAt) >= 600.0
        {
            s.status = .abandoned
        }

        return s
    }

    // MARK: - Status Derivation

    /// Status is derived by the Python hook and written to JSON.
    /// Swift just reads it, defaulting to .waiting for missing/unknown values.
    private func deriveStatus(_ session: AgentSession) -> AgentStatus {
        session.status != .unknown ? session.status : .waiting
    }

    // MARK: - Ghost Filtering

    /// Ghost sessions never produced output (no model set). Filter them after grace periods.
    /// Sessions with activeTools or agentWorking are never ghosts — they're actively tracked.
    private func isGhost(_ session: AgentSession, now: Date) -> Bool {
        // If we have active tool tracking, the session is real
        if let tools = session.activeTools, !tools.isEmpty { return false }
        if session.agentWorking == true { return false }

        guard session.model == nil else { return false }
        if let started = session.startedAt, let updated = session.updatedAt {
            let neverUpdated = abs(updated.timeIntervalSince(started)) < 1.0
            if neverUpdated, now.timeIntervalSince(started) > 30 { return true }
            if now.timeIntervalSince(updated) > 300 { return true }
        }
        guard let started = session.startedAt, now.timeIntervalSince(started) < 60 else {
            return true
        }
        return false
    }
}
