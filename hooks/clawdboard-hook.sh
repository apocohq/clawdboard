#!/bin/bash
# Clawdboard hook script — called by Claude Code hooks to track session state.
# Reads hook input from stdin, extracts session data from JSONL transcript,
# and writes/updates a state file in ~/.clawdboard/sessions/.
set -euo pipefail

SESSIONS_DIR="$HOME/.clawdboard/sessions"
LOG_FILE="$HOME/.clawdboard/hook-debug.log"
NOTIFICATION_SUBTYPE="${1:-}"  # Passed as arg for Notification hooks (idle_prompt, permission_prompt)
mkdir -p "$SESSIONS_DIR"

# Read hook input from stdin
INPUT=$(cat)

# Extract common fields
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))")
HOOK_EVENT=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hook_event_name',''))")
CWD=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))")
TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('transcript_path',''))")
AGENT_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agent_id',''))")
AGENT_TYPE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agent_type',''))")
CLAUDE_PID="$PPID"  # PID of the Claude Code process that invoked this hook

if [ -z "$SESSION_ID" ]; then
    exit 0
fi

STATE_FILE="$SESSIONS_DIR/$SESSION_ID.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Debug logging
echo "[$NOW] $HOOK_EVENT${NOTIFICATION_SUBTYPE:+:$NOTIFICATION_SUBTYPE} session=$SESSION_ID" >> "$LOG_FILE"

# Extract project name from cwd (last path component)
PROJECT_NAME=$(basename "$CWD")

# Python script to extract session data from the last JSONL entry with usage info.
# Reads the transcript backwards to find the most recent entry with token usage,
# then calculates cost and context percentage.
read_transcript_data() {
    if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
        echo '{}'
        return
    fi

    python3 << 'PYEOF'
import json, sys, os

transcript_path = os.environ.get("TRANSCRIPT_PATH", "")
state_file_path = os.environ.get("STATE_FILE_PATH", "")

if not transcript_path or not os.path.isfile(transcript_path):
    print("{}")
    sys.exit(0)

# Read existing state for running cost totals
prev_cost = 0.0
prev_input = 0
prev_output = 0
if state_file_path and os.path.isfile(state_file_path):
    try:
        with open(state_file_path) as f:
            prev = json.load(f)
            prev_cost = prev.get("cost_usd", 0.0) or 0.0
            prev_input = prev.get("input_tokens", 0) or 0
            prev_output = prev.get("output_tokens", 0) or 0
    except Exception:
        pass

# Read last few lines to find most recent entry with usage data
result = {}
try:
    with open(transcript_path, "rb") as f:
        # Seek backwards to find last entries
        f.seek(0, 2)
        size = f.tell()
        # Read last 100KB (enough for several entries)
        read_size = min(size, 100 * 1024)
        f.seek(size - read_size)
        lines = f.read().decode("utf-8", errors="replace").strip().split("\n")

    # Find last entry with usage data (scan from end)
    # Usage lives at entry["message"]["usage"], model at entry["message"]["model"]
    # Metadata (gitBranch, slug) lives at the entry top level
    latest_usage_entry = None
    latest_meta = None
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except Exception:
            continue
        if not latest_meta and entry.get("sessionId"):
            latest_meta = entry
        msg = entry.get("message") or {}
        if not latest_usage_entry and isinstance(msg, dict) and msg.get("usage"):
            latest_usage_entry = entry
        if latest_meta and latest_usage_entry:
            break

    if latest_meta:
        result["git_branch"] = latest_meta.get("gitBranch", "")
        result["slug"] = latest_meta.get("slug", "")

    if latest_usage_entry:
        msg = latest_usage_entry["message"]
        result["model"] = msg.get("model", "")
        usage = msg["usage"]
        input_tok = usage.get("input_tokens", 0) or 0
        output_tok = usage.get("output_tokens", 0) or 0
        cache_create = usage.get("cache_creation_input_tokens", 0) or 0
        cache_read = usage.get("cache_read_input_tokens", 0) or 0

        # Context % — all input tokens + output tokens fill the context window.
        # Output tokens become conversation history on the next turn.
        # effectiveWindow is 180k (not 200k) — Claude reserves 20k for output.
        context_used = input_tok + cache_create + cache_read + output_tok
        result["context_pct"] = round(context_used / 180000 * 100, 1)

        # Incremental cost calculation from this message's usage
        model = result.get("model", "")
        # Pricing per token (not per 1M)
        if "opus" in model:
            rates = (15e-6, 75e-6, 18.75e-6, 1.5e-6)
        elif "haiku" in model:
            rates = (0.25e-6, 1.25e-6, 0.30e-6, 0.025e-6)
        else:  # sonnet or unknown — use sonnet pricing
            rates = (3e-6, 15e-6, 3.75e-6, 0.30e-6)

        msg_cost = (
            input_tok * rates[0]
            + output_tok * rates[1]
            + cache_create * rates[2]
            + cache_read * rates[3]
        )

        # Running total: add this message's cost to previous total
        # But only if tokens changed (avoid double-counting on repeated reads)
        if input_tok != prev_input or output_tok != prev_output:
            result["cost_usd"] = round(prev_cost + msg_cost, 4)
        else:
            result["cost_usd"] = prev_cost

        result["input_tokens"] = input_tok
        result["output_tokens"] = output_tok

except Exception as e:
    # Non-fatal — we'll just have less data
    pass

print(json.dumps(result))
PYEOF
}

