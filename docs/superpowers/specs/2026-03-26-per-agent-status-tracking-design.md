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

### 3. Long-running tools after approval

After the user approves a permission dialog, no hook fires until PostToolUse (after the tool completes). For slow tools (e.g. `sleep 20`), this means 20+ seconds stuck at "approve" status.

### 4. Resumed sessions show "working"

When a session is resumed, `SessionStart` fires but Claude may already be idle. No Stop hook fires because the model never ran, leaving the status stuck at "working".

## Solution

### Per-Agent State

Each agent (main + subagents) tracks its own:
- `status` — current agent status
- `pending_tool_use_id` — set by PreToolUse, cleared by PostToolUse/Stop
- `pending_tool_command` — the shell command from PermissionRequest (for process matching)
- `transcript_path` — path to the agent's transcript file

The session-level `status` is derived from all agents via `recompute_session_status`.

### Hook Changes (Python)

All status-changing events are routed by `agent_id`. Key helpers:

```python
def _set_agent_status(state, agent_id, status):
    """Set status for the correct agent AND recompute session-level status."""
    if agent_id:
        for sub in state.get("subagents", []):
            if sub["agent_id"] == agent_id:
                sub["status"] = status
                break
    else:
        state["main_agent_status"] = status
    recompute_session_status(state)  # Always recompute to prevent race conditions

def _set_pending_tool(state, agent_id, tool_use_id):
    """Set or clear pending_tool_use_id (and pending_tool_command) for the correct agent."""
    if agent_id:
        for sub in state.get("subagents", []):
            if sub["agent_id"] == agent_id:
                sub["pending_tool_use_id"] = tool_use_id
                if not tool_use_id:
                    sub.pop("pending_tool_command", None)
                return
    else:
        state["main_pending_tool_use_id"] = tool_use_id
        if not tool_use_id:
            state.pop("pending_tool_command", None)

def recompute_session_status(state):
    """Derive session-level status from all agents.
    Priority: needs_approval > working > pending_waiting > waiting.
    Required because multiple agents write concurrently."""
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
```

Event routing:

| Event | What it does |
|---|---|
| SessionStart | `status=waiting`, `main_agent_status=waiting`, store `transcript_path` |
| UserPromptSubmit | `status=working` (main agent only, triggers recompute) |
| PreToolUse | `status=working`, `pending_tool_use_id=hook_input["tool_use_id"]` |
| PermissionRequest | `status=needs_approval`, store `pending_tool_command` from `tool_input["command"]` |
| PostToolUse / PostToolUseFailure | `status=working`, `pending_tool_use_id=None` |
| Stop | `status=pending_waiting`, `pending_tool_use_id=None` |
| StopFailure | `status=pending_waiting`, `pending_tool_use_id=None` |
| SubagentStart | Append to subagents with `status=working`, `transcript_path` |
| SubagentStop | Remove from subagents, call `recompute_session_status()` |

**Removed:** Notification handlers (idle_prompt, permission_prompt) — empirically unreliable, redundant with PermissionRequest and Stop.

**Race condition fix:** `write_state` uses PID in temp file suffix to prevent concurrent hook invocations from clobbering each other: `tmp = state_file.with_suffix(f".tmp.{os.getpid()}")`.

### Swift: SessionProcessor

All state computation logic is extracted into `SessionProcessor` (from AppState). It is the single source of truth for deriving display-ready session state.

```swift
public func process(_ session: AgentSession, now: Date) -> AgentSession? {
    var s = session

    // Filter ghost sessions (never produced output)
    if isGhost(s, now: now) { return nil }

    // Derive session status from per-agent data
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

    // Debounce: pending_waiting → waiting after 1.5s
    if s.status == .pendingWaiting, age >= 1.5 {
        s.status = .waiting
    }

    // Abandoned: waiting for 10+ minutes
    if s.status == .waiting, age >= 600.0 {
        s.status = .abandoned
    }

    return s
}
```

**Transcript resolution:** When a `pending_tool_use_id` is present and status hasn't changed for >2s, reads the last 4KB of each agent's transcript looking for a `tool_result` entry matching the ID. Detects rejections via `"User rejected tool use"` or `"Request interrupted by user"`.

**Process inspection:** When status is `needs_approval` and a `pending_tool_command` is stored, enumerates child + grandchild processes via `sysctl(KERN_PROC_ALL)` and reads their command-line args via `sysctl(KERN_PROCARGS2)`. If the exact command is found running, transitions to `working`. This handles the blind spot after permission approval where no hook fires until the tool completes.

**No 15s staleness heuristic.** The Stop hook reliably handles the `working → pending_waiting` transition. The old fallback was removed because it caused false "your turn" states during legitimate long-running tools.

### Session JSON Shape

```json
{
  "status": "needs_approval",
  "main_agent_status": "needs_approval",
  "main_pending_tool_use_id": "toolu_01Wwv6w7xX85ZkKW97zHseWm",
  "pending_tool_command": "ls -la /tmp",
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

## Files Modified

1. **`Sources/ClawdboardLib/Resources/clawdboard-hook.py`** — per-agent routing, `_set_agent_status` / `_set_pending_tool` / `recompute_session_status` helpers, `pending_tool_command` storage, StopFailure handler, PID-based temp file, removed Notification handlers
2. **`Sources/ClawdboardLib/SessionProcessor.swift`** (NEW) — extracted from AppState, single source of truth for state computation, transcript resolution, process inspection via sysctl
3. **`Sources/ClawdboardLib/Models.swift`** — new fields on Subagent (`status`, `pendingToolUseId`, `pendingToolCommand`, `transcriptPath`) and AgentSession (`mainAgentStatus`, `mainPendingToolUseId`, `pendingToolCommand`, `hasPendingTool`, `transcriptPath`)
4. **`Sources/ClawdboardLib/AppState.swift`** — simplified to delegate to SessionProcessor
5. **`Sources/ClawdboardLib/HookManager.swift`** — added `StopFailure` to hook events, removed Notification registration

## Performance

- Transcript read: ~4KB from end of file, only for sessions with a pending `tool_use_id` older than 2s. Typical: 0-2 sessions. Cost: <1ms per read on SSD.
- Process inspection: only runs when status is `needs_approval` with a `pending_tool_command`. Uses `sysctl` (kernel call, no shell subprocess).
- No reads when all tools are auto-approved (pending_tool_use_id cleared immediately by PostToolUse).
- Per-agent status computation: O(n) where n = subagent count (0-5 typical).

## Backward Compatibility

All new fields are optional. Existing state files work without migration. The first hook event after upgrade populates the new fields. Python helpers use `.get()` with sensible defaults.
