#!/usr/bin/env python3
"""Record application inputs at build time and reject stale Release packages."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess


def source_files(root: Path) -> dict[str, str]:
    paths = [root / name for name in (
        "Package.swift", "project.yml", "LICENSE", "WeGit.xcodeproj/project.pbxproj",
        "scripts/build_provenance.py",
    )]
    for directory in ("WeGitCore", "WeGit", "WeGitAskPass"):
        paths.extend(path for path in (root / directory).rglob("*")
                     if path.is_file() and path.name != ".DS_Store")
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(paths)}


def write_receipt(root: Path, output: Path) -> None:
    report = {
        "format": 1,
        "builtAt": datetime.now(timezone.utc).isoformat(),
        "configuration": os.environ.get("CONFIGURATION"),
        "bundleIdentifier": os.environ.get("PRODUCT_BUNDLE_IDENTIFIER"),
        "version": os.environ.get("MARKETING_VERSION"),
        "buildVersion": os.environ.get("CURRENT_PROJECT_VERSION"),
        "architectures": os.environ.get("ARCHS", "").split(),
        "xcodeBuild": os.environ.get("XCODE_PRODUCT_BUILD_VERSION"),
        "swiftOptimization": os.environ.get("SWIFT_OPTIMIZATION_LEVEL"),
        "swiftConditions": os.environ.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""),
        "sourceFiles": source_files(root),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")


def verify_bundle(root: Path, bundle: Path) -> None:
    receipt = bundle / "Contents/Resources/build-source.json"
    if not receipt.is_file():
        raise SystemExit("Release build has no source receipt. Rebuild with scripts/build.sh Release.")
    report = json.loads(receipt.read_text())
    if report.get("format") != 1 or report.get("configuration") != "Release":
        raise SystemExit("Only a Release build with a supported source receipt may be packaged.")
    conditions = set(report.get("swiftConditions", "").split())
    if conditions.intersection({"DEBUG", "WEGIT_PERFORMANCE"}):
        raise SystemExit("Refusing to package a build with debug or performance test entry points.")
    expected = report.get("sourceFiles", {})
    current = source_files(root)
    changed = sorted(name for name in set(expected) | set(current) if expected.get(name) != current.get(name))
    if changed:
        raise SystemExit("Release build does not match current application sources: "
                         + ", ".join(changed[:8]) + ". Rebuild with scripts/build.sh Release.")
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    for key, field in (("CFBundleIdentifier", "bundleIdentifier"),
                       ("CFBundleShortVersionString", "version"), ("CFBundleVersion", "buildVersion")):
        if info.get(key) != report.get(field):
            raise SystemExit("Build receipt does not match bundle metadata: " + key)
    if any(path.name == "WeGitTestGit" or path.suffix == ".xctest" for path in bundle.rglob("*")):
        raise SystemExit("Refusing to package native test fixtures or test bundles.")
    result = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)],
                            capture_output=True, check=True)
    entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    unsafe = [key for key, value in entitlements.items() if value and (
        key in ("com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation")
        or key.startswith("com.apple.security.temporary-exception."))]
    if unsafe:
        raise SystemExit("Release still has automation/debug signing entitlements: " + ", ".join(unsafe)
                         + ". Rebuild with scripts/build.sh Release before packaging.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True, type=Path)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--output", type=Path)
    action.add_argument("--verify-bundle", type=Path)
    arguments = parser.parse_args()
    root = arguments.source_root.resolve()
    if arguments.output:
        write_receipt(root, arguments.output)
    else:
        verify_bundle(root, arguments.verify_bundle)
        print("Release source receipt and bundle metadata verified.")


if __name__ == "__main__":
    main()
