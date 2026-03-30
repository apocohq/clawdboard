"""Tests for clawdboard-hook.py."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

NOW = "2026-01-01T00:00:00Z"


def read_session(hook, session_id):
    """Helper to read a session state file."""
    path = hook.SESSIONS_DIR / f"{session_id}.json"
    if not path.is_file():
        return None
    return json.loads(path.read_text())


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
        assert hook.read_transcript_data("") == {}

    def test_missing_file_returns_empty(self, hook):
        result = hook.read_transcript_data("/no/file.jsonl")
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
            data = hook.read_transcript_data(str(transcript))
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
            data = hook.read_transcript_data(str(transcript))
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
        assert state["pid"] == 1234
        assert state["is_hook_tracked"] is True
        assert state["active_tools"] == {}
        assert state["agent_working"] is False
        assert state["subagents"] == []


# -- Status derivation --


class TestDeriveStatus:
    def test_needs_approval_takes_priority(self, hook):
        state = {
            "active_tools": {
                "t1": {"status": "working"},
                "t2": {"status": "needs_approval"},
            },
            "agent_working": True,
        }
        assert hook.derive_status(state) == "needs_approval"

    def test_working_from_tools(self, hook):
        state = {"active_tools": {"t1": {"status": "working"}}, "agent_working": False}
        assert hook.derive_status(state) == "working"

    def test_working_from_agent_working(self, hook):
        state = {"active_tools": {}, "agent_working": True}
        assert hook.derive_status(state) == "working"

    def test_waiting_when_idle(self, hook):
        state = {"active_tools": {}, "agent_working": False}
        assert hook.derive_status(state) == "waiting"

    def test_waiting_when_empty(self, hook):
        state = {}
        assert hook.derive_status(state) == "waiting"


# -- Full reset helper --


class TestFullReset:
    def test_clears_all_transient_state(self, hook):
        state = {
            "active_tools": {"t1": {"status": "working"}},
            "subagents": [{"agent_id": "a1"}],
            "agent_working": True,
        }
        hook._full_reset(state, NOW)
        assert state["active_tools"] == {}
        assert state["subagents"] == []
        assert state["agent_working"] is False
        assert state["updated_at"] == NOW


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
        assert state["status"] == "waiting"
        assert state["active_tools"] == {}
        assert state["agent_working"] is False

    def test_pre_tool_use_adds_tool(self, hook, make_state):
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {},
                "agent_working": True,
            },
        )
        hook.handle_pre_tool_use(
            hook.SESSIONS_DIR / "s1.json",
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="",
            tool_use_id="tool-123",
            tool_name="Bash",
        )
        state = read_session(hook, "s1")
        assert "tool-123" in state["active_tools"]
        assert state["active_tools"]["tool-123"]["status"] == "working"
        assert state["status"] == "working"

    def test_pre_tool_use_noop_without_tool_id(self, hook, make_state):
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {},
                "agent_working": True,
            },
        )
        hook.handle_pre_tool_use(
            hook.SESSIONS_DIR / "s1.json",
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="",
            tool_use_id="",
            tool_name="Bash",
        )
        state = read_session(hook, "s1")
        assert state["active_tools"] == {}

    def test_post_tool_use_removes_tool(self, hook, make_state, make_transcript):
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {"tool-123": {"status": "working"}},
                "agent_working": True,
            },
        )
        transcript = make_transcript([])
        hook.handle_post_tool_use(
            hook.SESSIONS_DIR / "s1.json",
            str(transcript),
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="",
            tool_use_id="tool-123",
        )
        state = read_session(hook, "s1")
        assert "tool-123" not in state["active_tools"]

    def test_stop_full_reset(self, hook, make_state, make_transcript):
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {"t1": {"status": "working"}},
                "subagents": [{"agent_id": "a1"}],
                "agent_working": True,
            },
        )
        transcript = make_transcript([])
        hook.handle_stop(hook.SESSIONS_DIR / "s1.json", str(transcript), "s1", "", NOW)
        state = read_session(hook, "s1")
        assert state["status"] == "waiting"
        assert state["active_tools"] == {}
        assert state["subagents"] == []
        assert state["agent_working"] is False

    def test_stop_noop_for_subagent(self, hook, make_state, make_transcript):
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {"t1": {"status": "working", "agent_id": "a1"}},
                "agent_working": True,
            },
        )
        transcript = make_transcript([])
        hook.handle_stop(
            hook.SESSIONS_DIR / "s1.json", str(transcript), "s1", "a1", NOW
        )
        state = read_session(hook, "s1")
        # State should be unchanged — SubagentStop handles subagent cleanup
        assert "t1" in state["active_tools"]

    def test_stop_noop_without_state(self, hook, tmp_path, make_transcript):
        state_file = tmp_path / "missing.json"
        transcript = make_transcript([])
        hook.handle_stop(state_file, str(transcript), "s1", "", NOW)
        # No crash, no file created

    def test_stop_failure_full_reset(self, hook, make_state):
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {"t1": {"status": "working"}},
                "subagents": [{"agent_id": "a1"}],
                "agent_working": True,
            },
        )
        hook.handle_stop_failure(hook.SESSIONS_DIR / "s1.json", "s1", "", NOW)
        state = read_session(hook, "s1")
        assert state["status"] == "waiting"
        assert state["active_tools"] == {}
        assert state["subagents"] == []

    def test_permission_request_sets_needs_approval(self, hook, make_state):
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {
                    "t1": {"status": "working", "tool_name": "Bash", "agent_id": ""}
                },
                "agent_working": True,
            },
        )
        hook.handle_permission_request(
            hook.SESSIONS_DIR / "s1.json",
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="",
            tool_use_id="t1",
            tool_name="Bash",
            tool_input={"command": "rm -rf /"},
        )
        state = read_session(hook, "s1")
        assert state["active_tools"]["t1"]["status"] == "needs_approval"
        assert state["active_tools"]["t1"]["command"] == "rm -rf /"
        assert state["status"] == "needs_approval"

    def test_permission_request_synthetic_key_fallback(self, hook, make_state):
        """When tool_use_id can't be resolved, a synthetic key is used."""
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {},
                "agent_working": True,
            },
        )
        hook.handle_permission_request(
            hook.SESSIONS_DIR / "s1.json",
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="",
            tool_use_id="",
            tool_name="Bash",
        )
        state = read_session(hook, "s1")
        # Should have a synthetic key starting with "perm_"
        keys = [k for k in state["active_tools"] if k.startswith("perm_")]
        assert len(keys) == 1
        assert state["active_tools"][keys[0]]["status"] == "needs_approval"

    def test_permission_request_records_approval_timestamp(self, hook, make_state):
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {},
                "agent_working": True,
            },
        )
        hook.handle_permission_request(
            hook.SESSIONS_DIR / "s1.json",
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="",
        )
        state = read_session(hook, "s1")
        assert NOW in state["approval_timestamps"]

    def test_subagent_start_adds_to_list(self, hook, make_state):
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {},
                "agent_working": True,
                "subagents": [],
            },
        )
        hook.handle_subagent_start(
            hook.SESSIONS_DIR / "s1.json",
            "s1",
            "a1",
            "Explore",
            NOW,
        )
        state = read_session(hook, "s1")
        assert len(state["subagents"]) == 1
        assert state["subagents"][0]["agent_id"] == "a1"
        assert state["subagents"][0]["agent_type"] == "Explore"

    def test_subagent_start_no_duplicates(self, hook, make_state):
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {},
                "agent_working": True,
                "subagents": [
                    {"agent_id": "a1", "agent_type": "Explore", "started_at": NOW}
                ],
            },
        )
        hook.handle_subagent_start(
            hook.SESSIONS_DIR / "s1.json",
            "s1",
            "a1",
            "Explore",
            NOW,
        )
        state = read_session(hook, "s1")
        assert len(state["subagents"]) == 1

    def test_subagent_start_noop_empty_id(self, hook, make_state):
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {},
                "agent_working": True,
                "subagents": [],
            },
        )
        hook.handle_subagent_start(
            hook.SESSIONS_DIR / "s1.json",
            "s1",
            "",
            "general",
            NOW,
        )
        state = read_session(hook, "s1")
        assert state["subagents"] == []

    def test_subagent_stop_removes_agent_and_tools(self, hook, make_state):
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {
                    "t1": {"status": "working", "agent_id": "a1"},
                    "t2": {"status": "working", "agent_id": ""},
                },
                "agent_working": True,
                "subagents": [
                    {"agent_id": "a1", "agent_type": "Explore", "started_at": NOW}
                ],
            },
        )
        hook.handle_subagent_stop(hook.SESSIONS_DIR / "s1.json", "s1", "a1")
        state = read_session(hook, "s1")
        assert "t1" not in state["active_tools"]  # Removed (agent_id=a1)
        assert "t2" in state["active_tools"]  # Kept (main agent)
        assert state["subagents"] == []

    def test_user_prompt_submit_sets_working(self, hook, make_state, make_transcript):
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {"stale": {"status": "working"}},
                "subagents": [{"agent_id": "old"}],
                "agent_working": False,
            },
        )
        transcript = make_transcript([])
        hook.handle_user_prompt_submit(
            hook.SESSIONS_DIR / "s1.json",
            str(transcript),
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
        )
        state = read_session(hook, "s1")
        assert state["status"] == "working"
        assert state["agent_working"] is True
        assert state["active_tools"] == {}  # Stale tools cleared
        assert state["subagents"] == []  # Stale subagents cleared


