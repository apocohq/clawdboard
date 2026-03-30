"""Shared fixtures for hook tests."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

HOOK_PATH = (
    Path(__file__).parent.parent.parent
    / "Sources"
    / "ClawdboardLib"
    / "Resources"
    / "clawdboard-hook.py"
)


@pytest.fixture()
def hook(tmp_sessions):
    """Import the hook module, patching SESSIONS_DIR to use tmp dir."""
    spec = importlib.util.spec_from_file_location("clawdboard_hook", HOOK_PATH)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    # Redirect agent fact files to temp directory
    mod.SESSIONS_DIR = tmp_sessions
    return mod


@pytest.fixture()
def tmp_sessions(tmp_path):
    """Provide a temporary sessions directory."""
    sessions = tmp_path / "sessions"
    sessions.mkdir()
    return sessions


@pytest.fixture()
def make_transcript(tmp_path):
    """Factory to create a JSONL transcript file with entries."""
    _counter = [0]

    def _make(entries: list[dict]) -> Path:
        _counter[0] += 1
        transcript = tmp_path / f"transcript-{_counter[0]}.jsonl"
        lines = [json.dumps(e) for e in entries]
        transcript.write_text("\n".join(lines))
        return transcript

    return _make


@pytest.fixture()
def make_state(tmp_sessions):
    """Factory to create a session state file."""

    def _make(session_id: str, state: dict) -> Path:
        state_file = tmp_sessions / f"{session_id}.json"
        state_file.write_text(json.dumps(state))
        return state_file

    return _make


