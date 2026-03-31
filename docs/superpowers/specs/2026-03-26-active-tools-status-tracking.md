# Status Tracking via active_tools

## Architecture

Single `{session_id}.json` file per session. All state lives in one file, protected by a per-session file lock (`fcntl.flock`). Two writers:

1. **Hook script** (`clawdboard-hook.py`) — called synchronously by Claude Code on each hook event
2. **Watcher daemon** — background Python process polling every 1.5s, covers blind spots

Swift reads the JSON and applies only lifecycle rules (ghost filtering, abandoned detection). All status derivation happens in Python.

## State Model

```json
{
  "status": "working",
  "active_tools": {
    "toolu_01Abc...": {
      "status": "working",
      "tool_name": "Bash",
      "agent_id": "",
      "added_at": "2026-03-30T12:00:00Z",
      "command": "npm test"
    }
  },
  "agent_working": true,
  "subagents": [
    { "agent_id": "abc", "agent_type": "Explore", "started_at": "..." }
  ],
  "transcript_path": "/Users/x/.claude/projects/proj/session.jsonl",
  "pid": 12345
}
```

**`active_tools`**: Dict keyed by `tool_use_id`. Each entry tracks one in-flight tool call. The `command` field is only present for Bash tools (used for process inspection).

**`agent_working`**: Boolean. True between `UserPromptSubmit` and `Stop`/`StopFailure`. Represents "the model is generating tokens" even when no tool is actively running.

**`status`**: Derived field, recomputed on every write via `derive_status()`:
- If any tool has `status == "needs_approval"` → `"needs_approval"`
- If any tools exist OR `agent_working` is true → `"working"`
- Otherwise → `"waiting"`

## Status Transitions

### Session Lifecycle

```
SessionStart ──→ waiting (agent_working=False, no tools)
    │
UserPromptSubmit ──→ working (agent_working=True, _full_reset clears stale state)
    │
    ├── PreToolUse ──→ working (tool added with status="working")
    │       │
    │       ├── [tool auto-approved] ──→ PostToolUse ──→ tool removed
    │       │
    │       └── PermissionRequest ──→ needs_approval (tool flipped to "needs_approval")
    │               │
    │               ├── [user approves] ──→ (no hook fires — BLIND SPOT)
    │               │       │
    │               │       ├── PostToolUse ──→ tool removed, back to working
    │               │       │
    │               │       └── [watcher detects process running] ──→ tool flipped to "working"
    │               │
    │               └── [user rejects] ──→ PostToolUseFailure ──→ tool removed
    │
    ├── Stop ──→ waiting (_full_reset: all tools cleared, agent_working=False)
    │
    ├── StopFailure ──→ waiting (_full_reset)
    │
    └── [user interrupts — no hook fires] ──→ (watcher detects via transcript) ──→ waiting
```

### Hook Event Details

| Hook Event | What it does | Status after |
|---|---|---|
| **SessionStart** | Create state file. `active_tools={}`, `agent_working=False` | `waiting` |
| **UserPromptSubmit** | `_full_reset()` then `agent_working=True`. Clears all tools and subagents from previous turn. | `working` |
| **PreToolUse** | Add `tool_use_id` to `active_tools` with `status="working"` | `working` |
| **PermissionRequest** | Flip tool entry to `status="needs_approval"`, store `command` if Bash | `needs_approval` |
| **PostToolUse** | Remove `tool_use_id` from `active_tools`. Update git/transcript metadata. | depends on remaining tools |
| **PostToolUseFailure** | Same as PostToolUse (tool rejected or errored) | depends on remaining tools |
| **Stop** | `_full_reset()`. Update git/transcript metadata. Subagent Stop is a no-op. | `waiting` |
| **StopFailure** | `_full_reset()`. Subagent StopFailure is a no-op. | `waiting` |
| **SubagentStart** | Append to `subagents` list | unchanged |
| **SubagentStop** | Remove from `subagents`, remove its tools from `active_tools` | recomputed |
| **SessionEnd** | Delete state file and lock file | session gone |

### The PermissionRequest → Approval Blind Spot

This is the key problem. The hook event sequence for a tool requiring approval:

```
1. PreToolUse        → adds tool_use_id with status="working"
2. PermissionRequest → flips that tool to status="needs_approval", stores command
   --- user sees approval dialog ---
3. User clicks approve
   --- NO HOOK FIRES HERE ---
4. Tool starts executing (e.g., bash runs "npm test")
   --- tool is running but state still says "needs_approval" ---
5. PostToolUse       → removes tool_use_id, back to working
```

Between steps 3 and 5, the UI shows "Approve" even though the tool is already running. For fast tools (<1s), this is barely visible. For slow tools (e.g., `sleep 30`), it's stuck for the full duration.

**Watcher coverage**: The watcher daemon polls every 1.5s. For each tool with `status="needs_approval"` that has a `command` field:
1. Build process tree via `ps -eo pid,ppid,args` (one call, cached across sessions)
2. Find all children and grandchildren of the session's Claude PID
3. Check if the command string appears as a substring in any descendant's args
4. If found → flip tool to `status="working"` under lock

**Limitation**: Only works for Bash tools (only ones with a `command` field). Read, Write, Edit, Grep etc. have no inspectable process. For those, the `needs_approval` state persists until `PostToolUse` fires.

