"""Tests for clawdboard-hook.py."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

NOW = "2026-01-01T00:00:00Z"
SUBAGENT = {"agent_id": "a1", "agent_type": "general", "started_at": "t"}


# -- Context window lookup --


class TestGetContextWindow:
    def test_exact_match(self, hook):
        cache = {"claude-opus-4-6": 1000000}
        with patch.object(hook, "_load_model_cache", return_value=cache):
            assert hook.get_context_window("claude-opus-4-6") == 1000000

    def test_prefix_match(self, hook):
        cache = {"claude-opus-4-6": 1000000, "claude-sonnet-4-6": 200000}
        with patch.object(hook, "_load_model_cache", return_value=cache):
            result = hook.get_context_window("claude-opus-4-6-20260205")
            assert result == 1000000

    def test_empty_model_returns_default(self, hook):
        assert hook.get_context_window("") == 200000

    def test_unknown_model_returns_default(self, hook):
        with patch.object(hook, "_load_model_cache", return_value={}):
            assert hook.get_context_window("unknown-model") == 200000

    def test_fallback_baseline_has_opus_1m(self, hook):
        """Hardcoded baseline used when cache and fetch both fail."""
        fake = Path("/nonexistent/cache.json")
        with patch.object(hook, "MODEL_CACHE_FILE", fake):
            with patch("urllib.request.urlopen", side_effect=Exception):
                assert hook.get_context_window("claude-opus-4-6") == 1000000

    def test_fallback_baseline_has_sonnet_200k(self, hook):
        fake = Path("/nonexistent/cache.json")
        with patch.object(hook, "MODEL_CACHE_FILE", fake):
            with patch("urllib.request.urlopen", side_effect=Exception):
                assert hook.get_context_window("claude-sonnet-4-6") == 200000


# -- Transcript reading --


class TestReadTranscriptData:
    def test_empty_path_returns_empty(self, hook):
        assert hook.read_transcript_data("", Path("/dev/null")) == {}

    def test_missing_file_returns_empty(self, hook):
        result = hook.read_transcript_data("/no/file.jsonl", Path("/dev/null"))
        assert result == {}

    def test_extracts_model_and_context(self, hook, make_transcript):
        transcript = make_transcript(
            [
                {
                    "sessionId": "abc",
                    "gitBranch": "main",
                    "slug": "test-slug",
                    "message": {
                        "model": "claude-sonnet-4-6",
                        "usage": {
                            "input_tokens": 1000,
                            "output_tokens": 500,
                            "cache_creation_input_tokens": 200,
                            "cache_read_input_tokens": 3000,
                        },
                    },
                }
            ]
        )
        with patch.object(hook, "get_context_window", return_value=200000):
            data = hook.read_transcript_data(str(transcript), Path("/dev/null"))
        assert data["model"] == "claude-sonnet-4-6"
        assert data["git_branch"] == "main"
        assert data["slug"] == "test-slug"

    def test_context_pct_uses_model_window(self, hook, make_transcript):
        transcript = make_transcript(
            [
                {
                    "sessionId": "abc",
                    "message": {
                        "model": "claude-opus-4-6",
                        "usage": {
                            "input_tokens": 100000,
                            "output_tokens": 50000,
                            "cache_creation_input_tokens": 0,
                            "cache_read_input_tokens": 0,
                        },
                    },
                }
            ]
        )
        # 150k / 1M = 15%
        with patch.object(hook, "get_context_window", return_value=1000000):
            data = hook.read_transcript_data(str(transcript), Path("/dev/null"))
        assert data["context_pct"] == 15.0


# -- State helpers --


class TestStateHelpers:
    def test_read_write_roundtrip(self, hook, tmp_path):
        state_file = tmp_path / "test.json"
        state = {"session_id": "abc", "status": "working"}
        hook.write_state(state_file, state)
        assert hook.read_state(state_file) == state

    def test_read_missing_returns_none(self, hook, tmp_path):
        assert hook.read_state(tmp_path / "missing.json") is None

    def test_read_corrupt_returns_none(self, hook, tmp_path):
        bad = tmp_path / "bad.json"
        bad.write_text("not json{{{")
        assert hook.read_state(bad) is None

    def test_merge_transcript_data(self, hook):
        state = {"model": "old", "status": "working"}
        hook.merge_transcript_data(state, {"model": "new"})
        assert state["model"] == "new"
        assert state["status"] == "working"  # not in TRANSCRIPT_KEYS

    def test_merge_skips_none_values(self, hook):
        state = {"model": "keep-this"}
        hook.merge_transcript_data(state, {"model": None})
        assert state["model"] == "keep-this"

    def test_make_base_state(self, hook):
        state = hook.make_base_state("s1", "/home/user/proj", "proj", NOW, 1234)
        assert state["session_id"] == "s1"
        assert state["status"] == "working"
        assert state["pid"] == 1234
        assert state["is_hook_tracked"] is True


# -- Event handlers --


class TestEventHandlers:
    def test_session_start_creates_state(self, hook, tmp_path, make_transcript):
        state_file = tmp_path / "s1.json"
        transcript = make_transcript([])
        hook.handle_session_start(
            state_file,
            str(transcript),
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
        )
        state = json.loads(state_file.read_text())
        assert state["session_id"] == "s1"
        assert state["status"] == "working"

    def test_post_tool_use_updates_status(self, hook, tmp_path, make_transcript):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "status": "waiting"}))
        transcript = make_transcript([])
        hook.handle_post_tool_use(
            state_file,
            str(transcript),
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
        )
        state = json.loads(state_file.read_text())
        assert state["status"] == "working"

    def test_stop_sets_pending_waiting(self, hook, tmp_path, make_transcript):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "status": "working"}))
        transcript = make_transcript([])
        hook.handle_stop(state_file, str(transcript), NOW)
        state = json.loads(state_file.read_text())
        assert state["status"] == "pending_waiting"

    def test_stop_noop_without_state(self, hook, tmp_path, make_transcript):
        state_file = tmp_path / "missing.json"
        transcript = make_transcript([])
        hook.handle_stop(state_file, str(transcript), NOW)
        assert not state_file.exists()

    def test_notification_permission_prompt(self, hook, tmp_path):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "status": "working"}))
        hook.handle_notification(state_file, "permission_prompt", NOW)
        state = json.loads(state_file.read_text())
        assert state["status"] == "needs_approval"

    def test_notification_other(self, hook, tmp_path):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "status": "working"}))
        hook.handle_notification(state_file, "other_type", NOW)
        state = json.loads(state_file.read_text())
        assert state["status"] == "waiting"

    def test_permission_request(self, hook, tmp_path):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "status": "working"}))
        hook.handle_permission_request(state_file, NOW)
        state = json.loads(state_file.read_text())
        assert state["status"] == "needs_approval"

    def test_subagent_start_adds(self, hook, tmp_path):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "subagents": []}))
        hook.handle_subagent_start(state_file, "a1", "general", NOW)
        state = json.loads(state_file.read_text())
        assert len(state["subagents"]) == 1
        assert state["subagents"][0]["agent_id"] == "a1"

    def test_subagent_start_no_duplicate(self, hook, tmp_path):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "subagents": [SUBAGENT]}))
        hook.handle_subagent_start(state_file, "a1", "general", NOW)
        state = json.loads(state_file.read_text())
        assert len(state["subagents"]) == 1

    def test_subagent_stop_removes(self, hook, tmp_path):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "subagents": [SUBAGENT]}))
        hook.handle_subagent_stop(state_file, "a1", NOW)
        state = json.loads(state_file.read_text())
        assert len(state["subagents"]) == 0

    def test_subagent_start_noop_empty_id(self, hook, tmp_path):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "subagents": []}))
        hook.handle_subagent_start(state_file, "", "general", NOW)
        state = json.loads(state_file.read_text())
        assert len(state["subagents"]) == 0
