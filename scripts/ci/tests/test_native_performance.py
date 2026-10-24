import copy
import json
from pathlib import Path
import sys
import unittest
from tempfile import TemporaryDirectory
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_performance import budget_failure, main


class NativePerformanceTests(unittest.TestCase):
    def test_independent_scroll_is_diagnostic_and_does_not_repeat_other_scopes(self):
        with TemporaryDirectory() as directory:
            with patch.object(sys, "argv", ["native_performance", "--root", directory, "--scope", "scroll"]), \
                    patch("native_performance.run_scope", return_value={"exitCode": 0}) as run:
                main()
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[1][0], "scripts/benchmark-ui-large-scroll.sh")
            result = json.loads((Path(directory) / ".build/ci/performance/scope-results.json").read_text())
            self.assertTrue(result["diagnosticOnly"])
            self.assertEqual(result["requestedScope"], "scroll")

    def test_full_collection_stops_on_incomplete_launch_and_preserves_prior_failure(self):
        results = [{"exitCode": 65, "budgetOnlyFailure": True},
                   {"exitCode": 0, "budgetOnlyFailure": False},
                   {"exitCode": 1, "budgetOnlyFailure": False}]
        with TemporaryDirectory() as directory:
            with patch.object(sys, "argv", ["native_performance", "--root", directory]), \
                    patch("native_performance.run_scope", side_effect=results) as run:
                with self.assertRaisesRegex(SystemExit, "evidence is incomplete"):
                    main()
            self.assertEqual(run.call_count, 3)
            result = json.loads((Path(directory) / ".build/ci/performance/scope-results.json").read_text())
            self.assertFalse(result["diagnosticOnly"])
            self.assertEqual(result["scopes"], results)

    def summary(self):
        return {"totalTestCount": 1, "failedTests": 1, "passedTests": 0, "skippedTests": 0,
                "testFailures": [{"failureText": 'XCTAssertLessThan failed: ("151") is not less than ("150") - P95 diff is 151 ms',
                                  "testIdentifierString": "WorkbenchPerformanceTests/testActualWorkspaceFirstScreens()"}]}

    def report(self):
        budgets = {"shell": 500, "status": 300, "diff": 150, "history": 300, "external-update": 1000}
        return {"fixture": {"label": "normal"},
                "samples": [{"name": name, "milliseconds": budget + 1} for name, budget in budgets.items() for _ in range(30)],
                "metrics": {name: {"count": 30, "budgetMs": budget, "p95Ms": budget + 1, "passed": False} for name, budget in budgets.items()}}

    def test_only_complete_recomputed_budget_failures_allow_other_scopes(self):
        report = self.report()
        self.assertTrue(budget_failure(report, "workbench", self.summary()))
        for mutate in [lambda r: r["samples"].pop(),
                       lambda r: r["samples"][0].update(milliseconds=float("nan")),
                       lambda r: r["metrics"]["diff"].update(p95Ms=999),
                       lambda r: r["metrics"]["diff"].update(passed=True),
                       lambda r: r["fixture"].update(label="large")]:
            changed = copy.deepcopy(report)
            mutate(changed)
            self.assertFalse(budget_failure(changed, "workbench", self.summary()))
        self.assertFalse(budget_failure({}, "workbench"))
        self.assertFalse(budget_failure(report, "workbench"))
        summary = self.summary()
        summary["testFailures"].append({"failureText": "Failed to terminate application"})
        self.assertFalse(budget_failure(report, "workbench", summary))

    def test_launch_failure_cannot_hide_missing_samples_or_misreported_results(self):
        report = {"samplesMs": [1100] * 30, "sampleCount": 30, "p95Ms": 1100,
                  "budgetP95Ms": 1000, "withinBudget": False}
        self.assertTrue(budget_failure(report, "launch"))
        for change in [{"samplesMs": [1100]}, {"withinBudget": True}, {"p95Ms": 500}, {"budgetP95Ms": 2000}]:
            self.assertFalse(budget_failure(report | change, "launch"))
