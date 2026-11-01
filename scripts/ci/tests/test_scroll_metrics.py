"""Gate tests use the actual xcresult export layout and identifiers, with synthetic values.

The retained VirtualMac export has zero animation values but positive ScrollGesture time,
CPU time, and physical memory. No retained capture supplies valid counted frames.
"""
import copy
import io
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_scroll_metrics
from native_performance import run_scope
from verify_scroll_metrics import (normalize_scroll_metrics, read_scroll_run,
                                   validate_observations, verify_saved_scroll_report)


BUNDLE = "com.willxue.wegit.performanceHarness"
SIGNPOST = "com.apple.dt.XCTMetric_OSSignpost-ScrollGesture"
TEST = "LargeReadingPerformanceTests/testDiskDiffFixedScrollTrajectory()"


def retained_schema(zero_frames=False):
    # Field spellings, units, outer test/run structure, and optional zero CPU counters
    # come from the retained EP2aAd metrics.json. Positive frames below are test data.
    duration = [0.5 + index / 100 for index in range(30)]
    fields = [
        (SIGNPOST + ".animation.hitches.total.duration", "ms", [0] * 30),
        (SIGNPOST + ".animation.frame.count", "frames", [0 if zero_frames else 30] * 30),
        (SIGNPOST + ".animation.hitch.number", "hitches", [0] * 30),
        (f"com.apple.dt.XCTMetric_Memory-{BUNDLE}.physical_peak", "kB", [197266.304] * 30),
        (f"com.apple.dt.XCTMetric_Memory-{BUNDLE}.physical", "kB", [-1327.104] * 30),
        (SIGNPOST + ".animation.hitch.time.ratio", "ms per s", [0] * 30),
        (f"com.apple.dt.XCTMetric_CPU-{BUNDLE}.cycles", "kC", [0] * 30),
        (f"com.apple.dt.XCTMetric_CPU-{BUNDLE}.time", "s", [9.32215565] * 30),
        (SIGNPOST + ".animation.frame.rate", "fps", [0 if zero_frames else 60] * 30),
        (SIGNPOST + ".duration", "s", duration),
        (f"com.apple.dt.XCTMetric_Memory-{BUNDLE}.physical_absolute", "kB", [194726.784] * 30),
        (f"com.apple.dt.XCTMetric_CPU-{BUNDLE}.instructions_retired", "kI", [0] * 30),
    ]
    configuration = {"configurationId": "1", "configurationName": "Test Scheme Action"}
    return [{"testIdentifier": TEST,
             "testIdentifierURL": "test://com.apple.xcode/WeGit/WeGitPerformanceTests/" + TEST.removesuffix("()"),
             "testRuns": [{"device": {"deviceId": "fixture-device", "deviceName": "My Mac"},
                           "testPlanConfiguration": configuration,
                           "metrics": [{"identifier": identifier, "unitOfMeasurement": unit,
                                        "baselineAverage": 0, "baselineName": "", "measurements": values}
                                       for identifier, unit, values in fields]}]}]


def successful_summary():
    return {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0,
            "expectedFailures": 0, "testFailures": [], "runtimeWarnings": [], "result": "Passed",
            "environmentDescription": "WeGitPerformance · Built with macOS 27.0.1",
            "devicesAndConfigurations": [{
                "device": {"deviceId": "fixture-device", "platform": "macOS", "architecture": "arm64",
                           "modelName": "VirtualMac2,1", "osVersion": "27.0.1", "osBuildNumber": "26A434"},
                "testPlanConfiguration": {"configurationId": "1", "configurationName": "Test Scheme Action"}}]}


def build_receipt():
    return {"format": 1, "configuration": "ReleasePerformance", "bundleIdentifier": BUNDLE,
            "version": "1.1.1", "buildVersion": "4", "architectures": ["arm64"],
            "xcodeBuild": "27A9275", "swiftOptimization": "-O", "swiftConditions": "WEGIT_PERFORMANCE",
            "sourceFiles": {"WeGit/App/WeGitApp.swift": "a" * 64}}


def fixture():
    return {"format": 1, "label": "large", "commits": 100_000, "trackedFiles": 100_000}


