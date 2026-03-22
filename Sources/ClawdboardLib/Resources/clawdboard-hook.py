#!/usr/bin/env python3
"""Clawdboard hook script — called by Claude Code hooks to track session state.

Reads hook input from stdin, extracts session data from JSONL transcript,
and writes/updates a state file in ~/.clawdboard/sessions/.
"""

from __future__ import annotations

import json
import os
import random
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# JSON dict type alias
JsonDict = dict[str, Any]

SESSIONS_DIR = Path.home() / ".clawdboard" / "sessions"
LOG_FILE = Path.home() / ".clawdboard" / "hook-debug.log"
MODEL_CACHE_FILE = Path.home() / ".clawdboard" / "model-context-windows.json"
LITELLM_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

TITLE_PLACEHOLDERS = [
    "new-session",
    "getting-started",
    "loading...",
    "spinning-up",
    "warming-up",
    "initializing",
    "booting-up",
    "revving-up",
]


def get_context_window(model_id: str) -> int:
    """Look up context window size for a model from cached LiteLLM data.

    Fetches from GitHub on first call (or if cache is >24h old), then uses cache.
    Falls back to 200k if anything fails.
    """
    if not model_id:
        return 200000

    # Try to load/refresh cache
    cache = _load_model_cache()
    if cache:
        # Try exact match first, then prefix match
        if model_id in cache:
            return cache[model_id]
        # Try matching by model family (prefix match)
        for key, window in cache.items():
            if key.startswith(model_id) or model_id.startswith(key):
                return window

    return 200000


def _load_model_cache() -> dict[str, int]:
    """Load or refresh the model context window cache."""
    # Check if cache exists and is fresh (<24h)
    try:
        if MODEL_CACHE_FILE.is_file():
            age = (
                datetime.now(timezone.utc).timestamp()
                - MODEL_CACHE_FILE.stat().st_mtime
            )
            if age < 86400:  # 24 hours
                return json.loads(MODEL_CACHE_FILE.read_text())
    except Exception:
        pass

    # Fetch fresh data (non-blocking: if it fails, use stale cache or empty)
    try:
        import urllib.request

        resp = urllib.request.urlopen(LITELLM_URL, timeout=3)
        data = json.loads(resp.read())
        # Extract Claude model context windows
        cache: dict[str, int] = {}
        for key, val in data.items():
            if not isinstance(val, dict):
                continue
            if "claude" not in key:
                continue
            # Skip provider-prefixed keys, keep canonical names
            if "/" in key or "." in key:
                continue
            max_input = val.get("max_input_tokens")
            if isinstance(max_input, int) and max_input > 0:
                cache[key] = max_input
        if cache:
            MODEL_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
            MODEL_CACHE_FILE.write_text(json.dumps(cache, indent=2))
            return cache
    except Exception:
        pass

    # Fall back to stale cache
    try:
        if MODEL_CACHE_FILE.is_file():
            return json.loads(MODEL_CACHE_FILE.read_text())
    except Exception:
        pass

    # Last resort: hardcoded baseline (updated 2026-03-15)
    return {
        "claude-opus-4-6": 1000000,
        "claude-sonnet-4-6": 200000,
        "claude-sonnet-4-5": 200000,
        "claude-opus-4-5": 200000,
        "claude-opus-4-1": 200000,
        "claude-haiku-4-5": 200000,
    }


def get_git_branch(cwd: str) -> str | None:
    """Return the current git branch name for the given directory, or None."""
    if not cwd:
        return None
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=2,
            cwd=cwd,
        )
        if result.returncode != 0:
            return None
        branch = result.stdout.strip()
        return branch if branch and branch != "HEAD" else None
    except Exception:
        return None


