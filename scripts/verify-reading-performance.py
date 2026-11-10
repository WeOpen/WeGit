#!/usr/bin/env python3
"""Independently validate complete Release comparison/query sample evidence."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re

METRICS = {"comparisonFirst": ("comparisonFirstMilliseconds", 2000),
           "comparisonNext": ("comparisonNextMilliseconds", 1000),
           "queryFirst": ("queryFirstMilliseconds", 2000), "queryNext": ("queryNextMilliseconds", 1000),
           "switchFirst": ("switchFirstMilliseconds", 2000),
           "queryCancel": ("queryCancelMilliseconds", 500),
           "comparisonCancel": ("comparisonCancelMilliseconds", 500)}
QUERY_SCOPES = ["branches", "commands", "commits", "stashes", "tags", "trackedPaths", "worktrees"]
OBJECT_ID = re.compile(r"[a-f0-9]{40}|[a-f0-9]{64}")


def require(value, message):
    if not value:
        raise ValueError(message)


def bound_file(root, name):
    require(isinstance(name, str) and bool(name), "Missing bound file path")
    path = Path(name)
    require(not path.is_absolute() and ".." not in path.parts and bool(path.parts), "Input escaped root")
    require(not root.is_symlink(), "Binding root is a symbolic link")
    root = root.resolve(strict=True)
    current = root
    for component in path.parts:
        current = current/component
        require(not current.is_symlink(), "Bound file uses a symbolic link")
    require(current.is_file() and current.resolve(strict=True).is_relative_to(root), "Bound file escaped root")
    return current


def verify(report, source_root=None, fixture_path=None, artifact_root=None):
    require(type(report.get("format")) is int and report["format"] == 1
            and report.get("scope") == "comparison-and-unified-query-release-core", "Wrong reading evidence format")
    require(type(report.get("diagnosticOnly")) is bool, "Missing exact diagnostic marker")
    diagnostic = report["diagnosticOnly"]
    expected = 2 if diagnostic else 30
    require(type(report.get("requiredSamples")) is int and report["requiredSamples"] == 30
            and type(report.get("executedSamplesPerWorkload")) is int
            and report["executedSamplesPerWorkload"] == expected, "Incomplete sample contract")
    require(report.get("xctestExecuted") is False and report.get("failure") is None
            and report.get("incompleteSamples") == [] and report.get("partialMeasurements") == {},
            "Failed or incomplete execution")
    require(report.get("limits") == dict(firstMilliseconds=2000, nextMilliseconds=1000,
            cancelMilliseconds=500, ordinaryResidentBytes=256*1024*1024, largeResidentBytes=512*1024*1024), "Original budgets changed")
    require(report.get("cacheConditions") and report.get("cancellationConditions"), "Missing cache/cancellation conditions")
    workloads = report.get("workloads", [])
    require([w["fixture"]["name"] for w in workloads] == ["ordinary", "large"], "Missing workload")
    proof = {}
    for workload in workloads:
        fixture = workload["fixture"]; name = fixture["name"]; samples = workload["samples"]
        require(len(samples) == expected and all(type(s["iteration"]) is int for s in samples)
                and sorted(s["iteration"] for s in samples) == list(range(1, expected+1)), "Sample count or iteration changed")
        require(all(type(fixture.get(key)) is int and fixture[key] > 0
                    for key in ["commits", "references", "paths", "changedPaths"]), "Invalid fixture scale")
        require(type(fixture.get("stashes")) is int and fixture["stashes"] == 1
                and isinstance(fixture.get("stashObjectID"), str)
                and OBJECT_ID.fullmatch(fixture["stashObjectID"]),
                "Missing measured stash fixture")
        commits = fixture.get("expectedQueryCommits", [])
        references = fixture.get("expectedQueryReferences", {})
        require(isinstance(commits, list) and len(commits) == min(200, fixture["commits"])
                and all(isinstance(oid, str) and OBJECT_ID.fullmatch(oid) for oid in commits)
                and len(set(commits)) == len(commits) and commits[0] == fixture.get("target")
                and isinstance(references, dict) and 2 <= len(references) <= 200
                and all(isinstance(ref, str) and ref.startswith(("refs/heads/", "refs/tags/"))
                        and isinstance(oid, str) and OBJECT_ID.fullmatch(oid)
                        for ref, oid in references.items())
                and references.get("refs/heads/base") == fixture.get("base"),
                "Missing bounded exact query identity oracle")
        if not diagnostic:
            require((fixture["commits"], fixture["references"], fixture["paths"], fixture["changedPaths"]) ==
                    (10_000 if name == "ordinary" else 100_000, 10_000, 100_000, 100 if name == "ordinary" else 1_000), "Formal scale changed")
        preparation = fixture.get("preparedSeconds")
        require(isinstance(preparation, (int, float)) and not isinstance(preparation, bool)
                and math.isfinite(preparation) and preparation >= 0 and fixture["objectCounts"]
                and re.fullmatch(r"[a-f0-9]{64}", fixture["indexSHA256"]), "Missing first preparation evidence")
        recomputed = {}; violations = []
        for metric, (field, limit) in METRICS.items():
            values = [sample[field] for sample in samples]
            require(all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v >= 0 for v in values), "Invalid raw timing")
            recomputed[metric] = sorted(values)[math.ceil(.95*len(values))-1]
            if recomputed[metric] >= limit:
                violations.append(metric)
        memory = [sample["residentBytes"] for sample in samples]
        require(all(type(value) is int and value > 0 for value in memory), "Missing RSS")
        recomputed["residentBytes"] = sorted(memory)[math.ceil(.95*len(memory))-1]
        maximum = max(memory); limit = (256 if name == "ordinary" else 512)*1024*1024
        if maximum > limit:
            violations.append("residentBytes")
        require(recomputed == workload["p95"] and type(workload["maximumResidentBytes"]) is int
                and maximum == workload["maximumResidentBytes"], "Reported percentile/RSS does not match raw samples")
        require(sorted(violations) == sorted(workload["violations"]) and workload["passed"] is (not violations), "Budget conclusion does not match samples")
        require(not violations, "Original reading budget exceeded: " + name + ": " + ", ".join(violations))
        for sample in samples:
            require(sample.get("queryFirstScopes") == QUERY_SCOPES,
                    "All-scope first page did not cover every query category")
            counts = sample.get("queryFirstResultCounts", {})
            require(isinstance(counts, dict) and sorted(counts) == QUERY_SCOPES
                    and all(type(value) is int and value > 0 for value in counts.values())
                    and sum(counts.values()) == 100
                    and all(counts[name] == 1 for name in ("stashes", "worktrees", "commands"))
                    and sample.get("queryFixtureIdentitiesVerified") is True,
                    "Query category counts or concrete fixture identities were not verified")
            require(all(type(sample[key]) is int and sample[key] > 0 for key in
                    ["queryWrapperPID", "queryChildPID", "comparisonWrapperPID", "comparisonChildPID"]), "Cancellation process evidence absent")
            require(sample["queryWrapperPID"] != sample["queryChildPID"]
                    and sample["comparisonWrapperPID"] != sample["comparisonChildPID"],
                    "Cancellation wrapper and child must be distinct live processes")
            require(sample.get("queryProcessGroupExitVerified") is True
                    and sample.get("comparisonProcessGroupExitVerified") is True, "Cancellation group exit was not verified")
        proof[name] = dict(validSamples=expected, p95=recomputed, maximumResidentBytes=maximum,
                          queryScopes=QUERY_SCOPES, queryFixtureIdentitiesVerified=True)
    require(report["allPassed"] is (not diagnostic) and report["diagnosticPassed"] is diagnostic, "Diagnostic result promoted to formal evidence")
    if fixture_path is not None:
        require(hashlib.sha256(fixture_path.read_bytes()).hexdigest() == report.get("fixturesSHA256"), "Fixture manifest bytes changed")
        fixtures = json.loads(fixture_path.read_text())
        require(fixtures.get("complete") is True and fixtures.get("diagnosticOnly") is diagnostic
                and fixtures.get("workloads") == [workload["fixture"] for workload in workloads], "Measured fixture differs from generated scale")
    if artifact_root is not None:
        receipt = report.get("inputReceipt", {})
        require(type(receipt.get("format")) is int and receipt["format"] == 1
                and receipt.get("optimization") == "swiftc -O; Release WeGitCore"
                and all(receipt.get("toolchain", {}).get(key) for key in ["swift", "xcode", "architecture", "runnerImage"]), "Missing Release toolchain binding")
        def artifact(name, sha):
            require(hashlib.sha256(bound_file(artifact_root, name).read_bytes()).hexdigest() == sha, "Compiled artifact changed: " + name)
        artifact("checks", receipt.get("checkerSHA256"))
        artifact(receipt.get("coreObjectPath", "missing"), receipt.get("coreObjectSHA256"))
        resources = receipt.get("resourceFiles", {})
        require(bool(resources), "Missing linked resource binding")
        for name, sha in resources.items():
            artifact(name, sha)
    if source_root is not None:
        inputs = report.get("inputReceipt", {}).get("inputFiles", {})
        require(bool(inputs), "Missing input binding")
        for name, sha in inputs.items():
            require(hashlib.sha256(bound_file(source_root, name).read_bytes()).hexdigest() == sha, "Compiled source input changed: " + name)
    return dict(formalPassed=not diagnostic, diagnosticOnly=diagnostic, workloads=proof)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--fixtures", type=Path)
    parser.add_argument("--artifact-root", type=Path)
    args = parser.parse_args()
    result = verify(json.loads(args.report.read_text()), args.source_root, args.fixtures, args.artifact_root)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
