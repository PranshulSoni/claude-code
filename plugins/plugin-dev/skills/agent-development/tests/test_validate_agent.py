import os
import subprocess
from pathlib import Path
import pytest

SCRIPT_PATH = Path(__file__).resolve().parent.parent / "scripts" / "validate-agent.sh"
REPO_ROOT = Path(__file__).resolve().parents[5]
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


class TestValidateAgent:
    def test_shipped_agent_plugin_validator(self):
        agent_file = REPO_ROOT / "plugins" / "plugin-dev" / "agents" / "plugin-validator.md"
        assert agent_file.exists()
        res = run_validator(agent_file)
        assert res.returncode == 0
        assert "name: plugin-validator" in res.stdout
        assert "Validation passed" in res.stdout or "All checks passed" in res.stdout

    def test_warning_does_not_abort_script_under_set_e(self, tmp_path):
        agent_file = tmp_path / "warn-agent.md"
        # Has generic name and missing <example> block (triggers warnings)
        agent_file.write_text(
            """---
name: helper
description: Use this agent when helping with simple tasks.
model: inherit
color: blue
---
You are a helpful assistant that helps users with their work.
Responsibilities:
1. Help users.
Output format: plain text.
""",
            encoding="utf-8",
        )
        res = run_validator(agent_file)
        assert res.returncode == 0
        assert "name is too generic: helper" in res.stdout
        assert "model: inherit" in res.stdout
        assert "color: blue" in res.stdout
        assert "System prompt:" in res.stdout
        assert "Validation passed with" in res.stdout

    def test_utf8_bom_support(self, tmp_path):
        agent_file = tmp_path / "bom-agent.md"
        content = (
            "\ufeff"
            "---\n"
            "name: custom-reviewer\n"
            "description: Use this agent when reviewing pull requests.\n"
            "  <example>\n"
            "  user: review this\n"
            "  </example>\n"
            "model: sonnet\n"
            "color: green\n"
            "---\n"
            "You are a code reviewer.\n"
            "Responsibilities:\n"
            "1. Review code changes.\n"
            "Output: markdown report.\n"
        )
        agent_file.write_text(content, encoding="utf-8")
        res = run_validator(agent_file)
        assert res.returncode == 0
        assert "name: custom-reviewer" in res.stdout
        assert "All checks passed!" in res.stdout or "Validation passed" in res.stdout

    def test_missing_required_name_fails(self, tmp_path):
        agent_file = tmp_path / "no-name.md"
        agent_file.write_text(
            """---
description: Use this agent when testing.
model: inherit
color: blue
---
You are a test agent.
""",
            encoding="utf-8",
        )
        res = run_validator(agent_file)
        assert res.returncode == 1
        assert "Missing required field: name" in res.stdout
