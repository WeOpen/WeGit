from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ui_probe import run_logged, verify_summary


class NativeProcessDeadlineTests(unittest.TestCase):
    def test_passing_exit_without_executed_tests_or_with_skips_is_not_acceptance(self):
        valid = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        self.assertEqual(verify_summary(valid, smoke=True), valid)
        for change in ({"totalTestCount": 0, "passedTests": 0}, {"failedTests": 1},
                       {"skippedTests": 1}, {"totalTestCount": 2}, {"passedTests": None}):
            with self.assertRaises(ValueError):
                verify_summary(valid | change, smoke=True)

    def test_success_retains_complete_output_and_exit_status(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "result.log"
            result = run_logged([sys.executable, "-c", "print('complete native fixture output')"], log, 10)
            self.assertEqual(result["exitCode"], 0)
            self.assertFalse(result["timedOut"])
            self.assertEqual(log.read_text().strip(), "complete native fixture output")

    def test_deadline_stops_child_process_group_and_retains_failure_output(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            marker = root / "child-pid"
            child = "import pathlib,os,time; pathlib.Path(" + repr(str(marker)) + ").write_text(str(os.getpid())); time.sleep(60)"
            parent = "import subprocess,sys,time; print('before deadline',flush=True); subprocess.Popen([sys.executable,'-c'," + repr(child) + "]); time.sleep(60)"
            result = run_logged([sys.executable, "-c", parent], root / "timeout.log", 1)
            self.assertTrue(result["timedOut"])
            self.assertNotEqual(result["exitCode"], 0)
            self.assertIn("before deadline", (root / "timeout.log").read_text())
            child_pid = int(marker.read_text())
            time.sleep(0.1)
            # A terminated child may briefly be a zombie until its init parent reaps it.
            status = subprocess.run(["ps", "-o", "stat=", "-p", str(child_pid)], capture_output=True, text=True)
            self.assertTrue(status.returncode != 0 or status.stdout.strip().startswith("Z"), status.stdout)


if __name__ == "__main__":
    unittest.main()
