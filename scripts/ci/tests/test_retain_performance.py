from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from retain_performance import compact, measured_metrics


class RetentionTests(unittest.TestCase):
    def test_metrics_keep_all_measurements_without_device_identifiers(self):
        raw = {"deviceId": "private-device", "testRuns": [{"metrics": [{"identifier": "duration", "unitOfMeasurement": "ms", "measurements": [1, 9, 1000]}]}]}
        self.assertEqual(measured_metrics(raw), [{"identifier": "duration", "unitOfMeasurement": "ms", "measurements": [1, 9, 1000]}])

    def test_failures_and_exact_counts_survive_summary_compaction(self):
        raw = {"deviceId": "private-device", "totalTestCount": 1, "passedTests": 0, "failedTests": 1, "skippedTests": 0, "testFailures": [{"failureText": "P95 exceeded"}], "runtimeWarnings": []}
        result = compact("summary.json", raw)
        self.assertNotIn("deviceId", result)
        self.assertEqual(result["failedTests"], 1)
        self.assertEqual(result["testFailures"], raw["testFailures"])