def get_github_repo(cwd: str) -> str | None:
    """Return GitHub repo slug (e.g. 'user/repo') for the given directory, or None."""
    if not cwd:
        return None
    try:
        result = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            capture_output=True,
            text=True,
            timeout=2,
            cwd=cwd,
        )
        if result.returncode != 0:
            return None
        url = result.stdout.strip()
        if "github.com" not in url:
            return None
        # SSH: git@github.com:user/repo.git
        if url.startswith("git@"):
            path = url.split(":", 1)[-1]
        else:
            # HTTPS: https://github.com/user/repo[.git]
            from urllib.parse import urlparse

            path = urlparse(url).path.lstrip("/")
        return path.removesuffix(".git") or None
    except Exception:
        return None


def main() -> None:
    notification_subtype = sys.argv[1] if len(sys.argv) > 1 else ""
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

    hook_input = json.loads(sys.stdin.read())

    session_id: str = hook_input.get("session_id", "")
    hook_event: str = hook_input.get("hook_event_name", "")
    cwd: str = hook_input.get("cwd", "")
    transcript_path: str = hook_input.get("transcript_path", "")
    agent_id: str = hook_input.get("agent_id", "")
    agent_type: str = hook_input.get("agent_type", "")
    prompt: str = hook_input.get("prompt", "")
    model: str = hook_input.get("model", "")
    claude_pid = os.getppid()

    if not session_id or os.environ.get("_CLAWDBOARD_TITLE_GEN"):
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
            state_file,
            transcript_path,
            session_id,
            cwd,
            project_name,
            now,
            claude_pid,
            model,
        )
    elif hook_event == "PreToolUse":
        handle_pre_tool_use(state_file, now)
    elif hook_event == "PostToolUse" or hook_event == "PostToolUseFailure":
        handle_post_tool_use(
            state_file,
            transcript_path,
            session_id,
            cwd,
            project_name,
            now,
            claude_pid,
        )
    elif hook_event == "Stop":
        handle_stop(state_file, transcript_path, now)
    elif hook_event == "UserPromptSubmit":
        handle_user_prompt_submit(
            state_file,
            transcript_path,
            session_id,
            cwd,
            project_name,
            now,
            claude_pid,
            prompt,
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


def read_transcript_data(transcript_path: str, state_file: Path) -> JsonDict:
    """Extract session data from the last JSONL entry with usage info."""
    if not transcript_path or not os.path.isfile(transcript_path):
        return {}

    result: JsonDict = {}
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

            context_used = input_tok + cache_create + cache_read + output_tok
            model = result.get("model", "")
            ctx_window = get_context_window(model)
            result["context_pct"] = round(context_used / ctx_window * 100, 1)

    except Exception:
        pass

    return result


# --- State helpers ---

TRANSCRIPT_KEYS = (
    "model",
    "git_branch",
    "slug",
    "context_pct",
)


def read_state(state_file: Path) -> JsonDict | None:
    if not state_file.is_file():
        return None
    try:
        return json.loads(state_file.read_text())
    except Exception:
        return None


def write_state(state_file: Path, state: JsonDict) -> None:
    # Write atomically via temp file + rename to trigger DispatchSource directory events
    tmp = state_file.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.rename(state_file)


_TITLE_SCRIPT = """\
import json, os, re, subprocess
from pathlib import Path

state_file = Path(os.environ["_CLAWDBOARD_STATE_FILE"])
prompts = json.loads(os.environ["_CLAWDBOARD_PROMPTS"])

prompt_text = "\\n".join(f"Message {i+1}: {p}" for i, p in enumerate(prompts))
claude_prompt = (
    "Given these user messages from a coding session, generate a short "
    "kebab-case slug title (1-3 words, lowercase, hyphens between words). "
    "It should describe the task like a branch name. "
    "Examples: api-refactor, auth-module, test-suite, docs-update, cleanup, "
    "fix-login, db-migration, css-overhaul, perf-tuning, dep-upgrade. "
    "Just output the slug, nothing else.\\n\\n"
    + prompt_text
)

try:
    result = subprocess.run(
        ["claude", "-p", "--no-session-persistence",
         claude_prompt, "--output-format", "text"],
        capture_output=True, text=True, timeout=30,
    )
    raw = result.stdout.strip().lower().replace(" ", "-").replace("_", "-")[:40] if result.returncode == 0 else ""
    # Clean up: keep only alphanumeric and hyphens, collapse multiple hyphens
    title = re.sub(r"[^a-z0-9-]", "", raw)
    title = re.sub(r"-{2,}", "-", title).strip("-")
except Exception:
    title = ""

try:
    state = json.loads(state_file.read_text())
    if title:
        state["title"] = title
    state.pop("title_generating", None)
    tmp = state_file.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.rename(state_file)
except Exception:
    pass
"""


def generate_title_async(state_file: Path, user_prompts: list[str]) -> None:
    """Spawn a detached process to generate a session title via claude CLI."""
    env = os.environ.copy()
    env["_CLAWDBOARD_TITLE_GEN"] = "1"
    env["_CLAWDBOARD_STATE_FILE"] = str(state_file)
    env["_CLAWDBOARD_PROMPTS"] = json.dumps(user_prompts)
    subprocess.Popen(
        [sys.executable, "-c", _TITLE_SCRIPT],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
        start_new_session=True,
    )


def merge_transcript_data(state: JsonDict, transcript_data: JsonDict) -> None:
    for key in TRANSCRIPT_KEYS:
        val = transcript_data.get(key)
        if val is not None and val != "":
            state[key] = val


MAX_CONTEXT_SNAPSHOTS = 100


def append_context_snapshot(state: JsonDict, pct: float, timestamp: str) -> None:
    snapshots = state.get("context_snapshots", [])
    snapshots.append({"t": timestamp, "pct": pct})
    if len(snapshots) > MAX_CONTEXT_SNAPSHOTS:
        snapshots = snapshots[-MAX_CONTEXT_SNAPSHOTS:]
    state["context_snapshots"] = snapshots


def make_base_state(
    session_id: str, cwd: str, project_name: str, now: str, claude_pid: int
) -> JsonDict:
    return {
        "session_id": session_id,
        "cwd": cwd,
        "project_name": project_name,
        "github_repo": get_github_repo(cwd),
        "status": "working",
        "started_at": now,
        "updated_at": now,
        "pid": claude_pid,
        "is_hook_tracked": True,
    }


# --- Event handlers ---


def handle_session_start(
    state_file: Path,
    transcript_path: str,
    session_id: str,
    cwd: str,
    project_name: str,
    now: str,
    claude_pid: int,
    model: str = "",
) -> None:
    data = read_transcript_data(
        transcript_path, Path("/dev/null")
    )  # no prev state for new session
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "project_name": project_name,
        "github_repo": get_github_repo(cwd),
        "status": "working",
        "model": data.get("model") or model or None,
        "git_branch": data.get("git_branch") or get_git_branch(cwd),
        "slug": data.get("slug") or None,
        "context_pct": data.get("context_pct"),
        "started_at": now,
        "updated_at": now,
        "pid": claude_pid,
        "is_hook_tracked": True,
    }
    if data.get("context_pct") is not None:
        append_context_snapshot(state, data["context_pct"], now)
    write_state(state_file, state)


