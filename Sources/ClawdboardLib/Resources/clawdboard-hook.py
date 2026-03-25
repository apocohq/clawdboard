#!/usr/bin/env python3
"""Clawdboard hook script — called by Claude Code hooks to track session state.

Reads hook input from stdin, extracts session data from JSONL transcript,
and writes/updates a state file in ~/.clawdboard/sessions/.
"""

from __future__ import annotations

import json
import os
import random
import re
import subprocess
import sys
from datetime import datetime, timezone
from itertools import product
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

# Whimsical fallback titles when AI title generation fails (Claude-style)

_TITLE_ADJECTIVES = [
    "caffeinated",
    "wandering",
    "cosmic",
    "turbo",
    "electric",
    "quantum",
    "galloping",
    "hypersonic",
    "neon",
    "interstellar",
    "volcanic",
    "supersonic",
    "midnight",
    "chromatic",
    "orbital",
    "fizzy",
    "turbulent",
    "galactic",
    "velvet",
    "sparkling",
]
_TITLE_ANIMALS = [
    "quokka",
    "platypus",
    "pangolin",
    "capybara",
    "narwhal",
    "wombat",
    "axolotl",
    "otter",
    "tardigrade",
    "corgi",
    "penguin",
    "sloth",
    "flamingo",
    "hedgehog",
    "raccoon",
    "chameleon",
    "lemur",
    "puffin",
    "ocelot",
    "ibex",
]

TITLE_FALLBACKS = list(
    f"{adj}-{animal}" for adj, animal in product(_TITLE_ADJECTIVES, _TITLE_ANIMALS)
)


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


def update_commit_tracking(state: JsonDict, cwd: str) -> None:
    """Update head_sha, commit_count, unpushed_count, and git_dirty."""
    head = get_git_head_sha(cwd)
    if head:
        state["head_sha"] = head
    start = state.get("start_sha")
    if start and head:
        state["commit_count"] = get_commit_count(cwd, start)
    state["unpushed_count"] = get_unpushed_count(cwd)
    state["git_dirty"] = get_git_dirty(cwd)


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
        lf.write(
            f"[{now}] {hook_event}{subtype_suffix} session={session_id} cwd={cwd}\n"
        )

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


_TITLE_SYSTEM_PROMPT = (
    "Generate a 1-4 word kebab-case slug summarizing the topic of the user messages. "
    "Rules: lowercase, hyphens between words, no explanation, no commentary. "
    "Always generate a slug, even if the topic is not about coding. "
    "Examples: api-refactor, ant-habitats, shark-biology, fix-login, db-migration, "
    "gorilla-facts, perf-tuning, tree-species, dep-upgrade, recipe-ideas. "
    "Output ONLY the slug."
)

