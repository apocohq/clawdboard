"""Tests for clawdboard-hook.py."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

NOW = "2026-01-01T00:00:00Z"


def read_fact(hook, session_id, agent_id=""):
    """Helper to read an agent fact file."""
    return hook.read_agent_fact(session_id, agent_id)


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
        assert state["pid"] == 1234
        assert state["is_hook_tracked"] is True
        # status is no longer in session JSON — derived from agent facts


# -- Agent fact files --


class TestAgentFacts:
    def test_write_and_read_agent_fact(self, hook):
        hook.write_agent_fact("s1", "", {"status": "working", "tools": {}})
        fact = read_fact(hook, "s1", "")
        assert fact["status"] == "working"

    def test_agent_fact_path_main(self, hook, tmp_sessions):
        path = hook.agent_fact_path("s1", "")
        assert path.name == "s1.agent.main.json"

    def test_agent_fact_path_subagent(self, hook, tmp_sessions):
        path = hook.agent_fact_path("s1", "agent-abc")
        assert path.name == "s1.agent.agent-abc.json"

    def test_derive_agent_status_needs_approval(self, hook):
        fact = {"tools": {"t1": {"status": "working"}, "t2": {"status": "needs_approval"}}}
        assert hook.derive_agent_status(fact) == "needs_approval"

    def test_derive_agent_status_working(self, hook):
        fact = {"tools": {"t1": {"status": "working"}}}
        assert hook.derive_agent_status(fact) == "working"

    def test_derive_agent_status_no_tools(self, hook):
        fact = {"status": "waiting", "tools": {}}
        assert hook.derive_agent_status(fact) == "waiting"

    def test_derive_agent_status_no_tools_preserves_working(self, hook):
        """Between tool calls, agent is still working even with no active tools."""
        fact = {"status": "working", "tools": {}}
        assert hook.derive_agent_status(fact) == "working"

    def test_derive_agent_status_no_tools_preserves_needs_approval(self, hook):
        """Only Stop sets waiting — derive never downgrades."""
        fact = {"status": "needs_approval", "tools": {}}
        assert hook.derive_agent_status(fact) == "needs_approval"

    def test_delete_agent_fact_cleans_lock(self, hook, tmp_sessions):
        hook.write_agent_fact("s1", "", {"status": "working"})
        # Create a lock file
        lock = hook.agent_fact_path("s1", "").with_suffix(".lock")
        lock.write_text("")
        hook.delete_agent_fact("s1", "")
        assert not hook.agent_fact_path("s1", "").exists()
        assert not lock.exists()

    def test_delete_all_agent_facts(self, hook, tmp_sessions):
        hook.write_agent_fact("s1", "", {"status": "working"})
        hook.write_agent_fact("s1", "sub1", {"status": "working"})
        # Create lock files
        hook.agent_fact_path("s1", "").with_suffix(".lock").write_text("")
        hook.agent_fact_path("s1", "sub1").with_suffix(".lock").write_text("")
        hook.delete_all_agent_facts("s1")
        assert not list(tmp_sessions.glob("s1.agent.*"))

    def test_delete_subagent_facts_keeps_main(self, hook, tmp_sessions):
        hook.write_agent_fact("s1", "", {"status": "working"})
        hook.write_agent_fact("s1", "sub1", {"status": "working"})
        hook.delete_subagent_facts("s1")
        assert hook.agent_fact_path("s1", "").exists()
        assert not hook.agent_fact_path("s1", "sub1").exists()


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
        # Status is in agent fact, not session JSON
        fact = read_fact(hook, "s1")
        assert fact["status"] == "waiting"

    def test_pre_tool_use_adds_tool(self, hook):
        hook.write_agent_fact("s1", "", {"status": "working", "tools": {}})
        hook.handle_pre_tool_use("s1", "", "tool-123", "Bash", NOW)
        fact = read_fact(hook, "s1")
        assert "tool-123" in fact["tools"]
        assert fact["tools"]["tool-123"]["status"] == "working"
        assert fact["status"] == "working"

    def test_pre_tool_use_noop_without_tool_id(self, hook):
        hook.write_agent_fact("s1", "", {"status": "working", "tools": {}})
        hook.handle_pre_tool_use("s1", "", "", "Bash", NOW)
        fact = read_fact(hook, "s1")
        assert fact["tools"] == {}

    def test_post_tool_use_removes_tool(self, hook, tmp_path, make_transcript):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "updated_at": NOW}))
        hook.write_agent_fact("s1", "", {
            "status": "working",
            "tools": {"tool-123": {"status": "working"}},
        })
        transcript = make_transcript([])
        hook.handle_post_tool_use(
            state_file, str(transcript), "s1", "/proj", "proj", NOW, 99,
            agent_id="", tool_use_id="tool-123",
        )
        fact = read_fact(hook, "s1")
        assert "tool-123" not in fact.get("tools", {})

    def test_post_tool_use_keeps_needs_approval(self, hook, tmp_path, make_transcript):
        """PostToolUse without tool_use_id clears working tools but keeps needs_approval."""
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "updated_at": NOW}))
        hook.write_agent_fact("s1", "", {
            "status": "needs_approval",
            "tools": {
                "t1": {"status": "working"},
                "t2": {"status": "needs_approval"},
            },
        })
        transcript = make_transcript([])
        hook.handle_post_tool_use(
            state_file, str(transcript), "s1", "/proj", "proj", NOW, 99,
            agent_id="", tool_use_id="",
        )
        fact = read_fact(hook, "s1")
        assert "t1" not in fact["tools"]
        assert "t2" in fact["tools"]

    def test_stop_clears_tools_and_sets_waiting(self, hook, tmp_path, make_transcript):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "updated_at": NOW}))
        hook.write_agent_fact("s1", "", {
            "status": "working",
            "tools": {"t1": {"status": "working"}},
        })
        transcript = make_transcript([])
        hook.handle_stop(state_file, str(transcript), "s1", "", NOW)
        fact = read_fact(hook, "s1")
        assert fact["status"] == "waiting"
        assert fact["tools"] == {}

    def test_stop_noop_without_state(self, hook, tmp_path, make_transcript):
        state_file = tmp_path / "missing.json"
        hook.write_agent_fact("s1", "", {"status": "working", "tools": {}})
        transcript = make_transcript([])
        hook.handle_stop(state_file, str(transcript), "s1", "", NOW)
        # Agent fact should still be updated to waiting
        fact = read_fact(hook, "s1")
        assert fact["status"] == "waiting"

    def test_stop_cleans_subagent_facts(self, hook, tmp_path, make_transcript):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "updated_at": NOW}))
        hook.write_agent_fact("s1", "", {"status": "working", "tools": {}})
        hook.write_agent_fact("s1", "sub1", {"status": "working", "tools": {}})
        transcript = make_transcript([])
        hook.handle_stop(state_file, str(transcript), "s1", "", NOW)
        assert not hook.agent_fact_path("s1", "sub1").exists()

    def test_stop_failure_clears_tools(self, hook):
        hook.write_agent_fact("s1", "", {
            "status": "working",
            "tools": {"t1": {"status": "working"}},
        })
        hook.handle_stop_failure("s1", "", NOW)
        fact = read_fact(hook, "s1")
        assert fact["status"] == "waiting"
        assert fact["tools"] == {}

    def test_permission_request_sets_needs_approval(self, hook, tmp_path):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "updated_at": NOW}))
        hook.write_agent_fact("s1", "", {
            "status": "working",
            "tools": {"t1": {"status": "working", "tool_name": "Bash"}},
        })
        hook.handle_permission_request(
            state_file, "s1", "", NOW,
            tool_use_id="t1", tool_name="Bash",
            tool_input={"command": "rm -rf /"},
        )
        fact = read_fact(hook, "s1")
        assert fact["tools"]["t1"]["status"] == "needs_approval"
        assert fact["tools"]["t1"]["command"] == "rm -rf /"
        assert fact["status"] == "needs_approval"

    def test_permission_request_records_approval_timestamp(self, hook, tmp_path):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "updated_at": NOW}))
        hook.write_agent_fact("s1", "", {"status": "working", "tools": {}})
        hook.handle_permission_request(state_file, "s1", "", NOW)
        state = json.loads(state_file.read_text())
        assert NOW in state["approval_timestamps"]

    def test_subagent_start_creates_fact(self, hook, tmp_sessions):
        hook.handle_subagent_start("s1", "a1", "general", NOW)
        fact = read_fact(hook, "s1", "a1")
        assert fact["status"] == "working"
        assert fact["agent_type"] == "general"

    def test_subagent_start_with_transcript(self, hook, tmp_sessions):
        hook.handle_subagent_start("s1", "a1", "Explore", NOW, "/path/to/transcript.jsonl")
        fact = read_fact(hook, "s1", "a1")
        assert fact["transcript_path"] == "/path/to/transcript.jsonl"

    def test_subagent_start_noop_empty_id(self, hook, tmp_sessions):
        hook.handle_subagent_start("s1", "", "general", NOW)
        assert not list(tmp_sessions.glob("s1.agent.*.json"))

    def test_subagent_stop_deletes_fact(self, hook, tmp_sessions):
        hook.write_agent_fact("s1", "a1", {"status": "working"})
        hook.handle_subagent_stop("s1", "a1")
        assert not hook.agent_fact_path("s1", "a1").exists()

    def test_user_prompt_submit_sets_working(self, hook, tmp_path, make_transcript):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "updated_at": NOW}))
        hook.write_agent_fact("s1", "", {"status": "waiting", "tools": {}})
        transcript = make_transcript([])
        hook.handle_user_prompt_submit(
            state_file, str(transcript), "s1", "/proj", "proj", NOW, 99,
        )
        fact = read_fact(hook, "s1")
        assert fact["status"] == "working"

    def test_user_prompt_submit_clears_subagents(self, hook, tmp_path, make_transcript):
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "updated_at": NOW}))
        hook.write_agent_fact("s1", "", {"status": "waiting", "tools": {}})
        hook.write_agent_fact("s1", "sub1", {"status": "working", "tools": {}})
        transcript = make_transcript([])
        hook.handle_user_prompt_submit(
            state_file, str(transcript), "s1", "/proj", "proj", NOW, 99,
        )
        assert not hook.agent_fact_path("s1", "sub1").exists()


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


class TestWatcherTranscriptResolution:
    """Test _find_tool_result_in_transcript and _is_transcript_interrupted."""

    def test_finds_tool_result(self, hook, make_transcript):
        transcript = make_transcript([
            {"message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "toolu_abc", "content": "done"}
            ]}},
        ])
        result = hook._find_tool_result_in_transcript(str(transcript), "toolu_abc")
        assert result is True

    def test_returns_none_when_not_found(self, hook, make_transcript):
        transcript = make_transcript([
            {"message": {"role": "assistant", "content": "hello"}},
        ])
        result = hook._find_tool_result_in_transcript(str(transcript), "toolu_xyz")
        assert result is None

    def test_detects_interruption(self, hook, make_transcript):
        transcript = make_transcript([
            {"message": {"role": "assistant", "content": "working..."}},
            {"type": "summary", "summary": "[Request interrupted by user]"},
        ])
        assert hook._is_transcript_interrupted(str(transcript)) is True

    def test_no_interruption(self, hook, make_transcript):
        transcript = make_transcript([
            {"message": {"role": "assistant", "content": "done"}},
        ])
        assert hook._is_transcript_interrupted(str(transcript)) is False

    def test_missing_transcript(self, hook):
        assert hook._is_transcript_interrupted("/nonexistent/file.jsonl") is False
        assert hook._find_tool_result_in_transcript("/nonexistent/file.jsonl", "t1") is None


class TestWatcherResolveSession:
    """Test _resolve_session end-to-end with real fact files."""

    def test_resolves_completed_tool_via_transcript(self, hook, make_transcript, tmp_sessions):
        """A tool with a result in the transcript should be removed from the fact."""
        transcript = make_transcript([
            {"message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "toolu_abc", "content": "ok"}
            ]}},
        ])
        hook.write_agent_fact("s1", "", {
            "status": "working",
            "tools": {"toolu_abc": {"status": "working"}},
            "transcript_path": str(transcript),
        })
        state = {"session_id": "s1", "pid": 1, "transcript_path": str(transcript)}
        with patch("os.kill"):  # Don't actually check PID
            hook._resolve_session("s1", state, None)
        fact = read_fact(hook, "s1")
        assert "toolu_abc" not in fact.get("tools", {})
        assert fact["status"] == "working"  # Still working — Stop sets waiting

    def test_resolves_interrupted_session(self, hook, make_transcript, tmp_sessions):
        """Interruption marker should set all agents to waiting."""
        transcript = make_transcript([
            {"type": "summary", "summary": "[Request interrupted by user]"},
        ])
        hook.write_agent_fact("s1", "", {
            "status": "working", "tools": {"t1": {"status": "working"}},
        })
        hook.write_agent_fact("s1", "sub1", {
            "status": "working", "tools": {},
        })
        state = {"session_id": "s1", "pid": 1, "transcript_path": str(transcript)}
        hook._resolve_session("s1", state, None)
        main_fact = read_fact(hook, "s1")
        sub_fact = read_fact(hook, "s1", "sub1")
        assert main_fact["status"] == "waiting"
        assert main_fact["tools"] == {}
        assert sub_fact["status"] == "waiting"

    def test_no_resolution_when_no_pending_tools(self, hook, make_transcript, tmp_sessions):
        """No changes when agent has no pending tools."""
        transcript = make_transcript([])
        hook.write_agent_fact("s1", "", {
            "status": "waiting", "tools": {},
        })
        state = {"session_id": "s1", "pid": 1, "transcript_path": str(transcript)}
        hook._resolve_session("s1", state, None)
        fact = read_fact(hook, "s1")
        assert fact["status"] == "waiting"

    def test_process_inspection_flips_to_working(self, hook, tmp_sessions):
        """When a needs_approval command is already running, flip to working."""
        hook.write_agent_fact("s1", "", {
            "status": "needs_approval",
            "tools": {"t1": {"status": "needs_approval", "command": "npm test"}},
        })
        state = {"session_id": "s1", "pid": 12345, "transcript_path": ""}
        # Mock process tree: PID 12345 has child 12346 running "npm test"
        proc_tree = {12345: 1, 12346: 12345}
        with patch.object(hook, "_is_command_running", return_value=True):
            hook._resolve_session("s1", state, proc_tree)
        fact = read_fact(hook, "s1")
        assert fact["tools"]["t1"]["status"] == "working"
        assert fact["status"] == "working"


class TestWatcherTick:
    """Test _watcher_tick for PID liveness and session cleanup."""

    def test_cleans_up_dead_pid_session(self, hook, tmp_sessions, make_state):
        make_state("s1", {"session_id": "s1", "pid": 99999999, "updated_at": NOW})
        hook.write_agent_fact("s1", "", {"status": "working"})
        # PID 99999999 should not be alive
        active = hook._watcher_tick()
        assert active == 0
        assert not (tmp_sessions / "s1.json").exists()
        assert not hook.agent_fact_path("s1", "").exists()

    def test_counts_live_sessions(self, hook, tmp_sessions, make_state):
        import os
        make_state("s1", {"session_id": "s1", "pid": os.getpid(), "updated_at": NOW})
        hook.write_agent_fact("s1", "", {"status": "working", "tools": {}})
        active = hook._watcher_tick()
        assert active == 1


# -- Full lifecycle simulation --


class TestFullLifecycle:
    """Simulate a realistic session lifecycle through hook events."""

    def test_session_lifecycle(self, hook, tmp_path, make_transcript):
        """SessionStart → UserPromptSubmit → PreToolUse → PostToolUse → Stop."""
        state_file = tmp_path / "s1.json"
        transcript = make_transcript([])

        # 1. SessionStart
        hook.handle_session_start(state_file, str(transcript), "s1", "/proj", "proj", NOW, 99)
        fact = read_fact(hook, "s1")
        assert fact["status"] == "waiting"

        # 2. UserPromptSubmit
        hook.handle_user_prompt_submit(
            state_file, str(transcript), "s1", "/proj", "proj", NOW, 99,
        )
        fact = read_fact(hook, "s1")
        assert fact["status"] == "working"
        assert fact["tools"] == {}

        # 3. PreToolUse
        hook.handle_pre_tool_use("s1", "", "t1", "Bash", NOW)
        fact = read_fact(hook, "s1")
        assert fact["tools"]["t1"]["status"] == "working"

        # 4. PostToolUse
        hook.handle_post_tool_use(
            state_file, str(transcript), "s1", "/proj", "proj", NOW, 99,
            agent_id="", tool_use_id="t1",
        )
        fact = read_fact(hook, "s1")
        assert "t1" not in fact.get("tools", {})

        # 5. Stop
        hook.handle_stop(state_file, str(transcript), "s1", "", NOW)
        fact = read_fact(hook, "s1")
        assert fact["status"] == "waiting"

    def test_permission_lifecycle(self, hook, tmp_path, make_transcript):
        """PreToolUse → PermissionRequest → (approve) → PostToolUse."""
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "updated_at": NOW}))
        hook.write_agent_fact("s1", "", {"status": "working", "tools": {}})
        transcript = make_transcript([])

        # PreToolUse
        hook.handle_pre_tool_use("s1", "", "t1", "Bash", NOW)
        fact = read_fact(hook, "s1")
        assert fact["status"] == "working"

        # PermissionRequest
        hook.handle_permission_request(
            state_file, "s1", "", NOW,
            tool_use_id="t1", tool_name="Bash",
            tool_input={"command": "rm -rf /tmp/test"},
        )
        fact = read_fact(hook, "s1")
        assert fact["tools"]["t1"]["status"] == "needs_approval"
        assert fact["status"] == "needs_approval"

        # PostToolUse (after user approves and tool runs)
        hook.handle_post_tool_use(
            state_file, str(transcript), "s1", "/proj", "proj", NOW, 99,
            agent_id="", tool_use_id="t1",
        )
        fact = read_fact(hook, "s1")
        assert "t1" not in fact.get("tools", {})
        # Status preserved — only Stop sets "waiting"

    def test_subagent_lifecycle(self, hook, tmp_path, make_transcript):
        """Main + subagent working concurrently."""
        state_file = tmp_path / "s1.json"
        state_file.write_text(json.dumps({"session_id": "s1", "updated_at": NOW}))
        hook.write_agent_fact("s1", "", {"status": "working", "tools": {}})
        transcript = make_transcript([])

        # SubagentStart
        hook.handle_subagent_start("s1", "a1", "Explore", NOW)
        sub_fact = read_fact(hook, "s1", "a1")
        assert sub_fact["status"] == "working"

        # Subagent does a tool
        hook.handle_pre_tool_use("s1", "a1", "t-sub", "Read", NOW)
        sub_fact = read_fact(hook, "s1", "a1")
        assert "t-sub" in sub_fact["tools"]

        # Main agent does a tool concurrently
        hook.handle_pre_tool_use("s1", "", "t-main", "Edit", NOW)
        main_fact = read_fact(hook, "s1")
        assert "t-main" in main_fact["tools"]

        # SubagentStop
        hook.handle_subagent_stop("s1", "a1")
        assert not hook.agent_fact_path("s1", "a1").exists()

        # Main tool completes
        hook.handle_post_tool_use(
            state_file, str(transcript), "s1", "/proj", "proj", NOW, 99,
            agent_id="", tool_use_id="t-main",
        )
        main_fact = read_fact(hook, "s1")
        assert "t-main" not in main_fact.get("tools", {})
