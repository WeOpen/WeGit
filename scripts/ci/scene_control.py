#!/usr/bin/env python3
"""Run selected independent SwiftUI/XCTest controls, without changing OS permissions."""
from datetime import datetime, timezone
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys

from ui_probe import inspect_environment, result_summary, run_logged, verify_summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controls", default="defaultargs,marker,language")
    args = parser.parse_args()
    schemes = {"bare": "BareControl", "single": "SingleControl", "group": "GroupControl",
               "async": "AsyncControl", "workspace": "WorkspaceControl",
               "appkit": "AppKitControl", "hosting": "HostingControl",
               "defaultargs": "DefaultArgumentsControl", "marker": "MarkerControl",
               "language": "LanguageControl"}
    products = {"bare": ("BareControl", "BareControlTests"),
                "single": ("SingleControl", "SingleControlTests"),
                "group": ("GroupControl", "GroupControlTests"),
                "async": ("AsyncBareApp", "AsyncLaunchTests"),
                "workspace": ("WorkspaceBareApp", "WorkspaceLaunchTests"),
                "appkit": ("AppKitBareApp", "AppKitLaunchTests"),
                "hosting": ("HostingBareApp", "HostingLaunchTests"),
                "defaultargs": ("DefaultArgumentsApp", "DefaultArgumentsTests"),
                "marker": ("MarkerApp", "MarkerTests"),
                "language": ("LanguageApp", "LanguageTests")}
    selection = args.controls.split(",")
    if not selection or len(selection) != len(set(selection)) or any(key not in schemes for key in selection):
        parser.error("Select unique controls from " + ",".join(schemes))
    output = Path(".build/ci/scene-controls")
    output.mkdir(parents=True, exist_ok=True)
    report = {"date": datetime.now(timezone.utc).isoformat(), "kind": "isolated-scene-controls",
              "environment": inspect_environment(), "controls": [], "releaseReady": False}

    def save():
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    save()
    if not report["environment"]["interactivePrerequisites"]:
        raise SystemExit("The control requires a ready Aqua/console/developer-tools session; no permission was changed.")
    project = "Tools/SceneLaunchControl/SceneLaunchControl.xcodeproj"
    failed = False
    # These are independent one-test controls, not a larger WeGit suite after a failed smoke.
    for key in selection:
        scheme = schemes[key]
        base = ["xcodebuild", "-project", project, "-scheme", scheme, "-configuration", "Debug",
                "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", ".build/scene-controls",
                "-parallel-testing-enabled", "NO"]
        item = {"scheme": scheme}
        report["controls"].append(item)
        item["build"] = run_logged(base + ["build-for-testing"], output / (scheme + "-build.log"), 300)
        save()
        if item["build"]["exitCode"] or item["build"]["timedOut"]:
            failed = True
            continue
        signed = {}
        for role, name in zip(("application", "runner"), products[key]):
            suffix = ".app" if role == "application" else "-Runner.app"
            path = Path(".build/scene-controls/Build/Products/Debug") / (name + suffix)
            result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(path)],
                                    capture_output=True, timeout=15)
            try:
                entitlements = plistlib.loads(result.stdout)
                signed[role] = {"readSucceeded": result.returncode == 0,
                                "sandboxed": bool(entitlements.get("com.apple.security.app-sandbox", False))}
            except (ValueError, plistlib.InvalidFileException):
                signed[role] = {"readSucceeded": False, "sandboxed": None}
        item["signatureMetadata"] = signed
        bundle = output / (scheme + ".xcresult")
        item["test"] = run_logged(base + ["test-without-building", "-test-timeouts-enabled", "YES",
                                         "-default-test-execution-time-allowance", "60",
                                         "-maximum-test-execution-time-allowance", "90",
                                         "-resultBundlePath", str(bundle)],
                                  output / (scheme + "-test.log"), 240)
        item["summary"] = result_summary(bundle, output / (scheme + "-summary.json"))
        try:
            verify_summary(item["summary"], smoke=True)
            item["passed"] = item["test"]["exitCode"] == 0 and not item["test"]["timedOut"]
        except ValueError:
            item["passed"] = False
        failed = failed or not item["passed"]
        save()
        print(scheme, "passed=" + str(item["passed"]),
              {name: item["summary"].get(name) for name in ("totalTestCount", "passedTests", "failedTests", "skippedTests")},
              flush=True)
    report["result"] = "failed" if failed else "passed"
    save()
    print("Independent scene controls:", report["result"], "(not WeGit product acceptance)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