# -- Tag stripping / first-line extraction --


class TestExtractPromptFirstLine:
    def test_strips_xml_tags_and_returns_first_line(self, hook):
        prompt = (
            "<ide_opened_file>user opened foo.swift</ide_opened_file>"
            "<system_context>ctx\nmore</system_context>"
            "fix the login bug\nsecond line"
        )
        assert hook.extract_prompt_first_line(prompt) == "fix the login bug"

    def test_plain_prompt_returns_first_line(self, hook):
        assert hook.extract_prompt_first_line("hello world\nbye") == "hello world"

    def test_all_tags_returns_none(self, hook):
        assert hook.extract_prompt_first_line("<tag>only tags</tag>") is None


# -- Commit tracking --


class TestUpdateCommitTracking:
    def test_resets_start_sha_when_not_ancestor(self, hook):
        """start_sha should reset to HEAD when it's no longer an ancestor (rebase/force-push)."""
        state = {"start_sha": "old_sha", "head_sha": "old_sha", "commit_count": 3}
        with (
            patch.object(hook, "get_git_head_sha", return_value="new_head"),
            patch.object(hook, "is_ancestor", return_value=False),
            patch.object(hook, "get_unpushed_count", return_value=0),
            patch.object(hook, "get_git_dirty", return_value=False),
        ):
            hook.update_commit_tracking(state, "/fake")
        assert state["start_sha"] == "new_head"
        assert state["commit_count"] == 0

    def test_keeps_start_sha_when_ancestor(self, hook):
        """start_sha should stay and commit_count should update normally."""
        state = {"start_sha": "old_sha", "head_sha": "old_sha", "commit_count": 0}
        with (
            patch.object(hook, "get_git_head_sha", return_value="new_head"),
            patch.object(hook, "is_ancestor", return_value=True),
            patch.object(hook, "get_commit_count", return_value=2),
            patch.object(hook, "get_unpushed_count", return_value=1),
            patch.object(hook, "get_git_dirty", return_value=True),
        ):
            hook.update_commit_tracking(state, "/fake")
        assert state["start_sha"] == "old_sha"
        assert state["commit_count"] == 2
        assert state["unpushed_count"] == 1
        assert state["git_dirty"] is True


