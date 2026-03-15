"""Shared fixtures for hook tests."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

HOOK_PATH = Path(__file__).parent.parent.parent / "hooks" / "clawdboard-hook.py"


@pytest.fixture()
def hook():
    """Import the hook module (has a hyphen in the filename)."""
    spec = importlib.util.spec_from_file_location("clawdboard_hook", HOOK_PATH)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
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

    def _make(entries: list[dict]) -> Path:
        transcript = tmp_path / "transcript.jsonl"
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
