#!/usr/bin/env python3
"""Clawdboard hook script — called by Claude Code hooks to track session state.

Reads hook input from stdin, extracts session data from JSONL transcript,
and writes/updates a state file in ~/.clawdboard/sessions/.

State model: single {session_id}.json per session with an `active_tools` dict
tracking each tool call by tool_use_id. Status is derived from active_tools.
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

    # Only session files (skip .lock, .tmp, legacy .agent. files)
    session_files = [
        f for f in all_files if ".agent." not in f.name and ".tmp." not in f.name
    ]

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
        proc_tree = _resolve_active_tools(session_id, state, meta_file, proc_tree)

    return active


def _resolve_active_tools(
    session_id: str,
    state: JsonDict,
    state_file: Path,
    proc_tree: dict[int, tuple[int, str]] | None,
) -> dict[int, tuple[int, str]] | None:
    """Resolve blind spots for one session's active_tools. Returns (possibly built) proc_tree."""
    tools = state.get("active_tools", {})
    session_pid = state.get("pid")

    if not tools and not state.get("agent_working"):
        return proc_tree

    # --- Interruption detection ---
    # Check if the last transcript entry is a user interrupt message.
    # Must parse JSON to avoid false positives from conversation content
    # that happens to contain the interrupt string (e.g. discussing interrupts).
    transcript = state.get("transcript_path", "")
    if transcript and (tools or state.get("agent_working")):
        if _is_last_entry_interrupt(transcript):
            _watcher_log(f"interrupted {session_id[:8]} — resetting {len(tools)} tools")
            with _session_lock(session_id):
                state = read_state(state_file) or state
                if state.get("active_tools") or state.get("agent_working"):
                    if _is_last_entry_interrupt(state.get("transcript_path", "")):
                        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                        _full_reset(state, now)
                        state["status"] = derive_status(state)
                        update_terminal_tab_title(state)
                        write_state(state_file, state)
            return proc_tree

    flipped_ids: list[str] = []

    for tool_use_id, tool_entry in tools.items():
        status = tool_entry.get("status", "")

        # --- Process inspection: needs_approval → working if command running ---
        if status == "needs_approval" and session_pid:
            cmd = tool_entry.get("command", "")
            if cmd:
                if proc_tree is None:
                    proc_tree = _get_process_tree()
                if _is_command_running(cmd, session_pid, proc_tree):
                    _watcher_log(f"approved {session_id[:8]} tool={tool_use_id} cmd={cmd[:60]}")
                    flipped_ids.append(tool_use_id)

    if not flipped_ids:
        return proc_tree

    # Apply changes under lock
    with _session_lock(session_id):
        state = read_state(state_file) or state
        tools = state.get("active_tools", {})
        changed = False
        for tid in flipped_ids:
            if tid in tools and tools[tid].get("status") == "needs_approval":
                tools[tid]["status"] = "working"
                changed = True
        if changed:
            now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            state["active_tools"] = tools
            state["status"] = derive_status(state)
            state["updated_at"] = now
            update_terminal_tab_title(state)
            write_state(state_file, state)

    return proc_tree


def _is_last_entry_interrupt(transcript_path: str) -> bool:
    """Check if the last transcript entry is a user interrupt message.

    Parses the last JSON line and checks for the specific structure:
    {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted...}]}}
    This avoids false positives from conversation content discussing interrupts.
    """
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            read_size = min(size, 4096)
            if read_size == 0:
                return False
            f.seek(size - read_size)
            data = f.read().decode("utf-8", errors="replace")
    except Exception:
        return False
    # Get the last non-empty line
    lines = data.strip().split("\n")
    last = next((ln for ln in reversed(lines) if ln.strip()), None)
    if not last:
        return False
    try:
        entry = json.loads(last)
        if entry.get("type") != "user":
            return False
        msg = entry.get("message", {})
        if not isinstance(msg, dict) or msg.get("role") != "user":
            return False
        content = msg.get("content", [])
        if not isinstance(content, list):
            return False
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text", "")
                if "Request interrupted by user" in text:
                    return True
    except Exception:
        return False
    return False


