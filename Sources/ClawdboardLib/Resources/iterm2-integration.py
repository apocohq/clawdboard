#!/usr/bin/env python3
"""iTerm2 AutoLaunch script for Clawdboard.

Polls ~/.clawdboard/sessions/*.json every 2s and matches Claude Code sessions
to iTerm2 panes by PID ancestry. Writes the iTerm2 session UUID back into
the session JSON so the Clawdboard panel can focus the correct pane.

Install to: ~/.config/iterm2/AppSupport/Scripts/AutoLaunch/clawdboard.py
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import tempfile
from pathlib import Path

import iterm2  # type: ignore[import-untyped]  # bundled with iTerm2's Python runtime

SESSIONS_DIR = Path.home() / ".clawdboard" / "sessions"
POLL_INTERVAL = 2.0


def _build_ppid_map() -> dict[int, int]:
    """Build a full PID -> PPID map with a single subprocess call."""
    try:
        result = subprocess.run(
            ["ps", "-eo", "pid=,ppid="],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (subprocess.TimeoutExpired, OSError):
        return {}
    ppid_map: dict[int, int] = {}
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            try:
                ppid_map[int(parts[0])] = int(parts[1])
            except ValueError:
                continue
    return ppid_map


def _get_ancestor_pids(pid: int, ppid_map: dict[int, int]) -> set[int]:
    """Walk up the process tree using a pre-built PID -> PPID map."""
    ancestors: set[int] = set()
    current = pid
    for _ in range(64):  # guard against cycles
        ppid = ppid_map.get(current)
        if ppid is None or ppid <= 1:
            break
        ancestors.add(ppid)
        current = ppid
    return ancestors


def _read_sessions() -> list[dict[str, object]]:
    """Read all session JSON files from ~/.clawdboard/sessions/."""
    sessions: list[dict[str, object]] = []
    if not SESSIONS_DIR.is_dir():
        return sessions
    for path in SESSIONS_DIR.glob("*.json"):
        try:
            data = json.loads(path.read_text())
            sessions.append(data)
        except (json.JSONDecodeError, OSError):
            continue
    return sessions


def _write_iterm2_session_id(session_path: Path, iterm2_id: str) -> None:
    """Atomically write iterm2_session_id back into the session JSON."""
    try:
        data = json.loads(session_path.read_text())
        if data.get("iterm2_session_id") == iterm2_id:
            return  # already up to date
        data["iterm2_session_id"] = iterm2_id
        fd, tmp_path = tempfile.mkstemp(
            suffix=".iterm2tmp", dir=str(session_path.parent)
        )
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(data, f)
            os.rename(tmp_path, str(session_path))
        except BaseException:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
    except (json.JSONDecodeError, OSError):
        pass


async def main(connection: iterm2.Connection) -> None:
    """Main loop: match Claude sessions to iTerm2 panes by PID."""
    app = await iterm2.async_get_app(connection)

    while True:
        try:
            sessions = await asyncio.to_thread(_read_sessions)
            session_map: dict[str, dict[str, object]] = {}
            for s in sessions:
                sid = s.get("session_id")
                if isinstance(sid, str):
                    session_map[sid] = s

            # Build PID -> pane mapping
            pane_pid_map: dict[int, iterm2.Session] = {}
            for window in app.terminal_windows:
                for tab in window.tabs:
                    for pane in tab.sessions:
                        try:
                            pid = await pane.async_get_variable("pid")
                            if isinstance(pid, int):
                                pane_pid_map[pid] = pane
                        except Exception:  # noqa: BLE001
                            pass

            # Single subprocess to get the full process tree
            ppid_map = await asyncio.to_thread(_build_ppid_map)

            for sid, sdata in session_map.items():
                claude_pid = sdata.get("pid")
                if not isinstance(claude_pid, int) or claude_pid <= 0:
                    continue

                ancestors = _get_ancestor_pids(claude_pid, ppid_map)
                ancestors.add(claude_pid)
                matched_pane: iterm2.Session | None = None
                for shell_pid, pane in pane_pid_map.items():
                    if shell_pid in ancestors:
                        matched_pane = pane
                        break

                if matched_pane is None:
                    continue

                # Write iTerm2 session UUID back so Clawdboard can focus it
                session_file = SESSIONS_DIR / f"{sid}.json"
                if session_file.exists():
                    await asyncio.to_thread(
                        _write_iterm2_session_id, session_file, matched_pane.session_id
                    )

        except Exception:  # noqa: BLE001
            pass  # keep running even on transient errors

        await asyncio.sleep(POLL_INTERVAL)


iterm2.run_forever(main)
