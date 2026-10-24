#!/usr/bin/env python3
"""Collect independent scopes after proven budget failures; stop on missing/invalid evidence."""
import argparse
import json
import math
from pathlib import Path
import re
import subprocess


def budget_failure(report, kind, summary=None):
    """True only for complete measurements with a recomputed budget failure."""
    if kind == "workbench":
        budgets = {"shell": 500, "status": 300, "diff": 150, "history": 300, "external-update": 1000}
        if report.get("fixture", {}).get("label") != "normal":
            return False
        if not summary or any(summary.get(key) != value for key, value in
                              {"totalTestCount": 1, "failedTests": 1, "passedTests": 0, "skippedTests": 0}.items()):
            return False
        failures = summary.get("testFailures", [])
        if not failures:
            return False
        for failure in failures:
            match = re.fullmatch(r'XCTAssertLessThan failed: .* - P95 (shell|status|diff|history|external-update) is ([0-9.]+) ms', failure.get("failureText", ""))
            if (not match or failure.get("testIdentifierString") != "WorkbenchPerformanceTests/testActualWorkspaceFirstScreens()"
                    or report.get("metrics", {}).get(match[1], {}).get("p95Ms") != float(match[2])):
                return False
        failed = False
        for name, budget in budgets.items():
            values = [item.get("milliseconds") for item in report.get("samples", []) if item.get("name") == name]
            if len(values) != 30 or not all(isinstance(value, (int, float)) and math.isfinite(value) and value > 0 for value in values):
                return False
            metric = report.get("metrics", {}).get(name, {})
            p95 = sorted(values)[28]
            passed = p95 < budget
            if metric.get("count") != 30 or metric.get("budgetMs") != budget or metric.get("p95Ms") != p95 or metric.get("passed") is not passed:
                return False
            failed |= not passed
        return failed
    if kind == "launch":
        values = report.get("samplesMs", [])
        if len(values) != 30 or not all(isinstance(value, (int, float)) and math.isfinite(value) and value > 0 for value in values):
            return False
        p95 = sorted(values)[28]
        return (report.get("sampleCount") == 30 and report.get("budgetP95Ms") == 1000
                and report.get("p95Ms") == p95 and report.get("withinBudget") is False and p95 >= 1000)
    return False


def run_scope(root, command, prefix, report_name=None, kind=None):
    output = root / ".build/ui-benchmarks"
    before = set(output.glob(prefix + "-*"))
    result = subprocess.run(command, cwd=root)
    created = set(output.glob(prefix + "-*")) - before
    report = next(iter(created)) / report_name if len(created) == 1 and report_name else None
    budget_only = False
    if result.returncode and report and report.is_file():
        try:
            summary_path = report.parent / "summary.json"
            summary = json.loads(summary_path.read_text()) if summary_path.is_file() else None
            budget_only = budget_failure(json.loads(report.read_text()), kind, summary)
        except (ValueError, TypeError, KeyError):
            pass
    return {"command": command[0], "exitCode": result.returncode,
            "budgetOnlyFailure": budget_only, "report": str(report.relative_to(root)) if report else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--normal-only", action="store_true", help="A diagnostic baseline, never acceptance")
    parser.add_argument("--scope", choices=("full", "launch", "scroll"), default="full",
                        help="Collect an independent diagnostic without repeating unrelated scopes")
    args = parser.parse_args()
    if args.normal_only and args.scope != "full":
        parser.error("The released control only supports the normal workbench scope.")
    root = args.root.resolve()
    fixture = root / ".build/benchmarks/native/fixtures"
    scopes = [("scripts/benchmark-ui-workbench.sh", [str(fixture / "normal"), "30"], "workbench", "workbench.json", "workbench")]
    if not args.normal_only:
        scopes += [
            ("scripts/benchmark-ui-workbench.sh", [str(fixture / "large"), "30"], "workbench", "workbench.json", "workbench"),
            ("scripts/benchmark-ui-launch.sh", [], "launch", "launch.json", "launch"),
            ("scripts/benchmark-ui-large-scroll.sh", [str(fixture / "large")], "large-scroll", None, None),
        ]
    if args.scope != "full":
        scopes = [scope for scope in scopes if scope[2] == {"launch": "launch", "scroll": "large-scroll"}[args.scope]]
    results = []
    destination = root / ".build/ci/performance/scope-results.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    for script, arguments, prefix, report_name, kind in scopes:
        result = run_scope(root, [script, *arguments], prefix, report_name, kind)
        results.append(result)
        destination.write_text(json.dumps({"diagnosticOnly": args.normal_only or args.scope != "full",
                                           "requestedScope": args.scope, "scopes": results}, indent=2) + "\n")
        if result["exitCode"] and not result["budgetOnlyFailure"]:
            raise SystemExit("Interaction/infrastructure failed or evidence is incomplete; no larger scope started.")
    if any(result["exitCode"] for result in results):
        raise SystemExit("Retained all completed independent measurements; performance budgets failed.")


if __name__ == "__main__":
    main()
