#!/usr/bin/env python3
"""Measure a fixed released application with the current measurement-only harness."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

BASELINE = "2d1cb2a1e5a5b52f7ba45232e1f0b2a20530120a"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    args = parser.parse_args()
    tooling = Path(__file__).resolve().parents[2]
    baseline = args.baseline.resolve()
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=baseline, text=True).strip()
    if actual != BASELINE or subprocess.check_output(["git", "status", "--porcelain"], cwd=baseline):
        raise SystemExit("Baseline must start as the clean, immutable v1.0.0 commit.")
    names = ["WeGitPerformanceTests/WorkbenchPerformanceTests.swift", "scripts/benchmark-ui-workbench.sh",
             "scripts/summarize_workbench_benchmark.py", "scripts/ci/native_performance.py"]
    hashes = {}
    for name in names:
        source = tooling / name
        destination = baseline / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination.chmod(source.stat().st_mode)
        hashes[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    # The application, project and build receipt generator remain the released versions.
    changed = subprocess.check_output(["git", "diff", "--name-only"], cwd=baseline, text=True).splitlines()
    if not set(changed).issubset(names):
        raise SystemExit("Unexpected baseline application change.")
    fixture = baseline / ".build/benchmarks/native/fixtures"
    fixture.parent.mkdir(parents=True, exist_ok=True)
    fixture.symlink_to(tooling / ".build/benchmarks/native/fixtures", target_is_directory=True)
    output = tooling / ".build/ci/performance/baseline-comparison.json"
    record = {"baselineCommit": BASELINE, "candidateCommit": os.environ.get("GITHUB_SHA"),
              "sameVM": True, "measurementHarnessSHA256": hashes, "applicationOverlay": False,
              "scope": "normal repository first screens; serial fresh processes, warm filesystem cache",
              "result": "not-completed"}
    output.write_text(json.dumps(record, indent=2) + "\n")
    subprocess.run(["bash", "scripts/benchmark-ui-workbench.sh", str(fixture / "normal"), "1"], cwd=baseline, check=True)
    result = subprocess.run(["python3", "scripts/ci/native_performance.py", "--normal-only"], cwd=baseline)
    scopes = json.loads((baseline / ".build/ci/performance/scope-results.json").read_text())["scopes"]
    if result.returncode and (len(scopes) != 1 or not scopes[0]["budgetOnlyFailure"]):
        raise SystemExit("Baseline interaction/infrastructure failed; retain its xcresult.")
    receipt = json.loads((baseline / ".build-app/Build/Products/ReleasePerformance/WeGit.app/Contents/Resources/build-source.json").read_text())
    for name, digest in receipt["sourceFiles"].items():
        released = subprocess.check_output(["git", "show", BASELINE + ":" + name], cwd=baseline)
        if hashlib.sha256(released).hexdigest() != digest:
            raise SystemExit("Baseline build input differs from the released application: " + name)
    record.update(result="budget-failure" if result.returncode else "within-budget", scopes=scopes,
                  applicationSourceFiles=receipt["sourceFiles"], applicationMatchesRelease=True)
    output.write_text(json.dumps(record, indent=2) + "\n")
    print("Fixed v1.0 application baseline collected:", record["result"])


if __name__ == "__main__":
    main()