# -- Watcher resolution --


class TestIsLastEntryInterrupt:
    """Test _is_last_entry_interrupt."""

    def test_detects_real_interrupt(self, hook, make_transcript):
        """User interrupt message with correct JSON structure is detected."""
        transcript = make_transcript(
            [
                {"type": "assistant", "message": {"role": "assistant", "content": "working"}},
                {
                    "type": "user",
                    "message": {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": "[Request interrupted by user for tool use]"}
                        ],
                    },
                },
            ]
        )
        assert hook._is_last_entry_interrupt(str(transcript)) is True

    def test_ignores_assistant_discussing_interrupts(self, hook, make_transcript):
        """Assistant message containing the string should not trigger."""
        transcript = make_transcript(
            [
                {
                    "type": "assistant",
                    "message": {
                        "role": "assistant",
                        "content": [
                            {"type": "text", "text": "Request interrupted by user is handled by the watcher"}
                        ],
                    },
                },
            ]
        )
        assert hook._is_last_entry_interrupt(str(transcript)) is False

    def test_ignores_tool_result_containing_string(self, hook, make_transcript):
        """Tool result with the string in output should not trigger."""
        transcript = make_transcript(
            [
                {
                    "type": "user",
                    "message": {
                        "role": "user",
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": "toolu_123",
                                "content": "Request interrupted by user",
                            }
                        ],
                    },
                },
            ]
        )
        assert hook._is_last_entry_interrupt(str(transcript)) is False

    def test_no_interruption(self, hook, make_transcript):
        transcript = make_transcript(
            [{"type": "assistant", "message": {"role": "assistant", "content": "done"}}]
        )
        assert hook._is_last_entry_interrupt(str(transcript)) is False

    def test_missing_transcript(self, hook):
        assert hook._is_last_entry_interrupt("/nonexistent/file.jsonl") is False


