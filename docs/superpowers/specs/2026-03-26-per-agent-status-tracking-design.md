# Per-Agent Status Tracking with Transcript Resolution

## Problem

Clawdboard's hook-based state tracking has blind spots where the UI shows stale status:

### 1. Rejections and interruptions are invisible to hooks

When a user rejects a tool or interrupts execution, `toolUseResult="User rejected tool use"` is written to the transcript but **no hook fires** (no PostToolUse, no Stop). The status stays stuck at `needs_approval` or `working` until the next unrelated hook event.

Empirically verified (test session `9b8189e8`):

```
12:17:05  PreToolUse hook               → working
12:17:05  PermissionRequest hook        → needs_approval
          ---- user rejects after 3s ----
12:17:08  toolUseResult="User rejected" → transcript only, NO HOOK
12:17:08  "[Request interrupted]"       → transcript only, NO HOOK
          ---- 3s blind spot ----
12:17:11  SessionEnd hook               → session removed
```

### 2. Subagent race conditions

A single `status` field per session gets overwritten by concurrent agents. Subagent A's `PermissionRequest` is clobbered when the main agent fires `PreToolUse`.

### 3. Long-running tool staleness

The 15-second staleness heuristic (`working → waiting`) fires during legitimate long-running tools.

## Solution: `pending_tool_use_id` Correlation

One mechanism handles all three problems.

**Core idea:** Every tool call has a unique `tool_use_id`. The hook stores it on PreToolUse. The transcript records the resolution (completion or rejection) against the same ID. By matching IDs, we can precisely detect when a tool was resolved — even when no hook fires.

### Per-Agent State

Each agent (main + subagents) tracks its own:
- `status` — current status
- `pending_tool_use_id` — set by PreToolUse, cleared by PostToolUse/Stop
- `transcript_path` — path to the agent's transcript file

The session-level `status` is computed from all agents for backward compatibility.

### Hook Changes (Python)

Route all status-changing events by `agent_id`. Store `pending_tool_use_id` from PreToolUse. Helper functions:

```python
def _set_agent_status(state, agent_id, status):
    """Set status for the correct agent (main or subagent)."""
    if agent_id:
        for sub in state.get("subagents", []):
            if sub["agent_id"] == agent_id:
                sub["status"] = status
                return
    else:
        state["main_agent_status"] = status

def _set_pending_tool(state, agent_id, tool_use_id):
    """Set or clear pending_tool_use_id for the correct agent."""
    if agent_id:
        for sub in state.get("subagents", []):
            if sub["agent_id"] == agent_id:
                sub["pending_tool_use_id"] = tool_use_id
                return
    else:
        state["main_pending_tool_use_id"] = tool_use_id

def recompute_session_status(state):
    """Derive session-level status from all agents."""
    statuses = [state.get("main_agent_status", "working")]
    for sub in state.get("subagents", []):
        s = sub.get("status")
        if s:
            statuses.append(s)

    if "needs_approval" in statuses:
        state["status"] = "needs_approval"
    elif "working" in statuses:
        state["status"] = "working"
    elif "pending_waiting" in statuses:
        state["status"] = "pending_waiting"
    elif "waiting" in statuses:
        state["status"] = "waiting"
    else:
        state["status"] = state.get("main_agent_status", "unknown")

    # Compute session-level pending flag
    any_pending = bool(state.get("main_pending_tool_use_id"))
    for sub in state.get("subagents", []):
        if sub.get("pending_tool_use_id"):
            any_pending = True
            break
    state["has_pending_tool"] = any_pending
```

Event routing:

