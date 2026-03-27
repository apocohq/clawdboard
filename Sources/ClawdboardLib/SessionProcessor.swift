import Foundation

/// Single source of truth for session state computation.
///
/// The hook script writes per-agent facts (main_agent_status, pending_tool_use_id, etc.).
/// This processor derives the session-level status from those facts, resolves blind spots
/// via transcript parsing and process inspection, and applies debounce/lifecycle rules.
public struct SessionProcessor {

    // MARK: - Public API

    /// Process a raw session from a state file into a display-ready session.
    /// Returns nil if the session should be filtered out (ghost, dead PID).
    public func process(_ session: AgentSession, now: Date) -> AgentSession? {
        var s = session

        // Filter ghost sessions (never produced output)
        if isGhost(s, now: now) { return nil }

        // Derive session status from per-agent data (authoritative, ignores hook's computed status)
        s.status = deriveStatus(s)

        guard let updatedAt = s.updatedAt else { return s }
        let age = now.timeIntervalSince(updatedAt)

        // Resolve blind spots where hooks don't fire
        if age >= 2.0 {
            resolveViaTranscript(&s)
        }
        if s.status == .needsApproval {
            resolveViaProcessInspection(&s)
        }

        // Interrupted session: transcript ends with "[Request interrupted by user]"
        // but no Stop hook fires. An interrupt kills ALL agents (main + subagents)
        // since SubagentStop won't fire for killed subagents.
        if age >= 2.0, s.status != .waiting, s.status != .abandoned,
            let tp = s.transcriptPath, isTranscriptInterrupted(tp)
        {
            s.mainAgentStatus = .waiting
            if var subs = s.subagents {
                for i in subs.indices { subs[i].status = .waiting }
                s.subagents = subs
            }
            s.status = deriveStatus(s)
        }

        // Abandoned: waiting for 10+ minutes
        if s.status == .waiting, age >= 600.0 {
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

    // MARK: - Transcript Resolution

    /// Check each agent's transcript for tool resolution (completion or rejection).
    /// Handles the blind spot where hooks don't fire on rejection/interruption.
    private func resolveViaTranscript(_ session: inout AgentSession) {
        var changed = false

        // Main agent
        if let toolId = session.mainPendingToolUseId, !toolId.isEmpty,
            let tp = session.transcriptPath
        {
            if let resolution = findToolResult(in: tp, for: toolId) {
                session.mainAgentStatus = resolution.isRejection ? .waiting : .working
                session.mainPendingToolUseId = nil
                changed = true
            }
        }

        // Subagents (each has its own isolated transcript)
        if var subs = session.subagents {
            for i in subs.indices {
                if let toolId = subs[i].pendingToolUseId, !toolId.isEmpty,
                    let tp = subs[i].transcriptPath
                {
                    if let resolution = findToolResult(in: tp, for: toolId) {
                        subs[i].status = resolution.isRejection ? .waiting : .working
                        subs[i].pendingToolUseId = nil
                        changed = true
                    }
                }
            }
            if changed { session.subagents = subs }
        }

        if changed {
            session.status = deriveStatus(session)
        }
    }

    /// Read the last ~4KB of a transcript and look for a tool_result matching the tool_use_id.
    private func findToolResult(in transcriptPath: String, for toolUseId: String) -> ToolResult? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize = min(UInt64(4096), fileSize)
        guard readSize > 0 else { return nil }
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readData(ofLength: Int(readSize))

        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // tool_result entries use "tool_use_id" key; tool_use entries use "id" key.
        let lines = text.components(separatedBy: "\n")
        for line in lines.reversed() {
            guard line.contains(toolUseId),
                line.contains("tool_use_id")
            else { continue }
            let isRejection =
                line.contains("User rejected tool use")
                || line.contains("Request interrupted by user")
            return ToolResult(isRejection: isRejection)
        }
        return nil
    }

    // MARK: - Interruption Detection

    /// Check if the very last transcript entry is "[Request interrupted by user]".
    /// Only the last line matters — if anything happened after the interrupt, it's stale.
    private func isTranscriptInterrupted(_ transcriptPath: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return false }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize = min(UInt64(2048), fileSize)
        guard readSize > 0 else { return false }
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readData(ofLength: Int(readSize))

        guard let text = String(data: data, encoding: .utf8) else { return false }

        // Find the last non-empty line
        let lines = text.components(separatedBy: "\n")
        guard let lastLine = lines.last(where: { !$0.isEmpty }) else { return false }
        return lastLine.contains("Request interrupted by user")
    }

    // MARK: - Process Inspection

    /// If any agent is waiting for approval but its command is already running
    /// as a child process, transition that agent to working. Matches the exact command
    /// string from the PermissionRequest against child process args.
    private func resolveViaProcessInspection(_ session: inout AgentSession) {
        guard let pid = session.pid else { return }
        let parentPid = pid_t(pid)
        var changed = false

        // Check main agent
        if session.mainAgentStatus == .needsApproval,
            let cmd = session.pendingToolCommand, !cmd.isEmpty,
            isCommandRunning(cmd, underParent: parentPid)
        {
            session.mainAgentStatus = .working
            changed = true
        }

        // Check subagents
        if var subs = session.subagents {
            for i in subs.indices {
                if subs[i].status == .needsApproval,
                    let cmd = subs[i].pendingToolCommand, !cmd.isEmpty,
                    isCommandRunning(cmd, underParent: parentPid)
                {
                    subs[i].status = .working
                    changed = true
                }
            }
            if changed { session.subagents = subs }
        }

        if changed {
            session.status = deriveStatus(session)
        }
    }

    /// Check if a specific command is running as a child (or grandchild) of a process.
    private func isCommandRunning(_ command: String, underParent parentPid: pid_t) -> Bool {
        let allProcs = listAllProcesses()
        guard !allProcs.isEmpty else { return false }

        // Collect direct children + grandchildren (Claude -> bash -> actual command)
        var childPids: [pid_t] = []
        for proc in allProcs where proc.parentPid == parentPid {
            childPids.append(proc.pid)
        }
        let directChildren = Set(childPids)
        for proc in allProcs where directChildren.contains(proc.parentPid) {
            childPids.append(proc.pid)
        }

        return childPids.contains { getProcessArgs($0)?.contains(command) == true }
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

    // MARK: - System Helpers

    private struct ProcessInfo {
        let pid: pid_t
        let parentPid: pid_t
    }

    private func listAllProcesses() -> [ProcessInfo] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&name, UInt32(name.count), &procs, &size, nil, 0) == 0 else {
            return []
        }
        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        return (0..<actualCount).map {
            ProcessInfo(pid: procs[$0].kp_proc.p_pid, parentPid: procs[$0].kp_eproc.e_ppid)
        }
    }

    /// Get the full command-line arguments for a process via KERN_PROCARGS2.
    private func getProcessArgs(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // Layout: int32 argc, then null-terminated strings. Convert nulls to spaces.
        let str = buffer.prefix(size).map { $0 == 0 ? UInt8(0x20) : $0 }
        return String(bytes: str, encoding: .utf8)
    }
}

// MARK: - Supporting Types

private struct ToolResult {
    let isRejection: Bool
}
