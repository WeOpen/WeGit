#!/usr/bin/env python3
"""Read UI prerequisites and bound native XCTest runs without changing OS permissions."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import time

FOCUSED_TESTS = {
    "feedback-commit": "OperationFeedbackTests/testCommitFailureAndCancellationReplaceStagingSuccessAndPreserveDraft",
    "feedback-stash": "OperationFeedbackTests/testStashPopBeforeAndAfterDropFailuresExposeAppliedBytesAndTheRealList",
    "feedback-tag": "OperationFeedbackTests/testTagUnknownAbsentAndDifferentObjectStayPendingUntilMatchingVerification",
    "feedback-push": "OperationFeedbackTests/testUnmatchedAndAbsentPushVerificationPreservePendingUntilTheTargetMatches",
    "settings-lifecycle": "SettingsLifecycleTests/testConfigurationSaveBlocksQuitAndCancellationPreservesValue",
    "interactive-rebase": "RebaseWorkflowTests/testInteractiveSequenceEditsSquashesAndRecoversAfterRelaunch",
    "rebase-workflow": "RebaseWorkflowTests/testFixedTargetReplayAndRecoverAcrossRelaunch",
    "worktree-management": "WorktreeManagementWorkflowTests/testCreateCancelRemoveAndProtectChangedWorktrees",
    "selected-lines": "SelectedLinesWorkflowTests/testPreviewCancelStageUnstageAndStaleConfirmation",
    "blame": "BlameWorkflowTests/testCommittedAttributionPagingAndHistoricalNavigation",
    "single-commit": "SingleCommitWorkflowTests/testPreviewApplyRevertAndRecoverAfterRelaunch",
    "worktree-opening": "WorktreeWorkflowTests/testLinkedWorktreesKeepDraftsPagesAndIndexesAcrossSwitchAndRelaunch",
    "file-history": "FileHistoryWorkflowTests/testFileContextRenameSearchAndManualDeletedPath",
    "tags-workflow": "TagWorkflowTests/testCreateCancelInspectAndDeleteLocalTagPreservesBranch",
    "tags-push": "TagWorkflowTests/testSingleTagPushRequiresEndpointConfirmationAndPreservesOtherTags",
    "remote-workflow": "RemoteManagementWorkflowTests/testAddEditCancelAndRemoveRepositoryRemote",
    "stash-workflow": "StashWorkflowTests/testSaveInspectApplyAndDeletePreserveWorkingAndStagingState",
    "stash-recovery": "StashWorkflowTests/testPopCancelSuccessConflictAndExternalListRefresh",
    "changes-groups": "ChangesListTests/testCollapsibleGroupsAndFilteredStageCheckboxes",
    "toolbar-heights": "ToolbarMenuBarTests/testToolbarHeightsAndUpstreamCountsRefreshTogether",
    "sidebar-surface": "ToolbarMenuBarTests/testSidebarButtonRetainsItsSurfaceAfterRepeatedToggles",
    "minimum-layout": "LayoutTests/testMinimumWindowPreservesNavigationAndPrimaryControls",
    "compact-toolbar": "ToolbarMenuBarTests/testCompactToolbarKeepsSyncAndMoreActionsReachable",
    "menu-localization": "LocalizationUITests/testLanguageSwitchKeepsDraftAndGitDataAndCommitButtonsMatch",
    "text-settings": "SettingsReadingTests/testSixSettingsTabsAndLiveTextMeasurementChanges",
    "theme-interaction": "ThemeInteractionTests/testThemesUpdateOpenWindowsAndTabsKeepNeutralKeyboardFocus",
    "window-restoration": "WindowLifecycleTests/testWindowFrameRestoresAndClosedWorkspaceCanReopen",
    "inspector-boundary": "InspectorRestorationTests/testDiffFillsInspectorBoundaryAndSplitHeadersHaveInsets",
    "inspector-restoration": "InspectorRestorationTests/testOpenInspectorRestoresAcrossBothSplitWorkspaces",
    "submodule-lfs": "InspectorRestorationTests/testSubmoduleAndLFSResourcesAppearInInspector",
    "search-keyboard": "InterfacePolishTests/testSearchClearKeepsInputFocusAndKeyboardCommitInBothThemes",
    "sync-recovery": "WeGitUITests/testLostPushReplyRestoresVerificationAfterLocalHeadMoves",
    "diff-options": "WeGitUITests/testDiffReadingOptionsAndFilterEmptyState",
    "large-diff": "WeGitUITests/testLargeDiffSummaryPagingAndSelectionReset",
    "rebase-conflicts": "WorkflowRecoveryTests/testPullRebaseHandlesTwoConflictRoundsAndAbort",
    "conflict-editor": "WorkflowRecoveryTests/testConflictEditorPreservesIndexUntilResolveAndGuardsUnsavedClose",
}


def run_logged(command, output, timeout):
    start = time.monotonic()
    timed_out = False
    with output.open("w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
    return {"exitCode": process.returncode, "timedOut": timed_out,
            "seconds": round(time.monotonic() - start, 3), "log": output.name}


def inspect_environment():
    def read(command):
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=20)
            return {"exitCode": result.returncode, "output": (result.stdout + result.stderr).strip()}
        except (OSError, subprocess.TimeoutExpired) as error:
            return {"exitCode": -1, "output": type(error).__name__}

    manager = read(["/bin/launchctl", "managername"])
    developer = read(["/usr/sbin/DevToolsSecurity", "-status"])
    console_uid = Path("/dev/console").stat().st_uid if Path("/dev/console").exists() else None
    interactive = manager["exitCode"] == 0 and manager["output"] == "Aqua" and console_uid == os.getuid()
    return {
        "date": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(),
        "sourceCommit": read(["git", "rev-parse", "HEAD"])["output"],
        "workspaceDirty": bool(read(["git", "status", "--porcelain"])["output"]),
        "imageVersion": os.environ.get("ImageVersion"), "runId": os.environ.get("GITHUB_RUN_ID"),
        "manager": manager, "consoleUIDMatches": console_uid == os.getuid(),
        "developerTools": developer,
        "interactivePrerequisites": interactive and developer["exitCode"] == 0 and "currently enabled" in developer["output"],
        "sip": read(["/usr/bin/csrutil", "status"]),
        "gatekeeper": read(["/usr/sbin/spctl", "--status"]),
        "xcode": read(["/usr/bin/xcodebuild", "-version"]),
        "firstLaunch": read(["/usr/bin/xcodebuild", "-checkFirstLaunchStatus"]),
        "selectedGit": read(["/usr/bin/xcrun", "--find", "git"]),
        "osPermissionsChanged": False,
    }


def verify_summary(summary, smoke=False):
    keys = ("totalTestCount", "passedTests", "failedTests", "skippedTests")
    if any(type(summary.get(key)) is not int for key in keys):
        raise ValueError("Missing native test execution counts")
    total, passed, failed, skipped = (summary[key] for key in keys)
    if total < 1 or passed != total or failed != 0 or skipped != 0 or (smoke and total != 1):
        raise ValueError("Native scope must actually execute and pass every selected test without skips")
    return {key: summary[key] for key in keys}


def batch_methods(registry, name):
    data = json.loads(registry.read_text())
    methods = data.get("batches", {}).get(name, {}).get("methods")
    if data.get("format") != 1 or not isinstance(methods, list) or not 1 <= len(methods) <= 128:
        raise ValueError("Unknown or empty trusted native batch")
    import re
    if (len(set(methods)) != len(methods) or any(not re.fullmatch(r"[A-Za-z][A-Za-z0-9]+/test[A-Za-z0-9_]+", method)
                                               for method in methods)
            or "WeGitUITests/testWelcomeAndCloneForm" in methods):
        raise ValueError("Batch methods must be unique explicit tests; smoke runs separately once")
    return methods


def verify_batch_summary(summary, methods):
    result = verify_summary(summary)
    if result["totalTestCount"] != len(methods):
        raise ValueError("Native batch execution count does not match its complete registered method set")
    return result


def verify_batch_sources(root, methods):
    """Check selected methods in their actual candidate classes before building."""
    import re
    literal_pattern = re.compile(r'(#{0,})((?:""")|")')
    token_pattern = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|[{}:]")

    def tokens(text):
        def skip_comment(index):
            if text.startswith("//", index):
                end = text.find("\n", index + 2)
                return len(text) if end < 0 else end + 1
            depth = 1
            index += 2
            while index < len(text) and depth:
                if text.startswith("/*", index):
                    depth += 1
                    index += 2
                elif text.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            if depth:
                raise ValueError("Unterminated candidate Swift comment")
            return index

        def skip_interpolation(index):
            depth = 1
            while index < len(text) and depth:
                if text.startswith(("//", "/*"), index):
                    index = skip_comment(index)
                elif literal_pattern.match(text, index):
                    index = skip_literal(index)
                else:
                    if text[index] == "(":
                        depth += 1
                    elif text[index] == ")":
                        depth -= 1
                    index += 1
            if depth:
                raise ValueError("Unterminated candidate Swift interpolation")
            return index

        def skip_literal(index):
            literal = literal_pattern.match(text, index)
            hashes, quote = literal.groups()
            index = literal.end()
            interpolation = "\\" + hashes + "("
            escape = "\\" + hashes
            closing = quote + hashes
            while index < len(text):
                if text.startswith(interpolation, index):
                    index = skip_interpolation(index + len(interpolation))
                elif text.startswith(escape, index):
                    index += len(escape) + 1
                elif text.startswith(closing, index):
                    return index + len(closing)
                else:
                    index += 1
            raise ValueError("Unterminated candidate Swift string")

        index = 0
        while index < len(text):
            if text.startswith(("//", "/*"), index):
                index = skip_comment(index)
            elif literal_pattern.match(text, index):
                index = skip_literal(index)
            else:
                token = token_pattern.match(text, index)
                if token:
                    yield token.group()
                    index = token.end()
                else:
                    index += 1

    classes = {}
    methods_by_class = {}
    fingerprints = {}
    source_directory = root / "WeGitUITests"
    if source_directory.is_symlink() or not source_directory.is_dir():
        raise ValueError("Candidate native source directory must be real")
    for path in sorted(source_directory.glob("*.swift")):
        if path.is_symlink() or not path.is_file():
            raise ValueError("Candidate native source must be a regular file")
        source = path.read_bytes()
        sequence = list(tokens(source.decode("utf-8")))
        stack = []
        pending_class = None
        for index, token in enumerate(sequence):
            if token in {"class", "extension"} and index + 2 < len(sequence) and sequence[index + 2] in {":", "{"}:
                pending_class = sequence[index + 1]
                if token == "class":
                    classes.setdefault(pending_class, []).append(path)
            elif token == "{":
                stack.append(pending_class)
                pending_class = None
            elif token == "}":
                if not stack:
                    raise ValueError("Unbalanced candidate native source")
                stack.pop()
            elif token == "func" and index + 1 < len(sequence) and stack and stack[-1]:
                methods_by_class.setdefault((stack[-1], sequence[index + 1]), []).append(path)
        if stack:
            raise ValueError("Unbalanced candidate native source")
        fingerprints[str(path.relative_to(root))] = hashlib.sha256(source).hexdigest()
    for target in methods:
        suite, method = target.split("/")
        if len(classes.get(suite, [])) != 1 or len(methods_by_class.get((suite, method), [])) != 1:
            raise ValueError("Candidate must define exactly one registered native class and method: " + target)
    return fingerprints


