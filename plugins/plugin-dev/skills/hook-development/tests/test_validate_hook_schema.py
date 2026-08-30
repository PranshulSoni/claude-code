import json
import os
import subprocess
from pathlib import Path
import pytest

SCRIPT_PATH = Path(__file__).resolve().parent.parent / "scripts" / "validate-hook-schema.sh"
GIT_BASH = r"C:\Program Files\Git\bin\bash.exe"


def run_validator(target_file, env=None):
    bash_bin = GIT_BASH if os.path.exists(GIT_BASH) else "bash"
    script_posix = str(SCRIPT_PATH).replace("\\", "/")
    target_posix = str(target_file).replace("\\", "/")

    current_env = os.environ.copy()
    if env:
        current_env.update(env)

    return subprocess.run(
        [bash_bin, script_posix, target_posix],
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        env=current_env,
    )


class TestValidateHookSchema:
    def test_plugin_wrapper_format(self, tmp_path):
        hooks_json = tmp_path / "hooks.json"
        hooks_json.write_text(
            json.dumps({
                "description": "Sample plugin hooks",
                "hooks": {
                    "PreToolUse": [
                        {
                            "matcher": "Write",
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "${CLAUDE_PLUGIN_ROOT}/scripts/check.sh",
                                    "timeout": 30
                                }
                            ]
                        }
                    ]
                }
            }),
            encoding="utf-8",
        )
        res = run_validator(hooks_json)
        assert res.returncode == 0
        assert "Detected plugin wrapper format" in res.stdout
        assert "All checks passed!" in res.stdout

    def test_direct_settings_format(self, tmp_path):
        hooks_json = tmp_path / "hooks.json"
        hooks_json.write_text(
            json.dumps({
                "PreToolUse": [
                    {
                        "matcher": "Edit",
                        "hooks": [
                            {
                                "type": "command",
                                "command": "${CLAUDE_PLUGIN_ROOT}/scripts/edit_guard.sh"
                            }
                        ]
                    }
                ]
            }),
            encoding="utf-8",
        )
        res = run_validator(hooks_json)
        assert res.returncode == 0
        assert "Detected direct/settings format" in res.stdout
        assert "All checks passed!" in res.stdout

    def test_non_tool_event_without_matcher_passes(self, tmp_path):
        hooks_json = tmp_path / "hooks.json"
        hooks_json.write_text(
            json.dumps({
                "hooks": {
                    "UserPromptSubmit": [
                        {
                            "hooks": [
                                {
                                    "type": "prompt",
                                    "prompt": "Evaluate user prompt"
                                }
                            ]
                        }
                    ],
                    "Stop": [
                        {
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "${CLAUDE_PLUGIN_ROOT}/scripts/stop.sh"
                                }
                            ]
                        }
                    ]
                }
            }),
            encoding="utf-8",
        )
        res = run_validator(hooks_json)
        assert res.returncode == 0
        assert "All checks passed!" in res.stdout

    def test_tool_event_without_matcher_fails(self, tmp_path):
        hooks_json = tmp_path / "hooks.json"
        hooks_json.write_text(
            json.dumps({
                "hooks": {
                    "PreToolUse": [
                        {
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "${CLAUDE_PLUGIN_ROOT}/scripts/check.sh"
                                }
                            ]
                        }
                    ]
                }
            }),
            encoding="utf-8",
        )
        res = run_validator(hooks_json)
        assert res.returncode == 1
        assert "Missing 'matcher' field" in res.stdout

    def test_invalid_json_fails(self, tmp_path):
        hooks_json = tmp_path / "hooks.json"
        hooks_json.write_text("{ invalid json }", encoding="utf-8")
        res = run_validator(hooks_json)
        assert res.returncode == 1
        assert "Invalid JSON syntax" in res.stdout