| Event | What it does |
|---|---|
| PreToolUse | `status=working`, `pending_tool_use_id=hook_input["tool_use_id"]` |
| PermissionRequest | `status=needs_approval` (pending_tool_use_id stays — tool hasn't resolved) |
| PostToolUse / PostToolUseFailure | `status=working`, `pending_tool_use_id=None` |
| Stop | `status=pending_waiting`, `pending_tool_use_id=None` |
| StopFailure (NEW) | `status=pending_waiting`, `pending_tool_use_id=None` |
| UserPromptSubmit | `status=working` (main agent only) |
| Notification:permission_prompt | `status=needs_approval` (unless already working) |
| Notification:idle_prompt | `status=pending_waiting` (unless already working) |
| SubagentStart | Append to subagents with `transcript_path` from `agent_transcript_path` |
| SubagentStop | Remove from subagents, call `recompute_session_status()` |
| SessionStart | Set `main_agent_status=working`, store `transcript_path` |

All handlers call `recompute_session_status()` after updating per-agent state.

### Session JSON Shape

```json
{
  "status": "needs_approval",
  "main_agent_status": "needs_approval",
  "main_pending_tool_use_id": "toolu_01Wwv6w7xX85ZkKW97zHseWm",
  "has_pending_tool": true,
  "transcript_path": "/Users/x/.claude/projects/proj/session.jsonl",
  "subagents": [
    {
      "agent_id": "abc",
      "agent_type": "Explore",
      "started_at": "2026-03-26T09:00:00Z",
      "status": "working",
      "pending_tool_use_id": null,
      "transcript_path": "/Users/x/.claude/projects/proj/subagents/agent-abc.jsonl"
    }
  ]
}
```

### Swift Changes

**New model fields** (all optional for backward compat):

Subagent: `status: AgentStatus?`, `pendingToolUseId: String?`, `transcriptPath: String?`

AgentSession: `mainAgentStatus: AgentStatus?`, `mainPendingToolUseId: String?`, `hasPendingTool: Bool?`, `transcriptPath: String?`

**processSession() changes:**

```swift
private func processSession(_ session: AgentSession, now: Date) -> AgentSession? {
    var s = session

    // ... existing ghost filtering (unchanged) ...

    if let updatedAt = s.updatedAt {
        let age = now.timeIntervalSince(updatedAt)

        // NEW: Reactive transcript check for pending tools.
        // When a tool_use_id is pending and status hasn't changed for >2s,
        // check the transcript for a resolution (completion or rejection).
        if age >= 2.0 {
            var changed = false

            // Check main agent
            if let toolId = s.mainPendingToolUseId, !toolId.isEmpty,
               let tp = s.transcriptPath {
                if let resolution = checkToolResolution(transcriptPath: tp, toolUseId: toolId) {
                    s.mainAgentStatus = resolution.isRejection ? .waiting : .working
                    s.mainPendingToolUseId = nil
                    changed = true
                }
            }

            // Check each subagent
            if var subs = s.subagents {
                for i in subs.indices {
                    if let toolId = subs[i].pendingToolUseId, !toolId.isEmpty,
                       let tp = subs[i].transcriptPath {
                        if let resolution = checkToolResolution(transcriptPath: tp, toolUseId: toolId) {
                            subs[i].status = resolution.isRejection ? .waiting : .working
                            subs[i].pendingToolUseId = nil
                            changed = true
                        }
                    }
                }
                if changed { s.subagents = subs }
            }

            if changed {
                s.status = computeSessionStatus(s)
                s.hasPendingTool = hasAnyPendingTool(s)
            }
        }

        // Existing debounce (unchanged)
        if s.status == .pendingWaiting, age >= 1.5 {
            s.status = .waiting
        }

        // MODIFIED: Staleness with pending-tool awareness
        if s.status == .working, age >= 15.0 {
            if s.hasPendingTool == true {
                // Tool is legitimately running — use 10-minute timeout
                if age >= 600.0 { s.status = .waiting }
            } else {
                s.status = .waiting
            }
        }

        // Existing abandoned logic (unchanged)
        if s.status == .waiting, age >= 600.0 {
            s.status = .abandoned
        }
    }
    return s
}
```

**Transcript resolution check:**

```swift
struct ToolResolution {
    let isRejection: Bool
}

/// Read last ~4KB of transcript, look for a tool_result matching the given tool_use_id.
func checkToolResolution(transcriptPath: String, toolUseId: String) -> ToolResolution? {
    guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
    defer { handle.closeFile() }

    let fileSize = handle.seekToEndOfFile()
    let readSize = min(UInt64(4096), fileSize)
    handle.seek(toFileOffset: fileSize - readSize)
    let data = handle.readData(ofLength: Int(readSize))

    guard let text = String(data: data, encoding: .utf8) else { return nil }

    // Find complete JSON lines containing this tool_use_id as a tool_result
    // The tool_result entry has: "tool_use_id":"<id>" (in message.content)
    // The tool_use entry has: "id":"<id>" (in message.content)
    // We want the tool_result, which uses "tool_use_id" key.
    let lines = text.components(separatedBy: "\n")
    for line in lines.reversed() {
        guard line.contains(toolUseId),
              line.contains("tool_use_id") else { continue }

        // This line references our tool as a result
        let isRejection = line.contains("User rejected tool use")
                       || line.contains("Request interrupted by user")
        return ToolResolution(isRejection: isRejection)
    }
    return nil  // Tool hasn't resolved yet
}
```

**Status computation:**

```swift
func computeSessionStatus(_ session: AgentSession) -> AgentStatus {
    var statuses: [AgentStatus] = []
    if let main = session.mainAgentStatus { statuses.append(main) }
    for sub in session.subagents ?? [] {
        if let s = sub.status { statuses.append(s) }
    }
    if statuses.contains(.needsApproval) { return .needsApproval }
    if statuses.contains(.working) { return .working }
    if statuses.contains(.pendingWaiting) { return .pendingWaiting }
    return session.mainAgentStatus ?? session.status
}
```

## Files to Modify

1. **`Sources/ClawdboardLib/Resources/clawdboard-hook.py`** — per-agent routing, `pending_tool_use_id` tracking, `recompute_session_status()`, `transcript_path` storage, StopFailure handler
2. **`Sources/ClawdboardLib/Models.swift`** — new fields on Subagent and AgentSession
3. **`Sources/ClawdboardLib/AppState.swift`** — `checkToolResolution()`, updated `processSession()`
4. **Hook registration** — add `StopFailure` event matcher

## Performance

- Transcript read: ~4KB read from end of file, only for sessions with a pending tool_use_id older than 2s. Typical: 0-2 sessions at any time. Cost: <1ms per read on SSD.
- No reads when all tools are auto-approved (pending_tool_use_id cleared immediately by PostToolUse).
- Per-agent status computation: O(n) where n = subagent count (0-5 typical).

## Backward Compatibility

All new fields are optional. Existing state files work without migration. The first hook event after upgrade populates the new fields. Python helpers use `.get()` with sensible defaults.

## Verification

1. **Unit test**: Session with `pending_tool_use_id` and a transcript containing a matching rejection → verify `processSession()` transitions correctly.
2. **Unit test**: Session with `pending_tool_use_id` but no matching transcript entry → verify status stays unchanged.
3. **Unit test**: Session with `has_pending_tool=true` at 20s age → verify staleness suppressed.
4. **Build**: `mise run build`
5. **Manual test**: Run a Claude session, reject a tool, verify Clawdboard transitions within ~5s.
6. **Manual test**: Run concurrent subagents, reject one subagent's tool, verify the other's status is unaffected.
