#!/usr/bin/env python3
"""Trusted, bounded recovery timing diagnostics; never a canonical validation receipt."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import signal
import subprocess
import time

from ui_source import choose_source

SHA = re.compile(r"[a-f0-9]{40}")
TRUSTED_FILES = ("scripts/ci/recovery_diagnostic.py", "scripts/ci/ui_source.py",
                 "scripts/RecoveryPerformance.swift")
PHASES = ("preview", "reset", "restorePreview", "restore", "reflog", "cancel")
SAMPLE_FIELDS = ("previewMilliseconds", "resetMilliseconds", "restorePreviewMilliseconds",
                 "restoreMilliseconds", "reflogMilliseconds", "cancelMilliseconds")
COMMANDS = {"status", "diff", "diff-index", "ls-files", "ls-tree", "config", "rev-parse",
            "symbolic-ref", "cat-file", "update-ref", "update-index", "write-tree", "read-tree",
            "init", "reset", "reflog", "check-ref-format", "other"}
PACKAGE = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "WeGit", defaultLocalization: "zh-Hans", platforms: [.macOS("26.0")],
    products: [.library(name: "WeGitCore", targets: ["WeGitCore"]),
               .executable(name: "WeGitAskPass", targets: ["WeGitAskPass"])],
    targets: [.target(name: "WeGitCore", path: "WeGitCore", resources: [.process("Resources")]),
              .executableTarget(name: "WeGitAskPass", dependencies: ["WeGitCore"], path: "WeGitAskPass")],
    swiftLanguageModes: [.v6]
)
'''


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def output_directory():
    temporary = Path(os.environ["RUNNER_TEMP"])
    if not temporary.is_absolute() or not temporary.is_dir() or temporary.is_symlink():
        raise ValueError("A real absolute runner temporary directory is required")
    output = temporary / "wegit-recovery-diagnostic"
    if output.is_symlink():
        raise ValueError("Diagnostic output must not be redirected")
    output.mkdir(mode=0o700, exist_ok=True)
    return output


def isolated_environment():
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("GIT_", "GH_", "ACTIONS_")) and key != "GITHUB_TOKEN"}
    env.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
    return env


def git(root, arguments):
    return subprocess.check_output(["/usr/bin/git", "-C", str(root), *arguments],
                                   env=isolated_environment(), timeout=30)


def resolve_source(main_sha, repository, expected_sha, candidate, read_pr):
    if not SHA.fullmatch(expected_sha):
        raise ValueError("An immutable candidate SHA is required")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid repository")
    if candidate and not re.fullmatch(r"[1-9][0-9]*", candidate):
        raise ValueError("A positive PR number is required")
    first = read_pr(candidate) if candidate else None
    chosen = choose_source(main_sha, repository, first)
    if chosen != expected_sha:
        raise ValueError("Candidate SHA does not match the selected current source")
    if candidate and choose_source(main_sha, repository, read_pr(candidate)) != chosen:
        raise ValueError("Candidate PR changed during source resolution")
    return chosen


def resolve(args, output):
    workspace = Path(os.environ["GITHUB_WORKSPACE"]).resolve(strict=True)
    main_sha = os.environ["GITHUB_SHA"]
    if os.environ.get("GITHUB_REF") != "refs/heads/main" or git(workspace, ["rev-parse", "HEAD"]).decode().strip() != main_sha:
        raise ValueError("The trusted entry must run from the exact main workflow source")
    repository = os.environ["GITHUB_REPOSITORY"]
    def read_pr(number):
        return json.loads(subprocess.check_output(["gh", "api", f"repos/{repository}/pulls/{number}"],
                                                 text=True, timeout=30))
    chosen = resolve_source(main_sha, repository, args.expected_sha, args.candidate, read_pr)
    trusted = output / "trusted"
    trusted.mkdir(mode=0o700, exist_ok=False)
    hashes = {}
    for name in TRUSTED_FILES:
        data = git(workspace, ["show", main_sha + ":" + name])
        source = workspace / name
        if source.is_symlink() or source.read_bytes() != data:
            raise ValueError("Trusted main source differs from its Git object")
        destination = trusted / Path(name).name
        destination.write_bytes(data)
        hashes[destination.name] = digest(data)
    # Check again after preserving the exact trusted executable inputs.
    if args.candidate and choose_source(main_sha, repository, read_pr(args.candidate)) != chosen:
        raise ValueError("Candidate PR changed while preserving trusted inputs")
    resolution = {"format": 1, "diagnosticOnly": True, "requiredValidation": False,
                  "uiSmokeExecuted": False, "xctestExecuted": False,
                  "repository": repository, "trustedMainSHA": main_sha, "sourceCommit": chosen,
                  "candidatePR": args.candidate or None, "trustedFilesSHA256": hashes,
                  "workflowSHA256": digest(git(workspace, ["show", main_sha + ":.github/workflows/recovery-performance.yml"]))}
    write_json(output / "source-resolution.json", resolution)
    print("sha=" + chosen)


def extract_sources(root, sha, stage):
    if not SHA.fullmatch(sha) or git(root, ["rev-parse", "HEAD"]).decode().strip() != sha:
        raise ValueError("Checkout must match the resolved immutable candidate")
    rows = git(root, ["ls-tree", "-r", "-z", sha, "--", "WeGitCore", "WeGitAskPass"]).split(b"\0")
    entries, total = {}, 0
    for row in rows:
        if not row:
            continue
        header, raw_path = row.split(b"\t", 1)
        mode, kind, object_id = header.decode("ascii").split()
        name = raw_path.decode("utf-8")
        path = PurePosixPath(name)
        if (mode not in {"100644", "100755"} or kind != "blob" or not SHA.fullmatch(object_id)
                or path.is_absolute() or str(path) != name or ".." in path.parts
                or path.parts[0] not in {"WeGitCore", "WeGitAskPass"} or name in entries):
            raise ValueError("Diagnostic source must contain only bounded regular tracked blobs")
        size = int(git(root, ["cat-file", "-s", object_id]))
        total += size
        if size > 8 * 1024 * 1024 or total > 64 * 1024 * 1024 or len(entries) >= 1024:
            raise ValueError("Diagnostic source budget exceeded")
        data = git(root, ["cat-file", "blob", object_id])
        if len(data) != size or hashlib.sha1(b"blob " + str(size).encode() + b"\0" + data).hexdigest() != object_id:
            raise ValueError("Git blob bytes do not match their fixed object")
        destination = stage / name
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        destination.write_bytes(data)
        entries[name] = {"gitBlob": object_id, "mode": mode, "bytes": size, "sha256": digest(data)}
    for directory in ("WeGitCore", "WeGitAskPass"):
        if not any(name.startswith(directory + "/") and name.endswith(".swift") for name in entries):
            raise ValueError("Required diagnostic target source is missing")
    if not any(name.startswith("WeGitCore/Resources/") for name in entries):
        raise ValueError("Core localization resources are required")
    (stage / "Package.swift").write_text(PACKAGE)
    return entries


def source_fingerprint(stage, entries):
    actual = {}
    for directory in ("WeGitCore", "WeGitAskPass"):
        root = stage / directory
        if root.is_symlink() or not root.is_dir():
            raise ValueError("Staged diagnostic source directory changed")
        for path in root.rglob("*"):
            if path.is_symlink() or not (path.is_file() or path.is_dir()):
                raise ValueError("Staged diagnostic source identity changed")
            if path.is_file():
                actual[str(path.relative_to(stage))] = digest(path.read_bytes())
    if (stage / "Package.swift").is_symlink() or (stage / "Package.swift").read_text() != PACKAGE:
        raise ValueError("The fixed diagnostic package changed")
    if actual != {name: entry["sha256"] for name, entry in entries.items()}:
        raise ValueError("Staged source bytes changed")
    return actual


def bounded_command(command, root, environment, log, timeout):
    with log.open("wb") as stream:
        process = subprocess.Popen(command, cwd=root, env=environment, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            stop_owned_session(process, log.with_suffix(".cleanup.json"))
            raise
        if owned_session_processes(process.pid):
            stop_owned_session(process, log.with_suffix(".cleanup.json"))
            raise RuntimeError("An exited diagnostic command left running descendants")
        return code


def owned_session_processes(session):
    """Core Git children create new process groups within this private session."""
    text = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,pgid=,state=,lstart="],
                                   text=True, env=dict(isolated_environment(), LC_ALL="C"), timeout=5)
    owned = []
    for line in text.splitlines():
        if not line.strip():
            continue
        fields = line.split(None, 4)
        if len(fields) != 5:
            raise RuntimeError("Process identity inventory is incomplete")
        pid, parent, group = map(int, fields[:3])
        try:
            if os.getsid(pid) == session and "Z" not in fields[3]:
                owned.append({"pid": pid, "parentPID": parent, "group": group,
                              "session": session, "started": fields[4]})
        except ProcessLookupError:
            continue
    if len(owned) > 1024:
        raise RuntimeError("Owned diagnostic process inventory exceeded its budget")
    return owned


def stop_owned_session(process, log):
    session = process.pid
    observed, signalled = {}, []
    def signal_owned(kind):
        current = owned_session_processes(session)
        groups = set()
        for member in current:
            observed[(member["pid"], member["started"])] = member
            try:
                # Recheck membership immediately before signalling. POSIX groups
                # cannot contain processes from another session; session identity
                # remains anchored while any of these descendants are alive.
                if os.getsid(member["pid"]) == session and os.getpgid(member["pid"]) == member["group"]:
                    groups.add(member["group"])
            except ProcessLookupError:
                continue
        for group in groups:
            try:
                os.killpg(group, kind)
                signalled.append({"group": group, "signal": int(kind)})
            except ProcessLookupError:
                pass
        return current
    try:
        signal_owned(signal.SIGTERM)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            process.poll()
            if not owned_session_processes(session):
                break
            time.sleep(0.05)
        if owned_session_processes(session):
            signal_owned(signal.SIGKILL)
        process.wait(timeout=3)
        deadline = time.monotonic() + 3
        while owned_session_processes(session) and time.monotonic() < deadline:
            time.sleep(0.05)
        remaining = owned_session_processes(session)
        if remaining:
            raise RuntimeError("Owned diagnostic processes remain after bounded cleanup")
        write_json(log, {"session": session, "ownedProcesses": list(observed.values()),
                         "signalledGroups": signalled, "remainingRunningProcesses": []})
    except Exception as error:
        write_json(log, {"session": session, "ownedProcesses": list(observed.values()),
                         "signalledGroups": signalled, "cleanupFailure": str(error)})
        raise


def toolchain():
    def value(command):
        return subprocess.check_output(command, env=isolated_environment(), text=True, timeout=30).strip()
    result = {"os": value(["/usr/bin/sw_vers", "-productVersion"]), "architecture": platform.machine(),
              "image": os.environ.get("ImageVersion", ""), "xcode": value(["/usr/bin/xcodebuild", "-version"]),
              "swift": value(["/usr/bin/xcrun", "swift", "--version"]),
              "appleGit": value(["/usr/bin/git", "--version"]),
              "logicalCPUs": value(["/usr/sbin/sysctl", "-n", "hw.logicalcpu"]),
              "physicalCPUs": value(["/usr/sbin/sysctl", "-n", "hw.physicalcpu"]),
              "memoryBytes": value(["/usr/sbin/sysctl", "-n", "hw.memsize"])}
    if result["architecture"] != "arm64" or int(result["os"].split(".")[0]) < 27 or not re.match(r"Xcode 27(?:\.|\n|$)", result["xcode"]):
        raise ValueError("Hosted arm64 macOS/Xcode 27 toolchain is required")
    git_version = re.search(r"git version ([0-9]+)\.([0-9]+)", result["appleGit"])
    if git_version is None or tuple(map(int, git_version.groups())) < (2, 46):
        raise ValueError("Git 2.46 or newer is required")
    return result


def package_command(stage):
    return ["/usr/bin/xcrun", "swift", "build", "--package-path", str(stage),
            "--scratch-path", str(stage / "build"), "--cache-path", str(stage / "cache"),
            "--config-path", str(stage / "config"), "--security-path", str(stage / "security"),
            "--manifest-cache", "local", "--disable-dependency-cache", "--disable-netrc", "--disable-keychain",
            "-Xswiftc", "-module-cache-path", "-Xswiftc", str(stage / "module-cache"),
            "-Xcc", "-fmodules-cache-path=" + str(stage / "clang-module-cache"), "-c", "release"]


def phase_breakdown(trace):
    """Separate process wall time from the enclosing call without double counting."""
    result = {}
    for span in trace["phases"]:
        events = [event for event in trace["commands"] if event["phase"] == span["phase"]]
        intervals = sorted((event["startNanoseconds"], event["endNanoseconds"]) for event in events)
        covered, previous_end = 0, span["startNanoseconds"]
        categories = {}
        for event in events:
            categories[event["command"]] = categories.get(event["command"], 0) + (event["endNanoseconds"] - event["startNanoseconds"])
        for start, end in intervals:
            covered += max(0, end - max(start, previous_end))
            previous_end = max(previous_end, end)
        elapsed = span["endNanoseconds"] - span["startNanoseconds"]
        result[span["phase"]] = {
            "callMilliseconds": elapsed / 1_000_000,
            "processWallMilliseconds": covered / 1_000_000,
            "outsideProcessMilliseconds": (elapsed - covered) / 1_000_000,
            "commandCount": len(events),
            "commandTotalMilliseconds": {name: value / 1_000_000 for name, value in categories.items()},
        }
    return result


def verify_report(report, sha):
    if type(report.get("format")) is not int or report["format"] != 1 or report.get("diagnosticOnly") is not True or report.get("sourceCommit") != sha or type(report.get("requiredSamples")) is not int or report["requiredSamples"] != 30 or type(report.get("allPassed")) is not bool:
        raise ValueError("The original thirty-sample source-bound report is required")
    traces = report.get("processTrace")
    if not isinstance(traces, list) or not traces or len(traces) > 60:
        raise ValueError("Recovery command timings are missing")
    trace_map = {}
    for trace in traces:
        key = (trace.get("workload"), trace.get("iteration"))
        if key in trace_map or key[0] not in {"ordinary", "large"} or type(key[1]) is not int or not 1 <= key[1] <= 30:
            raise ValueError("Invalid or duplicate timing sample")
        if type(trace.get("droppedCommandEvents")) is not int or trace["droppedCommandEvents"] != 0 or not isinstance(trace.get("commands"), list) or not trace["commands"] or len(trace["commands"]) > 256:
            raise ValueError("Missing or truncated command timing evidence")
        spans = trace.get("phases", [])
        if not isinstance(spans, list) or not 1 <= len(spans) <= 6:
            raise ValueError("Phase timing evidence is missing")
        if [span.get("phase") for span in spans] != list(PHASES[:len(spans)]):
            raise ValueError("Phase timing order changed")
        for span in spans:
            if span.get("phase") not in PHASES or type(span.get("completed")) is not bool or type(span.get("startNanoseconds")) is not int or type(span.get("endNanoseconds")) is not int or not 0 <= span["startNanoseconds"] <= span["endNanoseconds"]:
                raise ValueError("Invalid phase time range")
        if any(left["endNanoseconds"] > right["startNanoseconds"] for left, right in zip(spans, spans[1:])):
            raise ValueError("Sample phase timings overlap")
        for event in trace["commands"]:
            if event.get("command") not in COMMANDS or event.get("state") not in {"exited", "failed", "cancelled", "timedOut"} or (event["state"] == "exited" and (isinstance(event.get("exitCode"), bool) or not isinstance(event.get("exitCode"), int))) or (event["state"] != "exited" and event.get("exitCode") is not None):
                raise ValueError("Invalid command category or process outcome")
            matching = [span for span in spans if span["phase"] == event.get("phase")]
            if len(matching) != 1 or type(event.get("startNanoseconds")) is not int or type(event.get("endNanoseconds")) is not int or not matching[0]["startNanoseconds"] <= event["startNanoseconds"] <= event["endNanoseconds"] <= matching[0]["endNanoseconds"]:
                raise ValueError("Command timing escaped its sample phase")
        trace_map[key] = trace
    recomputed = {}
    for workload in report.get("workloads", []):
        name = workload.get("name")
        samples = workload.get("samples", [])
        if name not in {"ordinary", "large"} or name in recomputed or not isinstance(samples, list) or len(samples) != 30 or any(type(sample.get("iteration")) is not int for sample in samples) or {sample.get("iteration") for sample in samples} != set(range(1, 31)):
            raise ValueError("A completed workload requires thirty independent samples")
        files, volume = (100, 16 * 1024 * 1024) if name == "ordinary" else (1000, 256 * 1024 * 1024)
        expected_bytes = ((volume - files * 256) // files) * files
        if type(workload.get("files")) is not int or workload["files"] != files or type(workload.get("bytes")) is not int or workload["bytes"] != expected_bytes:
            raise ValueError("The original recovery fixture scale changed")
        for sample in samples:
            trace = trace_map.get((name, sample["iteration"]))
            if trace is None or [span["phase"] for span in trace["phases"]] != list(PHASES) or not all(span["completed"] for span in trace["phases"]) or {event["phase"] for event in trace["commands"]} != set(PHASES):
                raise ValueError("A completed sample lost its full command timings")
            for field in SAMPLE_FIELDS:
                number = sample.get(field)
                if isinstance(number, bool) or not isinstance(number, (int, float)) or not math.isfinite(number) or number <= 0:
                    raise ValueError("Invalid measured performance value")
            if type(sample.get("residentBytes")) is not int or sample["residentBytes"] <= 0 or type(sample.get("backupBytes")) is not int or not 0 < sample["backupBytes"] <= 256 * 1024 * 1024 or any(type(sample.get(field)) is not int or sample[field] <= 0 for field in ("wrapperPID", "childPID")) or sample["wrapperPID"] == sample["childPID"]:
                raise ValueError("Invalid memory, backup budget or actual cancellation process identity")
        p95 = {field: sorted(sample[field] for sample in samples)[28] for field in SAMPLE_FIELDS + ("residentBytes",)}
        passed = all(p95[field] < 2000 for field in SAMPLE_FIELDS[:-1]) and p95["cancelMilliseconds"] < 500 and p95["residentBytes"] <= (256 if name == "ordinary" else 512) * 1024 * 1024
        recomputed[name] = {"validSamples": 30, "p95": p95, "measurementPassed": passed,
                            "samplePhaseBreakdown": [dict(iteration=sample["iteration"],
                                phases=phase_breakdown(trace_map[(name, sample["iteration"])])) for sample in samples]}
    if report.get("allPassed") is True and (set(recomputed) != {"ordinary", "large"} or not all(item["measurementPassed"] for item in recomputed.values()) or len(traces) != 60):
        raise ValueError("The report does not satisfy the original complete workload budgets")
    return recomputed


def run(output):
    receipt = {"format": 1, "diagnosticOnly": True, "requiredValidation": False,
               "uiSmokeExecuted": False, "xctestExecuted": False, "outcome": "failed"}
    write_json(output / "diagnostic-receipt.json", receipt)
    stage, entries, workspace = None, None, None
    try:
        resolution = json.loads((output / "source-resolution.json").read_text())
        sha = resolution["sourceCommit"]
        if resolution.get("diagnosticOnly") is not True or resolution.get("requiredValidation") is not False or not SHA.fullmatch(sha):
            raise ValueError("Trusted diagnostic source resolution is missing")
        trusted = output / "trusted"
        if trusted.is_symlink() or not trusted.is_dir():
            raise ValueError("Trusted input directory changed")
        for name, expected in resolution["trustedFilesSHA256"].items():
            if name not in {Path(item).name for item in TRUSTED_FILES} or (trusted / name).is_symlink() or digest((trusted / name).read_bytes()) != expected:
                raise ValueError("Trusted collector or entry changed")
        if set(resolution["trustedFilesSHA256"]) != {Path(item).name for item in TRUSTED_FILES}:
            raise ValueError("Trusted executable input set is incomplete")
        workspace = Path(os.environ["GITHUB_WORKSPACE"]).resolve(strict=True)
        stage = Path(os.environ["RUNNER_TEMP"]) / "wegit-recovery-diagnostic-staging"
        stage.mkdir(mode=0o700, exist_ok=False)
        entries = extract_sources(workspace, sha, stage)
        receipt.update(sourceCommit=sha, trustedMainSHA=resolution["trustedMainSHA"], sourceFiles=entries,
                       trustedFilesSHA256=resolution["trustedFilesSHA256"], packageSHA256=digest(PACKAGE.encode()),
                       sourceBeforeSHA256=source_fingerprint(stage, entries))
        tools = toolchain()
        receipt.update(toolchain=tools, toolchainSHA256=digest(json.dumps(tools, sort_keys=True, separators=(",", ":")).encode()))
        write_json(output / "diagnostic-receipt.json", receipt)
        env = isolated_environment()
        build = stage / "build"
        build_command = package_command(stage) + ["--product", "WeGitAskPass"]
        code = bounded_command(build_command, stage, env, output / "build.log", 600)
        receipt["buildExitCode"] = code
        if code != 0:
            raise ValueError("Release diagnostic source compilation failed")
        library = Path(subprocess.check_output(package_command(stage) + ["--show-bin-path"], env=env, text=True, timeout=30).strip()).resolve(strict=True)
        if not library.is_relative_to(build.resolve()) or not (library / "WeGitCore.o").is_file() or not (library / "WeGit_WeGitCore.bundle").is_dir():
            raise ValueError("Compiled module or resources escaped private staging")
        compile_command = ["/usr/bin/xcrun", "swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(stage / "module-cache"), "-parse-as-library", "-I", str(library), str(library / "WeGitCore.o"), str(trusted / "RecoveryPerformance.swift"), "-o", str(output / "checks")]
        code = bounded_command(compile_command, stage, env, output / "collector-build.log", 90)
        receipt["collectorBuildExitCode"] = code
        if code != 0:
            raise ValueError("Trusted collector compilation failed")
        shutil.copytree(library / "WeGit_WeGitCore.bundle", output / "WeGit_WeGitCore.bundle")
        receipt.update(coreObjectSHA256=digest((library / "WeGitCore.o").read_bytes()),
                       checkerSHA256=digest((output / "checks").read_bytes()),
                       moduleFilesSHA256={str(path.relative_to(library)): digest(path.read_bytes()) for path in library.rglob("*") if path.is_file() and ("WeGitCore.swiftmodule" in path.parts or "WeGit_WeGitCore.bundle" in path.parts)},
                       compileCommands=[build_command, compile_command])
        write_json(output / "diagnostic-receipt.json", receipt)
        started = time.monotonic()
        code = bounded_command([str(output / "checks"), str(output / "result.json")], workspace, env, output / "runtime.log", 600)
        receipt.update(measurementExitCode=code, measurementSeconds=time.monotonic() - started)
        report = json.loads((output / "result.json").read_text())
        receipt.update(resultSHA256=digest((output / "result.json").read_bytes()), recomputed=verify_report(report, sha))
        if code != 0 or report.get("allPassed") is not True:
            raise ValueError("The actual recovery measurement failed its original budgets or assertions")
        receipt["outcome"] = "completedDiagnostic"
    except Exception as error:
        receipt["failure"] = str(error)
    finally:
        try:
            if stage is not None and entries is not None:
                receipt["sourceAfterSHA256"] = source_fingerprint(stage, entries)
                if git(workspace, ["rev-parse", "HEAD"]).decode().strip() != receipt["sourceCommit"]:
                    raise ValueError("Candidate checkout changed during diagnostics")
            if "trustedFilesSHA256" in receipt:
                if (output / "trusted").is_symlink():
                    raise ValueError("Trusted input directory changed during diagnostics")
                for name, expected in receipt["trustedFilesSHA256"].items():
                    if (output / "trusted" / name).is_symlink() or digest((output / "trusted" / name).read_bytes()) != expected:
                        raise ValueError("Trusted executable input changed during diagnostics")
        except Exception as error:
            receipt.update(outcome="failed", sourceVerificationFailure=str(error))
        write_json(output / "diagnostic-receipt.json", receipt)
    if receipt["outcome"] != "completedDiagnostic":
        raise SystemExit(receipt.get("failure") or receipt.get("sourceVerificationFailure") or "Recovery diagnostic failed")
    print("Recovery timing diagnostic completed; no XCTest, UI smoke, canonical validation or release acceptance.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    source = commands.add_parser("resolve")
    source.add_argument("--candidate", default="")
    source.add_argument("--expected-sha", required=True)
    commands.add_parser("run")
    args = parser.parse_args()
    output = output_directory()
    try:
        resolve(args, output) if args.command == "resolve" else run(output)
    except Exception as error:
        write_json(output / "entry-failure.json", {"diagnosticOnly": True, "requiredValidation": False, "failure": str(error)})
        raise


if __name__ == "__main__":
    main()
