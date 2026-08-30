import os
import subprocess
from pathlib import Path
import pytest

SKILL_DIR = Path(__file__).resolve().parent.parent
PARSE_FRONTMATTER = SKILL_DIR / "scripts" / "parse-frontmatter.sh"
VALIDATE_SETTINGS = SKILL_DIR / "scripts" / "validate-settings.sh"
READ_HOOK = SKILL_DIR / "examples" / "read-settings-hook.sh"
GIT_BASH = r"C:\Program Files\Git\bin\bash.exe"


def run_bash(script_path, args, stdin_data=None):
    bash_bin = GIT_BASH if os.path.exists(GIT_BASH) else "bash"
    script_posix = str(script_path).replace("\\", "/")
    cmd = [bash_bin, script_posix] + [str(a).replace("\\", "/") for a in args]
    return subprocess.run(
        cmd,
        input=stdin_data,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
    )


class TestPluginSettingsWithBOM:
    def test_parse_frontmatter_with_and_without_bom(self, tmp_path):
        plain_file = tmp_path / "plain.local.md"
        plain_file.write_text("---\nenabled: true\nmax_file_size: 1024\n---\nBody here\n", encoding="utf-8")

        bom_file = tmp_path / "bom.local.md"
        bom_file.write_text("\ufeff---\nenabled: false\nmax_file_size: 2048\n---\nBody here\n", encoding="utf-8")

        # Test plain file
        res = run_bash(PARSE_FRONTMATTER, [plain_file, "enabled"])
        assert res.returncode == 0
        assert res.stdout.strip() == "true"

        # Test BOM file
        res = run_bash(PARSE_FRONTMATTER, [bom_file, "enabled"])
        assert res.returncode == 0
        assert res.stdout.strip() == "false"

        res = run_bash(PARSE_FRONTMATTER, [bom_file, "max_file_size"])
        assert res.returncode == 0
        assert res.stdout.strip() == "2048"

    def test_validate_settings_with_bom(self, tmp_path):
        bom_file = tmp_path / "bom.local.md"
        bom_file.write_text("\ufeff---\nenabled: true\nstrict_mode: true\n---\nSettings body\n", encoding="utf-8")

        res = run_bash(VALIDATE_SETTINGS, [bom_file])
        assert res.returncode == 0
        assert "Settings file structure is valid" in res.stdout

    def test_read_settings_hook_with_bom(self, tmp_path):
        claude_dir = tmp_path / ".claude"
        claude_dir.mkdir()
        settings_file = claude_dir / "my-plugin.local.md"
        settings_file.write_text("\ufeff---\nenabled: true\nstrict_mode: true\n---\n", encoding="utf-8")

        # Test path traversal in strict mode
        payload = '{"tool_input": {"file_path": "../etc/passwd"}}'
        bash_bin = GIT_BASH if os.path.exists(GIT_BASH) else "bash"
        script_posix = str(READ_HOOK).replace("\\", "/")
        res = subprocess.run(
            [bash_bin, script_posix],
            input=payload,
            cwd=tmp_path,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
        )
        assert res.returncode == 2
        assert "Path traversal blocked" in res.stderr