_TITLE_SCRIPT = """\
import json, os, re, signal, subprocess, random
from pathlib import Path

state_file = Path(os.environ["_CLAWDBOARD_STATE_FILE"])
prompts = json.loads(os.environ["_CLAWDBOARD_PROMPTS"])
fallbacks = json.loads(os.environ["_CLAWDBOARD_TITLE_FALLBACKS"])
system_prompt = os.environ["_CLAWDBOARD_TITLE_SYSTEM_PROMPT"]

claude_prompt = "\\n".join(f"Message {i+1}: {p}" for i, p in enumerate(prompts))

title = ""
try:
    proc = subprocess.Popen(
        ["claude", "-p", "--model", "haiku", "--no-session-persistence",
         "--system-prompt", system_prompt, "--tools", "",
         "--output-format", "text", "--max-budget-usd", "0.01",
         claude_prompt],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL, text=True,
        start_new_session=True,
    )
    try:
        stdout, _ = proc.communicate(timeout=15)
        if proc.returncode == 0 and stdout:
            text = stdout.strip()
            if not text.lower().startswith("error"):
                raw = text.lower().replace(" ", "-").replace("_", "-")
                slug = re.sub(r"[^a-z0-9-]", "", raw)
                slug = re.sub(r"-{2,}", "-", slug).strip("-")
                if slug:
                    words = slug.split("-")
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

# Fall back to a whimsical name
if not title and fallbacks:
    idx = random.choice(range(len(fallbacks)))
    title = fallbacks[idx]

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


def extract_prompt_first_line(prompt: str, max_len: int = 200) -> str | None:
    """Strip IDE/system XML tags and return the first line, or None if empty."""
    cleaned = re.sub(r"<([^>]+)>.*?</\1>", "", prompt, flags=re.DOTALL).strip()
    if not cleaned:
        return None
    first_line = cleaned.split("\n")[0].strip()[:max_len]
    return first_line or None


def generate_title_async(state_file: Path, user_prompts: list[str]) -> None:
    """Spawn a detached process to generate a session title via claude CLI."""
    env = os.environ.copy()
    env["_CLAWDBOARD_TITLE_GEN"] = "1"
    env["_CLAWDBOARD_STATE_FILE"] = str(state_file)
    env["_CLAWDBOARD_PROMPTS"] = json.dumps(user_prompts)
    env["_CLAWDBOARD_TITLE_FALLBACKS"] = json.dumps(TITLE_FALLBACKS)
    env["_CLAWDBOARD_TITLE_SYSTEM_PROMPT"] = _TITLE_SYSTEM_PROMPT
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
        "status": "working",
        "started_at": now,
        "updated_at": now,
        "pid": claude_pid,
        "is_hook_tracked": True,
        "start_sha": head_sha,
        "head_sha": head_sha,
        "commit_count": 0,
        "unpushed_count": get_unpushed_count(cwd),
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
    head_sha = get_git_head_sha(cwd)
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
        "start_sha": head_sha,
        "head_sha": head_sha,
        "commit_count": 0,
        "unpushed_count": get_unpushed_count(cwd),
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

    # Detect cwd change (e.g. session moved into a worktree) and re-derive git info
    cwd_changed = bool(cwd and cwd != state.get("cwd"))
    if cwd_changed:
        state["cwd"] = cwd
        new_branch = get_git_branch(cwd)
        new_repo = get_github_repo(cwd)
        state["git_branch"] = new_branch
        state["github_repo"] = new_repo
        # Reset start_sha when repo changes
        head_sha = get_git_head_sha(cwd)
        state["start_sha"] = head_sha
        state["head_sha"] = head_sha
        state["commit_count"] = 0
        state["unpushed_count"] = get_unpushed_count(cwd)

    # Write "working" immediately so the UI updates before the slow transcript read
    state["status"] = "working"
    state["updated_at"] = now
    write_state(state_file, state)

    # Then read transcript data and write again with full info
    data = read_transcript_data(transcript_path, state_file)
    merge_transcript_data(state, data)
    if cwd_changed:
        _reapply_git_info(state, new_branch, new_repo)
    if data.get("context_pct") is not None:
        append_context_snapshot(state, data["context_pct"], now)
    update_commit_tracking(state, cwd or state.get("cwd", ""))
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
    update_commit_tracking(state, state.get("cwd", ""))
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

    # Detect cwd change (e.g. session moved into a worktree) and re-derive git info
    cwd_changed = bool(cwd and cwd != state.get("cwd"))
    if cwd_changed:
        state["cwd"] = cwd
        new_branch = get_git_branch(cwd)
        new_repo = get_github_repo(cwd)
        state["git_branch"] = new_branch
        state["github_repo"] = new_repo
        # Reset start_sha when repo changes
        head_sha = get_git_head_sha(cwd)
        state["start_sha"] = head_sha
        state["head_sha"] = head_sha
        state["commit_count"] = 0
        state["unpushed_count"] = get_unpushed_count(cwd)

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
        first_line = extract_prompt_first_line(prompt)
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
        if cwd_changed:
            _reapply_git_info(state, new_branch, new_repo)
        if data.get("context_pct") is not None:
            append_context_snapshot(state, data["context_pct"], now)
        update_commit_tracking(state, cwd or state.get("cwd", ""))
        write_state(state_file, state)
        generate_title_async(state_file, prompts)
        return

    merge_transcript_data(state, data)
    if cwd_changed:
        _reapply_git_info(state, new_branch, new_repo)
    if data.get("context_pct") is not None:
        append_context_snapshot(state, data["context_pct"], now)
    update_commit_tracking(state, cwd or state.get("cwd", ""))
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
