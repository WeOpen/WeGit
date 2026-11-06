#!/usr/bin/env python3
"""Reuse executed results only after checking canonical provenance and every input.

Build caches are deliberately separate. Downloaded receipts never execute code.
An equivalent reviewed merge can reference its PR evidence without inventing a
second test count. Failed/expired/unverifiable evidence falls back to execution.
"""
import argparse
import ast
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time
import zipfile

SUITES = ("core", "signing", "behavior", "performance", "application", "package")
COMMON = ("Package.swift", "scripts/ci/batch_evidence.py", "scripts/ci/run-batch-suite.sh",
          "scripts/ci/isolate-git.sh", "scripts/ci/check-toolchain.sh", ".github/workflows/verify.yml")
SHA = re.compile(r"[0-9a-f]{40}")
MAX_ARCHIVE = 8 * 1024 * 1024
SUITE_STEPS = {
    "core": "Core regression on Apple, minimum and Homebrew Git",
    "signing": "Isolated Apple and Homebrew OpenPGP signing",
    "behavior": "Native feature behavior",
    "performance": "Backend performance budgets",
    "application": "Compile application and native UI regressions",
}
READER_ONLY_FUNCTIONS = {
    "canonical_run", "eligible", "restore", "suite_job_succeeded",
    "reader_execution_contract", "reader_compatibility", "source_matches", "ensure_commit",
    "suite_job_outcome", "failed_execution_matches",
}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def inputs(root, suite):
    if suite not in SUITES:
        raise ValueError("Unknown validation suite")
    directories = ["WeGitCore", "WeGitAskPass", "WeGitUpdater"]
    if suite == "core":
        directories += ["WeGitTests", "Benchmarks"]
    if suite in {"behavior", "application", "package"}:
        directories += ["WeGit", "WeGitUITests", "WeGitPerformanceTests", "WeGit.xcodeproj"]
    paths = set(COMMON)
    for directory in directories:
        paths.update(str(path.relative_to(root)) for path in (root / directory).rglob("*")
                     if path.is_file() and path.name != ".DS_Store")
    # All fixture/build entry inputs are included; no changed helper can hide
    # behind an unchanged test-method name. Application data stays out of Core.
    if suite == "core":
        paths.add("scripts/ci/prepare-git-246.sh")
    elif suite == "signing":
        paths.update(("scripts/verify-gpg-compatibility.sh", "scripts/GPGCompatibilityChecks.swift"))
    elif suite == "performance":
        paths.update(str(path.relative_to(root)) for pattern in ("*Performance.swift", "verify-*-performance.sh")
                     for path in (root / "scripts").glob(pattern))
        paths.add("scripts/ci/native-behavior.sh")
    else:
        paths.update(str(path.relative_to(root)) for path in (root / "scripts").glob("*")
                     if path.suffix in {".sh", ".swift", ".py"})
        paths.update(("project.yml", "LICENSE", "scripts/ci/native-behavior.sh"))
    paths.add(".swift-format")
    missing = [name for name in paths if not (root / name).is_file() or (root / name).is_symlink()]
    if missing:
        raise ValueError("Validation input missing or symlinked: " + ", ".join(sorted(missing)[:8]))
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sorted(paths)}


def command_output(command):
    result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=45)
    return result.stdout.strip()


def toolchain():
    brew_git = command_output(["brew", "--prefix", "git"]) + "/bin/git"
    gpg = command_output(["brew", "--prefix", "gnupg"]) + "/bin/gpg"
    return {"os": platform.platform(), "architecture": platform.machine(),
            "image": os.environ.get("ImageVersion", ""),
            "xcode": command_output(["xcodebuild", "-version"]),
            "swift": command_output(["swift", "--version"]),
            "appleGit": command_output(["/usr/bin/git", "--version"]),
            "homebrewGit": command_output([brew_git, "--version"]),
            "gpg": command_output([gpg, "--version"]).splitlines()[0]}