def _age_seconds(iso_timestamp: str) -> float:
    """Seconds since an ISO 8601 timestamp."""
    if not iso_timestamp:
        return 9999
    try:
        dt = datetime.fromisoformat(iso_timestamp.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - dt).total_seconds()
    except Exception:
        return 9999






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
    lock_file = SESSIONS_DIR / f"{session_id}.lock"
    lock_file.unlink(missing_ok=True)


# --- Session lock ---


@contextmanager
def _session_lock(session_id: str) -> Iterator[None]:
    """Exclusive lock on a session's state file. Held for <10ms typically."""
    lock_path = SESSIONS_DIR / f"{session_id}.lock"
    fd = open(lock_path, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        fd.close()


# --- Status derivation ---


def derive_status(state: JsonDict) -> str:
    """Derive session-level status from active_tools and agent_working.

    Priority: needs_approval > working > waiting.
    """
    tools = state.get("active_tools", {})
    if any(t.get("status") == "needs_approval" for t in tools.values()):
        return "needs_approval"
    if tools or state.get("agent_working"):
        return "working"
    return "waiting"


# --- State helpers ---


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
    # Log the resulting state for debugging transitions
    sid = state.get("session_id", "?")[:8]
    status = state.get("status", "?")
    n_tools = len(state.get("active_tools", {}))
    working = state.get("agent_working", False)
    n_subs = len(state.get("subagents", []))
    try:
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(LOG_FILE, "a") as f:
            f.write(
                f"[{now}]   → {sid} status={status} tools={n_tools} working={working} subs={n_subs}\n"
            )
    except Exception:
        pass


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
        "active_tools": {},
        "agent_working": False,
        "subagents": [],
    }


def _ensure_state(
    state_file: Path,
    session_id: str,
    cwd: str,
    project_name: str,
    now: str,
    claude_pid: int,
) -> JsonDict:
    """Read state file, creating a minimal one if it doesn't exist."""
    state = read_state(state_file)
    if state is not None:
        return state
    return make_base_state(session_id, cwd, project_name, now, claude_pid)


# --- Transcript reading ---


TRANSCRIPT_KEYS = (
    "model",
    "git_branch",
    "slug",
    "context_pct",
)


def read_transcript_data(transcript_path: str) -> JsonDict:
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


# --- Title generation ---


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
            "working": "\U0001f535",
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


# --- Transcript tool_use_id lookup for PermissionRequest ---


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


# --- Shared helpers for event handlers ---


def _full_reset(state: JsonDict, now: str) -> None:
    """Reset all transient session state. Used by Stop, StopFailure, UserPromptSubmit,
    and the watcher's interruption detection."""
    state["active_tools"] = {}
    state["subagents"] = []
    state["agent_working"] = False
    state["updated_at"] = now


def _update_session_metadata(
    state: JsonDict, transcript_path: str, cwd: str, now: str
) -> None:
    """Update git tracking and transcript-derived metadata (model, context, branch)."""
    git_changed, new_branch, new_repo = _detect_git_context_change(state, cwd)
    data = read_transcript_data(transcript_path)
    merge_transcript_data(state, data)
    if git_changed:
        _reapply_git_info(state, new_branch, new_repo)
    if data.get("context_pct") is not None:
        append_context_snapshot(state, data["context_pct"], now)
    update_commit_tracking(state, cwd or state.get("cwd", ""))


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
    data = read_transcript_data(transcript_path)
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
        "active_tools": {},
        "agent_working": False,
        "subagents": [],
    }
    if data.get("context_pct") is not None:
        append_context_snapshot(state, data["context_pct"], now)

    state["status"] = derive_status(state)
    update_terminal_tab_title(state)
    write_state(state_file, state)