class TestWatcherResolveActiveTools:
    """Test _resolve_active_tools with active_tools in session state."""

    def test_resolves_interrupted_session(self, hook, make_transcript, make_state):
        """Real interrupt entry as last line should reset."""
        transcript = make_transcript(
            [
                {
                    "type": "user",
                    "message": {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": "[Request interrupted by user]"}
                        ],
                    },
                },
            ]
        )
        make_state(
            "s1",
            {
                "session_id": "s1",
                "pid": 1,
                "transcript_path": str(transcript),
                "active_tools": {"t1": {"status": "working", "added_at": NOW}},
                "subagents": [{"agent_id": "a1"}],
                "agent_working": True,
                "updated_at": NOW,
            },
        )
        state = json.loads((hook.SESSIONS_DIR / "s1.json").read_text())
        hook._resolve_active_tools("s1", state, hook.SESSIONS_DIR / "s1.json", None)
        updated = json.loads((hook.SESSIONS_DIR / "s1.json").read_text())
        assert updated["active_tools"] == {}
        assert updated["agent_working"] is False
        assert updated["status"] == "waiting"

    def test_skips_non_interrupt_last_entry(self, hook, make_transcript, make_state):
        """Normal assistant message as last line should not reset."""
        transcript = make_transcript(
            [
                {
                    "type": "assistant",
                    "message": {
                        "role": "assistant",
                        "content": [
                            {"type": "text", "text": "Request interrupted by user is a known issue"}
                        ],
                    },
                },
            ]
        )
        make_state(
            "s1",
            {
                "session_id": "s1",
                "pid": 1,
                "transcript_path": str(transcript),
                "active_tools": {"t1": {"status": "working", "added_at": NOW}},
                "subagents": [],
                "agent_working": True,
                "updated_at": NOW,
            },
        )
        state = json.loads((hook.SESSIONS_DIR / "s1.json").read_text())
        hook._resolve_active_tools("s1", state, hook.SESSIONS_DIR / "s1.json", None)
        updated = json.loads((hook.SESSIONS_DIR / "s1.json").read_text())
        assert "t1" in updated["active_tools"]
        assert updated["agent_working"] is True

    def test_process_inspection_flips_to_working(self, hook, make_state):
        """When a needs_approval command is already running, flip to working."""
        make_state(
            "s1",
            {
                "session_id": "s1",
                "pid": 12345,
                "transcript_path": "",
                "active_tools": {
                    "t1": {
                        "status": "needs_approval",
                        "command": "npm test",
                        "added_at": "2025-01-01T00:00:00Z",
                    },
                },
                "agent_working": True,
                "updated_at": NOW,
            },
        )
        state = json.loads((hook.SESSIONS_DIR / "s1.json").read_text())
        with patch.object(hook, "_is_command_running", return_value=True):
            hook._resolve_active_tools("s1", state, hook.SESSIONS_DIR / "s1.json", None)
        updated = json.loads((hook.SESSIONS_DIR / "s1.json").read_text())
        assert updated["active_tools"]["t1"]["status"] == "working"
        assert updated["status"] == "working"


class TestWatcherTick:
    """Test _watcher_tick for PID liveness and session cleanup."""

    def test_cleans_up_dead_pid_session(self, hook, tmp_sessions, make_state):
        make_state("s1", {"session_id": "s1", "pid": 99999999, "updated_at": NOW})
        active = hook._watcher_tick()
        assert active == 0
        assert not (tmp_sessions / "s1.json").exists()

    def test_counts_live_sessions(self, hook, tmp_sessions, make_state):
        import os

        make_state(
            "s1",
            {
                "session_id": "s1",
                "pid": os.getpid(),
                "updated_at": NOW,
                "active_tools": {},
                "agent_working": False,
            },
        )
        active = hook._watcher_tick()
        assert active == 1


# -- Full lifecycle simulation --