def handle_post_tool_use(
    state_file: Path,
    transcript_path: str,
    session_id: str,
    cwd: str,
    project_name: str,
    now: str,
    claude_pid: int,
) -> None:
    state = read_state(state_file)
    if state is None:
        state = make_base_state(session_id, cwd, project_name, now, claude_pid)

    # Write "working" immediately so the UI updates before the slow transcript read
    state["status"] = "working"
    state["updated_at"] = now
    write_state(state_file, state)

    # Then read transcript data and write again with full info
    data = read_transcript_data(transcript_path, state_file)
    merge_transcript_data(state, data)
    if data.get("context_pct") is not None:
        append_context_snapshot(state, data["context_pct"], now)
    write_state(state_file, state)


def handle_stop(state_file: Path, transcript_path: str, now: str) -> None:
    state = read_state(state_file)
    if state is None:
        return
    data = read_transcript_data(transcript_path, state_file)
    state["status"] = "pending_waiting"
    state["updated_at"] = now
    merge_transcript_data(state, data)
    if data.get("context_pct") is not None:
        append_context_snapshot(state, data["context_pct"], now)
    write_state(state_file, state)


def handle_user_prompt_submit(
    state_file: Path,
    transcript_path: str,
    session_id: str,
    cwd: str,
    project_name: str,
    now: str,
    claude_pid: int,
    prompt: str = "",
) -> None:
    data = read_transcript_data(transcript_path, state_file)
    state = read_state(state_file)
    if state is None:
        state = make_base_state(session_id, cwd, project_name, now, claude_pid)
    state["status"] = "working"
    state["updated_at"] = now
    # Capture the first user prompt as a fallback label
    if prompt and not state.get("first_prompt"):
        first_line = prompt.strip().split("\n")[0].strip()
        if first_line:
            state["first_prompt"] = first_line[:100]

    # Track user message count and accumulate prompts for title generation
    count = state.get("user_message_count", 0) + 1
    state["user_message_count"] = count
    prompts = state.get("user_prompts", [])
    if len(prompts) < 2 and prompt:
        first_line = prompt.strip().split("\n")[0].strip()[:200]
        if first_line:
            prompts.append(first_line)
        state["user_prompts"] = prompts

    # Generate title on message 1 (quick) and message 2 (refined)
    # Message 2 always triggers even if message 1 generation is still running
    should_generate = count in (1, 2) and prompts
    if should_generate and (count == 2 or not state.get("title_generating")):
        state["title_generating"] = True
        if not state.get("title"):
            state["title"] = random.choice(TITLE_PLACEHOLDERS)
        merge_transcript_data(state, data)
        if data.get("context_pct") is not None:
            append_context_snapshot(state, data["context_pct"], now)
        write_state(state_file, state)
        generate_title_async(state_file, prompts)
        return

    merge_transcript_data(state, data)
    if data.get("context_pct") is not None:
        append_context_snapshot(state, data["context_pct"], now)
    write_state(state_file, state)


