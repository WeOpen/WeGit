import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout
from io import StringIO

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from batch_evidence import (COMMON, READING_PERFORMANCE_INPUTS, canonical_run, digest, eligible, inputs, run_suite, source_matches,
                            suite_job_succeeded, suite_job_outcome, failed_execution_matches,
                            reader_execution_contract, reader_compatibility)
from ui_probe import batch_methods, verify_batch_summary


class EvidenceTests(unittest.TestCase):
    def test_behavior_builds_app_objects_before_running_dependent_checks(self):
        root = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory(prefix="wegit-suite-order-") as folder:
            fixture = Path(folder)
            (fixture / "scripts/ci").mkdir(parents=True)
            scripts = {
                "scripts/build.sh": "#!/bin/bash\nset -eu\ntest \"$1\" = Debug\ntouch app-objects\n",
                "scripts/verify-preference-migration.sh": "#!/bin/bash\nset -eu\ntest -f app-objects\n",
                "scripts/ci/native-behavior.sh": "#!/bin/bash\nset -eu\ntest -f app-objects\ntest \"$1\" = behavior\n",
            }
            for name, value in scripts.items():
                path = fixture / name
                path.write_text(value); path.chmod(0o700)
            result = subprocess.run(["/bin/bash", str(root / "scripts/ci/run-batch-suite.sh"), "behavior"],
                                    cwd=fixture, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="wegit-evidence-")
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name)
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_CONFIG_SYSTEM=os.devnull, GIT_AUTHOR_NAME="Evidence fixture",
                        GIT_AUTHOR_EMAIL="fixture@example.invalid", GIT_COMMITTER_NAME="Evidence fixture",
                        GIT_COMMITTER_EMAIL="fixture@example.invalid")
        for name in (*COMMON, ".swift-format", "scripts/ci/prepare-git-246.sh",
                     "scripts/ci/native-behavior.sh", "scripts/verify-gpg-compatibility.sh",
                     "scripts/GPGCompatibilityChecks.swift", "WeGitCore/Core.swift", "WeGitTests/Test.swift",
                     "WeGit/App/AppPreferences.swift", "scripts/RebasePerformance.swift", "project.yml", "LICENSE"):
            self.write(name, "original\n")

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def test_app_edits_do_not_repeat_core_signing_or_backend_performance(self):
        before = {suite: inputs(self.root, suite) for suite in ("core", "signing", "behavior", "performance")}
        self.write("WeGit/App/AppPreferences.swift", "new theme library\n")
        for suite in ("core", "signing", "performance"):
            self.assertEqual(before[suite], inputs(self.root, suite))
        self.assertNotEqual(before["behavior"], inputs(self.root, "behavior"))
        self.write("WeGitTests/Test.swift", "new test\n")
        self.assertNotEqual(before["core"], inputs(self.root, "core"))

    def test_changed_fixture_or_shared_validator_expands_the_affected_scope(self):
        before = {suite: inputs(self.root, suite) for suite in ("core", "signing", "performance")}
        self.write("scripts/GPGCompatibilityChecks.swift", "changed signing assertion\n")
        self.assertNotEqual(before["signing"], inputs(self.root, "signing"))
        self.assertEqual(before["core"], inputs(self.root, "core"))
        self.write("scripts/ci/run-batch-suite.sh", "changed validation contract\n")
        for suite in before:
            self.assertNotEqual(before[suite], inputs(self.root, suite))

    def test_reading_feature_requires_all_fixtures_and_python_changes_invalidate_reuse(self):
        # A source without Query retains the old input contract, even when it
        # already has the M2 comparison service.
        self.write("WeGitCore/GitCore/CommitComparisonService.swift", "comparison\n")
        self.assertNotIn("scripts/verify-reading-performance.py", inputs(self.root, "performance"))
        self.write("WeGitCore/GitCore/RepositoryQueryService.swift", "query\n")
        with self.assertRaisesRegex(ValueError, "Validation input missing"):
            inputs(self.root, "performance")
        for name in READING_PERFORMANCE_INPUTS:
            self.write(name, "original reader input\n")
        before = inputs(self.root, "performance")
        self.assertTrue(set(READING_PERFORMANCE_INPUTS) <= before.keys())
        receipt, run, _ = self.receipt()
        receipt.update(suite="performance", inputFiles=before, inputDigest=digest(before))
        self.assertTrue(eligible(receipt, before, receipt["toolchain"], run, 17, "WeOpen/WeGit"))
        for name in ["scripts/create-reading-performance-fixtures.py", "scripts/verify-reading-performance.py",
                     "scripts/create-benchmark-fixtures.py"]:
            self.write(name, "changed reader fixture or verifier\n")
            changed = inputs(self.root, "performance")
            self.assertNotEqual(before, changed, name)
            self.assertFalse(eligible(receipt, changed, receipt["toolchain"], run, 17, "WeOpen/WeGit"))
            self.write(name, "original reader input\n")
        (self.root / "scripts/verify-reading-performance.py").unlink()
        with self.assertRaisesRegex(ValueError, "scripts/verify-reading-performance.py"):
            inputs(self.root, "performance")

    def test_query_performance_gate_executes_required_checker_and_refuses_missing_script(self):
        root = Path(__file__).resolve().parents[3]
        runner = root / "scripts/ci/native-behavior.sh"
        self.write("WeGitCore/GitCore/CommitComparisonService.swift", "comparison\n")
        result = subprocess.run(["/bin/bash", str(runner), "performance"], cwd=self.root,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Comparison/query performance not covered", result.stdout)
        self.write("WeGitCore/GitCore/RepositoryQueryService.swift", "query\n")
        missing = subprocess.run(["/bin/bash", str(runner), "performance"], cwd=self.root,
                                 capture_output=True, text=True)
        self.assertNotEqual(missing.returncode, 0)
        checker = self.root / "scripts/verify-reading-performance.sh"
        self.write(str(checker.relative_to(self.root)), "#!/bin/bash\nset -eu\nprintf 'reading-checker-ran\\n'\n")
        checker.chmod(0o700)
        result = subprocess.run(["/bin/bash", str(runner), "performance"], cwd=self.root,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("reading-checker-ran"), 1)
        self.assertNotIn("Comparison/query performance not covered", result.stdout)

    def test_native_evidence_always_retains_bounded_reading_results_and_failure_logs(self):
        import yaml
        from check_policy import Loader
        root = Path(__file__).resolve().parents[3]
        workflow = yaml.load((root / ".github/workflows/verify.yml").read_text(), Loader=Loader)
        steps = workflow["jobs"]["native"]["steps"]
        retained = next(step for step in steps if step.get("name") == "Retain native evidence and preview")
        self.assertEqual(retained["if"], "always()")
        paths = set(retained["with"]["path"].splitlines())
        expected = {".build/reading-performance-*/" + name for name in ["result.json", "fixtures.json",
                    "input-receipt.json", "source-before.json", "independent-verification.json", "build.log",
                    "checker-build.log", "fixture.log", "runtime.log", "verification.log", "fixture-root.txt"]}
        self.assertTrue(expected <= paths)
        self.assertFalse(any("**" in path for path in paths if "reading-performance" in path))

    def receipt(self):
        files = inputs(self.root, "core")
        run = {"id": 11, "workflow_id": 17, "head_sha": "a" * 40, "head_branch": "main",
               "event": "push", "status": "completed", "conclusion": "success"}
        receipt = {"format": 1, "status": "success", "suite": "core", "repository": "WeOpen/WeGit", "runId": "11",
                   "runAttempt": "1", "mode": "executed",
                   "sourceCommit": "a" * 40, "inputFiles": files, "inputDigest": digest(files), "toolchain": {"xcode": "fixed"},
                   "execution": {"kind": "executed", "exitCode": 0, "runId": "11", "sourceCommit": "a" * 40,
                                 "logSHA256": "b" * 64}}
        return receipt, run, files

    def test_failed_later_phase_reuses_only_an_actually_completed_successful_suite(self):
        receipt, run, files = self.receipt()
        run["conclusion"] = "failure"
        jobs = [{"name": "Native macOS", "conclusion": "failure", "steps": [
            {"name": "Core regression on Apple, minimum and Homebrew Git", "status": "completed", "conclusion": "success"},
            {"name": "Compile application and native UI regressions", "status": "completed", "conclusion": "failure"}]}]
        self.assertFalse(eligible(receipt, files, receipt["toolchain"], run, 17, "WeOpen/WeGit"))
        verified = suite_job_succeeded(receipt, jobs)
        self.assertTrue(verified)
        self.assertTrue(eligible(receipt, files, receipt["toolchain"], run, 17, "WeOpen/WeGit", phase_verified=verified))
        for conclusion in ("failure", "skipped", "cancelled", None):
            modified = copy.deepcopy(jobs)
            modified[0]["steps"][0]["conclusion"] = conclusion
            self.assertFalse(suite_job_succeeded(receipt, modified))
        application = copy.deepcopy(receipt)
        application["suite"] = "application"
        self.assertFalse(suite_job_succeeded(application, jobs))
        reused = copy.deepcopy(receipt)
        reused["mode"] = "reused"
        self.assertFalse(suite_job_succeeded(reused, jobs))
        for field in ("runId", "sourceCommit"):
            modified = copy.deepcopy(receipt)
            modified["execution"][field] = "different"
            self.assertFalse(suite_job_succeeded(modified, jobs))

    def test_reader_only_change_preserves_every_execution_statement(self):
        before = "import json\nCOMMON=('entry',)\ndef run_suite():\n return 1\ndef restore():\n return False\n"
        reader = before.replace("return False", "return True")
        self.assertEqual(reader_execution_contract(before), reader_execution_contract(reader))
        self.assertNotEqual(reader_execution_contract(before),
                            reader_execution_contract(reader.replace("return 1", "return 2")))
        self.assertNotEqual(reader_execution_contract(before),
                            reader_execution_contract(reader + "\nrun_suite=lambda: 2\n"))
        self.assertNotEqual(reader_execution_contract(before),
                            reader_execution_contract(reader.replace("('entry',)", "('different',)")))

    def test_reader_compatibility_is_recomputed_from_the_source_git_blob(self):
        def git(*args):
            return subprocess.check_output(["git", "-C", str(self.root), *args], env=self.env,
                                           stderr=subprocess.DEVNULL, text=True).strip()
        name = "scripts/ci/batch_evidence.py"
        before = "import json\nCOMMON=('entry',)\ndef run_suite():\n return 1\ndef restore():\n return False\n"
        self.write(name, before)
        git("init", "--initial-branch=main"); git("add", "--all")
        git("-c", "commit.gpgsign=false", "commit", "-m", "fixture")
        receipt, run, files = self.receipt()
        receipt["sourceCommit"] = run["head_sha"] = git("rev-parse", "HEAD")
        self.write(name, before.replace("return False", "return True"))
        expected = inputs(self.root, "core")
        proof = reader_compatibility(self.root, receipt, expected)
        self.assertIsNotNone(proof)
        self.assertTrue(source_matches(self.root, "WeOpen/WeGit", receipt, run))
        self.assertTrue(eligible(receipt, expected, receipt["toolchain"], run, 17, "WeOpen/WeGit", reader_proof=proof))
        forged = proof | {"currentSHA256": "0" * 64}
        self.assertFalse(eligible(receipt, expected, receipt["toolchain"], run, 17, "WeOpen/WeGit", reader_proof=forged))
        self.write("WeGitCore/Core.swift", "changed backend\n")
        self.assertIsNone(reader_compatibility(self.root, receipt, inputs(self.root, "core")))
        self.write("WeGitCore/Core.swift", "original\n")
        self.write(name, before.replace("return 1", "return 2"))
        self.assertIsNone(reader_compatibility(self.root, receipt, inputs(self.root, "core")))

    def test_missing_failed_wrong_workflow_and_changed_inputs_never_count_as_reuse(self):
        receipt, run, files = self.receipt()
        self.assertTrue(eligible(receipt, files, receipt["toolchain"], run, 17, "WeOpen/WeGit"))
        for mutate in (lambda r: r.update(status="failure"), lambda r: r.update(inputDigest="f" * 64),
                       lambda r: r.update(runId="12"), lambda r: r.update(execution={}),
                       lambda r: r["execution"].update(exitCode=1), lambda r: r.update(toolchain={"xcode": "changed"})):
            modified = copy.deepcopy(receipt)
            mutate(modified)
            self.assertFalse(eligible(modified, files, receipt["toolchain"], run, 17, "WeOpen/WeGit"))
        for mutate in (lambda r: r.update(conclusion="failure"), lambda r: r.update(workflow_id=18),
                       lambda r: r.update(head_branch="other"), lambda r: r.update(head_sha="main")):
            modified = copy.deepcopy(run)
            mutate(modified)
            self.assertFalse(canonical_run(modified, 17, "WeOpen/WeGit"))

    def test_source_input_claims_are_independently_recomputed_from_git_objects(self):
        def git(*args):
            return subprocess.check_output(["git", "-C", str(self.root), *args], env=self.env,
                                           stderr=subprocess.DEVNULL, text=True).strip()
        git("init", "--initial-branch=main")
        git("add", "--all")
        git("-c", "commit.gpgsign=false", "commit", "-m", "fixture")
        sha = git("rev-parse", "HEAD")
        receipt, run, _ = self.receipt()
        receipt["sourceCommit"] = run["head_sha"] = sha
        self.assertTrue(source_matches(self.root, "WeOpen/WeGit", receipt, run))
        receipt["inputFiles"]["WeGitCore/Core.swift"] = "0" * 64
        receipt["inputDigest"] = digest(receipt["inputFiles"])
        self.assertFalse(source_matches(self.root, "WeOpen/WeGit", receipt, run))

    def test_shallow_merge_provenance_reads_raw_commit_parents(self):
        def git(*args):
            return subprocess.check_output(["git", "-C", str(self.root), *args], env=self.env,
                                           stderr=subprocess.DEVNULL, text=True).strip()
        git("init", "--initial-branch=main"); git("add", "--all")
        git("-c", "commit.gpgsign=false", "commit", "-m", "base")
        base = git("rev-parse", "HEAD")
        git("checkout", "-b", "head")
        self.write("WeGitCore/Core.swift", "new backend\n")
        git("add", "--all"); git("-c", "commit.gpgsign=false", "commit", "-m", "head")
        head = git("rev-parse", "HEAD")
        tree = git("rev-parse", "HEAD^{tree}")
        source = subprocess.check_output(
            ["git", "-C", str(self.root), "commit-tree", tree, "-p", base, "-p", head],
            input="fixture merge\n", env=self.env, text=True, stderr=subprocess.DEVNULL).strip()
        raw = git("cat-file", "-p", source)
        self.assertEqual(len([row for row in raw.splitlines() if row.startswith("parent ")]), 2)
        receipt, run, _ = self.receipt()
        receipt["sourceCommit"] = source
        run.update(head_sha=head, event="pull_request")
        self.write(".git/shallow", source + "\n")
        self.assertEqual(git("show", "-s", "--format=%P", source), "")
        self.assertTrue(source_matches(self.root, "WeOpen/WeGit", receipt, run))

    def test_newer_matching_failed_execution_cannot_be_replaced_by_an_older_pass(self):
        receipt, run, files = self.receipt()
        receipt.update(status="failure")
        receipt["execution"]["exitCode"] = 1
        run["conclusion"] = "failure"
        jobs = [{"name": "Native macOS", "steps": [
            {"name": "Core regression on Apple, minimum and Homebrew Git",
             "status": "completed", "conclusion": "failure"}]}]
        self.assertEqual(suite_job_outcome(receipt, jobs), "failure")
        self.assertTrue(failed_execution_matches(receipt, files, receipt["toolchain"], run, 17, "WeOpen/WeGit"))
        changed = copy.deepcopy(files)
        changed["WeGitCore/Core.swift"] = "different"
        self.assertFalse(failed_execution_matches(receipt, changed, receipt["toolchain"], run, 17, "WeOpen/WeGit"))
        self.assertFalse(eligible(receipt, files, receipt["toolchain"], run, 17, "WeOpen/WeGit", phase_verified=True))

    def test_local_tool_checks_cannot_execute_native_suites(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}), patch("batch_evidence.subprocess.run") as execute:
            with self.assertRaisesRegex(ValueError, "only on GitHub-hosted"):
                run_suite(self.root, "core", self.root / "out.json", self.root / "none.json")
            execute.assert_not_called()