class TestFullLifecycle:
    """Simulate a realistic session lifecycle through hook events."""

    def test_session_lifecycle(self, hook, make_transcript):
        """SessionStart → UserPromptSubmit → PreToolUse → PostToolUse → Stop."""
        state_file = hook.SESSIONS_DIR / "s1.json"
        transcript = make_transcript([])

        # 1. SessionStart
        hook.handle_session_start(
            state_file, str(transcript), "s1", "/proj", "proj", NOW, 99
        )
        state = read_session(hook, "s1")
        assert state["status"] == "waiting"
        assert state["active_tools"] == {}

        # 2. UserPromptSubmit
        hook.handle_user_prompt_submit(
            state_file,
            str(transcript),
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
        )
        state = read_session(hook, "s1")
        assert state["status"] == "working"
        assert state["agent_working"] is True

        # 3. PreToolUse
        hook.handle_pre_tool_use(
            state_file,
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="",
            tool_use_id="t1",
            tool_name="Bash",
        )
        state = read_session(hook, "s1")
        assert state["active_tools"]["t1"]["status"] == "working"

        # 4. PostToolUse
        hook.handle_post_tool_use(
            state_file,
            str(transcript),
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="",
            tool_use_id="t1",
        )
        state = read_session(hook, "s1")
        assert "t1" not in state["active_tools"]

        # 5. Stop
        hook.handle_stop(state_file, str(transcript), "s1", "", NOW)
        state = read_session(hook, "s1")
        assert state["status"] == "waiting"
        assert state["agent_working"] is False

    def test_permission_lifecycle(self, hook, make_state, make_transcript):
        """PreToolUse → PermissionRequest → (approve) → PostToolUse."""
        state_file = hook.SESSIONS_DIR / "s1.json"
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {},
                "agent_working": True,
            },
        )
        transcript = make_transcript([])

        # PreToolUse
        hook.handle_pre_tool_use(
            state_file,
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="",
            tool_use_id="t1",
            tool_name="Bash",
        )
        state = read_session(hook, "s1")
        assert state["status"] == "working"

        # PermissionRequest
        hook.handle_permission_request(
            state_file,
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="",
            tool_use_id="t1",
            tool_name="Bash",
            tool_input={"command": "rm -rf /tmp/test"},
        )
        state = read_session(hook, "s1")
        assert state["active_tools"]["t1"]["status"] == "needs_approval"
        assert state["status"] == "needs_approval"

        # PostToolUse (after user approves and tool runs)
        hook.handle_post_tool_use(
            state_file,
            str(transcript),
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="",
            tool_use_id="t1",
        )
        state = read_session(hook, "s1")
        assert "t1" not in state["active_tools"]
        assert state["status"] == "working"  # agent_working is still True

    def test_subagent_lifecycle(self, hook, make_state, make_transcript):
        """Main + subagent working concurrently."""
        state_file = hook.SESSIONS_DIR / "s1.json"
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {},
                "agent_working": True,
                "subagents": [],
            },
        )
        transcript = make_transcript([])

        # SubagentStart
        hook.handle_subagent_start(state_file, "s1", "a1", "Explore", NOW)
        state = read_session(hook, "s1")
        assert len(state["subagents"]) == 1

        # Subagent does a tool
        hook.handle_pre_tool_use(
            state_file,
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="a1",
            tool_use_id="t-sub",
            tool_name="Read",
        )
        state = read_session(hook, "s1")
        assert "t-sub" in state["active_tools"]
        assert state["active_tools"]["t-sub"]["agent_id"] == "a1"

        # Main agent does a tool concurrently
        hook.handle_pre_tool_use(
            state_file,
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="",
            tool_use_id="t-main",
            tool_name="Edit",
        )
        state = read_session(hook, "s1")
        assert "t-main" in state["active_tools"]

        # SubagentStop — removes subagent's tools but not main's
        hook.handle_subagent_stop(state_file, "s1", "a1")
        state = read_session(hook, "s1")
        assert "t-sub" not in state["active_tools"]
        assert "t-main" in state["active_tools"]
        assert state["subagents"] == []

        # Main tool completes
        hook.handle_post_tool_use(
            state_file,
            str(transcript),
            "s1",
            "/proj",
            "proj",
            NOW,
            99,
            agent_id="",
            tool_use_id="t-main",
        )
        state = read_session(hook, "s1")
        assert "t-main" not in state["active_tools"]

    def test_interrupt_full_reset(self, hook, make_state, make_transcript):
        """Stop after interrupt clears everything including subagents."""
        state_file = hook.SESSIONS_DIR / "s1.json"
        make_state(
            "s1",
            {
                "session_id": "s1",
                "updated_at": NOW,
                "active_tools": {
                    "t1": {"status": "working", "agent_id": ""},
                    "t2": {"status": "needs_approval", "agent_id": "a1"},
                },
                "subagents": [
                    {"agent_id": "a1", "agent_type": "Explore", "started_at": NOW}
                ],
                "agent_working": True,
            },
        )
        transcript = make_transcript([])

        # Stop fires (interrupt) — SubagentStop does NOT fire
        hook.handle_stop(state_file, str(transcript), "s1", "", NOW)
        state = read_session(hook, "s1")
        assert state["active_tools"] == {}
        assert state["subagents"] == []
        assert state["agent_working"] is False
        assert state["status"] == "waiting"
