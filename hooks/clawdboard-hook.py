#!/usr/bin/env python3
"""Clawdboard hook script — called by Claude Code hooks to track session state.

Reads hook input from stdin, extracts session data from JSONL transcript,
and writes/updates a state file in ~/.clawdboard/sessions/.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

SESSIONS_DIR = Path.home() / ".clawdboard" / "sessions"
LOG_FILE = Path.home() / ".clawdboard" / "hook-debug.log"


def main():
    notification_subtype = sys.argv[1] if len(sys.argv) > 1 else ""
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

    hook_input = json.loads(sys.stdin.read())

    session_id = hook_input.get("session_id", "")
    hook_event = hook_input.get("hook_event_name", "")
    cwd = hook_input.get("cwd", "")
    transcript_path = hook_input.get("transcript_path", "")
    agent_id = hook_input.get("agent_id", "")
    agent_type = hook_input.get("agent_type", "")
    claude_pid = os.getppid()

    if not session_id:
        print('{"suppressOutput": true}')
        return

    state_file = SESSIONS_DIR / f"{session_id}.json"
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    project_name = os.path.basename(cwd) if cwd else ""

    # Debug logging
    subtype_suffix = f":{notification_subtype}" if notification_subtype else ""
    with open(LOG_FILE, "a") as lf:
        lf.write(f"[{now}] {hook_event}{subtype_suffix} session={session_id}\n")

    if hook_event == "SessionStart":
        handle_session_start(
            state_file, transcript_path, session_id, cwd, project_name, now, claude_pid
        )
    elif hook_event == "PostToolUse":
        handle_post_tool_use(
            state_file, transcript_path, session_id, cwd, project_name, now, claude_pid
        )
    elif hook_event == "Stop":
        handle_stop(state_file, transcript_path, now)
    elif hook_event == "UserPromptSubmit":
        handle_user_prompt_submit(
            state_file, transcript_path, session_id, cwd, project_name, now, claude_pid
        )
    elif hook_event == "Notification":
        handle_notification(state_file, notification_subtype, now)
    elif hook_event == "SessionEnd":
        state_file.unlink(missing_ok=True)
    elif hook_event == "PermissionRequest":
        handle_permission_request(state_file, now)
    elif hook_event == "SubagentStart":
        handle_subagent_start(state_file, agent_id, agent_type, now)
    elif hook_event == "SubagentStop":
        handle_subagent_stop(state_file, agent_id, now)

    print('{"suppressOutput": true}')


# --- Transcript reading ---


def read_transcript_data(transcript_path: str, state_file: Path) -> dict:
    """Extract session data from the last JSONL entry with usage info."""
    if not transcript_path or not os.path.isfile(transcript_path):
        return {}

    # Read existing state for running cost totals
    prev_cost = 0.0
    prev_input = 0
    prev_output = 0
    if state_file.is_file():
        try:
            prev = json.loads(state_file.read_text())
            prev_cost = prev.get("cost_usd", 0.0) or 0.0
            prev_input = prev.get("input_tokens", 0) or 0
            prev_output = prev.get("output_tokens", 0) or 0
        except Exception:
            pass

    result = {}
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            read_size = min(size, 100 * 1024)
            f.seek(size - read_size)
            lines = f.read().decode("utf-8", errors="replace").strip().split("\n")

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

            # Context % — total tokens relative to model's context window
            model = result.get("model", "")
            ctx_window = 200000  # default
            for key in ("opus", "sonnet", "haiku"):
                if key in model:
                    ctx_window = 200000
                    break

            context_used = input_tok + cache_create + cache_read + output_tok
            result["context_pct"] = round(context_used / ctx_window * 100, 1)

            # Pricing per token
            if "opus" in model:
                rates = (15e-6, 75e-6, 18.75e-6, 1.5e-6)
            elif "haiku" in model:
                rates = (0.25e-6, 1.25e-6, 0.30e-6, 0.025e-6)
            else:  # sonnet or unknown
                rates = (3e-6, 15e-6, 3.75e-6, 0.30e-6)

            msg_cost = (
                input_tok * rates[0]
                + output_tok * rates[1]
                + cache_create * rates[2]
                + cache_read * rates[3]
            )

            # Running total — only increment if tokens changed (avoid double-counting)
            if input_tok != prev_input or output_tok != prev_output:
                result["cost_usd"] = round(prev_cost + msg_cost, 4)
            else:
                result["cost_usd"] = prev_cost

            result["input_tokens"] = input_tok
            result["output_tokens"] = output_tok

    except Exception:
        pass

    return result


# --- State helpers ---

TRANSCRIPT_KEYS = (
    "model",
    "git_branch",
    "slug",
    "cost_usd",
    "context_pct",
    "input_tokens",
    "output_tokens",
)


def read_state(state_file: Path) -> Optional[dict]:
    if not state_file.is_file():
        return None
    try:
        return json.loads(state_file.read_text())
    except Exception:
        return None


def write_state(state_file: Path, state: dict):
    state_file.write_text(json.dumps(state, indent=2))


def merge_transcript_data(state: dict, transcript_data: dict):
    for key in TRANSCRIPT_KEYS:
        if key in transcript_data and transcript_data[key] is not None:
            state[key] = transcript_data[key]


def make_base_state(session_id, cwd, project_name, now, claude_pid) -> dict:
    return {
        "session_id": session_id,
        "cwd": cwd,
        "project_name": project_name,
        "status": "working",
        "started_at": now,
        "updated_at": now,
        "pid": claude_pid,
        "is_hook_tracked": True,
    }


# --- Event handlers ---


def handle_session_start(
    state_file, transcript_path, session_id, cwd, project_name, now, claude_pid
):
    data = read_transcript_data(
        transcript_path, Path("/dev/null")
    )  # no prev state for new session
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "project_name": project_name,
        "status": "working",
        "model": data.get("model"),
        "git_branch": data.get("git_branch"),
        "slug": data.get("slug"),
        "cost_usd": 0.0,
        "context_pct": data.get("context_pct"),
        "input_tokens": 0,
        "output_tokens": 0,
        "started_at": now,
        "updated_at": now,
        "pid": claude_pid,
        "is_hook_tracked": True,
    }
    write_state(state_file, state)


def handle_post_tool_use(
    state_file, transcript_path, session_id, cwd, project_name, now, claude_pid
):
    data = read_transcript_data(transcript_path, state_file)
    state = read_state(state_file)
    if state is None:
        state = make_base_state(session_id, cwd, project_name, now, claude_pid)
    state["status"] = "working"
    state["updated_at"] = now
    merge_transcript_data(state, data)
    write_state(state_file, state)


def handle_stop(state_file, transcript_path, now):
    state = read_state(state_file)
    if state is None:
        return
    data = read_transcript_data(transcript_path, state_file)
    state["status"] = "pending_waiting"
    state["updated_at"] = now
    merge_transcript_data(state, data)
    write_state(state_file, state)


def handle_user_prompt_submit(
    state_file, transcript_path, session_id, cwd, project_name, now, claude_pid
):
    data = read_transcript_data(transcript_path, state_file)
    state = read_state(state_file)
    if state is None:
        state = make_base_state(session_id, cwd, project_name, now, claude_pid)
    state["status"] = "working"
    state["updated_at"] = now
    merge_transcript_data(state, data)
    write_state(state_file, state)


def handle_notification(state_file, notification_subtype, now):
    state = read_state(state_file)
    if state is None:
        return
    if notification_subtype == "permission_prompt":
        state["status"] = "needs_approval"
    else:
        state["status"] = "waiting"
    state["updated_at"] = now
    write_state(state_file, state)


def handle_permission_request(state_file, now):
    state = read_state(state_file)
    if state is None:
        return
    state["status"] = "needs_approval"
    state["updated_at"] = now
    write_state(state_file, state)


def handle_subagent_start(state_file, agent_id, agent_type, now):
    if not agent_id:
        return
    state = read_state(state_file)
    if state is None:
        return
    subagents = state.get("subagents", [])
    if not any(s["agent_id"] == agent_id for s in subagents):
        subagents.append(
            {
                "agent_id": agent_id,
                "agent_type": agent_type,
                "started_at": now,
            }
        )
    state["subagents"] = subagents
    state["updated_at"] = now
    write_state(state_file, state)


def handle_subagent_stop(state_file, agent_id, now):
    if not agent_id:
        return
    state = read_state(state_file)
    if state is None:
        return
    subagents = state.get("subagents", [])
    subagents = [s for s in subagents if s["agent_id"] != agent_id]
    state["subagents"] = subagents
    state["updated_at"] = now
    write_state(state_file, state)


if __name__ == "__main__":
    main()
