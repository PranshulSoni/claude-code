import json
import os
import subprocess
from pathlib import Path
import pytest

PLUGIN_ROOT = Path(__file__).resolve().parent.parent
STOP_HOOK = PLUGIN_ROOT / "hooks" / "stop-hook.sh"
GIT_BASH = r"C:\Program Files\Git\bin\bash.exe"
TEST_BIN = r"C:\tmp\claude_test_bin"


def run_stop_hook(cwd, stdin_data, env=None):
    bash_executable = GIT_BASH if os.path.exists(GIT_BASH) else "bash"
    script_posix = str(STOP_HOOK).replace("\\", "/")
    
    current_env = os.environ.copy()
    if env:
        current_env.update(env)

    # Ensure TEST_BIN is on PATH for jq binary resolution
    if os.path.exists(TEST_BIN):
        current_env["PATH"] = f"{TEST_BIN};" + current_env.get("PATH", "")

    result = subprocess.run(
        [bash_executable, script_posix],
        input=stdin_data,
        cwd=cwd,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        env=current_env,
    )
    return result


class TestStopHookErrorHandling:
    def test_no_state_file_allows_exit(self, tmp_path):
        res = run_stop_hook(tmp_path, '{"transcript_path":"/nonexistent"}')
        assert res.returncode == 0
        assert res.stdout == ""

    def test_missing_iteration_field_outputs_diagnostic_and_cleans_up(self, tmp_path):
        claude_dir = tmp_path / ".claude"
        claude_dir.mkdir()
        state_file = claude_dir / "ralph-loop.local.md"
        state_file.write_text(
            "---\nmax_iterations: 5\ncompletion_promise: null\n---\nDo the task\n",
            encoding="utf-8",
        )

        res = run_stop_hook(tmp_path, '{"transcript_path":"/nonexistent"}')
        assert res.returncode == 0
        assert "Problem: 'iteration' field is not a valid number" in res.stderr
        assert not state_file.exists(), "Corrupted state file should be removed"

    def test_missing_max_iterations_field_outputs_diagnostic_and_cleans_up(self, tmp_path):
        claude_dir = tmp_path / ".claude"
        claude_dir.mkdir()
        state_file = claude_dir / "ralph-loop.local.md"
        state_file.write_text(
            "---\niteration: 1\ncompletion_promise: null\n---\nDo the task\n",
            encoding="utf-8",
        )

        res = run_stop_hook(tmp_path, '{"transcript_path":"/nonexistent"}')
        assert res.returncode == 0
        assert "Problem: 'max_iterations' field is not a valid number" in res.stderr
        assert not state_file.exists(), "Corrupted state file should be removed"

    def test_non_numeric_iteration_outputs_diagnostic_and_cleans_up(self, tmp_path):
        claude_dir = tmp_path / ".claude"
        claude_dir.mkdir()
        state_file = claude_dir / "ralph-loop.local.md"
        state_file.write_text(
            "---\niteration: bad_value\nmax_iterations: 5\n---\nDo the task\n",
            encoding="utf-8",
        )

        res = run_stop_hook(tmp_path, '{"transcript_path":"/nonexistent"}')
        assert res.returncode == 0
        assert "Problem: 'iteration' field is not a valid number" in res.stderr
        assert not state_file.exists()

    def test_invalid_json_input_cleans_up(self, tmp_path):
        claude_dir = tmp_path / ".claude"
        claude_dir.mkdir()
        state_file = claude_dir / "ralph-loop.local.md"
        state_file.write_text(
            "---\niteration: 1\nmax_iterations: 5\n---\nDo the task\n",
            encoding="utf-8",
        )

        res = run_stop_hook(tmp_path, "not-valid-json")
        assert res.returncode == 0
        assert "Transcript file not found" in res.stderr
        assert not state_file.exists()

    def test_max_iterations_reached_exits_cleanly(self, tmp_path):
        claude_dir = tmp_path / ".claude"
        claude_dir.mkdir()
        state_file = claude_dir / "ralph-loop.local.md"
        state_file.write_text(
            "---\niteration: 5\nmax_iterations: 5\n---\nDo the task\n",
            encoding="utf-8",
        )

        res = run_stop_hook(tmp_path, '{"transcript_path":"/nonexistent"}')
        assert res.returncode == 0
        assert "Max iterations (5) reached" in res.stdout
        assert not state_file.exists()

    def test_completion_promise_matched_exits_cleanly(self, tmp_path):
        claude_dir = tmp_path / ".claude"
        claude_dir.mkdir()
        state_file = claude_dir / "ralph-loop.local.md"
        state_file.write_text(
            '---\niteration: 1\nmax_iterations: 5\ncompletion_promise: "TASK COMPLETE"\n---\nDo the task\n',
            encoding="utf-8",
        )
        transcript = tmp_path / "transcript.jsonl"
        transcript.write_text(
            json.dumps({
                "role": "assistant",
                "message": {
                    "content": [{"type": "text", "text": "Work done <promise>TASK COMPLETE</promise>"}]
                }
            }) + "\n",
            encoding="utf-8",
        )

        transcript_posix = str(transcript).replace("\\", "/")
        payload = json.dumps({"transcript_path": transcript_posix})
        res = run_stop_hook(tmp_path, payload)
        assert res.returncode == 0
        assert "Detected <promise>TASK COMPLETE</promise>" in res.stdout
        assert not state_file.exists()