### The PermissionRequest tool_use_id Problem

`PermissionRequest` does NOT receive `tool_use_id` in its hook input. To match it with the correct `active_tools` entry:

1. **Transcript lookup**: Read the last 16KB of the transcript, scan for a `tool_use` block matching `tool_name` + `tool_input`
2. **Existing entry match**: If `tool_use_id` found and already in `active_tools` (from PreToolUse), update it in place
3. **Synthetic key fallback**: If lookup fails, create entry with key `perm_{timestamp}`. This orphans — PostToolUse will remove the real `tool_use_id` but the synthetic one stays. The next `_full_reset()` (on Stop or UserPromptSubmit) cleans it up.

### The Interruption Blind Spot

When a user interrupts execution (Ctrl+C / Escape), **no hook fires** (`Stop` does NOT fire on interrupt). Claude Code writes an interrupt entry to the transcript — a JSONL line with this structure:

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user for tool use]"}]}}
```

**Watcher coverage** (`_is_last_entry_interrupt`): On each tick, for sessions with active tools or `agent_working=True`:
1. Read the last 4KB of the transcript
2. Parse the last JSONL line as JSON
3. Check if it's a `type: "user"` message with a `type: "text"` content block containing `"Request interrupted by user"`
4. If found → `_full_reset()` under lock → status becomes `waiting`

**Why JSON parsing, not string search**: The string `"Request interrupted by user"` can appear in conversation content — assistant messages discussing the feature, tool results containing code or logs with the string. A raw `in` search produces false positives. Parsing the JSON and checking the specific structure (`type: "user"` + `type: "text"` block) eliminates these. Tool results (`type: "tool_result"`) and assistant messages (`role: "assistant"`) are not matched.

**Why `agent_working` must not be falsely reset**: `agent_working=True` is only set by `UserPromptSubmit`. If the watcher incorrectly resets it to `False`, no hook will restore it until the next user prompt. The session flickers to "waiting" between every tool call for the rest of the turn, since `derive_status()` returns `"waiting"` when `active_tools` is empty and `agent_working` is `False`.

### Dead Process Cleanup

The watcher also handles crashed Claude processes:
- For sessions with a `pid`: `os.kill(pid, 0)` — if the process is dead, delete the session file
- For sessions without a `pid`: if `updated_at` is >120s old, delete

## Concurrency

All state modifications happen under `_session_lock(session_id)` — a per-session `fcntl.flock`. This prevents races between:
- Concurrent hook invocations (e.g., PreToolUse + PermissionRequest firing simultaneously)
- Hook vs. watcher daemon writing at the same time

Atomic writes via temp file + rename: `state_file.with_suffix(f".tmp.{os.getpid()}")`.

## Watcher Daemon Lifecycle

- **Started by**: `ensure_watcher()`, called on every hook invocation
- **Guarded by**: Non-blocking lock (`LOCK_NB`) on `watcher.pid.lock` — fails fast if another hook is already checking
- **PID file**: `~/.clawdboard/watcher.pid` — contains PID + script mtime version
- **Version check**: If script mtime changed (reinstall), old watcher is killed and replaced
- **Idle timeout**: Exits after 60s with no active sessions
- **Poll interval**: 1.5s

## Swift Side (SessionProcessor)

Swift does NOT derive status — it trusts the `status` field from Python. It only applies:

1. **Ghost filtering**: Sessions with no `model` and no `activeTools`/`agentWorking` are filtered after grace periods (30s if never updated, 60s absolute, 300s if stale)
2. **Abandoned detection**: `waiting` for 10+ minutes → `abandoned`

## Logging

All logs go to `~/.clawdboard/hook-debug.log`.

**Hook events** — one line with pre-state context (truncated session/agent IDs):
```
[time] PreToolUse session=32cf468c tool=toolu_01Abc name=Bash was=working tools=2 working=True
```

**State writes** — arrow line after every `write_state()`:
```
[time]   → 32cf468c status=working tools=3 working=True subs=1
```

**Watcher actions** — prefixed with `[watcher]`:
```
[time] [watcher] interrupted 32cf468c — resetting 2 tools
[time] [watcher] approved 32cf468c tool=toolu_01Abc cmd=npm test
[time] [watcher] no active sessions, exiting
```

To debug status flickering: look for unexpected `status=waiting` in the `→` lines. The `was=` field on hook events shows what status existed before the hook ran.

## Files

| File | Role |
|---|---|
| `clawdboard-hook.py` | Hook handler + watcher daemon. All status logic. |
| `SessionProcessor.swift` | Ghost filtering + abandoned detection. Trusts Python's `status` field. |
| `SessionStateWatcher.swift` | DispatchSource watching `~/.clawdboard/sessions/` for file changes. Reads and decodes JSON. No polling timer — watcher daemon handles liveness. |
| `Models.swift` | `AgentSession`, `ActiveTool`, `AgentStatus` enum (no `pendingWaiting`). |
| `HookManager.swift` | Registers hooks for all events in Claude Code settings. |
| `AppState.swift` | Delegates to `SessionProcessor.process()`. Status accessed directly via `.status` (no `displayStatus` indirection). |