# Determine new status based on hook event
case "$HOOK_EVENT" in
    SessionStart)
        # Create fresh state file
        TRANSCRIPT_DATA=$(TRANSCRIPT_PATH="$TRANSCRIPT" STATE_FILE_PATH="" read_transcript_data)
        python3 -c "
import json, sys
data = json.loads('$TRANSCRIPT_DATA') if '$TRANSCRIPT_DATA' != '{}' else {}
state = {
    'session_id': '$SESSION_ID',
    'cwd': '$CWD',
    'project_name': '$PROJECT_NAME',
    'status': 'working',
    'model': data.get('model'),
    'git_branch': data.get('git_branch'),
    'slug': data.get('slug'),
    'cost_usd': 0.0,
    'context_pct': data.get('context_pct'),
    'input_tokens': 0,
    'output_tokens': 0,
    'started_at': '$NOW',
    'updated_at': '$NOW',
    'pid': $CLAUDE_PID,
    'is_hook_tracked': True
}
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"
        ;;

    PostToolUse)
        # Update with latest transcript data, keep status as working
        TRANSCRIPT_DATA=$(TRANSCRIPT_PATH="$TRANSCRIPT" STATE_FILE_PATH="$STATE_FILE" read_transcript_data)
        python3 << PYEOF
import json, os

state_file = "$STATE_FILE"
transcript_data = json.loads('''$TRANSCRIPT_DATA''') if '''$TRANSCRIPT_DATA''' != '{}' else {}

if os.path.isfile(state_file):
    with open(state_file) as f:
        state = json.load(f)
else:
    state = {
        "session_id": "$SESSION_ID",
        "cwd": "$CWD",
        "project_name": "$PROJECT_NAME",
        "status": "working",
        "started_at": "$NOW",
        "pid": $CLAUDE_PID,
        "is_hook_tracked": True
    }

state["status"] = "working"
state["updated_at"] = "$NOW"
for key in ("model", "git_branch", "slug", "cost_usd", "context_pct", "input_tokens", "output_tokens"):
    if key in transcript_data and transcript_data[key] is not None:
        state[key] = transcript_data[key]

with open(state_file, "w") as f:
    json.dump(state, f, indent=2)
PYEOF
        ;;

    Stop)
        # Mark as pending_waiting — Swift app will debounce 3s before showing as "waiting"
        if [ -f "$STATE_FILE" ]; then
            TRANSCRIPT_DATA=$(TRANSCRIPT_PATH="$TRANSCRIPT" STATE_FILE_PATH="$STATE_FILE" read_transcript_data)
            python3 << PYEOF
import json

with open("$STATE_FILE") as f:
    state = json.load(f)

transcript_data = json.loads('''$TRANSCRIPT_DATA''') if '''$TRANSCRIPT_DATA''' != '{}' else {}

state["status"] = "pending_waiting"
state["updated_at"] = "$NOW"
for key in ("model", "git_branch", "slug", "cost_usd", "context_pct", "input_tokens", "output_tokens"):
    if key in transcript_data and transcript_data[key] is not None:
        state[key] = transcript_data[key]

with open("$STATE_FILE", "w") as f:
    json.dump(state, f, indent=2)
