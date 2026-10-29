from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ui_probe
from ui_probe import run_logged, verify_summary
from ui_source import choose_source


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


class NativeScopeSelectionTests(unittest.TestCase):
    def test_worktree_management_requires_passing_smoke_and_one_bounded_method(self):
        root = Path(__file__).resolve().parents[3]
        target = "WorktreeManagementWorkflowTests/testCreateCancelRemoveAndProtectChangedWorktrees"
        self.assertEqual(ui_probe.FOCUSED_TESTS["worktree-management"], target)
        self.assertIn("worktree-management", (root / ".github/workflows/native-ui.yml").read_text())
        for passed, failed, skipped in ((1, 0, 0), (0, 1, 0), (0, 0, 1)):
            summary = {"totalTestCount": 1, "passedTests": passed, "failedTests": failed, "skippedTests": skipped}
            with self.subTest(summary=summary), tempfile.TemporaryDirectory() as folder:
                with patch.object(sys, "argv", ["ui_probe.py", "--mode", "smoke", "--focus", "worktree-management", "--output", folder]), \
                     patch.object(ui_probe, "inspect_environment", return_value={"interactivePrerequisites": True}), \
                     patch.object(ui_probe, "run_logged", return_value={"exitCode": 0, "timedOut": False}) as runner, \
                     patch.object(ui_probe, "result_summary", return_value=summary), \
                     redirect_stdout(StringIO()):
                    if passed:
                        ui_probe.main()
                    else:
                        with self.assertRaises(ValueError):
                            ui_probe.main()
                self.assertEqual(runner.call_count, 2 if passed else 1)
                if passed:
                    command = runner.call_args_list[1].args[0]
                    self.assertEqual([x for x in command if x.startswith("-only-testing:")], ["-only-testing:WeGitUITests/" + target])
                    self.assertLessEqual(runner.call_args_list[1].args[2], 300)

    def test_selected_lines_diagnostic_is_bounded_and_requires_a_passing_smoke(self):
        root = Path(__file__).resolve().parents[3]
        target = "SelectedLinesWorkflowTests/testPreviewCancelStageUnstageAndStaleConfirmation"
        self.assertEqual(ui_probe.FOCUSED_TESTS["selected-lines"], target)
        self.assertIn("selected-lines", (root / ".github/workflows/native-ui.yml").read_text())
        for success in (True, False):
            summary = {"totalTestCount": 1, "passedTests": int(success), "failedTests": int(not success), "skippedTests": 0}
            with self.subTest(success=success), tempfile.TemporaryDirectory() as folder:
                with patch.object(sys, "argv", ["ui_probe.py", "--mode", "smoke", "--focus", "selected-lines", "--output", folder]), \
                     patch.object(ui_probe, "inspect_environment", return_value={"interactivePrerequisites": True}), \
                     patch.object(ui_probe, "run_logged", return_value={"exitCode": 0 if success else 65, "timedOut": False}) as runner, \
                     patch.object(ui_probe, "result_summary", return_value=summary), \
                     redirect_stdout(StringIO()):
                    if success:
                        ui_probe.main()
                    else:
                        with self.assertRaises(SystemExit):
                            ui_probe.main()
                self.assertEqual(runner.call_count, 2 if success else 1)
                if success:
                    self.assertIn("-only-testing:WeGitUITests/" + target, runner.call_args_list[1].args[0])
                    self.assertLessEqual(runner.call_args_list[1].args[2], 300)

    def test_blame_diagnostic_is_bounded_and_requires_a_passing_smoke(self):
        root = Path(__file__).resolve().parents[3]
        target = "BlameWorkflowTests/testCommittedAttributionPagingAndHistoricalNavigation"
        self.assertEqual(ui_probe.FOCUSED_TESTS["blame"], target)
        self.assertIn("blame", (root / ".github/workflows/native-ui.yml").read_text())
        for success in (True, False):
            summary = {"totalTestCount": 1, "passedTests": int(success), "failedTests": int(not success), "skippedTests": 0}
            with self.subTest(success=success), tempfile.TemporaryDirectory() as folder:
                with patch.object(sys, "argv", ["ui_probe.py", "--mode", "smoke", "--focus", "blame", "--output", folder]), \
                     patch.object(ui_probe, "inspect_environment", return_value={"interactivePrerequisites": True}), \
                     patch.object(ui_probe, "run_logged", return_value={"exitCode": 0 if success else 65, "timedOut": False}) as runner, \
                     patch.object(ui_probe, "result_summary", return_value=summary), \
                     redirect_stdout(StringIO()):
                    if success:
                        ui_probe.main()
                    else:
                        with self.assertRaises(SystemExit):
                            ui_probe.main()
                self.assertEqual(runner.call_count, 2 if success else 1)
                if success:
                    self.assertIn("-only-testing:WeGitUITests/" + target, runner.call_args_list[1].args[0])
                    self.assertLessEqual(runner.call_args_list[1].args[2], 300)

    def test_single_commit_diagnostic_cannot_expand_its_candidate_scope(self):
        root = Path(__file__).resolve().parents[3]
        target = "SingleCommitWorkflowTests/testPreviewApplyRevertAndRecoverAfterRelaunch"
        self.assertEqual(ui_probe.FOCUSED_TESTS["single-commit"], target)
        self.assertIn("single-commit", (root / ".github/workflows/native-ui.yml").read_text())
        summary = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(sys, "argv", ["ui_probe.py", "--mode", "smoke", "--focus", "single-commit", "--output", folder]), \
                 patch.object(ui_probe, "inspect_environment", return_value={"interactivePrerequisites": True}), \
                 patch.object(ui_probe, "run_logged", return_value={"exitCode": 0, "timedOut": False}) as runner, \
                 patch.object(ui_probe, "result_summary", return_value=summary), \
                 redirect_stdout(StringIO()):
                ui_probe.main()
            self.assertEqual(runner.call_count, 2)
            self.assertIn("-only-testing:WeGitUITests/WeGitUITests/testWelcomeAndCloneForm", runner.call_args_list[0].args[0])
            self.assertIn("-only-testing:WeGitUITests/" + target, runner.call_args_list[1].args[0])
            self.assertLessEqual(runner.call_args_list[1].args[2], 300)

    def test_worktree_diagnostic_runs_only_registered_candidate_method(self):
        root = Path(__file__).resolve().parents[3]
        target = ui_probe.FOCUSED_TESTS["worktree-opening"]
        self.assertEqual(target, "WorktreeWorkflowTests/testLinkedWorktreesKeepDraftsPagesAndIndexesAcrossSwitchAndRelaunch")
        self.assertIn("worktree-opening", (root / ".github/workflows/native-ui.yml").read_text())
        summary = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(sys, "argv", ["ui_probe.py", "--mode", "smoke", "--focus", "worktree-opening", "--output", folder]), \
                 patch.object(ui_probe, "inspect_environment", return_value={"interactivePrerequisites": True}), \
                 patch.object(ui_probe, "run_logged", return_value={"exitCode": 0, "timedOut": False}) as runner, \
                 patch.object(ui_probe, "result_summary", return_value=summary), \
                 redirect_stdout(StringIO()):
                ui_probe.main()
            self.assertEqual(runner.call_count, 2)
            self.assertIn("-only-testing:WeGitUITests/" + target, runner.call_args_list[1].args[0])
            self.assertLessEqual(runner.call_args_list[1].args[2], 300)

    def test_v1_1_focused_diagnostics_resolve_real_bounded_test_methods(self):
        root = Path(__file__).resolve().parents[3]
        for focus in ("stash-workflow", "stash-recovery", "changes-groups", "toolbar-heights", "sidebar-surface"):
            target = ui_probe.FOCUSED_TESTS[focus]
            suite, method = target.split("/")
            source = (root / "WeGitUITests" / (suite + ".swift")).read_text()
            self.assertIn("func " + method + "(", source)

    def test_candidate_focus_runs_one_bounded_allowlisted_test_after_smoke(self):
        summary = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(sys, "argv", ["ui_probe.py", "--mode", "smoke", "--focus", "minimum-layout", "--output", folder]), \
                 patch.object(ui_probe, "inspect_environment", return_value={"interactivePrerequisites": True}), \
                 patch.object(ui_probe, "run_logged", return_value={"exitCode": 0, "timedOut": False}) as runner, \
                 patch.object(ui_probe, "result_summary", return_value=summary), \
                 redirect_stdout(StringIO()):
                ui_probe.main()
            self.assertEqual(runner.call_count, 2)
            first, focused = (call.args[0] for call in runner.call_args_list)
            self.assertIn("-only-testing:WeGitUITests/WeGitUITests/testWelcomeAndCloneForm", first)
            self.assertIn("-only-testing:WeGitUITests/LayoutTests/testMinimumWindowPreservesNavigationAndPrimaryControls", focused)
            self.assertIn("-maximum-test-execution-time-allowance", focused)
            self.assertLessEqual(runner.call_args_list[1].args[2], 300)

    def test_focus_refuses_arbitrary_tests_and_larger_candidate_scopes(self):
        for values in (["--mode", "functional", "--focus", "minimum-layout"],
                       ["--mode", "smoke", "--focus", "WeGitUITests/ManualAccessibilitySession"]):
            with self.subTest(values=values), patch.object(sys, "argv", ["ui_probe.py", *values]), \
                 patch.object(ui_probe, "inspect_environment") as inspect, \
                 redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                with self.assertRaises(SystemExit):
                    ui_probe.main()
                inspect.assert_not_called()

    def test_focused_diagnostic_never_starts_after_a_failed_smoke(self):
        summary = {"totalTestCount": 1, "passedTests": 0, "failedTests": 1, "skippedTests": 0}
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(sys, "argv", ["ui_probe.py", "--mode", "smoke", "--focus", "minimum-layout", "--output", folder]), \
                 patch.object(ui_probe, "inspect_environment", return_value={"interactivePrerequisites": True}), \
                 patch.object(ui_probe, "run_logged", return_value={"exitCode": 65, "timedOut": False}) as runner, \
                 patch.object(ui_probe, "result_summary", return_value=summary), \
                 redirect_stdout(StringIO()):
                with self.assertRaises(SystemExit):
                    ui_probe.main()
            self.assertEqual(runner.call_count, 1)

    def test_automatic_scopes_keep_opt_in_manual_session_out_of_zero_skip_acceptance(self):
        summary = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        for mode in ("functional", "accessibility"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                with patch.object(sys, "argv", ["ui_probe.py", "--mode", mode, "--output", folder]), \
                     patch.object(ui_probe, "inspect_environment", return_value={"interactivePrerequisites": True}), \
                     patch.object(ui_probe, "run_logged", return_value={"exitCode": 0, "timedOut": False}) as runner, \
                     patch.object(ui_probe, "result_summary", return_value=summary), \
                     redirect_stdout(StringIO()):
                    ui_probe.main()
                self.assertEqual(runner.call_count, 2)
                smoke, selected = (call.args[0] for call in runner.call_args_list)
                self.assertIn("-only-testing:WeGitUITests/WeGitUITests/testWelcomeAndCloneForm", smoke)
                audit = "WeGitUITests/LayoutTests/testAccessibilityAuditInBothThemes"
                if mode == "functional":
                    self.assertIn("-skip-testing:WeGitUITests/ManualAccessibilitySession", selected)
                    self.assertIn("-skip-testing:" + audit, selected)
                    self.assertFalse(any(value.startswith("-only-testing:") for value in selected))
                else:
                    self.assertIn("-only-testing:" + audit, selected)
                    self.assertFalse(any(value.startswith("-skip-testing:") for value in selected))


class NativeCandidateSourceTests(unittest.TestCase):
    def candidate(self):
        return {"state": "open", "base": {"ref": "main", "repo": {"full_name": "WeOpen/WeGit"}},
                "head": {"sha": "b" * 40, "repo": {"full_name": "WeOpen/WeGit"}}}

    def test_main_and_owned_candidate_use_explicit_immutable_commits(self):
        self.assertEqual(choose_source("a" * 40, "WeOpen/WeGit"), "a" * 40)
        self.assertEqual(choose_source("a" * 40, "WeOpen/WeGit", self.candidate()), "b" * 40)

    def test_forks_closed_wrong_base_and_mutable_source_are_refused(self):
        import copy
        for mutate in [lambda p: p.update(state="closed"), lambda p: p["base"].update(ref="other"),
                       lambda p: p["head"].update(repo={"full_name": "external/WeGit"}),
                       lambda p: p["head"].update(sha="main")]:
            candidate = copy.deepcopy(self.candidate())
            mutate(candidate)
            with self.assertRaises(ValueError):
                choose_source("a" * 40, "WeOpen/WeGit", candidate)
        with self.assertRaises(ValueError):
            choose_source("main", "WeOpen/WeGit")


if __name__ == "__main__":
    unittest.main()