def api(repo, suffix, binary=False):
    result = subprocess.run(["gh", "api", "repos/" + repo + "/" + suffix],
                            capture_output=True, check=True, timeout=45)
    return result.stdout if binary else json.loads(result.stdout)


def canonical_run(run, workflow_id, repo, allow_partial=False):
    return (run.get("workflow_id") == workflow_id and run.get("status") == "completed"
            and (run.get("conclusion") == "success" or allow_partial and run.get("conclusion") == "failure")
            and SHA.fullmatch(run.get("head_sha", ""))
            and (run.get("repository") or {}).get("full_name", repo).casefold() == repo.casefold()
            and (run.get("event") in {"push", "workflow_dispatch"} and run.get("head_branch") == "main"
                 or run.get("event") == "pull_request"))


def suite_job_outcome(receipt, jobs):
    step_name = SUITE_STEPS.get(receipt.get("suite"))
    origin = receipt.get("execution", {})
    if (step_name is None or receipt.get("mode") != "executed"
            or str(origin.get("runId")) != str(receipt.get("runId"))
            or origin.get("sourceCommit") != receipt.get("sourceCommit")):
        return None
    for job in jobs:
        if job.get("name") != "Native macOS":
            continue
        for step in job.get("steps", []):
            if step.get("name") == step_name and step.get("status") == "completed":
                outcome = step.get("conclusion")
                return outcome if outcome in {"success", "failure"} else None
    return None


def suite_job_succeeded(receipt, jobs):
    return suite_job_outcome(receipt, jobs) == "success"


def failed_execution_matches(receipt, expected_files, expected_tools, run, workflow_id, repo, reader_proof=None):
    original = receipt.get("inputFiles", {})
    origin = receipt.get("execution", {})
    name = "scripts/ci/batch_evidence.py"
    equivalent = (isinstance(reader_proof, dict) and reader_proof.get("kind") == "read-only-evidence-reader"
                  and original.keys() == expected_files.keys()
                  and [key for key in original if original[key] != expected_files[key]] == [name]
                  and reader_proof.get("sourceSHA256") == original.get(name)
                  and reader_proof.get("currentSHA256") == expected_files.get(name))
    return bool(canonical_run(run, workflow_id, repo, allow_partial=True)
                and receipt.get("format") == 1 and receipt.get("status") == "failure"
                and receipt.get("mode") == "executed" and origin.get("kind") == "executed"
                and isinstance(origin.get("exitCode"), int) and origin["exitCode"] != 0
                and (original == expected_files or equivalent) and receipt.get("inputDigest") == digest(original)
                and receipt.get("toolchain") == expected_tools
                and receipt.get("repository", "").casefold() == repo.casefold()
                and str(receipt.get("runId")) == str(run.get("id"))
                and str(origin.get("runId")) == str(run.get("id"))
                and origin.get("sourceCommit") == receipt.get("sourceCommit"))


def reader_execution_contract(source):
    """Keep every execution statement; only evidence-reading definitions differ."""
    module = ast.parse(source)
    body = []
    for node in module.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in READER_ONLY_FUNCTIONS:
            continue
        if isinstance(node, ast.Import) and len(node.names) == 1 and node.names[0].name == "ast" and node.names[0].asname is None:
            continue
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if node.targets[0].id in {"SUITE_STEPS", "READER_ONLY_FUNCTIONS"}:
                ast.literal_eval(node.value)
                continue
        body.append(node)
    normalized = ast.dump(ast.Module(body=body, type_ignores=[]), include_attributes=False)
    return hashlib.sha256(normalized.encode()).hexdigest()