class TrustedBatchTests(unittest.TestCase):
    def test_workflow_exposes_exact_trusted_registry_and_copies_it_before_candidate_checkout(self):
        import yaml
        from check_policy import Loader
        root = Path(__file__).resolve().parents[3]
        workflow = yaml.load((root / ".github/workflows/native-ui.yml").read_text(), Loader=Loader)
        registry = json.loads((root / "scripts/ci/ui_batches.json").read_text())
        choices = workflow["on"]["workflow_dispatch"]["inputs"]["batch"]["options"]
        self.assertEqual(len(choices), len(set(choices)))
        self.assertEqual(set(choices), {"none", *registry["batches"]})
        job = workflow["jobs"]["ui"]
        self.assertEqual(job["if"], "github.ref == 'refs/heads/main'")
        steps = job["steps"]
        source = next(index for index, step in enumerate(steps) if step.get("id") == "source")
        checkouts = [index for index, step in enumerate(steps)
                     if step.get("uses", "").startswith("actions/checkout@")]
        self.assertEqual(len(checkouts), 2)
        self.assertLess(checkouts[0], source)
        self.assertLess(source, checkouts[1])
        self.assertEqual(steps[checkouts[0]]["with"]["ref"], "${{ github.sha }}")
        self.assertEqual(steps[checkouts[1]]["with"]["ref"], "${{ steps.source.outputs.sha }}")
        self.assertIn('cp scripts/ci/ui_batches.json "$RUNNER_TEMP/wegit-trusted-ui-batches.json"',
                      steps[source]["run"])
        execution = next(step["run"] for step in steps if step.get("name") == "Run bounded native scope")
        self.assertIn('--registry "$RUNNER_TEMP/wegit-trusted-ui-batches.json"', execution)

    def test_batch_runs_one_smoke_then_one_complete_set_without_rebuilding(self):
        import ui_probe
        root = Path(__file__).resolve().parents[3]
        methods = batch_methods(root / "scripts/ci/ui_batches.json", "baseline-controls")
        smoke = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        batch = smoke | {"totalTestCount": len(methods), "passedTests": len(methods)}
        with tempfile.TemporaryDirectory() as folder, \
             patch.object(sys, "argv", ["ui_probe.py", "--mode", "batch", "--batch", "baseline-controls", "--output", folder]), \
             patch.object(ui_probe, "inspect_environment", return_value={"interactivePrerequisites": True}), \
             patch.object(ui_probe, "run_logged", return_value={"exitCode": 0, "timedOut": False}) as runner, \
             patch.object(ui_probe, "result_summary", side_effect=[smoke, batch]), redirect_stdout(StringIO()):
            ui_probe.main()
        self.assertEqual(runner.call_count, 2)
        selected = runner.call_args_list[1].args[0]
        self.assertTrue(all("-only-testing:WeGitUITests/" + method in selected for method in methods))
        self.assertIn("test-without-building", selected)
        self.assertNotIn("build-for-testing", selected)

    def test_every_baseline_method_exists_and_is_unique_in_main_native_sources(self):
        root = Path(__file__).resolve().parents[3]
        registry = root / "scripts/ci/ui_batches.json"
        sources = list((root / "WeGitUITests").glob("*.swift"))
        # New candidate-only batches are checked against the actual candidate
        # checkout by the trusted probe before build and again before execution.
        for name in ("baseline-controls", "baseline-recovery", "baseline-repository"):
            methods = batch_methods(registry, name)
            for target in methods:
                suite, method = target.split("/")
                matching = [p.read_text() for p in sources if ("class " + suite + ":") in p.read_text()]
                self.assertEqual(len(matching), 1, target)
                self.assertIn("func " + method + "(", matching[0])

    def test_partial_passing_or_zero_skip_subset_cannot_pass_the_full_batch(self):
        valid = {"totalTestCount": 2, "passedTests": 2, "failedTests": 0, "skippedTests": 0}
        self.assertEqual(verify_batch_summary(valid, ["A/testOne", "A/testTwo"]), valid)
        for update in ({"totalTestCount": 1, "passedTests": 1}, {"skippedTests": 1}, {"failedTests": 1}):
            with self.assertRaises(ValueError):
                verify_batch_summary(valid | update, ["A/testOne", "A/testTwo"])


if __name__ == "__main__":
    unittest.main()
