import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


validator = load("reading_validator", "verify-reading-performance.py")
fixtures = load("reading_fixtures", "create-reading-performance-fixtures.py")


class ReadingPerformanceEvidenceTests(unittest.TestCase):
    def report(self):
        sample = dict(iteration=1, residentBytes=1_000_000, queryWrapperPID=11, queryChildPID=12,
                      comparisonWrapperPID=13, comparisonChildPID=14,
                      queryFirstScopes=validator.QUERY_SCOPES.copy(),
                      queryFirstResultCounts=dict(commits=25, trackedPaths=24, branches=24, tags=24,
                                                  stashes=1, worktrees=1, commands=1),
                      queryFixtureIdentitiesVerified=True,
                      queryProcessGroupExitVerified=True, comparisonProcessGroupExitVerified=True)
        sample.update({field: 10.0 for field, _ in validator.METRICS.values()})
        values = {metric: 10.0 for metric in validator.METRICS}
        values["residentBytes"] = sample["residentBytes"]
        workloads = []
        for name, commits, refs, paths, changed in fixtures.SCALES:
            workloads.append(dict(fixture=dict(name=name, commits=commits, references=refs, paths=paths,
                                  changedPaths=changed, preparedSeconds=1, objectCounts="packed", indexSHA256="a"*64),
                                  samples=[sample | {"iteration": i} for i in range(1, 31)], p95=values.copy(),
                                  maximumResidentBytes=sample["residentBytes"], violations=[], passed=True))
            workloads[-1]["fixture"].update(stashes=1, stashObjectID="b"*40)
            workloads[-1]["fixture"].update(base=f"{1:040x}", target=f"{200:040x}",
                expectedQueryCommits=[f"{i:040x}" for i in range(200, 0, -1)],
                expectedQueryReferences={"refs/heads/base": f"{1:040x}",
                    **{f"refs/heads/fixture-{i:05d}": f"{i + 2:040x}" for i in range(99)},
                    **{f"refs/tags/fixture-{i:05d}": f"{i + 2:040x}" for i in range(100)}})
        return dict(format=1, scope="comparison-and-unified-query-release-core", diagnosticOnly=False,
                    requiredSamples=30, executedSamplesPerWorkload=30, xctestExecuted=False, failure=None,
                    incompleteSamples=[], partialMeasurements={}, limits=dict(firstMilliseconds=2000, nextMilliseconds=1000,
                    cancelMilliseconds=500, ordinaryResidentBytes=256*1024*1024, largeResidentBytes=512*1024*1024),
                    cacheConditions="OS cache uncontrolled", cancellationConditions="live marker/group exit",
                    workloads=workloads, allPassed=True, diagnosticPassed=False)

    def test_original_scale_and_complete_raw_samples_are_required(self):
        report = self.report()
        self.assertTrue(validator.verify(report)["formalPassed"])
        for mutate in [lambda r: r["workloads"][0]["samples"].pop(),
                       lambda r: r["workloads"][1]["fixture"].update(commits=99999),
                       lambda r: r["workloads"][0]["samples"][1].update(iteration=1),
                       lambda r: r["limits"].update(firstMilliseconds=2500),
                       lambda r: r.update(diagnosticOnly=None),
                       lambda r: r.pop("diagnosticOnly"),
                       lambda r: r.update(requiredSamples=True),
                       lambda r: r["workloads"][0]["samples"][0].update(iteration=True),
                       lambda r: r["workloads"][0]["fixture"].update(preparedSeconds=float("nan")),
                       lambda r: r["workloads"][0]["fixture"].update(preparedSeconds=float("inf")),
                       lambda r: r.update(partialMeasurements={"queryFirstMilliseconds": 20}),
                       lambda r: r.update(failure="cancel failed")]:
            changed = copy.deepcopy(report); mutate(changed)
            with self.assertRaises(ValueError):
                validator.verify(changed)

    def test_tampered_percentile_invalid_values_and_rss_peak_cannot_pass(self):
        report = self.report()
        for mutate in [lambda r: r["workloads"][0]["p95"].update(queryFirst=0),
                       lambda r: r["workloads"][0]["samples"][0].update(queryFirstMilliseconds=float("nan")),
                       lambda r: r["workloads"][0]["samples"][0].update(residentBytes=300*1024*1024),
                       lambda r: r["workloads"][0]["samples"][0].update(queryChildPID=0),
                       lambda r: r["workloads"][0]["samples"][0].update(queryChildPID=True),
                       lambda r: r["workloads"][0]["samples"][0].update(queryChildPID=11),
                       lambda r: r["workloads"][0]["samples"][0].update(residentBytes=True),
                       lambda r: r["workloads"][0]["samples"][0].update(queryProcessGroupExitVerified=False),
                       lambda r: r.update(diagnosticOnly=True)]:
            changed = copy.deepcopy(report); mutate(changed)
            with self.assertRaises(ValueError):
                validator.verify(changed)

    def test_absent_stash_or_missing_query_category_cannot_pass(self):
        report = self.report()
        for mutate in [lambda r: r["workloads"][0]["fixture"].update(stashes=0),
                       lambda r: r["workloads"][0]["fixture"].update(stashObjectID="invalid"),
                       lambda r: r["workloads"][0]["fixture"].update(expectedQueryCommits=[]),
                       lambda r: r["workloads"][0]["fixture"].update(expectedQueryReferences={}),
                       lambda r: r["workloads"][0]["samples"][0]["queryFirstScopes"].remove("stashes"),
                       lambda r: r["workloads"][0]["samples"][0]["queryFirstResultCounts"].update(stashes=0),
                       lambda r: r["workloads"][0]["samples"][0]["queryFirstResultCounts"].update(stashes=True),
                       lambda r: r["workloads"][0]["samples"][0]["queryFirstResultCounts"].update(commits=26),
                       lambda r: r["workloads"][0]["samples"][0].update(queryFixtureIdentitiesVerified=False)]:
            changed = copy.deepcopy(report); mutate(changed)
            with self.assertRaises(ValueError):
                validator.verify(changed)

    def test_two_sample_development_control_never_claims_formal_acceptance(self):
        report = self.report()
        report.update(diagnosticOnly=True, executedSamplesPerWorkload=2, allPassed=False,
                      diagnosticPassed=True)
        for workload, (_, commits, refs, paths, changed) in zip(report["workloads"], fixtures.DIAGNOSTIC_SCALES):
            workload["samples"] = workload["samples"][:2]
            workload["fixture"].update(commits=commits, references=refs, paths=paths, changedPaths=changed)
        self.assertFalse(validator.verify(report)["formalPassed"])
        report["allPassed"] = True
        with self.assertRaisesRegex(ValueError, "promoted"):
            validator.verify(report)

    def test_source_changes_and_outside_input_paths_are_refused(self):
        report = self.report()
        with tempfile.TemporaryDirectory(prefix="WeGitReadingEvidence-") as folder:
            root = Path(folder); (root/"source.swift").write_text("actual source")
            report["inputReceipt"] = {"inputFiles": {"source.swift": "a"*64}}
            with self.assertRaisesRegex(ValueError, "source input changed"):
                validator.verify(report, root)
            report["inputReceipt"]["inputFiles"] = {"../outside": "a"*64}
            with self.assertRaisesRegex(ValueError, "escaped"):
                validator.verify(report, root)
            outside = root/"outside"; outside.write_bytes(b"outside bytes")
            (root/"symlink.swift").symlink_to(outside)
            report["inputReceipt"]["inputFiles"] = {"symlink.swift": hashlib.sha256(outside.read_bytes()).hexdigest()}
            with self.assertRaisesRegex(ValueError, "symbolic link"):
                validator.verify(report, root)

    def test_original_fixture_manifest_and_compiled_artifact_bytes_are_bound(self):
        report = self.report()
        with tempfile.TemporaryDirectory(prefix="WeGitReadingArtifact-") as folder:
            root = Path(folder)
            manifest = root/"fixtures.json"
            manifest.write_text(json.dumps(dict(complete=True, diagnosticOnly=False,
                                workloads=[w["fixture"] for w in report["workloads"]])))
            digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
            report["fixturesSHA256"] = digest(manifest)
            for name in ["checks", "core.o", "Resources/strings"]:
                path = root/name; path.parent.mkdir(exist_ok=True); path.write_bytes(name.encode())
            report["inputReceipt"] = dict(format=1, optimization="swiftc -O; Release WeGitCore",
                toolchain=dict(swift="Swift", xcode="Xcode", architecture="arm64", runnerImage="image"),
                coreObjectPath="core.o", coreObjectSHA256=digest(root/"core.o"),
                checkerSHA256=digest(root/"checks"), resourceFiles={"Resources/strings": digest(root/"Resources/strings")})
            self.assertTrue(validator.verify(report, fixture_path=manifest, artifact_root=root)["formalPassed"])
            (root/"linked-core.o").symlink_to(root/"core.o")
            report["inputReceipt"]["coreObjectPath"] = "linked-core.o"
            with self.assertRaisesRegex(ValueError, "symbolic link"):
                validator.verify(report, fixture_path=manifest, artifact_root=root)
            report["inputReceipt"]["coreObjectPath"] = "core.o"
            (root/"checks").write_bytes(b"changed executable")
            with self.assertRaisesRegex(ValueError, "artifact changed"):
                validator.verify(report, fixture_path=manifest, artifact_root=root)
            manifest.write_text(manifest.read_text()+"\n")
            with self.assertRaisesRegex(ValueError, "manifest bytes changed"):
                validator.verify(report, fixture_path=manifest)

    def test_private_fixture_has_real_ancestry_varied_refs_index_and_changed_paths(self):
        with tempfile.TemporaryDirectory(prefix="WeGitReadingFixtureTest-") as folder:
            destination = Path(folder)/"fixture"
            result = fixtures.create(destination, "development", 250, 32, 512, 16, "/usr/bin/git")
            self.assertEqual((result["commits"], result["references"], result["paths"], result["changedPaths"]),
                             (250, 32, 512, 16))
            self.assertNotEqual(result["base"], result["target"])
            self.assertEqual(result["stashes"], 1)
            self.assertRegex(result["stashObjectID"], "^[a-f0-9]{40}$")
            self.assertEqual(len(result["expectedQueryCommits"]), 200)
            self.assertEqual(result["expectedQueryCommits"][0], result["target"])
            self.assertEqual(len(result["expectedQueryReferences"]), 32)
            self.assertEqual(result["expectedQueryReferences"]["refs/heads/base"], result["base"])
            self.assertEqual(result["expectedQueryReferences"]["refs/heads/main"], result["target"])
            self.assertFalse((destination/"paths").exists())
            original = (destination/".git/index").read_bytes()
            with self.assertRaises(FileExistsError):
                fixtures.create(destination, "development", 250, 32, 512, 16, "/usr/bin/git")
            self.assertEqual((destination/".git/index").read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
