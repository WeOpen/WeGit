#!/usr/bin/env python3
"""Keep compact, verifiable measurements in logs before an artifact service request."""
import argparse
import hashlib
import json
from pathlib import Path


def measured_metrics(value):
    found = []
    if isinstance(value, dict):
        if "identifier" in value and "measurements" in value:
            found.append({key: value[key] for key in ("identifier", "unitOfMeasurement", "measurements") if key in value})
        else:
            for child in value.values():
                found.extend(measured_metrics(child))
    elif isinstance(value, list):
        for child in value:
            found.extend(measured_metrics(child))
    return found


def compact(name, value):
    if name == "workbench.json":
        receipt = value["buildReceipt"]
        result = {key: value[key] for key in ("fixture", "metrics", "hardwareModel", "memoryBytes", "system", "toolchain", "conditions", "boundaries", "peakRSSBytes", "testSources")}
        result["application"] = {key: receipt.get(key) for key in ("version", "buildVersion", "bundleIdentifier", "configuration", "xcodeBuild", "swiftOptimization", "swiftConditions")}
        result["sourceSHA256"] = hashlib.sha256(json.dumps(receipt["sourceFiles"], sort_keys=True).encode()).hexdigest()
        result["rawMeasurementsMs"] = {key: [sample["milliseconds"] for sample in value["samples"] if sample["name"] == key] for key in value["metrics"]}
        result["rawPeakRSSBytes"] = [sample["peakRSSBytes"] for sample in value["samples"]]
        return result
    if name == "metrics.json":
        return {"metrics": measured_metrics(value)}
    if name == "summary.json":
        return {key: value.get(key) for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "testFailures", "runtimeWarnings")}
    if name == "baseline-comparison.json":
        return {key: item for key, item in value.items() if key != "applicationSourceFiles"}
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--samples", type=int, choices=(1, 30), required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    destination = root / ".build/ci/performance/essential"
    destination.mkdir(parents=True, exist_ok=True)
    names = {"workbench.json", "launch.json", "metrics.json", "summary.json"}
    paths = list((root / ".build/ui-benchmarks").glob("*/*.json"))
    paths += list((root / ".build/performance-baseline/.build/ui-benchmarks").glob("*/*.json"))
    paths = [path for path in paths if path.name in names]
    paths += [root / ".build/benchmarks/native" / name for name in ("normal.json", "large.json")]
    paths += [root / ".build/ci/performance" / name for name in ("scope-results.json", "baseline-comparison.json")]
    paths += [root / ".build/performance-baseline/.build/ci/performance/scope-results.json"]
    records, errors = [], []
    for path in paths:
        if not path.is_file():
            continue
        relative = str(path.relative_to(root))
        try:
            raw = path.read_bytes()
            report = {"path": relative, "originalSHA256": hashlib.sha256(raw).hexdigest(), "data": compact(path.name, json.loads(raw))}
            (destination / (relative.replace("/", "__") + ".json")).write_text(json.dumps(report, indent=2) + "\n")
            print("WEGIT_PERFORMANCE_BEGIN " + relative, flush=True)
            print(json.dumps(report, indent=2), flush=True)
            print("WEGIT_PERFORMANCE_END " + relative, flush=True)
            records.append(relative)
        except (ValueError, KeyError, TypeError) as error:
            errors.append({"path": relative, "error": type(error).__name__})
    index = {"expectedSamples": args.samples, "records": records, "errors": errors,
             "acceptance": "Measurements preserve their original failures; retention is not a pass."}
    (destination / "index.json").write_text(json.dumps(index, indent=2) + "\n")
    if errors or not records:
        raise SystemExit("Performance evidence is incomplete; retained available diagnostics.")


if __name__ == "__main__":
    main()
