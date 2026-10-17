"""Exercise installation with temporary configuration, never the real hosts file."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hack install ")
        self.directory = Path(self.temp.name)
        self.config = self.directory / "shell config"
        self.sample = self.directory / "hack.sample.sh"
        self.sample.write_text('#!/usr/bin/env bash\nprintf "sample %s\\n" "$1"\n')
        self.script = self.directory / "hack.sh"

    def tearDown(self):
        self.temp.cleanup()

    def install(self, permission="0", shell_result="0"):
        return subprocess.run([BASH, "-c", r'''
source "$TEST_INSTALLER"
parent_dir=$TEST_DIRECTORY
check_and_provide_install_commands() { return 0; }
make_host_file_writeable() { return "$TEST_PERMISSION"; }
detect_shell_config() { printf '%s\n' "$TEST_CONFIG"; return "$TEST_SHELL_RESULT"; }
install
'''], env=dict(os.environ, TEST_INSTALLER=str(ROOT / "src/install.sh"),
               TEST_DIRECTORY=str(self.directory), TEST_CONFIG=str(self.config),
               TEST_PERMISSION=permission, TEST_SHELL_RESULT=shell_result),
            capture_output=True, text=True, timeout=5)

    def test_reinstall_preserves_configuration_and_does_not_duplicate_alias(self):
        personal = '#!/usr/bin/env bash\nprintf "personal %s\\n" "$1"\n'
        self.script.write_text(personal)
        for _ in range(2):
            result = self.install()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.script.read_text(), personal)
        self.assertEqual(self.config.read_text().count("alias hack="), 1)
        shells = [BASH]
        if shutil.which("zsh"):
            shells.append(shutil.which("zsh"))
        for shell in shells:
            code = 'source "$1"; eval "hack list"'
            if shell == BASH:
                code = 'shopt -s expand_aliases; ' + code
            result = subprocess.run([shell, "-fc", code, "test", str(self.config)],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "personal list\n")

    def test_fresh_install_creates_executable_config(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.script.read_text(), self.sample.read_text())
        self.assertTrue(os.access(self.script, os.X_OK))
        self.assertTrue(self.config.exists())

    def test_permission_failure_aborts_before_alias_and_success_message(self):
        result = self.install(permission="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.config.exists())
        self.assertNotIn("start hacking", result.stdout)

    def test_unsupported_shell_does_not_report_success(self):
        result = self.install(shell_result="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.config.exists())
        self.assertNotIn("start hacking", result.stdout)
