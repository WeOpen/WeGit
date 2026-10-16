#!/usr/bin/env python3
"""Preserve samples and provenance even when a performance budget fails."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    arguments = parser.parse_args()
    exported = arguments.run / "attachments"
    manifest = json.loads((exported / "manifest.json").read_text())
    files = [exported / item["exportedFileName"]
             for test in manifest for item in test.get("attachments", [])
             if item.get("suggestedHumanReadableName", "").startswith("workbench-samples")]
    if len(files) != 1:
        raise SystemExit("Expected one workbench sample attachment; retain xcresult for diagnosis.")
    samples = json.loads(files[0].read_text())
    fixture = json.loads((arguments.fixture / ".git/wegit-benchmark.json").read_text())
    receipt = json.loads(arguments.receipt.read_text())
    root = Path(__file__).resolve().parent.parent
    test_sources = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in sorted((root / "WeGitPerformanceTests").rglob("*.swift"))}
    budgets = {"shell": 500, "status": 300, "diff": 150, "history": 300, "external-update": 1000}
    metrics = {}
    for name in sorted({sample["name"] for sample in samples}):
        values = sorted(sample["milliseconds"] for sample in samples if sample["name"] == name)
        p95 = values[math.ceil(len(values) * .95) - 1]
        budget = budgets.get(name) if fixture["label"] == "normal" else None
        metrics[name] = {"count": len(values), "medianMs": statistics.median(values), "p95Ms": p95,
                         "budgetMs": budget,
                         "passed": p95 < budget if budget is not None and len(values) == 30 else None}
    source_digest = hashlib.sha256(json.dumps(receipt["sourceFiles"], sort_keys=True).encode()).hexdigest()
    report = {
        "format": 1, "sourceSHA256": source_digest, "buildReceipt": receipt, "testSources": test_sources,
        "hardwareModel": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
        "memoryBytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
        "system": subprocess.check_output(["sw_vers"], text=True).strip(),
        "toolchain": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
        "git": subprocess.check_output(["/usr/bin/git", "--version"], text=True).strip(),
        "fixture": fixture,
        "conditions": "Serial fresh application processes; filesystem caches warm; fixture copied once into runner-private directory; update-index --refresh before timing; no concurrent builds.",
        "boundaries": "Shell/status/history end after native view drawing; diff ends after native code drawing; external-update starts before atomic write and ends after authoritative snapshot drawing.",
        "metrics": metrics, "peakRSSBytes": max(sample["peakRSSBytes"] for sample in samples),
        "samples": samples,
    }
    (arguments.run / "workbench.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"metrics": metrics, "peakRSSBytes": report["peakRSSBytes"]}, indent=2))


if __name__ == "__main__":
    main()
