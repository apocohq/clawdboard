#!/usr/bin/env python3
"""Clawdboard hook script — called by Claude Code hooks to track session state.

Reads hook input from stdin, extracts session data from JSONL transcript,
and writes/updates a state file in ~/.clawdboard/sessions/.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import time
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# JSON dict type alias
JsonDict = dict[str, Any]

SESSIONS_DIR = Path.home() / ".clawdboard" / "sessions"
LOG_FILE = Path.home() / ".clawdboard" / "hook-debug.log"
WATCHER_PID_FILE = Path.home() / ".clawdboard" / "watcher.pid"
WATCHER_POLL_INTERVAL = 1.5
WATCHER_IDLE_TIMEOUT = 60
MODEL_CACHE_FILE = Path.home() / ".clawdboard" / "model-context-windows.json"
LITELLM_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

TITLE_FALLBACK = "untitled-session"
TITLE_PLACEHOLDERS = ("", "new-session", TITLE_FALLBACK)

STATUS_PREFIX = {
    "working": "\U0001f535",  # 🔵
    "pending_waiting": "\U0001f535",  # 🔵 (shows as working)
    "needs_approval": "\U0001f534",  # 🔴
    "waiting": "\U0001f7e2",  # 🟢
    "abandoned": "\u26aa",  # ⚪
    "unknown": "\u26aa",  # ⚪
}
DEFAULT_PREFIX = "\u26aa"  # ⚪


def set_terminal_title(title: str) -> None:
    """Set the terminal tab title via ANSI OSC escape sequence.

    Writes directly to /dev/tty to bypass stdout (which goes to Claude Code).
    """
    try:
        with open("/dev/tty", "w") as tty:
            tty.write(f"\033]0;{title}\007")
            tty.flush()
    except (OSError, IOError):
        pass  # Not in a terminal (e.g. title gen subprocess)


def _status_prefix(state: JsonDict) -> str:
    return STATUS_PREFIX.get(state.get("status", ""), DEFAULT_PREFIX)


def _title_body(state: JsonDict) -> str:
    """Return the title text part (without status prefix)."""
    title = state.get("title", "")
    if title and title not in TITLE_PLACEHOLDERS:
        return title
    slug = state.get("slug", "")
    if slug and slug not in TITLE_PLACEHOLDERS:
        return slug
    project = state.get("project_name", "")
    if project:
        return project
    return "session"


def get_terminal_tab_title(state: JsonDict) -> str:
    """Compute the terminal tab title from session state.

    Format: {status_emoji} {title}
    Status emoji: 🔵 working, 🔴 needs approval, 🟢 waiting, ⚪ other
    Title priority: AI-generated title > slug > project name > 'session'.
    """
    return f"{_status_prefix(state)} {_title_body(state)}"


def update_terminal_tab_title(state: JsonDict) -> None:
    """Recompute and set the terminal tab title if it changed.

    Skips if the user renamed the tab manually.
    """
    if state.get("user_renamed_tab"):
        return
    new_title = get_terminal_tab_title(state)
    if new_title != state.get("terminal_tab_title"):
        state["terminal_tab_title"] = new_title
        set_terminal_title(new_title)


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


def get_git_head_sha(cwd: str) -> str | None:
    """Return the full HEAD commit SHA for the given directory, or None."""
    if not cwd:
        return None
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=2,
            cwd=cwd,
        )
        if result.returncode != 0:
            return None
        sha = result.stdout.strip()
        return sha if len(sha) == 40 else None
    except Exception:
        return None


def get_commit_count(cwd: str, start_sha: str) -> int:
    """Count commits from start_sha (exclusive) to HEAD."""
    if not cwd or not start_sha:
        return 0
    try:
        result = subprocess.run(
            ["git", "rev-list", "--count", f"{start_sha}..HEAD"],
            capture_output=True,
            text=True,
            timeout=2,
            cwd=cwd,
        )
        if result.returncode != 0:
            return 0
        return int(result.stdout.strip())
    except Exception:
        return 0


def get_unpushed_count(cwd: str) -> int | None:
    """Return the number of commits ahead of upstream, or None if no upstream."""
    if not cwd:
        return None
    try:
        result = subprocess.run(
            ["git", "rev-list", "--count", "@{upstream}..HEAD"],
            capture_output=True,
            text=True,
            timeout=2,
            cwd=cwd,
        )
        if result.returncode != 0:
            return None
        return int(result.stdout.strip())
    except Exception:
        return None


def get_git_dirty(cwd: str) -> bool:
    """Return True if the working tree has uncommitted changes, False otherwise."""
    if not cwd:
        return False
    try:
        result = subprocess.run(
            ["git", "status", "--porcelain", "-uno"],
            capture_output=True,
            text=True,
            timeout=2,
            cwd=cwd,
        )
        if result.returncode != 0:
            return False
        return bool(result.stdout.strip())
    except Exception:
        return False


def is_ancestor(cwd: str, ancestor: str, descendant: str) -> bool:
    """Return True if ancestor is an ancestor of (or equal to) descendant."""
    try:
        result = subprocess.run(
            ["git", "merge-base", "--is-ancestor", ancestor, descendant],
            capture_output=True,
            timeout=2,
            cwd=cwd,
        )
        return result.returncode == 0
    except Exception:
        return False


def update_commit_tracking(state: JsonDict, cwd: str) -> None:
    """Update head_sha, commit_count, unpushed_count, and git_dirty."""
    head = get_git_head_sha(cwd)
    if head:
        state["head_sha"] = head
    start = state.get("start_sha")
    # Reset start_sha if it's no longer an ancestor of HEAD (rebase, force-push, etc.)
    if start and head and start != head and not is_ancestor(cwd, start, head):
        state["start_sha"] = head
        state["commit_count"] = 0
    elif start and head:
        state["commit_count"] = get_commit_count(cwd, start)
    state["unpushed_count"] = get_unpushed_count(cwd)
    state["git_dirty"] = get_git_dirty(cwd)


# --- Watcher daemon ---


def _script_version() -> str:
    """Version stamp based on the script's mtime. Changes on reinstall."""
    try:
        return str(os.path.getmtime(__file__))
    except OSError:
        return ""