def handle_pre_tool_use(
    state_file: Path,
    session_id: str,
    cwd: str,
    project_name: str,
    now: str,
    claude_pid: int,
    agent_id: str,
    tool_use_id: str,
    tool_name: str,
) -> None:
    """Tool is about to run — add it to active_tools."""
    if not tool_use_id:
        return
    with _session_lock(session_id):
        state = _ensure_state(
            state_file, session_id, cwd, project_name, now, claude_pid
        )
        tools = state.get("active_tools", {})
        tools[tool_use_id] = {
            "status": "working",
            "tool_name": tool_name,
            "agent_id": agent_id,
            "added_at": now,
        }
        state["active_tools"] = tools
        state["updated_at"] = now
        state["status"] = derive_status(state)
        update_terminal_tab_title(state)
        write_state(state_file, state)


def handle_permission_request(
    state_file: Path,
    session_id: str,
    cwd: str,
    project_name: str,
    now: str,
    claude_pid: int,
    agent_id: str,
    tool_use_id: str = "",
    tool_name: str = "",
    transcript_path: str = "",
    tool_input: JsonDict | None = None,
) -> None:
    # PermissionRequest does NOT provide tool_use_id — resolve via transcript
    if not tool_use_id and transcript_path:
        tool_use_id = (
            _find_tool_use_id_in_transcript(transcript_path, tool_name, tool_input)
            or ""
        )

    cmd = (tool_input or {}).get("command", "") if tool_input else ""

    with _session_lock(session_id):
        state = _ensure_state(
            state_file, session_id, cwd, project_name, now, claude_pid
        )
        tools = state.get("active_tools", {})

        tool_entry: JsonDict = {
            "status": "needs_approval",
            "tool_name": tool_name,
            "agent_id": agent_id,
            "added_at": now,
        }
        if cmd:
            tool_entry["command"] = cmd

        if tool_use_id and tool_use_id in tools:
            # Update existing entry (PreToolUse already added it)
            tools[tool_use_id] = tool_entry
        elif tool_use_id:
            # tool_use_id from transcript but not yet in tools (PreToolUse race)
            tools[tool_use_id] = tool_entry
        else:
            # Fallback: synthetic key so approval state is still tracked
            synthetic_key = f"perm_{now.replace(':', '').replace('-', '')}"
            tools[synthetic_key] = tool_entry

        state["active_tools"] = tools
        state["updated_at"] = now
        state["status"] = derive_status(state)

        # Record approval timestamp
        approvals = state.get("approval_timestamps", [])
        approvals.append(now)
        state["approval_timestamps"] = approvals

        update_terminal_tab_title(state)
        write_state(state_file, state)


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
    with _session_lock(session_id):
        state = _ensure_state(
            state_file, session_id, cwd, project_name, now, claude_pid
        )
        tools = state.get("active_tools", {})
        if tool_use_id:
            tools.pop(tool_use_id, None)
        state["active_tools"] = tools
        state["updated_at"] = now
        state["transcript_path"] = transcript_path

        if not agent_id:
            _update_session_metadata(state, transcript_path, cwd, now)
            update_terminal_tab_title(state)

        state["status"] = derive_status(state)
        write_state(state_file, state)


def handle_stop(
    state_file: Path,
    transcript_path: str,
    session_id: str,
    agent_id: str,
    now: str,
) -> None:
    # Subagent Stop is a no-op — SubagentStop handles cleanup
    if agent_id:
        return

    # Main agent stopped — full reset
    with _session_lock(session_id):
        state = read_state(state_file)
        if state is None:
            return
        _full_reset(state, now)
        _update_session_metadata(state, transcript_path, state.get("cwd", ""), now)
        state["status"] = derive_status(state)
        update_terminal_tab_title(state)
        write_state(state_file, state)