def handle_pre_tool_use(state_file: Path, now: str) -> None:
    """Tool is about to run (user approved) — mark as working immediately."""
    state = read_state(state_file)
    if state is None:
        return
    state["status"] = "working"
    state["updated_at"] = now
    write_state(state_file, state)


def handle_notification(state_file: Path, notification_subtype: str, now: str) -> None:
    state = read_state(state_file)
    if state is None:
        return
    if notification_subtype == "permission_prompt":
        state["status"] = "needs_approval"
        approvals = state.get("approval_timestamps", [])
        approvals.append(now)
        state["approval_timestamps"] = approvals
    else:
        # idle_prompt is async and can arrive after UserPromptSubmit has
        # already set the session back to "working". Never clobber working.
        if state.get("status") == "working":
            return
        # Use pending_waiting to go through the same debounce as Stop,
        # rather than jumping straight to "waiting".
        state["status"] = "pending_waiting"
    state["updated_at"] = now
    write_state(state_file, state)


def handle_permission_request(state_file: Path, now: str) -> None:
    state = read_state(state_file)
    if state is None:
        return
    state["status"] = "needs_approval"
    approvals = state.get("approval_timestamps", [])
    approvals.append(now)
    state["approval_timestamps"] = approvals
    state["updated_at"] = now
    write_state(state_file, state)


def handle_subagent_start(
    state_file: Path, agent_id: str, agent_type: str, now: str
) -> None:
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


def handle_subagent_stop(state_file: Path, agent_id: str, now: str) -> None:
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