def ensure_watcher() -> None:
    """Start the watcher daemon if not already running or if code changed."""
    lock_path = WATCHER_PID_FILE.with_suffix(".lock")
    try:
        fd = open(lock_path, "w")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, IOError):
        return  # Another hook is already checking/spawning
    try:
        current_version = _script_version()

        if WATCHER_PID_FILE.is_file():
            try:
                lines = WATCHER_PID_FILE.read_text().strip().split("\n")
                pid = int(lines[0])
                version = lines[1] if len(lines) > 1 else ""
                os.kill(pid, 0)
                if version == current_version:
                    return  # Alive and up-to-date
                # Stale version — SIGKILL and wait so its finally block
                # doesn't delete the new watcher's PID file.
                os.kill(pid, signal.SIGKILL)
                for _ in range(20):  # up to 1s
                    time.sleep(0.05)
                    try:
                        os.kill(pid, 0)
                    except OSError:
                        break
            except (ValueError, OSError):
                pass  # Stale PID file or already dead
            WATCHER_PID_FILE.unlink(missing_ok=True)

        subprocess.Popen(
            [sys.executable, __file__, "--watch"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception:
        pass  # Hook must not break if watcher fails
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        fd.close()


def run_watcher() -> None:
    """Main watcher loop. Polls sessions, resolves blind spots, writes back."""
    # Write PID + version atomically so ensure_watcher() can detect stale code
    tmp = WATCHER_PID_FILE.with_suffix(f".tmp.{os.getpid()}")
    tmp.write_text(f"{os.getpid()}\n{_script_version()}")
    tmp.rename(WATCHER_PID_FILE)

    # Clean exit on SIGTERM
    _watcher_running = [True]
    signal.signal(signal.SIGTERM, lambda _s, _f: _watcher_running.__setitem__(0, False))

    idle_since: float | None = None
    try:
        while _watcher_running[0]:
            try:
                active = _watcher_tick()
            except Exception as exc:
                _watcher_log(f"tick error: {exc}")
                active = 1  # Assume active to avoid premature exit
            if active == 0:
                if idle_since is None:
                    idle_since = time.monotonic()
                elif time.monotonic() - idle_since >= WATCHER_IDLE_TIMEOUT:
                    _watcher_log("no active sessions, exiting")
                    break
            else:
                idle_since = None
            time.sleep(WATCHER_POLL_INTERVAL)
    finally:
        WATCHER_PID_FILE.unlink(missing_ok=True)


def _watcher_log(msg: str) -> None:
    try:
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(LOG_FILE, "a") as f:
            f.write(f"[{now}] [watcher] {msg}\n")
    except Exception:
        pass


def _watcher_tick() -> int:
    """One poll cycle. Returns number of active sessions."""
    try:
        all_files = list(SESSIONS_DIR.glob("*.json"))
    except Exception:
        return 0

    session_files = [f for f in all_files if ".agent." not in f.name]

    proc_tree: dict[int, tuple[int, str]] | None = None  # Lazy — built on first need
    active = 0

    for meta_file in session_files:
        try:
            state = json.loads(meta_file.read_text())
        except Exception:
            continue

        session_id = state.get("session_id", "")
        if not session_id:
            continue

        pid = state.get("pid")
        if pid:
            try:
                os.kill(pid, 0)
            except OSError:
                _cleanup_session(session_id, meta_file)
                continue
        else:
            updated = state.get("updated_at", "")
            if _age_seconds(updated) > 120:
                _cleanup_session(session_id, meta_file)
                continue

        active += 1
        proc_tree = _resolve_session(session_id, state, proc_tree)

    return active


def _age_seconds(iso_timestamp: str) -> float:
    """Seconds since an ISO 8601 timestamp."""
    if not iso_timestamp:
        return 9999
    try:
        dt = datetime.fromisoformat(iso_timestamp.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - dt).total_seconds()
    except Exception:
        return 9999


def _resolve_session(
    session_id: str, state: JsonDict, proc_tree: dict[int, tuple[int, str]] | None
) -> dict[int, tuple[int, str]] | None:
    """Resolve blind spots for one session. Returns (possibly built) proc_tree."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    main_transcript = state.get("transcript_path", "")
    session_pid = state.get("pid")

    # Collect agent fact files for this session
    agent_files = list(SESSIONS_DIR.glob(f"{session_id}.agent.*.json"))

    for agent_file in agent_files:
        name = agent_file.stem  # {session_id}.agent.{key}
        agent_range = name.find(".agent.")
        if agent_range < 0:
            continue
        agent_key = name[agent_range + len(".agent.") :]
        agent_id = "" if agent_key == "main" else agent_key

        # Read fact WITHOUT holding the lock (avoid blocking hooks during I/O)
        try:
            fact = json.loads(agent_file.read_text())
        except Exception:
            continue

        tools = fact.get("tools", {})
        if not tools:
            continue  # Nothing to resolve

        transcript = fact.get("transcript_path") or (
            main_transcript if agent_key == "main" else ""
        )

        # --- Transcript resolution (no lock needed — read-only on transcript) ---
        resolved_ids = []
        if transcript:
            for tool_use_id, tool_entry in tools.items():
                status = tool_entry.get("status", "")
                if status not in ("working", "needs_approval"):
                    continue
                result = _find_tool_result_in_transcript(transcript, tool_use_id)
                if result is not None:
                    resolved_ids.append(tool_use_id)

        # --- Process inspection (no lock needed — read-only on process tree) ---
        flipped_ids = []
        if session_pid:
            for tool_use_id, tool_entry in tools.items():
                if tool_entry.get("status") != "needs_approval":
                    continue
                cmd = tool_entry.get("command", "")
                if not cmd:
                    continue
                if proc_tree is None:
                    proc_tree = _get_process_tree()
                if _is_command_running(cmd, session_pid, proc_tree):
                    flipped_ids.append(tool_use_id)

        if not resolved_ids and not flipped_ids:
            continue

        # Re-read and update under lock (fact may have changed since we read it)
        with _agent_lock(session_id, agent_id):
            try:
                fact = json.loads(agent_file.read_text())
            except Exception:
                continue
            tools = fact.get("tools", {})
            changed = False
            for tid in resolved_ids:
                if tid in tools:
                    tools.pop(tid)
                    changed = True
            for tid in flipped_ids:
                if tid in tools and tools[tid].get("status") == "needs_approval":
                    tools[tid]["status"] = "working"
                    changed = True
            if changed:
                fact["tools"] = tools
                fact["status"] = derive_agent_status(fact)
                fact["updated_at"] = now
                write_agent_fact(session_id, agent_id, fact)

    # --- Interruption detection (main transcript only) ---
    if main_transcript and _is_transcript_interrupted(main_transcript):
        # Check if any agent is still marked non-waiting
        for agent_file in agent_files:
            name = agent_file.stem
            agent_range = name.find(".agent.")
            if agent_range < 0:
                continue
            agent_key = name[agent_range + len(".agent.") :]
            agent_id = "" if agent_key == "main" else agent_key

            with _agent_lock(session_id, agent_id):
                try:
                    fact = json.loads(agent_file.read_text())
                except Exception:
                    continue
                if fact.get("status") not in ("waiting", None) or fact.get("tools"):
                    fact["tools"] = {}
                    fact["status"] = "waiting"
                    fact["updated_at"] = now
                    write_agent_fact(session_id, agent_id, fact)

    return proc_tree


def _find_tool_result_in_transcript(
    transcript_path: str, tool_use_id: str
) -> bool | None:
    """Check if a tool_result exists for the given tool_use_id.

    Returns True if found (rejection or completion), None if not found.
    """
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            read_size = min(size, 4096)
            if read_size == 0:
                return None
            f.seek(size - read_size)
            data = f.read().decode("utf-8", errors="replace")
    except Exception:
        return None

    for line in reversed(data.strip().split("\n")):
        if tool_use_id in line and "tool_use_id" in line:
            return True
    return None


def _is_transcript_interrupted(transcript_path: str) -> bool:
    """Check if the last transcript line is an interruption marker."""
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            read_size = min(size, 2048)
            if read_size == 0:
                return False
            f.seek(size - read_size)
            data = f.read().decode("utf-8", errors="replace")
    except Exception:
        return False
    lines = data.strip().split("\n")
    last = next((ln for ln in reversed(lines) if ln.strip()), None)
    return bool(last and "Request interrupted by user" in last)


def _get_process_tree() -> dict[int, tuple[int, str]]:
    """Return {pid: (ppid, args)} for all processes. Single ps call."""
    try:
        result = subprocess.run(
            ["ps", "-eo", "pid,ppid,args"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        tree: dict[int, tuple[int, str]] = {}
        for line in result.stdout.strip().split("\n")[1:]:
            parts = line.split(None, 2)
            if len(parts) >= 2:
                pid, ppid = int(parts[0]), int(parts[1])
                args = parts[2] if len(parts) > 2 else ""
                tree[pid] = (ppid, args)
        return tree
    except Exception:
        return {}


def _is_command_running(
    command: str, parent_pid: int, proc_tree: dict[int, tuple[int, str]]
) -> bool:
    """Check if command runs as child/grandchild of parent_pid."""
    children = {pid for pid, (ppid, _) in proc_tree.items() if ppid == parent_pid}
    descendants = set(children)
    for pid, (ppid, _) in proc_tree.items():
        if ppid in children:
            descendants.add(pid)
    return any(command in proc_tree[pid][1] for pid in descendants if pid in proc_tree)


def _cleanup_session(session_id: str, meta_file: Path) -> None:
    """Remove a dead session's files."""
    meta_file.unlink(missing_ok=True)
    delete_all_agent_facts(session_id)


def main() -> None:
    notification_subtype = sys.argv[1] if len(sys.argv) > 1 else ""
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
    ensure_watcher()

    hook_input = json.loads(sys.stdin.read())

    session_id: str = hook_input.get("session_id", "")
    hook_event: str = hook_input.get("hook_event_name", "")
    cwd: str = hook_input.get("cwd", "")
    transcript_path: str = hook_input.get("transcript_path", "")
    agent_id: str = hook_input.get("agent_id", "")
    agent_type: str = hook_input.get("agent_type", "")
    tool_name: str = hook_input.get("tool_name", "")
    prompt: str = hook_input.get("prompt", "")
    model: str = hook_input.get("model", "")
    tool_use_id: str = hook_input.get("tool_use_id", "")
    claude_pid = os.getppid()

    if not session_id or os.environ.get("_CLAWDBOARD_TITLE_GEN"):
        print('{"suppressOutput": true}')
        return

    state_file = SESSIONS_DIR / f"{session_id}.json"
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    project_name = os.path.basename(cwd) if cwd else ""

    # Debug logging
    subtype_suffix = f":{notification_subtype}" if notification_subtype else ""
    agent_suffix = f" agent={agent_id}" if agent_id else ""
    tool_suffix = f" tool={tool_use_id}" if tool_use_id else ""
    with open(LOG_FILE, "a") as lf:
        lf.write(
            f"[{now}] {hook_event}{subtype_suffix} session={session_id}{agent_suffix}{tool_suffix} cwd={cwd}\n"
        )
        if hook_event in ("PermissionRequest", "PreToolUse"):
            lf.write(f"  INPUT: {json.dumps(hook_input, default=str)[:2000]}\n")

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
        handle_pre_tool_use(session_id, agent_id, tool_use_id, tool_name, now)
    elif hook_event == "PostToolUse" or hook_event == "PostToolUseFailure":
        handle_post_tool_use(
            state_file,
            transcript_path,
            session_id,
            cwd,
            project_name,
            now,
            claude_pid,
            agent_id,
            tool_use_id,
        )
    elif hook_event == "Stop":
        handle_stop(state_file, transcript_path, session_id, agent_id, now)
    elif hook_event == "StopFailure":
        handle_stop_failure(session_id, agent_id, now)
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
    elif hook_event == "SessionEnd":
        set_terminal_title("")
        state_file.unlink(missing_ok=True)
        delete_all_agent_facts(session_id)
    elif hook_event == "PermissionRequest":
        handle_permission_request(
            state_file,
            session_id,
            agent_id,
            now,
            tool_use_id,
            tool_name,
            transcript_path,
            hook_input.get("tool_input"),
        )
    elif hook_event == "SubagentStart":
        handle_subagent_start(
            session_id,
            agent_id,
            agent_type,
            now,
            hook_input.get("agent_transcript_path", ""),
        )
    elif hook_event == "SubagentStop":
        handle_subagent_stop(session_id, agent_id)

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
    # Write atomically via temp file + rename to trigger DispatchSource directory events.
    # Use PID in suffix to avoid races when the hook is registered multiple times.
    tmp = state_file.with_suffix(f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.rename(state_file)


_TITLE_SCRIPT = """\
import json, os, re, signal, subprocess
from pathlib import Path

state_file = Path(os.environ["_CLAWDBOARD_STATE_FILE"])
prompts = json.loads(os.environ["_CLAWDBOARD_PROMPTS"])

messages = "\\n".join(f"Message {i+1}: {p}" for i, p in enumerate(prompts))
claude_prompt = (
    "Generate a kebab-case slug title (1-3 words, max 5 words) for this coding session. "
    "Output ONLY the slug, nothing else. No greetings, no explanation.\\n"
    "Examples: api-refactor, auth-module, test-suite, docs-update, cleanup, "
    "fix-login, db-migration, general-chat, config-update\\n\\n"
    f"{messages}\\n\\nSlug:"
)

title = ""
try:
    proc = subprocess.Popen(
        ["claude", "-p", "--model", "haiku", "--no-session-persistence",
         "--tools", "", "--output-format", "text", "--max-budget-usd", "0.05",
         claude_prompt],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL, text=True,
        start_new_session=True,
    )
    try:
        stdout, _ = proc.communicate(timeout=30)
        if proc.returncode == 0 and stdout:
            text = stdout.strip()
            if not text.lower().startswith("error"):
                raw = text.lower().replace(" ", "-").replace("_", "-")
                slug = re.sub(r"[^a-z0-9-]", "", raw)
                slug = re.sub(r"-{2,}", "-", slug).strip("-")
                if slug:
                    words = slug.split("-")
                    if len(words) <= 5:
                        title = words[0]
                        for word in words[1:]:
                            if len(title) + len(word) + 1 > 40:
                                break
                            title += "-" + word
    except subprocess.TimeoutExpired:
        # Kill the entire process group to avoid orphaned children
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            proc.kill()
        try:
            proc.wait(timeout=5)
        except Exception:
            pass
except Exception:
    pass

if not title:
    title = "untitled-session"

try:
    state = json.loads(state_file.read_text())
    state["title"] = title
    state.pop("title_generating", None)
    # Recompute terminal tab title with status-based prefix
    if not state.get("user_renamed_tab"):
        status_map = {
            "working": "\U0001f535", "pending_waiting": "\U0001f535",
            "needs_approval": "\U0001f534", "waiting": "\U0001f7e2",
        }
        prefix = status_map.get(state.get("status", ""), "\u26aa")
        placeholders = ("", "new-session", "untitled-session")
        body = title if (title and title not in placeholders) else state.get("project_name", "session")
        tab_title = f"{prefix} {body}"
        state["terminal_tab_title"] = tab_title
        try:
            with open("/dev/tty", "w") as tty:
                tty.write(f"\\033]0;{tab_title}\\007")
                tty.flush()
        except (OSError, IOError):
            pass
    tmp = state_file.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.rename(state_file)
except Exception:
    pass
"""


def extract_prompt_first_line(prompt: str, max_len: int = 200) -> str | None:
    """Strip IDE/system XML tags and return the first line, or None if empty."""
    cleaned = re.sub(r"<([^>]+)>.*?</\1>", "", prompt, flags=re.DOTALL).strip()
    if not cleaned:
        return None
    first_line = cleaned.split("\n")[0].strip()[:max_len]
    return first_line or None


def generate_title_async(state_file: Path, user_prompts: list[str]) -> None:
    """Spawn a detached process to generate a session title via claude CLI.

    Does NOT use start_new_session so the subprocess inherits the controlling
    terminal and can set the tab title via /dev/tty immediately.
    """
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
    )


def merge_transcript_data(state: JsonDict, transcript_data: JsonDict) -> None:
    for key in TRANSCRIPT_KEYS:
        val = transcript_data.get(key)
        if val is not None and val != "":
            state[key] = val


def _detect_git_context_change(
    state: JsonDict, cwd: str
) -> tuple[bool, str | None, str | None]:
    """Detect cwd or branch change, update state, return (changed, branch, repo)."""
    cwd_changed = bool(cwd and cwd != state.get("cwd"))
    effective_cwd = cwd if cwd else state.get("cwd", "")
    new_branch = get_git_branch(effective_cwd)
    new_repo: str | None = None
    if cwd_changed:
        state["cwd"] = cwd
        new_repo = get_github_repo(cwd)
        state["github_repo"] = new_repo
    branch_changed = bool(new_branch and new_branch != state.get("git_branch"))
    changed = cwd_changed or branch_changed
    if changed:
        state["git_branch"] = new_branch
        head_sha = get_git_head_sha(effective_cwd)
        state["start_sha"] = head_sha
        state["head_sha"] = head_sha
        state["commit_count"] = 0
    return changed, new_branch, new_repo or state.get("github_repo")


def _reapply_git_info(state: JsonDict, branch: str | None, repo: str | None) -> None:
    """Re-apply git info after merge_transcript_data which
    may clobber them with stale transcript metadata."""
    if branch:
        state["git_branch"] = branch
    if repo:
        state["github_repo"] = repo


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
    head_sha = get_git_head_sha(cwd)
    return {
        "session_id": session_id,
        "cwd": cwd,
        "project_name": project_name,
        "github_repo": get_github_repo(cwd),
        "started_at": now,
        "updated_at": now,
        "pid": claude_pid,
        "is_hook_tracked": True,
        "transcript_path": "",
        "start_sha": head_sha,
        "head_sha": head_sha,
        "commit_count": 0,
        "unpushed_count": get_unpushed_count(cwd),
    }


# --- Per-agent fact files ---
# Each agent writes its own file: {session_id}.agent.{agent_key}.json
# Main agent uses key "main", subagents use their agent_id.
# Swift reads all agent files and derives the session-level status.
# File locking prevents same-agent races (e.g. PostToolUse for Read
# overwriting PermissionRequest for Bash when both fire concurrently).


def agent_fact_path(session_id: str, agent_id: str) -> Path:
    """Return the path for an agent's fact file."""
    key = agent_id if agent_id else "main"
    return SESSIONS_DIR / f"{session_id}.agent.{key}.json"


@contextmanager
def _agent_lock(session_id: str, agent_id: str) -> Iterator[None]:
    """Exclusive lock on an agent's fact file. Held for <50ms typically."""
    lock_path = agent_fact_path(session_id, agent_id).with_suffix(".lock")
    fd = open(lock_path, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        fd.close()


def read_agent_fact(session_id: str, agent_id: str) -> JsonDict:
    """Read an agent's fact file, returning empty dict if missing."""
    path = agent_fact_path(session_id, agent_id)
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def write_agent_fact(session_id: str, agent_id: str, fact: JsonDict) -> None:
    """Write an agent's fact file atomically."""
    path = agent_fact_path(session_id, agent_id)
    tmp = path.with_suffix(f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(fact, indent=2))
    tmp.rename(path)


def derive_agent_status(fact: JsonDict) -> str:
    """Derive agent-level status from its active tools.

    Priority: needs_approval > working > waiting (no tools).
    """
    tools = fact.get("tools", {})
    if not tools:
        # No active tools — preserve existing status. Only Stop/StopFailure
        # should transition to "waiting"; derive should never downgrade.
        return fact.get("status", "working")
    statuses = [t.get("status", "working") for t in tools.values()]
    if "needs_approval" in statuses:
        return "needs_approval"
    if "working" in statuses:
        return "working"
    return "waiting"


def delete_agent_fact(session_id: str, agent_id: str) -> None:
    """Delete an agent's fact file and lock file."""
    path = agent_fact_path(session_id, agent_id)
    path.unlink(missing_ok=True)
    path.with_suffix(".lock").unlink(missing_ok=True)


def delete_all_agent_facts(session_id: str) -> None:
    """Delete all agent fact files and lock files for a session."""
    for f in SESSIONS_DIR.glob(f"{session_id}.agent.*.json"):
        f.unlink(missing_ok=True)
    for f in SESSIONS_DIR.glob(f"{session_id}.agent.*.lock"):
        f.unlink(missing_ok=True)


def delete_subagent_facts(session_id: str) -> None:
    """Delete subagent fact files and lock files (not main)."""
    for f in SESSIONS_DIR.glob(f"{session_id}.agent.*.json"):
        if f.name.endswith(".agent.main.json"):
            continue
        f.unlink(missing_ok=True)
    for f in SESSIONS_DIR.glob(f"{session_id}.agent.*.lock"):
        if f.name.endswith(".agent.main.lock"):
            continue
        f.unlink(missing_ok=True)


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
    head_sha = get_git_head_sha(cwd)
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "project_name": project_name,
        "github_repo": get_github_repo(cwd),
        "model": data.get("model") or model or None,
        "git_branch": data.get("git_branch") or get_git_branch(cwd),
        "slug": data.get("slug") or None,
        "context_pct": data.get("context_pct"),
        "started_at": now,
        "updated_at": now,
        "pid": claude_pid,
        "is_hook_tracked": True,
        "transcript_path": transcript_path,
        "start_sha": head_sha,
        "head_sha": head_sha,
        "commit_count": 0,
        "unpushed_count": get_unpushed_count(cwd),
    }
    if data.get("context_pct") is not None:
        append_context_snapshot(state, data["context_pct"], now)

    update_terminal_tab_title(state)

    write_state(state_file, state)
    # Main agent starts in "waiting" — transitions to "working" on UserPromptSubmit
    write_agent_fact(session_id, "", {"status": "waiting", "updated_at": now})


def handle_post_tool_use(
    state_file: Path,
    transcript_path: str,
    session_id: str,
    cwd: str,
    project_name: str,
    now: str,
    claude_pid: int,
    agent_id: str = "",
    tool_use_id: str = "",
) -> None:
    # Tool completed — remove it from active tools
    with _agent_lock(session_id, agent_id):
        fact = read_agent_fact(session_id, agent_id)
        tools = fact.get("tools", {})
        if tool_use_id:
            tools.pop(tool_use_id, None)
        else:
            # No tool_use_id provided — remove all working tools (completed ones).
            # Keep needs_approval entries since those are still pending user action.
            tools = {
                k: v for k, v in tools.items() if v.get("status") == "needs_approval"
            }
        fact["tools"] = tools
        fact["status"] = derive_agent_status(fact)
        fact["updated_at"] = now
        write_agent_fact(session_id, agent_id, fact)

    # Update session metadata (only for main agent — subagents don't touch it)
    if not agent_id:
        state = read_state(state_file)
        if state is None:
            state = make_base_state(session_id, cwd, project_name, now, claude_pid)

        git_changed, new_branch, new_repo = _detect_git_context_change(state, cwd)
        state["updated_at"] = now
        state["transcript_path"] = transcript_path

        data = read_transcript_data(transcript_path, state_file)
        merge_transcript_data(state, data)
        if git_changed:
            _reapply_git_info(state, new_branch, new_repo)
        if data.get("context_pct") is not None:
            append_context_snapshot(state, data["context_pct"], now)
        update_commit_tracking(state, cwd or state.get("cwd", ""))
        update_terminal_tab_title(state)
        write_state(state_file, state)


def handle_stop(
    state_file: Path,
    transcript_path: str,
    session_id: str,
    agent_id: str,
    now: str,
) -> None:
    # Subagent Stop is a no-op — SubagentStop will delete the fact file.
    # Writing "waiting" here causes a flicker before SubagentStop fires.
    if agent_id:
        return

    # Main agent stopped — clean up orphaned subagent fact files
    delete_subagent_facts(session_id)

    with _agent_lock(session_id, agent_id):
        fact = read_agent_fact(session_id, agent_id)
        fact["tools"] = {}
        fact["status"] = "waiting"
        fact["updated_at"] = now
        write_agent_fact(session_id, agent_id, fact)

    # Update session metadata (only for main agent)
    if not agent_id:
        state = read_state(state_file)
        if state is None:
            return
        data = read_transcript_data(transcript_path, state_file)
        state["updated_at"] = now
        merge_transcript_data(state, data)
        if data.get("context_pct") is not None:
            append_context_snapshot(state, data["context_pct"], now)
        update_commit_tracking(state, state.get("cwd", ""))
        update_terminal_tab_title(state)
        write_state(state_file, state)


def handle_stop_failure(session_id: str, agent_id: str, now: str) -> None:
    if agent_id:
        return  # Subagent — SubagentStop handles cleanup
    with _agent_lock(session_id, ""):
        fact = read_agent_fact(session_id, "")
        fact["tools"] = {}
        fact["status"] = "waiting"
        fact["updated_at"] = now
        write_agent_fact(session_id, "", fact)


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
    # User submitted a prompt — clear stale tools and orphaned subagents
    delete_subagent_facts(session_id)
    with _agent_lock(session_id, ""):
        fact = read_agent_fact(session_id, "")
        fact["tools"] = {}
        fact["status"] = "working"
        fact["updated_at"] = now
        write_agent_fact(session_id, "", fact)

    data = read_transcript_data(transcript_path, state_file)
    state = read_state(state_file)
    if state is None:
        state = make_base_state(session_id, cwd, project_name, now, claude_pid)

    git_changed, new_branch, new_repo = _detect_git_context_change(state, cwd)

    state["updated_at"] = now
    state["transcript_path"] = transcript_path
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
        first_line = extract_prompt_first_line(prompt)
        if first_line:
            prompts.append(first_line)
        state["user_prompts"] = prompts

    # Generate title on message 1 (quick) and message 2 (refined)
    # Message 2 only re-triggers if the title is still a placeholder
    # (i.e. message 1's async generation hasn't finished yet)
    title_is_placeholder = state.get("title", "") in TITLE_PLACEHOLDERS
    should_generate = count in (1, 2) and prompts
    if should_generate and (
        (count == 2 and title_is_placeholder)
        or (count == 1 and not state.get("title_generating"))
    ):
        state["title_generating"] = True
        merge_transcript_data(state, data)
        if git_changed:
            _reapply_git_info(state, new_branch, new_repo)
        if data.get("context_pct") is not None:
            append_context_snapshot(state, data["context_pct"], now)
        update_commit_tracking(state, cwd or state.get("cwd", ""))
        update_terminal_tab_title(state)
        write_state(state_file, state)
        generate_title_async(state_file, prompts)
        return

    merge_transcript_data(state, data)
    if git_changed:
        _reapply_git_info(state, new_branch, new_repo)
    if data.get("context_pct") is not None:
        append_context_snapshot(state, data["context_pct"], now)
    update_commit_tracking(state, cwd or state.get("cwd", ""))
    update_terminal_tab_title(state)
    write_state(state_file, state)


def handle_pre_tool_use(
    session_id: str, agent_id: str, tool_use_id: str, tool_name: str, now: str
) -> None:
    """Tool is about to run — add it to active tools."""
    if not tool_use_id:
        return
    with _agent_lock(session_id, agent_id):
        fact = read_agent_fact(session_id, agent_id)
        tools = fact.get("tools", {})
        entry: JsonDict = {"status": "working"}
        if tool_name:
            entry["tool_name"] = tool_name
        tools[tool_use_id] = entry
        fact["tools"] = tools
        fact["status"] = derive_agent_status(fact)
        fact["updated_at"] = now
        write_agent_fact(session_id, agent_id, fact)


def _find_tool_use_id_in_transcript(
    transcript_path: str, tool_name: str, tool_input: JsonDict | None
) -> str | None:
    """Find tool_use_id by matching tool_name + input in the transcript.

    Reads the last ~16KB and scans for tool_use entries in assistant messages.
    Returns the matching id, or None.
    """
    if not transcript_path or not tool_name:
        return None
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            read_size = min(size, 16 * 1024)
            f.seek(size - read_size)
            data = f.read().decode("utf-8", errors="replace")
    except Exception:
        return None

    # Build a match key from tool_input (for Bash: the command string)
    match_cmd = (tool_input or {}).get("command", "") if tool_input else ""

    # Scan lines in reverse for the most recent matching tool_use
    for line in reversed(data.strip().split("\n")):
        if '"tool_use"' not in line:
            continue
        try:
            entry = json.loads(line)
            msg = entry.get("message", {})
            if not isinstance(msg, dict):
                continue
            for block in msg.get("content", []):
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                if block.get("name") != tool_name:
                    continue
                inp = block.get("input", {})
                # Match by command for Bash/shell tools, or by full input equality
                if match_cmd and inp.get("command") == match_cmd:
                    return block.get("id")
                if not match_cmd and inp == (tool_input or {}):
                    return block.get("id")
        except Exception:
            continue
    return None


def handle_permission_request(
    state_file: Path,
    session_id: str,
    agent_id: str,
    now: str,
    tool_use_id: str = "",
    tool_name: str = "",
    transcript_path: str = "",
    tool_input: JsonDict | None = None,
) -> None:
    # Resolve tool_use_id from transcript if not provided by hook
    if not tool_use_id and transcript_path:
        tool_use_id = (
            _find_tool_use_id_in_transcript(transcript_path, tool_name, tool_input)
            or ""
        )

    cmd = (tool_input or {}).get("command", "") if tool_input else ""
    with _agent_lock(session_id, agent_id):
        fact = read_agent_fact(session_id, agent_id)
        tools = fact.get("tools", {})
        tool_entry: JsonDict = {"status": "needs_approval"}
        if cmd:
            tool_entry["command"] = cmd
        if tool_name:
            tool_entry["tool_name"] = tool_name

        if tool_use_id and tool_use_id in tools:
            # Exact match — found via hook input or transcript lookup
            tools[tool_use_id] = tool_entry
        elif tool_use_id:
            # tool_use_id from transcript but not yet in tools dict (PreToolUse race)
            tools[tool_use_id] = tool_entry
        else:
            # Last resort: match by tool_name + working status
            for tid, t in tools.items():
                if t.get("tool_name") == tool_name and t.get("status") == "working":
                    tools[tid] = tool_entry
                    break

        fact["tools"] = tools
        fact["status"] = derive_agent_status(fact)
        fact["updated_at"] = now
        write_agent_fact(session_id, agent_id, fact)

    # Update approval timestamps on session metadata
    state = read_state(state_file)
    if state is None:
        return
    approvals = state.get("approval_timestamps", [])
    approvals.append(now)
    state["approval_timestamps"] = approvals
    state["updated_at"] = now
    write_state(state_file, state)


def handle_subagent_start(
    session_id: str,
    agent_id: str,
    agent_type: str,
    now: str,
    agent_transcript_path: str = "",
) -> None:
    if not agent_id:
        return
    fact: JsonDict = {
        "status": "working",
        "agent_type": agent_type,
        "started_at": now,
        "updated_at": now,
    }
    if agent_transcript_path:
        fact["transcript_path"] = agent_transcript_path
    write_agent_fact(session_id, agent_id, fact)


def handle_subagent_stop(session_id: str, agent_id: str) -> None:
    if not agent_id:
        return
    delete_agent_fact(session_id, agent_id)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--watch":
        run_watcher()
    else:
        main()