def handle_stop_failure(
    state_file: Path,
    session_id: str,
    agent_id: str,
    now: str,
) -> None:
    # Subagent — no-op
    if agent_id:
        return

    # Main agent — full reset
    with _session_lock(session_id):
        state = read_state(state_file)
        if state is None:
            return
        _full_reset(state, now)
        state["status"] = derive_status(state)
        update_terminal_tab_title(state)
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
    with _session_lock(session_id):
        state = _ensure_state(
            state_file, session_id, cwd, project_name, now, claude_pid
        )

        # Full reset: clear stale tools and subagents from previous turn
        _full_reset(state, now)
        state["agent_working"] = True  # Override: model is now generating
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

        _update_session_metadata(state, transcript_path, cwd, now)

        state["status"] = derive_status(state)
        update_terminal_tab_title(state)

        # Generate title on message 1 (quick) and message 2 (refined)
        title_is_placeholder = state.get("title", "") in TITLE_PLACEHOLDERS
        should_generate = count in (1, 2) and prompts
        if should_generate and (
            (count == 2 and title_is_placeholder)
            or (count == 1 and not state.get("title_generating"))
        ):
            state["title_generating"] = True
            write_state(state_file, state)
            generate_title_async(state_file, prompts)
            return

        write_state(state_file, state)


def handle_subagent_start(
    state_file: Path,
    session_id: str,
    agent_id: str,
    agent_type: str,
    now: str,
) -> None:
    if not agent_id:
        return
    with _session_lock(session_id):
        state = read_state(state_file)
        if state is None:
            return
        subagents = state.get("subagents", [])
        # Don't add duplicates
        if not any(s.get("agent_id") == agent_id for s in subagents):
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


def handle_subagent_stop(
    state_file: Path,
    session_id: str,
    agent_id: str,
) -> None:
    if not agent_id:
        return
    with _session_lock(session_id):
        state = read_state(state_file)
        if state is None:
            return
        # Remove subagent from list
        subagents = state.get("subagents", [])
        subagents = [s for s in subagents if s.get("agent_id") != agent_id]
        state["subagents"] = subagents
        # Remove its tools from active_tools
        tools = state.get("active_tools", {})
        tools = {k: v for k, v in tools.items() if v.get("agent_id") != agent_id}
        state["active_tools"] = tools
        state["status"] = derive_status(state)
        state["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        update_terminal_tab_title(state)
        write_state(state_file, state)


# --- Main entry point ---


def main() -> None:
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

    # Debug logging — one line per event with key state info
    parts = [f"[{now}] {hook_event} session={session_id[:8]}"]
    if agent_id:
        parts.append(f"agent={agent_id[:8]}")
    if tool_use_id:
        parts.append(f"tool={tool_use_id}")
    if tool_name:
        parts.append(f"name={tool_name}")
    # Log pre/post status for debugging transitions
    prev_state = read_state(state_file)
    if prev_state:
        prev_status = prev_state.get("status", "?")
        n_tools = len(prev_state.get("active_tools", {}))
        working = prev_state.get("agent_working", False)
        parts.append(f"was={prev_status} tools={n_tools} working={working}")
    with open(LOG_FILE, "a") as lf:
        lf.write(" ".join(parts) + "\n")

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
        handle_pre_tool_use(
            state_file,
            session_id,
            cwd,
            project_name,
            now,
            claude_pid,
            agent_id,
            tool_use_id,
            tool_name,
        )
    elif hook_event in ("PostToolUse", "PostToolUseFailure"):
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
        handle_stop_failure(state_file, session_id, agent_id, now)
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
        lock_file = SESSIONS_DIR / f"{session_id}.lock"
        lock_file.unlink(missing_ok=True)
    elif hook_event == "PermissionRequest":
        handle_permission_request(
            state_file,
            session_id,
            cwd,
            project_name,
            now,
            claude_pid,
            agent_id,
            tool_use_id,
            tool_name,
            transcript_path,
            hook_input.get("tool_input"),
        )
    elif hook_event == "SubagentStart":
        handle_subagent_start(
            state_file,
            session_id,
            agent_id,
            agent_type,
            now,
        )
    elif hook_event == "SubagentStop":
        handle_subagent_stop(state_file, session_id, agent_id)

    print('{"suppressOutput": true}')


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--watch":
        run_watcher()
    else:
        main()