PYEOF
        fi
        ;;

    UserPromptSubmit)
        # User sent a message — back to working, also read transcript for model data
        TRANSCRIPT_DATA=$(TRANSCRIPT_PATH="$TRANSCRIPT" STATE_FILE_PATH="$STATE_FILE" read_transcript_data)
        if [ -f "$STATE_FILE" ]; then
            python3 << PYEOF
import json

with open("$STATE_FILE") as f:
    state = json.load(f)

transcript_data = json.loads('''$TRANSCRIPT_DATA''') if '''$TRANSCRIPT_DATA''' != '{}' else {}

state["status"] = "working"
state["updated_at"] = "$NOW"
for key in ("model", "git_branch", "slug", "cost_usd", "context_pct", "input_tokens", "output_tokens"):
    if key in transcript_data and transcript_data[key] is not None:
        state[key] = transcript_data[key]

with open("$STATE_FILE", "w") as f:
    json.dump(state, f, indent=2)
PYEOF
        else
            # State file doesn't exist yet — create minimal one
            python3 -c "
import json
state = {
    'session_id': '$SESSION_ID',
    'cwd': '$CWD',
    'project_name': '$PROJECT_NAME',
    'status': 'working',
    'started_at': '$NOW',
    'updated_at': '$NOW',
    'pid': $CLAUDE_PID,
    'is_hook_tracked': True
}
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"
        fi
        ;;

    Notification)
        if [ -f "$STATE_FILE" ]; then
            if [ "$NOTIFICATION_SUBTYPE" = "permission_prompt" ]; then
                # Agent is blocked waiting for user to approve a tool use
                python3 << PYEOF
import json

with open("$STATE_FILE") as f:
    state = json.load(f)

state["status"] = "needs_approval"
state["updated_at"] = "$NOW"

with open("$STATE_FILE", "w") as f:
    json.dump(state, f, indent=2)
PYEOF
            else
                # idle_prompt or other — definitively waiting (no debounce needed)
                python3 << PYEOF
import json

with open("$STATE_FILE") as f:
    state = json.load(f)

state["status"] = "waiting"
state["updated_at"] = "$NOW"

with open("$STATE_FILE", "w") as f:
    json.dump(state, f, indent=2)
PYEOF
            fi
        fi
        ;;

    SessionEnd)
        # Clean up state file
        rm -f "$STATE_FILE"
        ;;

    PermissionRequest)
        # Agent is showing a permission dialog — needs user approval
        if [ -f "$STATE_FILE" ]; then
            python3 << PYEOF
import json

with open("$STATE_FILE") as f:
    state = json.load(f)

state["status"] = "needs_approval"
state["updated_at"] = "$NOW"

with open("$STATE_FILE", "w") as f:
    json.dump(state, f, indent=2)
PYEOF
        fi
        ;;

    SubagentStart)
        # A subagent was spawned — add to the parent session's subagents list
        if [ -f "$STATE_FILE" ] && [ -n "$AGENT_ID" ]; then
            python3 << PYEOF
import json

with open("$STATE_FILE") as f:
    state = json.load(f)

subagents = state.get("subagents", [])
# Avoid duplicates
if not any(s["agent_id"] == "$AGENT_ID" for s in subagents):
    subagents.append({
        "agent_id": "$AGENT_ID",
        "agent_type": "$AGENT_TYPE",
        "started_at": "$NOW"
    })
state["subagents"] = subagents
state["updated_at"] = "$NOW"

with open("$STATE_FILE", "w") as f:
    json.dump(state, f, indent=2)
PYEOF
        fi
        ;;

    SubagentStop)
        # A subagent finished — remove from the parent session's subagents list
        if [ -f "$STATE_FILE" ] && [ -n "$AGENT_ID" ]; then
            python3 << PYEOF
import json

with open("$STATE_FILE") as f:
    state = json.load(f)

subagents = state.get("subagents", [])
subagents = [s for s in subagents if s["agent_id"] != "$AGENT_ID"]
state["subagents"] = subagents
state["updated_at"] = "$NOW"

with open("$STATE_FILE", "w") as f:
    json.dump(state, f, indent=2)
PYEOF
        fi
        ;;

    *)
        # Unknown event — ignore
        ;;
esac

# Output empty JSON to indicate success without adding noise to transcript
echo '{"suppressOutput": true}'
exit 0
