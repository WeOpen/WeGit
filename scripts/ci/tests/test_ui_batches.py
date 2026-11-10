"""Trusted native batch dispatch checks; xcodebuild is mocked, never executed."""
from contextlib import redirect_stdout
import copy
from io import StringIO
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import Mock

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_policy import Loader
import ui_probe
from ui_source import choose_source


ROOT = Path(__file__).resolve().parents[3]
REGISTRY = ROOT / "scripts/ci/ui_batches.json"
SMOKE = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
SUCCESS = {"exitCode": 0, "timedOut": False}


class TrustedNativeBatchTests(unittest.TestCase):
    def workflow(self):
        return yaml.load((ROOT / ".github/workflows/native-ui.yml").read_text(), Loader=Loader)

    def batches(self):
        return json.loads(REGISTRY.read_text())["batches"]

    def test_dispatch_choices_match_the_complete_trusted_registry(self):
        choices = self.workflow()["on"]["workflow_dispatch"]["inputs"]["batch"]["options"]
        self.assertEqual(len(choices), len(set(choices)))
        self.assertEqual(set(choices), {"none", *self.batches()})
        for name in self.batches():
            self.assertGreater(len(ui_probe.batch_methods(REGISTRY, name)), 0)

    def test_main_owns_resolution_and_registry_before_candidate_checkout(self):
        job = self.workflow()["jobs"]["ui"]
        self.assertEqual(job["if"], "github.ref == 'refs/heads/main'")
        self.assertEqual(job["permissions"], {"contents": "read", "pull-requests": "read"})
        steps = job["steps"]
        checkouts = [index for index, step in enumerate(steps)
                     if step.get("uses", "").startswith("actions/checkout@")]
        source = next(index for index, step in enumerate(steps) if step.get("id") == "source")
        self.assertEqual(len(checkouts), 2)
        self.assertLess(checkouts[0], source)
        self.assertLess(source, checkouts[1])
        self.assertEqual(steps[checkouts[0]]["with"]["ref"], "${{ github.sha }}")
        self.assertEqual(steps[checkouts[1]]["with"]["ref"], "${{ steps.source.outputs.sha }}")
        for checkout in checkouts:
            self.assertFalse(steps[checkout]["with"]["persist-credentials"])
        for original, trusted in [("ui_probe.py", "wegit-trusted-ui-probe.py"),
                                  ("ui_batches.json", "wegit-trusted-ui-batches.json")]:
            self.assertIn('cp scripts/ci/' + original + ' "$RUNNER_TEMP/' + trusted + '"', steps[source]["run"])
        execution = next(step["run"] for step in steps if step.get("name") == "Run bounded native scope")
        self.assertIn('--registry "$RUNNER_TEMP/wegit-trusted-ui-batches.json"', execution)
        self.assertIn('"$RUNNER_TEMP/wegit-trusted-ui-probe.py"', execution)
        preflight = next(index for index, step in enumerate(steps)
                         if step.get("name") == "Check complete trusted batch against candidate source before building")
        build = next(index for index, step in enumerate(steps) if step.get("name") == "Build native regression once")
        self.assertLess(checkouts[1], preflight)
        self.assertLess(preflight, build)
        self.assertEqual(steps[preflight]["if"], "inputs.scope == 'batch'")
        self.assertIn('--mode batch-preflight', steps[preflight]["run"])
        self.assertIn('--registry "$RUNNER_TEMP/wegit-trusted-ui-batches.json"', steps[preflight]["run"])

    def test_explicit_open_same_repository_main_candidates_require_fixed_sha(self):
        candidate = {"state": "open", "base": {"ref": "main", "repo": {"full_name": "WeOpen/WeGit"}},
                     "head": {"sha": "b" * 40, "repo": {"full_name": "WeOpen/WeGit"}}}
        self.assertEqual(choose_source("a" * 40, "WeOpen/WeGit"), "a" * 40)
        self.assertEqual(choose_source("a" * 40, "WeOpen/WeGit", candidate), "b" * 40)
        for mutate in [lambda p: p.update(state="closed"),
                       lambda p: p["base"].update(ref="other"),
                       lambda p: p["base"].update(repo={"full_name": "external/WeGit"}),
                       lambda p: p["head"].update(repo={"full_name": "external/WeGit"}),
                       lambda p: p["head"].update(sha="main")]:
            invalid = copy.deepcopy(candidate)
            mutate(invalid)
            with self.assertRaises(ValueError):
                choose_source("a" * 40, "WeOpen/WeGit", invalid)
        with self.assertRaises(ValueError):
            choose_source("main", "WeOpen/WeGit")

    def test_unknown_duplicate_and_smoke_in_registry_are_rejected(self):
        for methods in [[], ["A/testOne", "A/testOne"], ["A"],
                        ["WeGitUITests/testWelcomeAndCloneForm"], ["A/testOne;command"]]:
            with self.subTest(methods=methods), tempfile.TemporaryDirectory() as folder:
                registry = Path(folder) / "registry.json"
                registry.write_text(json.dumps({"format": 1, "batches": {"fixture": {"methods": methods}}}))
                with self.assertRaises(ValueError):
                    ui_probe.batch_methods(registry, "fixture")
        with self.assertRaises(ValueError):
            ui_probe.batch_methods(REGISTRY, "unregistered")

    def dispatch(self, name, folder, summaries, results):
        return (patch.object(sys, "argv", ["ui_probe.py", "--mode", "batch", "--batch", name,
                                          "--registry", str(REGISTRY), "--output", folder]),
                patch.multiple(ui_probe, inspect_environment=Mock(return_value={"interactivePrerequisites": True}),
                               verify_batch_sources=Mock(return_value={})),
                patch.object(ui_probe, "run_logged", side_effect=results),
                patch.object(ui_probe, "result_summary", side_effect=summaries))

    def test_every_batch_runs_one_smoke_then_exactly_its_complete_set_without_building(self):
        for name in self.batches():
            methods = ui_probe.batch_methods(REGISTRY, name)
            complete = SMOKE | {"totalTestCount": len(methods), "passedTests": len(methods)}
            with self.subTest(batch=name), tempfile.TemporaryDirectory() as folder:
                argv, environment, runner_patch, summary = self.dispatch(name, folder, [SMOKE, complete], [SUCCESS, SUCCESS])
                with argv, environment, runner_patch as runner, summary, redirect_stdout(StringIO()):
                    ui_probe.main()
                self.assertEqual(runner.call_count, 2)
                smoke_command = runner.call_args_list[0].args[0]
                command = runner.call_args_list[1].args[0]
                self.assertEqual([arg for arg in smoke_command if arg.startswith("-only-testing:")],
                                 ["-only-testing:WeGitUITests/WeGitUITests/testWelcomeAndCloneForm"])
                self.assertEqual([arg for arg in command if arg.startswith("-only-testing:")],
                                 ["-only-testing:WeGitUITests/" + method for method in methods])
                self.assertIn("test-without-building", command)
                self.assertNotIn("build-for-testing", command)
                self.assertFalse(any(arg.startswith("-skip-testing:") for arg in command))
                self.assertLessEqual(runner.call_args_list[1].args[2], 5400)
                report = json.loads((Path(folder) / "batch.json").read_text())
                self.assertEqual(report["selectedMethods"], methods)
                self.assertEqual(len(report["tests"]), 2)
                self.assertFalse(report["releaseReady"])

    def test_smoke_missing_failed_or_skipped_stops_before_the_batch(self):
        name = next(iter(self.batches()))
        for changes in [{"totalTestCount": 0, "passedTests": 0}, {"passedTests": 0, "failedTests": 1},
                        {"passedTests": 0, "skippedTests": 1}]:
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as folder:
                argv, environment, runner_patch, summary = self.dispatch(name, folder, [SMOKE | changes], [SUCCESS])
                with argv, environment, runner_patch as runner, summary, redirect_stdout(StringIO()), self.assertRaises(ValueError):
                    ui_probe.main()
                self.assertEqual(runner.call_count, 1)

    def test_passing_subset_and_failed_or_skipped_methods_cannot_pass_the_full_set(self):
        for name in self.batches():
            methods = ui_probe.batch_methods(REGISTRY, name)
            complete = SMOKE | {"totalTestCount": len(methods), "passedTests": len(methods)}
            for changes in [{"totalTestCount": len(methods) - 1, "passedTests": len(methods) - 1},
                            {"passedTests": len(methods) - 1, "failedTests": 1},
                            {"passedTests": len(methods) - 1, "skippedTests": 1}]:
                with self.subTest(batch=name, changes=changes), self.assertRaises(ValueError):
                    ui_probe.verify_batch_summary(complete | changes, methods)

    def test_batch_timeout_retains_full_selection_and_does_not_claim_release_acceptance(self):
        name = next(iter(self.batches()))
        failed = {"exitCode": -15, "timedOut": True}
        with tempfile.TemporaryDirectory() as folder:
            argv, environment, runner_patch, summary = self.dispatch(name, folder, [SMOKE, {}], [SUCCESS, failed])
            with argv, environment, runner_patch as runner, summary, redirect_stdout(StringIO()), self.assertRaises(SystemExit):
                ui_probe.main()
            self.assertEqual(runner.call_count, 2)
            report = json.loads((Path(folder) / "batch.json").read_text())
            self.assertFalse(report["releaseReady"])
            self.assertEqual(report["tests"][1]["selectedMethods"], ui_probe.batch_methods(REGISTRY, name))
            self.assertTrue(report["tests"][1]["timedOut"])

    def test_candidate_source_requires_one_method_in_exactly_one_owning_class(self):
        valid = [
            'final class Selected: XCTestCase { func testChosen() { let text = "}" } }',
            r'final class Selected: XCTestCase { func testChosen() { let text = "\(String("}"))" } }',
            r'final class Selected: XCTestCase { func testChosen() { let text = #"\#(String("}"))"# } }',
            'final class Selected: XCTestCase { func testChosen() { let text = """\n}\n""" } }',
        ]
        invalid = [
            'final class Selected: XCTestCase {}',
            'final class Selected: XCTestCase {} final class Other: XCTestCase { func testChosen() {} }',
            'final class Selected: XCTestCase { func testChosen() {} func testChosen() {} }',
            'final class Selected: XCTestCase { func testChosen() {} } final class Selected: XCTestCase {}',
            'final class Selected: XCTestCase { func helper() { func testChosen() {} } }',
            'final class Selected: XCTestCase { let text = "func testChosen() {}" }',
            'final class Selected: XCTestCase { /* outer /* nested */ func testChosen() {} */ }',
            'final class Selected: XCTestCase { let text = #"func testChosen() {}"# }',
        ]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            directory = root / "WeGitUITests"
            directory.mkdir()
            source = directory / "Fixture.swift"
            for value in valid:
                source.write_text(value)
                with self.subTest(source=value):
                    self.assertEqual(set(ui_probe.verify_batch_sources(root, ["Selected/testChosen"])),
                                     {"WeGitUITests/Fixture.swift"})
            for value in invalid:
                source.write_text(value)
                with self.subTest(source=value), self.assertRaises(ValueError):
                    ui_probe.verify_batch_sources(root, ["Selected/testChosen"])

    def test_preflight_checks_candidate_before_any_build_or_native_execution(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            native = root / "WeGitUITests"
            native.mkdir()
            source = native / "Selected.swift"
            source.write_text('final class Selected: XCTestCase { func testChosen() {} }')
            registry = root / "registry.json"
            registry.write_text(json.dumps({"format": 1, "batches": {"candidate": {"methods": ["Selected/testChosen"]}}}))
            arguments = ["ui_probe.py", "--mode", "batch-preflight", "--batch", "candidate", "--registry", str(registry),
                         "--output", str(root / "out")]
            with patch.object(sys, "argv", arguments), patch.object(ui_probe.Path, "cwd", return_value=root), \
                 patch.object(ui_probe, "inspect_environment") as environment, \
                 patch.object(ui_probe, "run_logged") as execute, redirect_stdout(StringIO()):
                ui_probe.main()
            execute.assert_not_called()
            environment.assert_not_called()
            report = json.loads((root / "out/batch-preflight.json").read_text())
            self.assertEqual(report["selectedMethods"], ["Selected/testChosen"])
            self.assertFalse(report["xctestExecuted"])
            self.assertFalse(report["releaseReady"])
            source.write_text('final class Selected: XCTestCase {}')
            with patch.object(sys, "argv", arguments), patch.object(ui_probe.Path, "cwd", return_value=root), \
                 patch.object(ui_probe, "run_logged") as execute, self.assertRaises(ValueError):
                ui_probe.main()
            execute.assert_not_called()


if __name__ == "__main__":
    unittest.main()
