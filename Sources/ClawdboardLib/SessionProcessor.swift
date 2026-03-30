import Foundation

/// Single source of truth for session state computation.
///
/// The Python watcher daemon resolves blind spots (transcript parsing, process inspection)
/// and writes resolved state back to agent fact files. This processor only derives
/// the session-level status from those facts and applies lifecycle rules.
public struct SessionProcessor {

    // MARK: - Public API

    /// Process a raw session from state + fact files into a display-ready session.
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

    /// Compute session-level status from per-agent statuses.
    /// Priority: needs_approval > working > waiting.
    private func deriveStatus(_ session: AgentSession) -> AgentStatus {
        var statuses: [AgentStatus] = []
        if let main = session.mainAgentStatus { statuses.append(main) }
        for sub in session.subagents ?? [] {
            if let s = sub.status { statuses.append(s) }
        }
        if statuses.contains(.needsApproval) { return .needsApproval }
        if statuses.contains(.working) { return .working }
        if statuses.contains(.waiting) { return .waiting }
        return session.mainAgentStatus ?? session.status
    }

    // MARK: - Ghost Filtering

    /// Ghost sessions never produced output (no model set). Filter them after grace periods.
    private func isGhost(_ session: AgentSession, now: Date) -> Bool {
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
