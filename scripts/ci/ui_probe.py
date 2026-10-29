#!/usr/bin/env python3
"""Read UI prerequisites and bound native XCTest runs without changing OS permissions."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import time

FOCUSED_TESTS = {
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
    "search-keyboard": "InterfacePolishTests/testSearchClearKeepsInputFocusAndKeyboardCommitInBothThemes",
    "sync-recovery": "WeGitUITests/testLostPushReplyRestoresVerificationAfterLocalHeadMoves",
    "diff-options": "WeGitUITests/testDiffReadingOptionsAndFilterEmptyState",
    "large-diff": "WeGitUITests/testLargeDiffSummaryPagingAndSelectionReset",
    "rebase-conflicts": "WorkflowRecoveryTests/testPullRebaseHandlesTwoConflictRoundsAndAbort",
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
    parser.add_argument("--mode", choices=("environment", "smoke", "functional", "accessibility"), default="environment")
    parser.add_argument("--focus", choices=("none", *FOCUSED_TESTS), default="none")
    parser.add_argument("--require-interactive", action="store_true")
    parser.add_argument("--output", type=Path, default=Path(".build/ci/ui"))
    args = parser.parse_args()
    if args.focus != "none" and args.mode != "smoke":
        parser.error("A focused diagnostic is only available after the minimal smoke, not in larger scopes.")
    args.output.mkdir(parents=True, exist_ok=True)
    report = inspect_environment()
    report.update(mode=args.mode, focus=args.focus, tests=[], releaseReady=False)

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
    elif args.mode != "smoke":
        selection = (["-only-testing:WeGitUITests/LayoutTests/testAccessibilityAuditInBothThemes"]
                     if args.mode == "accessibility" else [
                         "-skip-testing:WeGitUITests/LayoutTests/testAccessibilityAuditInBothThemes",
                         "-skip-testing:WeGitUITests/ManualAccessibilitySession",
                     ])
        result = run_logged(base + selection + ["-resultBundlePath", str(args.output / (args.mode + ".xcresult"))],
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