def reader_compatibility(root, receipt, expected_files):
    original = receipt.get("inputFiles", {})
    name = "scripts/ci/batch_evidence.py"
    if original.keys() != expected_files.keys():
        return None
    if [key for key in original if original[key] != expected_files[key]] != [name]:
        return None
    source = receipt.get("sourceCommit", "")
    if not SHA.fullmatch(source):
        return None
    old = subprocess.run(["git", "-C", str(root), "show", source + ":" + name],
                         capture_output=True, timeout=15)
    new = (root / name).read_bytes()
    if old.returncode or hashlib.sha256(old.stdout).hexdigest() != original[name]:
        return None
    try:
        before = reader_execution_contract(old.stdout.decode())
        after = reader_execution_contract(new.decode())
    except (SyntaxError, ValueError, UnicodeError):
        return None
    if before != after:
        return None
    return {"kind": "read-only-evidence-reader", "path": name, "sourceSHA256": original[name],
            "currentSHA256": expected_files[name], "executionContractSHA256": before}

def ensure_commit(root, repo, sha):
    if not SHA.fullmatch(sha or ""):
        raise ValueError("Mutable evidence source")
    if subprocess.run(["git", "cat-file", "-e", sha + "^{commit}"], cwd=root,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        subprocess.run(["git", "fetch", "--quiet", "--no-tags", "--depth=1",
                        "https://github.com/" + repo + ".git", sha], cwd=root,
                       capture_output=True, check=True, timeout=45)


def source_matches(root, repo, receipt, run):
    source = receipt.get("sourceCommit", "")
    ensure_commit(root, repo, source)
    if source != run["head_sha"]:
        # pull_request checkout commonly uses GitHub's synthetic merge commit.
        # Revision walking hides parents at a shallow boundary. Read the
        # immutable commit header itself when proving a PR merge's provenance.
        commit = subprocess.run(["git", "-C", str(root), "cat-file", "-p", source],
                                capture_output=True, check=True, timeout=15).stdout
        header = commit.split(b"\n\n", 1)[0]
        parents = [line[7:].decode("ascii") for line in header.splitlines() if line.startswith(b"parent ")]
        if run.get("event") != "pull_request" or len(parents) != 2 or parents[1] != run["head_sha"]:
            return False
    files = receipt.get("inputFiles")
    if not isinstance(files, dict) or receipt.get("inputDigest") != digest(files):
        return False
    # Recompute from Git objects, not just the receipt's claimed hashes.
    for name, expected in files.items():
        if not isinstance(name, str) or name.startswith("/") or any(p in {"", ".", ".."} for p in name.split("/")):
            return False
        blob = subprocess.run(["git", "-C", str(root), "show", source + ":" + name],
                              capture_output=True, timeout=15)
        if blob.returncode or hashlib.sha256(blob.stdout).hexdigest() != expected:
            return False
    return True


def eligible(receipt, expected_files, expected_tools, run, workflow_id, repo,
             phase_verified=False, reader_proof=None):
    origin = receipt.get("execution", {})
    original = receipt.get("inputFiles", {})
    reader_name = "scripts/ci/batch_evidence.py"
    equivalent = (isinstance(reader_proof, dict)
                  and reader_proof.get("kind") == "read-only-evidence-reader"
                  and reader_proof.get("path") == reader_name
                  and original.keys() == expected_files.keys()
                  and [key for key in original if original[key] != expected_files[key]] == [reader_name]
                  and reader_proof.get("sourceSHA256") == original.get(reader_name)
                  and reader_proof.get("currentSHA256") == expected_files.get(reader_name)
                  and re.fullmatch(r"[0-9a-f]{64}", reader_proof.get("executionContractSHA256", "")))
    return bool(canonical_run(run, workflow_id, repo, allow_partial=phase_verified)
                and receipt.get("format") == 1 and receipt.get("status") == "success"
                and (receipt.get("inputFiles") == expected_files or equivalent)
                and receipt.get("inputDigest") == digest(receipt.get("inputFiles", {}))
                and receipt.get("toolchain") == expected_tools
                and receipt.get("repository", "").casefold() == repo.casefold()
                and str(receipt.get("runId")) == str(run.get("id"))
                and origin.get("kind") == "executed" and origin.get("exitCode") == 0
                and origin.get("runId") and origin.get("sourceCommit") and origin.get("logSHA256"))


def restore(root, repo, output):
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        raise ValueError("Invalid evidence repository")
    tools = toolchain()
    workflow_id = api(repo, "actions/workflows/verify.yml")["id"]
    runs = api(repo, "actions/workflows/verify.yml/runs?status=completed&per_page=20")["workflow_runs"]
    found = {}
    blocked = {}
    runs.sort(key=lambda item: item.get("updated_at", item.get("created_at", "")), reverse=True)
    start = time.monotonic()
    expected = {suite: inputs(root, suite) for suite in SUITES if suite != "package"}
    for run in runs:
        if time.monotonic() - start > 90:
            break
        if not canonical_run(run, workflow_id, repo, allow_partial=True) or str(run["id"]) == os.environ.get("GITHUB_RUN_ID"):
            continue
        # Accept PR evidence only after the same-repository source was reviewed
        # into main, or while validating a later head of that same owned PR.
        if run["event"] == "pull_request":
            accepted = False
            current_pr = os.environ.get("CI_PR_NUMBER", "")
            for pr_info in run.get("pull_requests", []):
                pr = api(repo, "pulls/" + str(pr_info["number"]))
                if ((pr.get("head", {}).get("repo") or {}).get("full_name", "").casefold() == repo.casefold()
                    and pr.get("base", {}).get("ref") == "main"
                    and ((pr.get("merged_at") is not None) or str(pr_info["number"]) == current_pr)):
                    accepted = True
            if not accepted:
                continue
        jobs = api(repo, f"actions/runs/{run['id']}/jobs?filter=latest&per_page=100")["jobs"]
        required_jobs = ("Repository validation", "Change scope") if run.get("conclusion") == "failure" else ("Native macOS", "Repository policy")
        if not all(any(job.get("name") == name and job.get("conclusion") == "success" for job in jobs)
                   for name in required_jobs):
            continue
        artifacts = api(repo, f"actions/runs/{run['id']}/artifacts?per_page=100")["artifacts"]
        for artifact in artifacts:
            if artifact.get("expired") or not artifact["name"].startswith("batch-receipts-") or artifact["size_in_bytes"] > MAX_ARCHIVE:
                continue
            archive = api(repo, f"actions/artifacts/{artifact['id']}/zip", binary=True)
            if len(archive) > MAX_ARCHIVE:
                continue
            with zipfile.ZipFile(io.BytesIO(archive)) as zip_file:
                for item in zip_file.infolist():
                    suite = Path(item.filename).stem
                    if suite in found or suite in blocked or suite not in expected or item.file_size > 2 * 1024 * 1024:
                        continue
                    receipt = json.loads(zip_file.read(item))
                    if receipt.get("suite") != suite or not source_matches(root, repo, receipt, run):
                        continue
                    attempt = str(receipt.get("runAttempt", ""))
                    if not attempt.isdigit() or int(attempt) < 1:
                        continue
                    attempt_jobs = jobs if attempt == str(run.get("run_attempt")) else api(
                        repo, f"actions/runs/{run['id']}/attempts/{attempt}/jobs?per_page=100")["jobs"]
                    phase = suite_job_succeeded(receipt, attempt_jobs)
                    proof = reader_compatibility(root, receipt, expected[suite])
                    if (suite_job_outcome(receipt, attempt_jobs) == "failure"
                            and failed_execution_matches(receipt, expected[suite], tools, run, workflow_id, repo, proof)):
                        blocked[suite] = {"runId": run["id"], "runAttempt": attempt, "status": "failure",
                                          "sourceCommit": receipt["sourceCommit"], "inputDigest": receipt["inputDigest"]}
                        continue
                    if not eligible(receipt, expected[suite], tools, run, workflow_id, repo,
                                    phase_verified=phase, reader_proof=proof):
                        continue
                    if run.get("conclusion") == "failure" and not phase:
                        continue
                    # This candidate certifies equivalent current inputs, not a
                    # new execution. Preserve the original signed-off bytes and
                    # counts in originalReceipt and in the downloaded archive.
                    certified = dict(receipt)
                    if proof:
                        certified.update(inputFiles=expected[suite], inputDigest=digest(expected[suite]),
                                         inputEquivalence=proof)
                    found[suite] = {"receipt": certified, "originalReceipt": receipt,
                                    "readerCompatibility": proof, "runId": run["id"],
                                    "runConclusion": run["conclusion"], "runAttempt": attempt,
                                    "artifactId": artifact["id"], "artifactSHA256": hashlib.sha256(archive).hexdigest()}
        if len(found) == len(expected):
            break
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"format": 1, "toolchain": tools, "suites": found,
                                  "blockedByNewerFailure": blocked}, indent=2) + "\n")
    print("Verified reusable suite inputs: " + (", ".join(sorted(found)) or "none"))