def metric(raw, suffix):
    if suffix == ".duration":
        return next(item for item in raw[0]["testRuns"][0]["metrics"] if item["identifier"] == SIGNPOST + suffix)
    return next(item for item in raw[0]["testRuns"][0]["metrics"] if item["identifier"].endswith(suffix))


def write_run(run, raw=None):
    run.mkdir(parents=True, exist_ok=True)
    files = {"metrics.json": retained_schema() if raw is None else raw,
             "summary.json": successful_summary(), "build-source.json": build_receipt(), "fixture.json": fixture()}
    for name, value in files.items():
        (run / name).write_text(json.dumps(value) + "\n")
    report = read_scroll_run(run)
    (run / "scroll.json").write_text(json.dumps(report, allow_nan=False) + "\n")
    return report


class ScrollMetricsTests(unittest.TestCase):
    def normalize(self, raw=None, summary=None, receipt=None, manifest=None):
        return normalize_scroll_metrics(retained_schema() if raw is None else raw,
                                        successful_summary() if summary is None else summary,
                                        build_receipt() if receipt is None else receipt,
                                        fixture() if manifest is None else manifest)

    def test_actual_native_export_schema_normalizes_30_observations_without_budget_claims(self):
        report = self.normalize()
        self.assertTrue(report["validation"]["nativeExecutionComplete"])
        self.assertTrue(report["validation"]["collectionComplete"])
        self.assertTrue(report["validation"]["frameDataValid"])
        self.assertEqual(report["validation"]["validSampleCount"], 30)
        self.assertEqual([sample["index"] for sample in report["samples"]], list(range(1, 31)))
        self.assertAlmostEqual(report["samples"][0]["peakPhysicalMemoryBytes"], 197266304)
        self.assertIsNone(report["samples"][0]["peakRSSBytes"])
        self.assertIsNone(report["samples"][0]["drawingCount"])
        self.assertIsNone(report["samples"][0]["frameIntervalsMs"])
        self.assertIsNone(report["validation"]["withinBudget"])
        self.assertIsNone(report["environment"]["displayRefreshRateHz"])
        self.assertIsNone(report["collector"]["selfCheck"])
        self.assertTrue(report["diagnosticOnly"])
        self.assertNotIn("deviceId", report["environment"])

    def test_all_zero_motion_metrics_are_unavailable_despite_xct_pass_and_positive_time(self):
        report = self.normalize(retained_schema(zero_frames=True))
        self.assertTrue(report["validation"]["nativeExecutionComplete"])
        self.assertFalse(report["validation"]["collectionComplete"])
        self.assertFalse(report["validation"]["frameDataValid"])
        self.assertEqual(report["collector"]["status"], "unavailable")
        self.assertEqual(len(report["samples"]), 30)
        self.assertEqual(report["validation"]["validSampleCount"], 0)
        self.assertGreater(report["samples"][0]["observationDurationSeconds"], 0)
        self.assertIsNone(report["metrics"]["frameRateFps"])
        self.assertIn("native NSScrollView", report["collector"]["nextRequiredControl"])

    def test_positive_exported_fps_cannot_rescue_missing_counted_frames(self):
        raw = retained_schema()
        metric(raw, "animation.frame.count")["measurements"] = [0] * 30
        metric(raw, "animation.frame.rate")["measurements"] = [95.39080404] * 30
        report = self.normalize(raw)
        self.assertFalse(report["validation"]["frameDataValid"])
        self.assertIsNone(report["metrics"]["frameRateFps"])
        self.assertEqual(report["samples"][0]["frameRateFps"], 95.39080404)

    def test_zero_hitches_are_valid_with_real_frame_and_time_measurements(self):
        report = self.normalize()
        self.assertEqual(report["samples"][0]["hitchCount"], 0)
        self.assertEqual(report["samples"][0]["hitchTimeRatioMsPerSecond"], 0)
        self.assertTrue(report["validation"]["frameDataValid"])
        raw = retained_schema()
        metric(raw, "animation.hitch.number")["measurements"][0] = 1
        metric(raw, "animation.hitches.total.duration")["measurements"][0] = 10
        metric(raw, "animation.hitch.time.ratio")["measurements"][0] = 20
        self.assertTrue(self.normalize(raw)["validation"]["frameDataValid"])
        metric(raw, "animation.hitch.time.ratio")["measurements"][0] = 0
        self.assertFalse(self.normalize(raw)["validation"]["frameDataValid"])

    def test_one_missing_iteration_is_not_filled_or_filtered(self):
        raw = retained_schema()
        for item in raw[0]["testRuns"][0]["metrics"]:
            item["measurements"].pop(21)
        report = self.normalize(raw)
        self.assertEqual(report["sampleCount"], 29)
        self.assertFalse(report["validation"]["collectionComplete"])
        self.assertFalse(report["validation"]["frameDataValid"])
        raw = retained_schema()
        metric(raw, "animation.frame.count")["measurements"].pop(21)
        report = self.normalize(raw)
        self.assertEqual(report["sampleCount"], 30)
        self.assertIsNone(report["samples"][-1]["frameCount"])
        self.assertFalse(report["validation"]["collectionComplete"])

    def test_extra_iteration_is_retained_and_rejected(self):
        raw = retained_schema()
        for item in raw[0]["testRuns"][0]["metrics"]:
            item["measurements"].append(item["measurements"][0])
        report = self.normalize(raw)
        self.assertEqual(report["sampleCount"], 31)
        self.assertFalse(report["validation"]["collectionComplete"])

    def test_missing_time_wrong_units_and_timer_video_fps_do_not_create_native_data(self):
        for suffix, change in [
            (".duration", {"measurements": []}),
            (".duration", {"unitOfMeasurement": "ms"}),
            ("animation.frame.rate", {"identifier": "video.frame.rate"}),
            ("animation.frame.rate", {"identifier": "timer.frame.rate"}),
        ]:
            with self.subTest(change=change):
                raw = retained_schema()
                metric(raw, suffix).update(change)
                report = self.normalize(raw)
                self.assertFalse(report["validation"]["collectionComplete"])
                self.assertFalse(report["validation"]["frameDataValid"])
        raw = retained_schema()
        metric(raw, ".duration")["measurements"][0] = 0
        self.assertFalse(self.normalize(raw)["validation"]["frameDataValid"])

    def test_nonfinite_values_and_boolean_measurements_are_invalid_and_json_safe(self):
        for suffix, value in [("animation.frame.rate", float("nan")),
                              (f"CPU-{BUNDLE}.time", float("inf")),
                              (f"CPU-{BUNDLE}.cycles", float("nan")),
                              ("animation.frame.count", True)]:
            with self.subTest(suffix=suffix):
                raw = retained_schema()
                metric(raw, suffix)["measurements"][6] = value
                report = self.normalize(raw)
                self.assertFalse(report["validation"]["collectionComplete"])
                json.dumps(report, allow_nan=False)

    def test_native_summary_build_fixture_and_environment_provenance_are_required(self):
        variants = [
            {"summary": successful_summary() | {"skippedTests": 1}},
            {"summary": successful_summary() | {"totalTestCount": 0}},
            {"receipt": build_receipt() | {"configuration": "Release"}},
            {"receipt": build_receipt() | {"sourceFiles": {}}},
            {"receipt": build_receipt() | {"swiftConditions": None}},
            {"manifest": fixture() | {"commits": 5000}},
            {"summary": successful_summary() | {"devicesAndConfigurations": []}},
        ]
        for variant in variants:
            with self.subTest(variant=variant):
                self.assertFalse(self.normalize(**variant)["validation"]["collectionComplete"])

    def test_multiple_native_runs_cannot_be_combined_to_reach_30(self):
        raw = retained_schema()
        first = raw[0]["testRuns"][0]
        for item in first["metrics"]:
            item["measurements"] = item["measurements"][:15]
        raw[0]["testRuns"].append(copy.deepcopy(first))
        report = self.normalize(raw)
        self.assertFalse(report["validation"]["collectionComplete"])
        self.assertEqual(report["sampleCount"], 0)

    def test_static_hidden_inactive_and_idle_allow_zero_drawing_with_null_frame_verdict(self):
        samples = [{"index": index, "observationDurationSeconds": 2, "drawingCount": 0,
                    "cpuSeconds": 0, "peakRSSBytes": 1000000, "frameCount": 0, "frameRateFps": 0}
                   for index in range(1, 31)]
        collector = {"kind": "native-draw-observation", "selfCheck": {
            "passed": True, "observationDurationSeconds": 1, "drawingCount": 2, "evidenceSHA256": "b" * 64}}
        for kind in ("static", "hidden", "inactive", "idle"):
            with self.subTest(kind=kind):
                result = validate_observations(samples, {"kind": kind, "expectsFrames": False}, collector)
                self.assertTrue(result["collectionComplete"])
                self.assertIsNone(result["frameDataValid"])
                self.assertIsNone(result["withinBudget"])
        for changed in (collector | {"selfCheck": None}, collector | {"kind": "timer"}, {}):
            self.assertFalse(validate_observations(samples, {"kind": "hidden", "expectsFrames": False}, changed)["collectionComplete"])
        samples[0]["observationDurationSeconds"] = 0
        self.assertFalse(validate_observations(samples, {"kind": "static", "expectsFrames": False}, collector)["collectionComplete"])
        self.assertFalse(validate_observations(samples, {"kind": "scrolling", "expectsFrames": False}, collector)["collectionComplete"])

    def test_saved_report_is_checked_against_original_measurements_and_hashes(self):
        with TemporaryDirectory() as directory:
            run = Path(directory)
            report = write_run(run)
            path = run / "scroll.json"
            self.assertTrue(verify_saved_scroll_report(path))
            for mutate in (lambda value: value["samples"][0].update(frameRateFps=120),
                           lambda value: value["fixture"].update(label="normal"),
                           lambda value: value["environment"].update(platform="iOS"),
                           lambda value: value["collector"].update(status="unavailable"),
                           lambda value: value["validation"].update(withinBudget=True)):
                changed = copy.deepcopy(report)
                mutate(changed)
                path.write_text(json.dumps(changed))
                self.assertFalse(verify_saved_scroll_report(path))
            report = write_run(run)
            raw = retained_schema(zero_frames=True)
            (run / "metrics.json").write_text(json.dumps(raw))
            self.assertFalse(verify_saved_scroll_report(path))
            report["scenario"] = {"kind": "static", "expectsFrames": False}
            path.write_text(json.dumps(report))
            self.assertFalse(verify_saved_scroll_report(path))

    def test_missing_raw_files_write_an_incomplete_report_before_cli_failure(self):
        with TemporaryDirectory() as directory:
            with patch.object(sys, "argv", ["verify_scroll_metrics", "--run", directory]), \
                    patch("sys.stdout", new=io.StringIO()):
                with self.assertRaisesRegex(SystemExit, "unavailable/incomplete"):
                    verify_scroll_metrics.main()
            report = json.loads((Path(directory) / "scroll.json").read_text())
            self.assertEqual(report["sampleCount"], 0)
            self.assertFalse(report["validation"]["nativeExecutionComplete"])
            self.assertFalse(report["validation"]["collectionComplete"])

    def test_scope_rechecks_frames_on_exit_zero_and_preserves_native_failures(self):
        for zero_frames, native_exit, expected_exit in [(False, 0, 0), (True, 0, 1), (True, 65, 65)]:
            with self.subTest(zero_frames=zero_frames, native_exit=native_exit), TemporaryDirectory() as directory:
                root = Path(directory)
                def collect(*args, **kwargs):
                    write_run(root / ".build/ui-benchmarks/large-scroll-fixture", retained_schema(zero_frames))
                    return SimpleNamespace(returncode=native_exit)
                with patch("native_performance.subprocess.run", side_effect=collect):
                    result = run_scope(root, ["scripts/benchmark-ui-large-scroll.sh"], "large-scroll", "scroll.json", "scroll")
                self.assertEqual(result["exitCode"], expected_exit)
                self.assertEqual(result["evidenceValid"], not zero_frames)
                self.assertFalse(result["budgetOnlyFailure"])


if __name__ == "__main__":
    unittest.main()
