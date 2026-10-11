#!/usr/bin/env python3
"""Keep launch samples and build identity without exporting hardware identifiers."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import plistlib
import statistics
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    args = parser.parse_args()
    reports = json.loads((args.run / "metrics.json").read_text())
    metrics = [metric for report in reports for run in report["testRuns"] for metric in run["metrics"]
               if metric["identifier"].endswith("ApplicationFirstFramePresentationResponsive.duration")]
    if len(metrics) != 1 or metrics[0]["unitOfMeasurement"] != "s":
        raise SystemExit("Expected one native responsive-launch duration metric, measured in seconds.")
    samples = metrics[0]["measurements"]
    if len(samples) != 30 or not all(math.isfinite(value) and value > 0 for value in samples):
        raise SystemExit("Expected 30 finite, positive launch samples.")
    receipt_bytes = (args.app / "Contents/Resources/build-source.json").read_bytes()
    receipt = json.loads(receipt_bytes)
    if receipt["configuration"] != "Release":
        raise SystemExit("Launch measurements must use a Release application.")
    saved_receipt = args.run / "build-source.json"
    if saved_receipt.exists() and saved_receipt.read_bytes() != receipt_bytes:
        raise SystemExit("The application changed after this benchmark; preserve the original build receipt.")
    saved_receipt.write_bytes(receipt_bytes)
    signature = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(args.app)],
                               capture_output=True, check=True)
    entitlements = plistlib.loads(signature.stdout) if signature.stdout.strip() else {}
    milliseconds = [value * 1000 for value in samples]
    report = {
        "format": 1,
        "recordedAt": datetime.now(timezone.utc).isoformat(),
        "metric": metrics[0]["identifier"],
        "conditions": "Fresh app process per sample; warm OS/filesystem cache; first XCTest warm-up iteration excluded; repository and window restoration disabled for this launch measurement.",
        "version": receipt["version"], "configuration": "Release", "xcodeBuild": receipt["xcodeBuild"],
        "xctestSigningPermissions": bool(entitlements.get("com.apple.security.get-task-allow")),
        "buildReceiptSHA256": hashlib.sha256(receipt_bytes).hexdigest(),
        "executableSHA256": hashlib.sha256((args.app / "Contents/MacOS/WeGit").read_bytes()).hexdigest(),
        "sampleCount": len(samples), "samplesMs": milliseconds,
        "medianMs": statistics.median(milliseconds),
        "p95Ms": sorted(milliseconds)[math.ceil(len(milliseconds) * 0.95) - 1],
        "maximumMs": max(milliseconds), "budgetP95Ms": 1000,
    }
    report["withinBudget"] = report["p95Ms"] < report["budgetP95Ms"]
    (args.run / "launch.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Launch: median {report['medianMs']:.2f} ms; P95 {report['p95Ms']:.2f} ms; {len(samples)} samples.")


if __name__ == "__main__":
    main()