def run_suite(root, suite, output, candidates):
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise ValueError("Actual batch suites run only on GitHub-hosted VMs; local tool tests never run XCTest")
    files = inputs(root, suite)
    tools = toolchain()
    source = command_output(["git", "rev-parse", "HEAD"])
    if command_output(["git", "status", "--porcelain"]):
        raise ValueError("Batch source must be clean and immutable")
    report = {"format": 1, "suite": suite, "inputFiles": files, "inputDigest": digest(files),
              "toolchain": tools, "sourceCommit": source, "repository": os.environ["GITHUB_REPOSITORY"],
              "runId": os.environ["GITHUB_RUN_ID"], "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
              "recordedAt": datetime.now(timezone.utc).isoformat(), "status": "running", "mode": "executed"}
    previous = json.loads(candidates.read_text()).get("suites", {}).get(suite) if candidates.is_file() else None
    # package always builds the actual deliverable; receipts are not build artifacts.
    if previous and suite != "package":
        receipt = previous["receipt"]
        if receipt["inputFiles"] == files and receipt["toolchain"] == tools:
            report.update(status="success", mode="reused", execution=receipt["execution"],
                          reusedFrom={key: previous[key] for key in ("runId", "artifactId", "artifactSHA256")})
            output.write_text(json.dumps(report, indent=2) + "\n")
            print(f"{suite}: reused verified inputs from run {previous['runId']}; original execution count retained")
            return
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    start = time.monotonic()
    log = output.with_suffix(".log")
    with log.open("w") as handle:
        result = subprocess.run(["/bin/bash", "scripts/ci/run-batch-suite.sh", suite], cwd=root,
                                stdout=handle, stderr=subprocess.STDOUT)
    report.update(status="success" if result.returncode == 0 else "failure",
                  execution={"kind": "executed", "exitCode": result.returncode,
                             "seconds": round(time.monotonic() - start, 3), "sourceCommit": source,
                             "runId": os.environ["GITHUB_RUN_ID"], "log": str(log.relative_to(root)),
                             "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest()})
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{suite}: {report['status']}; log: {log}")
    if result.returncode:
        raise SystemExit(result.returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    restore_parser = sub.add_parser("restore")
    restore_parser.add_argument("--repo", required=True)
    restore_parser.add_argument("--output", type=Path, default=Path(".build/ci/receipts/candidates.json"))
    run_parser = sub.add_parser("run")
    run_parser.add_argument("--suite", choices=SUITES, required=True)
    run_parser.add_argument("--candidates", type=Path, default=Path(".build/ci/receipts/candidates.json"))
    args = parser.parse_args()
    root = Path.cwd()
    if args.command == "restore":
        try:
            restore(root, args.repo, args.output)
        except (ValueError, OSError, subprocess.SubprocessError, zipfile.BadZipFile, KeyError) as error:
            # An unavailable receipt cannot change the validation result. Execute.
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps({"format": 1, "suites": {}, "restoreError": type(error).__name__}) + "\n")
            print("Evidence unavailable; all required suites will execute: " + type(error).__name__)
    else:
        run_suite(root, args.suite, root / ".build/ci/receipts" / (args.suite + ".json"), args.candidates)


if __name__ == "__main__":
    main()
