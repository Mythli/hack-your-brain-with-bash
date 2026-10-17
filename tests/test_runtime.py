"""Integration tests use a temporary hosts file and record, rather than kill, apps."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hack runtime ")
        self.directory = Path(self.temp.name)
        self.hosts = self.directory / "hosts"
        self.hosts.write_text("127.0.0.1 localhost\n0.0.0.0 unrelated.example\n")
        self.state = self.directory / "state"
        self.apps = self.directory / "closed-apps"
        self.fixture = self.directory / "hack.sh"
        self.fixture.write_text(r'''#!/usr/bin/env bash
script_dir=$TEST_PROJECT
script_path=$0
log_file=$TEST_LOG
default_mode=zen
allow_challenges=addition2
modes=(zen work clear)
declare -A zen=([default_duration]=-1 [max_duration]=-1
    [hosts]="www.youtube.com youtube.example blocked.example literal[1].example"
    [suppressed_apps]="slack discord" [closed_apps]="startup-app" [challenges]="")
declare -A work=([default_duration]=5 [max_duration]=60
    [hosts]="blocked.example" [suppressed_apps]="discord" [closed_apps]="" [challenges]="")
declare -A clear=([default_duration]=5 [max_duration]=60
    [hosts]="" [suppressed_apps]="" [closed_apps]="" [challenges]="")
addition2() {
    printf 'challenge\n' >> "$TEST_CHALLENGES"
    if [[ ${TEST_CHANGE_MODE:-0} == 1 ]]; then switch_mode work; fi
    return "${TEST_CHALLENGE_RESULT:-0}"
}
source "$script_dir/src/main.sh"
close_app() { printf '%s\n' "$1" >> "$TEST_APPS"; }
stop_legacy_workers() { :; }
spawn_mode_worker() {
    if [[ ${TEST_REAL_SCREEN:-0} == 1 ]]; then
        screen -dmS "hack_test_$2" "$BASH" "$script_path" enforce_mode "$1" "$2"
    fi
    return 0
}
case $1 in
    _render) read_runtime_state; runtime_locked set_mode_hosts "$active_mode" "$active_session" ;;
    _apps) read_runtime_state; runtime_locked close_mode_apps "$active_mode" suppressed_apps "$active_session" ;;
    _tick) runtime_locked enforce_tick_locked "$2" true '' false ;;
    *) main "$@" ;;
esac
''')
        self.env = dict(os.environ, TEST_PROJECT=str(ROOT), TEST_LOG=str(self.directory / "log"),
                        TEST_APPS=str(self.apps), TEST_CHALLENGES=str(self.directory / "challenges"),
                        HACK_HOSTS_FILE=str(self.hosts), HACK_STATE_DIR=str(self.state))
        self.workers = []
        self.screens = []

    def tearDown(self):
        for name in self.screens:
            subprocess.run(["screen", "-S", name, "-X", "quit"], capture_output=True)
        for worker in self.workers:
            if worker.poll() is None:
                os.killpg(worker.pid, signal.SIGTERM)
                worker.wait(timeout=5)
        self.temp.cleanup()

    def run_hack(self, *args, success=True, **env):
        result = subprocess.run([BASH, str(self.fixture), *args], env=dict(self.env, **env),
                                capture_output=True, text=True, timeout=15)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def mode(self):
        return (self.state / "mode.tsv").read_text().strip().split("\t")

    def start_worker(self):
        mode, session, _ = self.mode()
        worker = subprocess.Popen([BASH, str(self.fixture), "enforce_mode", mode, session],
                                  env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  start_new_session=True)
        self.workers.append(worker)
        self.wait_for(lambda: self.apps.exists() and "discord" in self.apps.read_text())
        return worker

    def wait_for(self, condition, timeout=6):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.1)
        self.fail("Condition did not become true before deadline")

    def write_allow(self, rows):
        pending = self.state / "pending"
        pending.write_text("".join("\t".join(map(str, row)) + "\n" for row in rows))
        pending.replace(self.state / "allow.tsv")

    def test_resume_without_state_starts_default_mode(self):
        self.run_hack("resume")
        self.assertEqual(self.mode()[0], "zen")
        self.assertEqual(self.mode()[2], "0")
        self.assertIn("blocked.example", self.hosts.read_text())

    def test_resume_preserves_live_mode_deadline_and_allowances(self):
        self.run_hack("switch", "work", "5")
        self.run_hack("allow", "blocked", "2")
        original_mode = self.mode()
        original_allow = (self.state / "allow.tsv").read_text()
        self.hosts.write_text("127.0.0.1 localhost\n")
        self.run_hack("resume")
        self.assertEqual(self.mode(), original_mode)
        self.assertEqual((self.state / "allow.tsv").read_text(), original_allow)
        self.assertNotIn("blocked.example", self.hosts.read_text())

    def test_resume_expired_mode_returns_to_default(self):
        self.run_hack("switch", "work", "1")
        self.run_hack("allow", "blocked")
        mode, session, _ = self.mode()
        (self.state / "mode.tsv").write_text(f"{mode}\t{session}\t{int(time.time()) - 1}\n")
        self.run_hack("resume")
        self.assertEqual(self.mode()[0], "zen")
        self.assertEqual((self.state / "allow.tsv").read_text(), "")
        self.assertIn("blocked.example", self.hosts.read_text())

    def test_resume_recovers_worker_without_duplicates_or_new_allowance(self):
        text = self.fixture.read_text()
        start = text.index("spawn_mode_worker() {")
        end = text.index("case $1 in", start)
        self.fixture.write_text(text[:start] + text[end:])
        self.run_hack("resume")
        original_mode = self.mode()
        name = "hackbrain_runtime_" + original_mode[1]
        self.screens.append(name)
        self.wait_for(lambda: self.apps.exists() and "discord" in self.apps.read_text())
        self.run_hack("resume")
        self.assertEqual(subprocess.run(["screen", "-ls"], capture_output=True,
                         text=True).stdout.count(name), 1)
        subprocess.run(["screen", "-S", name, "-X", "quit"], check=True, capture_output=True)
        self.apps.write_text("")
        self.run_hack("resume")
        self.assertEqual(self.mode(), original_mode)
        self.assertEqual((self.state / "allow.tsv").read_text(), "")
        self.wait_for(lambda: "discord" in self.apps.read_text())

    def test_hosts_block_is_idempotent_and_clear_really_clears(self):
        self.run_hack("switch", "zen")
        content = self.hosts.read_text()
        self.assertIn("# START PRIME_HOSTS\n", content)
        self.assertTrue(content.endswith("# END PRIME_HOSTS\n"))
        self.assertIn("0.0.0.0 unrelated.example\n", content)
        mtime = self.hosts.stat().st_mtime_ns
        self.run_hack("_render")
        self.assertEqual(self.hosts.stat().st_mtime_ns, mtime)
        self.run_hack("switch", "clear")
        self.assertNotIn("youtube", self.hosts.read_text())
        self.assertIn("unrelated.example", self.hosts.read_text())

    def test_repairs_missing_and_glued_legacy_end_markers(self):
        for tail in ("0.0.0.0 old.exampleEND PRIME_HOSTS\n127.0.0.1 custom\n",
                     "0.0.0.0 old.example\n127.0.0.1 custom\n# keep this comment"):
            self.hosts.write_text("127.0.0.1 localhost\nSTART PRIME_HOSTS\n" + tail)
            self.run_hack("switch", "work")
            content = self.hosts.read_text()
            self.assertEqual(content.count("# START PRIME_HOSTS"), 1)
            self.assertEqual(content.count("# END PRIME_HOSTS"), 1)
            self.assertIn("127.0.0.1 custom\n", content)
            self.assertNotIn("old.example", content)

    def test_allow_is_literal_case_insensitive_and_filters_apps(self):
        self.run_hack("switch", "zen")
        original_state = self.mode()
        self.run_hack("allow", "YOUTUBE")
        self.assertNotIn("youtube", self.hosts.read_text())
        self.assertIn("blocked.example", self.hosts.read_text())
        self.run_hack("allow", "[1]", "5")
        self.assertNotIn("literal[1]", self.hosts.read_text())
        self.run_hack("allow", "*", success=False)
        self.run_hack("allow", "SLACK", "5")
        self.apps.write_text("")
        self.run_hack("_apps")
        self.assertEqual(self.apps.read_text(), "discord\n")
        self.assertEqual(self.mode(), original_state)
        self.assertIn("slack", self.run_hack("status").stdout)

    def test_failures_do_not_grant_and_mode_changes_invalidate_challenge(self):
        self.run_hack("switch", "zen")
        for query, minutes in (("", "2"), ("slack", "0"), ("slack", "-1"),
                               ("slack", "61"), ("slack", "1+2"), ("a\tb", "2")):
            self.run_hack("allow", query, minutes, success=False)
        self.run_hack("allow", "slack", success=False, TEST_CHALLENGE_RESULT="1")
        self.assertEqual((self.state / "allow.tsv").read_text(), "")
        result = self.run_hack("allow", "slack", success=False, TEST_CHANGE_MODE="1")
        self.assertIn("mode changed", result.stderr)
        self.assertEqual(self.mode()[0], "work")
        self.assertEqual((self.state / "allow.tsv").read_text(), "")

    def test_overlapping_allowances_expire_independently(self):
        self.run_hack("switch", "zen")
        session = self.mode()[1]
        now = int(time.time())
        self.write_allow([(session, now - 1, "youtube"), (session, now + 60, "www.youtube")])
        self.run_hack("_render")
        content = self.hosts.read_text()
        self.assertNotIn("www.youtube.com", content)
        self.assertIn("youtube.example", content)
        self.run_hack("switch", "zen")
        self.assertNotEqual(self.mode()[1], session)
        self.assertIn("www.youtube.com", self.hosts.read_text())
        before = self.hosts.read_text()
        result = self.run_hack("_tick", session, success=False)
        self.assertEqual(result.returncode, 20)
        self.assertEqual(before, self.hosts.read_text())

    def test_grant_is_capped_at_mode_deadline(self):
        self.run_hack("switch", "work", "1")
        self.run_hack("allow", "blocked", "30")
        row = (self.state / "allow.tsv").read_text().strip().split("\t")
        self.assertEqual(row[1], self.mode()[2])

    def test_watcher_repairs_edits_and_replacements_without_write_loop(self):
        self.run_hack("switch", "zen")
        self.start_worker()
        time.sleep(0.5)
        self.hosts.write_text("127.0.0.1 localhost\n127.0.0.1 custom\n")
        self.wait_for(lambda: "blocked.example" in self.hosts.read_text())
        self.assertIn("127.0.0.1 custom", self.hosts.read_text())
        self.run_hack("allow", "youtube")
        replacement = self.directory / "hosts.new"
        replacement.write_text("127.0.0.1 localhost\n")
        replacement.replace(self.hosts)
        self.wait_for(lambda: "blocked.example" in self.hosts.read_text())
        self.assertNotIn("youtube", self.hosts.read_text())
        mtime = self.hosts.stat().st_mtime_ns
        time.sleep(1.5)
        self.assertEqual(mtime, self.hosts.stat().st_mtime_ns)

    def test_worker_expires_allows_without_a_file_event_at_deadline(self):
        self.run_hack("switch", "zen")
        self.run_hack("allow", "youtube")
        session = self.mode()[1]
        expiry = int(time.time()) + 3
        self.write_allow([(session, expiry, "youtube"), (session, expiry, "slack")])
        self.start_worker()
        self.assertNotIn("youtube", self.hosts.read_text())
        self.assertNotIn("slack", self.apps.read_text())
        self.wait_for(lambda: "www.youtube.com" in self.hosts.read_text())
        self.wait_for(lambda: "slack" in self.apps.read_text(), timeout=12)

    def test_worker_returns_to_default_at_mode_deadline(self):
        self.run_hack("switch", "work", "1")
        self.run_hack("allow", "blocked")
        mode, session, _ = self.mode()
        (self.state / "mode.tsv").write_text(f"{mode}\t{session}\t{int(time.time()) + 3}\n")
        worker = self.start_worker()
        self.wait_for(lambda: self.mode()[0] == "zen")
        self.assertIn("www.youtube.com", self.hosts.read_text())
        self.assertEqual((self.state / "allow.tsv").read_text(), "")
        self.wait_for(lambda: worker.poll() is not None)

    def test_concurrent_grants_are_not_lost(self):
        self.run_hack("switch", "zen")
        commands = [subprocess.Popen([BASH, str(self.fixture), "allow", query], env=self.env,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    for query in ("youtube", "slack", "blocked")]
        for command in commands:
            out, err = command.communicate(timeout=15)
            self.assertEqual(command.returncode, 0, out + err)
        self.assertEqual(len((self.state / "allow.tsv").read_text().splitlines()), 3)
        self.assertNotIn("youtube", self.hosts.read_text())
        self.assertNotIn("blocked.example", self.hosts.read_text())

    def test_detached_screen_worker_with_paths_containing_spaces(self):
        # Exercise the production spawner, including its duplicate-session check.
        text = self.fixture.read_text()
        start = text.index("spawn_mode_worker() {")
        end = text.index("case $1 in", start)
        self.fixture.write_text(text[:start] + text[end:])
        self.run_hack("switch", "zen")
        name = "hackbrain_runtime_" + self.mode()[1]
        self.screens.append(name)
        self.wait_for(lambda: self.apps.exists() and "discord" in self.apps.read_text())
        self.run_hack("allow", "youtube")
        result = subprocess.run(["screen", "-ls"], capture_output=True, text=True)
        self.assertEqual(result.stdout.count(name), 1)
        self.hosts.write_text("127.0.0.1 localhost\n")
        self.wait_for(lambda: "blocked.example" in self.hosts.read_text())
        self.assertNotIn("youtube", self.hosts.read_text())
        # Restarting a missing worker must preserve both mode identity and grants.
        subprocess.run(["screen", "-S", name, "-X", "quit"], check=True, capture_output=True)
        original_mode = self.mode()
        self.run_hack("allow", "slack")
        self.assertEqual(self.mode(), original_mode)
        self.wait_for(lambda: name in subprocess.run(["screen", "-ls"],
                      capture_output=True, text=True).stdout)

    def test_stale_pid_lock_recovers(self):
        if shutil.which("flock"):
            self.skipTest("PID-lock recovery is the macOS backend")
        self.state.mkdir()
        (self.state / "runtime.lock").write_text("99999999\n")
        self.run_hack("switch", "zen")
        self.assertFalse((self.state / "runtime.lock").exists())

    def test_legacy_migration_does_not_stop_its_calling_screen(self):
        text = self.fixture.read_text().replace("stop_legacy_workers() { :; }", r'''
screen() {
    if [[ $1 == -ls ]]; then
        printf '123.hackbrain___delayed_command\n234.hackbrain___suppress_apps_zen\n345.unrelated\n'
    else
        printf '%s\n' "$2" >> "$TEST_STOPPED_SCREENS"
    fi
}
''')
        self.fixture.write_text(text)
        stopped = self.directory / "stopped"
        self.run_hack("switch", "zen", STY="123.hackbrain___delayed_command",
                      TEST_STOPPED_SCREENS=str(stopped))
        self.assertEqual(stopped.read_text(), "234.hackbrain___suppress_apps_zen\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
