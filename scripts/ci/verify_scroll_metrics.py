#!/usr/bin/env python3
"""Retain native scroll observations; missing frames are unavailable evidence, not a pass."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import statistics


EXPECTED_SAMPLES = 30
SCROLL_TEST = "LargeReadingPerformanceTests/testDiskDiffFixedScrollTrajectory()"
SIGNPOST = "com.apple.dt.XCTMetric_OSSignpost-ScrollGesture"
STATIC_SCENARIOS = {"static", "hidden", "inactive", "idle"}
FRAME_FIELDS = {
    "frameCount": ("animation.frame.count", "frames"),
    "frameRateFps": ("animation.frame.rate", "fps"),
    "hitchCount": ("animation.hitch.number", "hitches"),
    "hitchDurationMs": ("animation.hitches.total.duration", "ms"),
    "hitchTimeRatioMsPerSecond": ("animation.hitch.time.ratio", "ms per s"),
}
NEXT_CONTROL = (
    "Run the same trajectory against a private native NSScrollView control on the hosted Mac, "
    "and require nonzero counted frames and signpost duration. If that control also lacks frames, "
    "retain a native animation/frame trace with a collector self-check before defining a frame budget."
)


def finite_scalar(value):
    try:
        return type(value) in (int, float) and math.isfinite(value)
    except (OverflowError, ValueError):
        return False


def finite_number(value, *, positive=False, integer=False):
    return (finite_scalar(value) and (value > 0 if positive else value >= 0)
            and (not integer or int(value) == value))


def sha256(value):
    return hashlib.sha256(value).hexdigest()


def safe_value(value):
    """Keep non-finite input auditable while writing standards-compliant JSON."""
    if isinstance(value, float) and not math.isfinite(value):
        return str(value)
    if isinstance(value, dict):
        return {key: safe_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [safe_value(item) for item in value]
    return value


def execution_complete(summary):
    if not isinstance(summary, dict):
        return False
    counts = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
    return (all(type(summary.get(key)) is int and summary[key] == value for key, value in counts.items())
            and summary.get("expectedFailures", 0) == 0
            and summary.get("testFailures") == []
            and summary.get("result", "Passed") == "Passed")


def validate_observations(samples, scenario, collector):
    """Validate motion or explicit draw controls without deriving FPS from a timer/video."""
    errors = []
    collector = collector if isinstance(collector, dict) else {}
    expects_frames = scenario.get("expectsFrames") if isinstance(scenario, dict) else None
    kind = scenario.get("kind") if isinstance(scenario, dict) else None
    if type(expects_frames) is not bool or (expects_frames and kind != "scrolling") or (
            expects_frames is False and kind not in STATIC_SCENARIOS):
        errors.append("Scenario must explicitly declare scrolling or a static/hidden/inactive/idle control.")
    if not isinstance(samples, list):
        samples = []
    if len(samples) != EXPECTED_SAMPLES:
        errors.append(f"Expected exactly {EXPECTED_SAMPLES} observations; received {len(samples)}.")
    if expects_frames is False:
        check = collector.get("selfCheck", {})
        check = check if isinstance(check, dict) else {}
        if (collector.get("kind") != "native-draw-observation"
                or check.get("passed") is not True
                or not finite_number(check.get("observationDurationSeconds"), positive=True)
                or not finite_number(check.get("drawingCount"), positive=True, integer=True)
                or not re.fullmatch(r"[0-9a-f]{64}", str(check.get("evidenceSHA256", "")))):
            errors.append("Static controls require an auditable positive native drawing collector self-check.")
    invalid = []
    frames_valid = len(samples) == EXPECTED_SAMPLES and expects_frames is True
    for index, sample in enumerate(samples, 1):
        problems = []
        if not isinstance(sample, dict):
            invalid.append({"index": index, "errors": ["Observation must be an object."]})
            frames_valid = False
            continue
        if type(sample.get("index")) is not int or sample["index"] != index:
            problems.append("Observation indices must be consecutive and preserve the export order.")
        duration_valid = finite_number(sample.get("observationDurationSeconds"), positive=True)
        if not duration_valid:
            problems.append("observationDurationSeconds must be finite and positive.")
        if not finite_number(sample.get("cpuSeconds")):
            problems.append("cpuSeconds must be finite and nonnegative.")
        memory_field = "peakPhysicalMemoryBytes" if expects_frames else "peakRSSBytes"
        if not finite_number(sample.get(memory_field), positive=True):
            problems.append(f"{memory_field} must be finite and positive.")
        if expects_frames is True:
            frame_problems = []
            for field in FRAME_FIELDS:
                if not finite_number(sample.get(field), positive=field in {"frameCount", "frameRateFps"},
                                     integer=field in {"frameCount", "hitchCount"}):
                    frame_problems.append(f"{field} has no valid native measurement.")
            if not duration_valid or frame_problems:
                frames_valid = False
            problems.extend(frame_problems)
            # Zero hitches are valid only when the frame/time observations above exist.
            if not frame_problems and duration_valid:
                total = sample["hitchDurationMs"]
                ratio = sample["hitchTimeRatioMsPerSecond"]
                if not math.isclose(ratio, total / sample["observationDurationSeconds"], rel_tol=1e-5, abs_tol=1e-5):
                    problems.append("Hitch time ratio does not match the measured hitch duration and signpost time.")
                    frames_valid = False
                if (sample["hitchCount"] == 0) != (total == 0 and ratio == 0):
                    problems.append("Hitch count and hitch duration disagree.")
                    frames_valid = False
        elif expects_frames is False and not finite_number(sample.get("drawingCount"), integer=True):
            problems.append("drawingCount must be finite, nonnegative, and integral.")
        if problems:
            invalid.append({"index": index, "errors": problems})
    if invalid:
        errors.append(f"{len(invalid)} observation(s) are invalid; no samples were dropped or replaced.")
    return {"collectionComplete": not errors,
            "frameDataValid": frames_valid if expects_frames is True else None,
            "withinBudget": None, "validSampleCount": len(samples) - len(invalid),
            "errors": errors, "invalidSamples": invalid}


def metric_stats(samples, field, unit):
    values = [sample.get(field) for sample in samples]
    if len(values) != EXPECTED_SAMPLES or not all(finite_number(value) for value in values):
        return None
    return {"count": len(values), "unit": unit, "median": statistics.median(values),
            "p95": sorted(values)[28], "minimum": min(values), "maximum": max(values),
            "budget": None, "passed": None}


def normalize_scroll_metrics(raw, summary, receipt, fixture, hashes=None, read_errors=None):
    """Parse the retained xcresulttool testIdentifier/testRuns/metrics export schema."""
    errors = list(read_errors or [])
    receipt = receipt if isinstance(receipt, dict) else {}
    fixture = fixture if isinstance(fixture, dict) else {}
    summary = summary if isinstance(summary, dict) else {}
    conditions = receipt.get("swiftConditions")
    if (receipt.get("configuration") != "ReleasePerformance" or receipt.get("swiftOptimization") != "-O"
            or not isinstance(conditions, str) or "WEGIT_PERFORMANCE" not in conditions.split()
            or not isinstance(receipt.get("sourceFiles"), dict) or not receipt["sourceFiles"]
            or not all(re.fullmatch(r"[0-9a-f]{64}", str(value)) for value in receipt["sourceFiles"].values())):
        errors.append("A ReleasePerformance build receipt with application input hashes is required.")
    if fixture.get("label") != "large" or type(fixture.get("commits")) is not int or fixture["commits"] != 100_000:
        errors.append("The scroll test requires its retained large, 100000-commit fixture manifest.")
    complete_execution = execution_complete(summary)
    if not complete_execution:
        errors.append("Native execution must be exactly 1 passed test, 0 failures, and 0 skips.")
    tests = [test for test in raw if isinstance(test, dict) and test.get("testIdentifier") == SCROLL_TEST] if isinstance(raw, list) else []
    runs = tests[0].get("testRuns", []) if len(tests) == 1 else []
    if len(tests) != 1 or len(raw) != 1 or not isinstance(runs, list) or len(runs) != 1 or not isinstance(runs[0], dict):
        errors.append("Expected exactly one fixed-scroll test and one native test run; runs cannot be combined.")
        run = {}
    else:
        run = runs[0]
    metrics = run.get("metrics", [])
    metrics = metrics if isinstance(metrics, list) else []
    identifiers = [metric.get("identifier") for metric in metrics if isinstance(metric, dict)]
    if any(not isinstance(identifier, str) for identifier in identifiers) or len(set(identifiers)) != len(identifiers):
        errors.append("Native metric identifiers must be unique strings.")
    for metric in metrics:
        values = metric.get("measurements") if isinstance(metric, dict) else None
        if not isinstance(values, list) or len(values) != EXPECTED_SAMPLES:
            errors.append("Every exported metric must retain exactly 30 measurements.")
        elif any(not finite_scalar(value) for value in values):
            errors.append("Exported metric measurements must be finite numbers, including optional CPU/memory counters.")
    bundle = receipt.get("bundleIdentifier", "")
    expected = {"observationDurationSeconds": (SIGNPOST + ".duration", "s")}
    expected.update({field: (SIGNPOST + "." + suffix, unit) for field, (suffix, unit) in FRAME_FIELDS.items()})
    expected.update({"cpuSeconds": (f"com.apple.dt.XCTMetric_CPU-{bundle}.time", "s"),
                     "peakPhysicalMemoryBytes": (f"com.apple.dt.XCTMetric_Memory-{bundle}.physical_peak", "kB")})
    sources, series = {}, {}
    for field, (identifier, unit) in expected.items():
        matches = [metric for metric in metrics if isinstance(metric, dict) and metric.get("identifier") == identifier]
        if len(matches) != 1:
            errors.append(f"Expected exactly one native {field} metric ({identifier}).")
            series[field] = []
            continue
        metric = matches[0]
        sources[field] = {"identifier": identifier, "unitOfMeasurement": metric.get("unitOfMeasurement")}
        values = metric.get("measurements")
        if metric.get("unitOfMeasurement") != unit or not isinstance(values, list):
            errors.append(f"{field} requires native measurements in {unit}.")
            series[field] = []
            continue
        series[field] = values
        if len(values) != EXPECTED_SAMPLES:
            errors.append(f"{field}: expected {EXPECTED_SAMPLES} samples, received {len(values)}.")
    samples = []
    for index in range(max((len(values) for values in series.values()), default=0)):
        sample = {"index": index + 1, "drawingCount": None, "peakRSSBytes": None, "frameIntervalsMs": None}
        for field, values in series.items():
            value = values[index] if index < len(values) else None
            # XCT exports decimal kB. Retain physical memory separately from process RSS.
            if field == "peakPhysicalMemoryBytes" and type(value) in (int, float):
                value *= 1000
            sample[field] = safe_value(value)
        samples.append(sample)
    scenario = {"kind": "scrolling", "expectsFrames": True,
                "observationBoundary": "System ScrollGesture signpost duration in each XCTest measure iteration.",
                "cpuMemoryBoundary": "Whole XCTest measure block, including time between scroll commands.",
                "trajectory": "Four -400 and four +400 vertical scroll commands per iteration."}
    collector = {"kind": "XCTOSSignpostMetric.scrollingAndDecelerationMetric", "selfCheck": None,
                 "frameTiming": "Aggregate native frame rate only; individual frame intervals are not exported.",
                 "nextRequiredControl": NEXT_CONTROL}
    devices = summary.get("devicesAndConfigurations", [])
    device_configuration = devices[0] if isinstance(devices, list) and len(devices) == 1 and isinstance(devices[0], dict) else {}
    device = device_configuration.get("device", {})
    device = device if isinstance(device, dict) else {}
    exported_device = run.get("device", {})
    exported_device = exported_device if isinstance(exported_device, dict) else {}
    if (device.get("platform") != "macOS" or device.get("architecture") != "arm64"
            or not device.get("deviceId") or device.get("deviceId") != exported_device.get("deviceId")
            or not run.get("testPlanConfiguration")
            or run.get("testPlanConfiguration") != device_configuration.get("testPlanConfiguration")):
        errors.append("The exported test run and native macOS/arm64 environment must match the summary.")
    validation = validate_observations(samples, scenario, collector)
    validation["nativeExecutionComplete"] = complete_execution
    validation["errors"] = errors + validation["errors"]
    validation["collectionComplete"] = not validation["errors"]
    if errors:
        validation["frameDataValid"] = False
    zero_frames = bool(series.get("frameCount")) and all(value == 0 for value in series["frameCount"])
    collector["status"] = "available" if validation["frameDataValid"] else "unavailable" if zero_frames else "incomplete"
    descriptive = {"observationDurationSeconds": metric_stats(samples, "observationDurationSeconds", "s"),
                   "cpuSeconds": metric_stats(samples, "cpuSeconds", "s"),
                   "peakPhysicalMemoryBytes": metric_stats(samples, "peakPhysicalMemoryBytes", "bytes")}
    for field, (_, unit) in FRAME_FIELDS.items():
        descriptive[field] = metric_stats(samples, field, unit) if validation["frameDataValid"] else None
    environment = {key: device.get(key) for key in ("platform", "architecture", "modelName", "osVersion", "osBuildNumber")}
    environment.update({"xcodeBuild": receipt.get("xcodeBuild"), "description": summary.get("environmentDescription"),
                        "testPlanConfiguration": run.get("testPlanConfiguration"), "displayRefreshRateHz": None})
    hashes = hashes or {}
    return safe_value({"schemaVersion": 1, "diagnosticOnly": True,
                       "expectedSampleCount": EXPECTED_SAMPLES, "sampleCount": len(samples),
                       "source": {"testIdentifier": SCROLL_TEST, **hashes,
                                  "application": {key: receipt.get(key) for key in ("version", "buildVersion", "bundleIdentifier", "configuration", "xcodeBuild")}},
                       "environment": environment, "fixture": fixture,
                       "nativeTestSummary": {key: summary.get(key) for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures", "result", "testFailures", "runtimeWarnings")},
                       "scenario": scenario, "collector": collector, "samples": samples,
                       "metricSources": sources, "metrics": descriptive, "validation": validation})


def read_scroll_run(run):
    values, hashes, errors = {}, {}, []
    files = {"raw": ("metrics.json", "metricExportSHA256"),
             "summary": ("summary.json", "nativeSummarySHA256"),
             "receipt": ("build-source.json", "buildReceiptSHA256"),
             "fixture": ("fixture.json", "fixtureManifestSHA256")}
    for key, (name, hash_name) in files.items():
        try:
            data = (run / name).read_bytes()
            hashes[hash_name] = sha256(data)
            values[key] = json.loads(data)
        except (OSError, ValueError) as error:
            errors.append(f"{name} is unavailable or invalid ({type(error).__name__}).")
            values[key] = [] if key == "raw" else {}
    return normalize_scroll_metrics(**values, hashes=hashes, read_errors=errors)


def verify_saved_scroll_report(path):
    """Recompute from retained raw data even when the benchmark process exits successfully."""
    try:
        saved = json.loads(path.read_text())
        recomputed = read_scroll_run(path.parent)
        if (not isinstance(saved, dict)
                or json.dumps(saved, sort_keys=True, allow_nan=False) != json.dumps(recomputed, sort_keys=True, allow_nan=False)):
            return False
        return (saved.get("diagnosticOnly") is True
                and recomputed["validation"]["collectionComplete"] is True
                and recomputed["validation"]["frameDataValid"] is True
                and recomputed["validation"]["withinBudget"] is None)
    except (OSError, ValueError, TypeError, KeyError, OverflowError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    args = parser.parse_args()
    report = read_scroll_run(args.run)
    (args.run / "scroll.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    validation = report["validation"]
    print(f"Scroll: execution={validation['nativeExecutionComplete']}; "
          f"valid samples={validation['validSampleCount']}/{EXPECTED_SAMPLES}; "
          f"frames={validation['frameDataValid']}; budget={validation['withinBudget']}.", flush=True)
    if not validation["collectionComplete"] or validation["frameDataValid"] is not True:
        raise SystemExit("Scroll evidence is unavailable/incomplete; retained all observations and the required native control.")


if __name__ == "__main__":
    main()