def result_summary(bundle, output):
    try:
        result = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                 "--path", str(bundle), "--compact"],
                                capture_output=True, text=True, timeout=30)
        if result.returncode:
            return {"summaryError": result.stderr.strip()}
        summary = json.loads(result.stdout)
        output.write_text(json.dumps(summary, indent=2) + "\n")
        return summary
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        return {"summaryError": type(error).__name__}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("environment", "smoke", "functional", "accessibility", "batch", "batch-preflight"), default="environment")
    parser.add_argument("--focus", choices=("none", *FOCUSED_TESTS), default="none")
    parser.add_argument("--require-interactive", action="store_true")
    parser.add_argument("--output", type=Path, default=Path(".build/ci/ui"))
    parser.add_argument("--batch", default="")
    parser.add_argument("--registry", type=Path, default=Path(__file__).with_name("ui_batches.json"))
    args = parser.parse_args()
    is_batch = args.mode in {"batch", "batch-preflight"}
    if bool(args.batch) != is_batch:
        parser.error("A batch scope requires exactly one trusted registered batch")
    methods = batch_methods(args.registry, args.batch) if is_batch else []
    if args.focus != "none" and args.mode != "smoke":
        parser.error("A focused diagnostic is only available after the minimal smoke, not in larger scopes.")
    args.output.mkdir(parents=True, exist_ok=True)
    sources = verify_batch_sources(Path.cwd(), methods) if is_batch else {}
    if args.mode == "batch-preflight":
        (args.output / "batch-preflight.json").write_text(json.dumps({
            "batch": args.batch, "selectedMethods": methods, "sourceFiles": sources,
            "registrySHA256": hashlib.sha256(args.registry.read_bytes()).hexdigest(),
            "xctestExecuted": False, "releaseReady": False,
        }, indent=2) + "\n")
        print("Complete trusted native batch found in the candidate source; no build or XCTest executed.")
        return
    report = inspect_environment()
    report.update(mode=args.mode, focus=args.focus, batch=args.batch, selectedMethods=methods, tests=[], releaseReady=False)

    def save():
        (args.output / (args.mode + ".json")).write_text(json.dumps(report, indent=2) + "\n")

    save()
    if (args.require_interactive or args.mode != "environment") and not report["interactivePrerequisites"]:
        raise SystemExit("No ready Aqua/console/developer-tools session. See the environment report; no permission was changed.")
    if args.mode == "environment":
        print("UI prerequisites recorded; this command ran no XCTest and changed no permissions.")
        return
    base = ["xcodebuild", "-project", "WeGit.xcodeproj", "-scheme", "WeGit", "-configuration", "Debug",
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", ".build-app",
            "-parallel-testing-enabled", "NO", "test-without-building"]
    smoke = base + ["-only-testing:WeGitUITests/WeGitUITests/testWelcomeAndCloneForm",
                    "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "60",
                    "-maximum-test-execution-time-allowance", "90",
                    "-resultBundlePath", str(args.output / "smoke.xcresult")]
    result = run_logged(smoke, args.output / "smoke.log", 240)
    summary = result_summary(args.output / "smoke.xcresult", args.output / "smoke-summary.json")
    report["tests"].append({"scope": "smoke", **result, "summary": summary})
    save()
    if result["timedOut"] or result["exitCode"]:
        raise SystemExit("Minimal XCTest failed. Retain this result; do not run a larger suite in this environment.")
    verify_summary(summary, smoke=True)
    print("One minimal native UI test actually executed and passed.", flush=True)
    if args.focus != "none":
        name = "focused-" + args.focus
        result = run_logged(base + ["-only-testing:WeGitUITests/" + FOCUSED_TESTS[args.focus],
                                   "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "120",
                                   "-maximum-test-execution-time-allowance", "180",
                                   "-resultBundlePath", str(args.output / (name + ".xcresult"))],
                            args.output / (name + ".log"), 300)
        summary = result_summary(args.output / (name + ".xcresult"), args.output / (name + "-summary.json"))
        report["tests"].append({"scope": name, **result, "summary": summary})
        save()
        if result["timedOut"] or result["exitCode"]:
            raise SystemExit("Focused native diagnostic failed; retain its log and xcresult.")
        verify_summary(summary, smoke=True)
        print("One allowlisted native diagnostic actually executed and passed:", args.focus, flush=True)
    elif args.mode == "batch":
        result = run_logged(base + ["-only-testing:WeGitUITests/" + method for method in methods] + [
                                "-test-timeouts-enabled", "YES",
                                "-default-test-execution-time-allowance", "180",
                                "-maximum-test-execution-time-allowance", "300",
                                "-resultBundlePath", str(args.output / (args.batch + ".xcresult"))],
                            args.output / (args.batch + ".log"), min(5400, 300 * len(methods) + 240))
        summary = result_summary(args.output / (args.batch + ".xcresult"), args.output / (args.batch + "-summary.json"))
        report["tests"].append({"scope": args.batch, "selectedMethods": methods, **result, "summary": summary})
        save()
        if result["timedOut"] or result["exitCode"]:
            raise SystemExit("Native batch failed; retain the complete selected set, log and xcresult.")
        verify_batch_summary(summary, methods)
    elif args.mode != "smoke":
        selection = (["-only-testing:WeGitUITests/LayoutTests/testAccessibilityAuditInBothThemes"]
                     if args.mode == "accessibility" else [
                         "-skip-testing:WeGitUITests/LayoutTests/testAccessibilityAuditInBothThemes",
                         "-skip-testing:WeGitUITests/ManualAccessibilitySession",
                     ])
        result = run_logged(base + selection + [
                                "-test-timeouts-enabled", "YES",
                                "-default-test-execution-time-allowance", "300",
                                "-maximum-test-execution-time-allowance", "2700",
                                "-resultBundlePath", str(args.output / (args.mode + ".xcresult"))],
                            args.output / (args.mode + ".log"), 5400)
        summary = result_summary(args.output / (args.mode + ".xcresult"), args.output / (args.mode + "-summary.json"))
        report["tests"].append({"scope": args.mode, **result, "summary": summary})
        save()
        if result["timedOut"] or result["exitCode"]:
            raise SystemExit("Native suite failed; inspect the archived log and xcresult.")
        verify_summary(summary)
    print("Native UI scope passed:", args.mode, "(release sign-off remains separate).")


if __name__ == "__main__":
    main()
