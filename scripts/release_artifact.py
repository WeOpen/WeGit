#!/usr/bin/env python3
"""Build and verify an architecture-specific DMG, retaining exact bundle and size evidence."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

from build_provenance import verify_bundle

VARIANTS = {"universal": ["arm64", "x86_64"], "applesilicon": ["arm64"], "intel": ["x86_64"]}
MINIMUM_SYSTEM = "26.0"
BUDGETS = {"imageBytes": 30 * 1024 * 1024, "bundleBytes": 60 * 1024 * 1024}
MACHO_MAGIC = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
               b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(arguments):
    return subprocess.run(arguments, text=True, capture_output=True, check=True).stdout


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_bundle(root, app, variant="universal"):
    expected_architectures = VARIANTS[variant]
    verify_bundle(root, app)
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if os.environ.get("WEGIT_RELEASE_TAG"):
        require(info.get("WeGitReleaseVersion") == os.environ["WEGIT_RELEASE_TAG"].removeprefix("v"),
                "Installed release version must retain the full reviewed tag version")
    installed_variant = info.get("WeGitDistributionVariant")
    require(installed_variant == variant or (installed_variant is None and variant == "universal"),
            "Info.plist distribution variant must match the packaged CPU variant")
    require(info.get("LSMinimumSystemVersion") == MINIMUM_SYSTEM, "Expected macOS 26 minimum system version")
    receipt = json.loads((app / "Contents/Resources/build-source.json").read_text())
    require(sorted(receipt.get("architectures", [])) == expected_architectures, "Build receipt must match the selected CPU variant")
    binaries = {}
    bundle_bytes = 0
    for path in sorted(app.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        bundle_bytes += path.stat().st_size
        with path.open("rb") as handle:
            magic = handle.read(4)
        if magic not in MACHO_MAGIC:
            continue
        architectures = sorted(command(["/usr/bin/lipo", "-archs", str(path)]).split())
        require(architectures == expected_architectures, "Wrong executable architecture in bundle: " + str(path.relative_to(app)))
        minimums = {}
        for architecture in architectures:
            build = command(["/usr/bin/xcrun", "vtool", "-show-build", "-arch", architecture, str(path)])
            version = re.search(r"^\s*minos\s+(\d+\.\d+(?:\.\d+)?)\s*$", build, re.MULTILINE)
            require(version is not None, "Missing deployment version: " + str(path.relative_to(app)))
            require(tuple(map(int, version[1].split("."))) <= (26, 0, 0), "Executable requires macOS newer than 26: " + str(path.relative_to(app)))
            minimums[architecture] = version[1]
        binaries[str(path.relative_to(app))] = {"sha256": sha256(path), "architectures": architectures, "minimumSystemVersions": minimums}
    required_binaries = {"Contents/MacOS/WeGit", "Contents/Helpers/WeGitAskPass"}
    if any(name.startswith("WeGitUpdater/") for name in receipt.get("sourceFiles", {})):
        required_binaries.add("Contents/Helpers/WeGitUpdater")
    require(required_binaries.issubset(binaries), "App or declared helper executable missing")
    require(bundle_bytes <= BUDGETS["bundleBytes"], "Application exceeds the 60 MiB release bundle budget")
    return {
        "variant": variant, "distributionVariantSource": "info-plist" if installed_variant is not None else "legacy-universal",
        "architectures": expected_architectures, "minimumSystemVersion": MINIMUM_SYSTEM,
        "bundleBytes": bundle_bytes, "binaries": binaries,
        "buildReceiptSHA256": sha256(app / "Contents/Resources/build-source.json"),
        "startupIconSHA256": sha256(app / "Contents/Resources/AppIcon.icns"),
    }


def check_udif(path):
    require(path.stat().st_size >= 512, "Disk image is truncated")
    with path.open("rb") as handle:
        handle.seek(-512, os.SEEK_END)
        require(handle.read(4) == b"koly", "Expected a UDIF disk image, not a renamed ZIP")


def source_files(root):
    paths = [root / "Package.swift", root / "project.yml", root / "LICENSE"]
    for name in ("WeGitCore", "WeGit", "WeGitAskPass", "WeGitUpdater", "WeGitTests", "WeGitUITests", "WeGitPerformanceTests", "Benchmarks", "scripts"):
        paths.extend(path for path in (root / name).rglob("*") if path.is_file() and path.suffix in
                     (".swift", ".c", ".h", ".sh", ".py", ".entitlements", ".strings", ".stringsdict"))
    return {str(path.relative_to(root)): sha256(path) for path in sorted(paths)}


def create_image(root, app, output, archive, mode, variant="universal"):
    original = inspect_bundle(root, app, variant)
    stage = output / "dmg-root"
    stage.mkdir()
    command(["/usr/bin/ditto", str(app), str(stage / "WeGit.app")])
    (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    creation = command(["/usr/bin/hdiutil", "create", "-volname", "WeGit " + info["CFBundleShortVersionString"],
                        "-fs", "HFS+", "-srcfolder", str(stage), "-format", "UDZO", "-imagekey", "zlib-level=9", str(archive)])
    (output / "dmg-create.log").write_text(creation)
    if mode == "notarize":
        result = json.loads(command(["/usr/bin/xcrun", "notarytool", "submit", str(archive),
                                     "--keychain-profile", os.environ["WEGIT_NOTARY_PROFILE"], "--wait", "--output-format", "json"]))
        (output / "dmg-notarization.json").write_text(json.dumps(result, indent=2) + "\n")
        require(result.get("status") == "Accepted", "Disk image notarization was not accepted")
        command(["/usr/bin/xcrun", "stapler", "staple", str(archive)])
        command(["/usr/bin/xcrun", "stapler", "validate", str(archive)])
    check_udif(archive)
    verification = command(["/usr/bin/hdiutil", "verify", str(archive)])
    (output / "dmg-verify.log").write_text(verification)
    with tempfile.TemporaryDirectory(prefix="dmg-mount-", dir=output) as mount_directory:
        mount = Path(mount_directory)
        attached = False
        try:
            command(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(archive)])
            attached = True
            require({path.name for path in mount.iterdir() if not path.name.startswith(".")} == {"WeGit.app", "Applications"},
                    "DMG must contain only WeGit.app and an Applications shortcut")
            require((mount / "Applications").is_symlink() and os.readlink(mount / "Applications") == "/Applications",
                    "DMG Applications shortcut is invalid")
            mounted = inspect_bundle(root, mount / "WeGit.app", variant)
            require(mounted == original, "Mounted application does not match the packaged application")
        finally:
            if attached:
                subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], capture_output=True, check=True)
    image_bytes = archive.stat().st_size
    require(image_bytes <= BUDGETS["imageBytes"], "Disk image exceeds the 30 MiB release download budget")
    digest = sha256(archive)
    (output / (archive.name + ".sha256")).write_text(digest + "  " + archive.name + "\n")
    report = {
        "createdAt": datetime.now(timezone.utc).isoformat(), "version": info["CFBundleShortVersionString"],
        "bundleIdentifier": info["CFBundleIdentifier"], "buildVersion": info["CFBundleVersion"], "mode": mode,
        "notarized": mode == "notarize", "signing": "ad-hoc" if mode in ("preview", "adhoc") else "developer-id",
        "releaseTag": os.environ.get("WEGIT_RELEASE_TAG"), "gitCommit": command(["git", "-C", str(root), "rev-parse", "--verify", "HEAD"]).strip(),
        "workspaceDirty": bool(command(["git", "-C", str(root), "status", "--porcelain"])),
        "archive": archive.name, "archiveFormat": "dmg", "archiveSHA256": digest,
        "imageBytes": image_bytes, "budgets": BUDGETS, **original, "sourceFiles": source_files(root),
        "diskImageVerification": {"hdiutilVerified": True, "readOnlyMountVerified": True, "applicationsShortcutVerified": True},
    }
    manifest_bytes = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    (output / "manifest.json").write_text(manifest_bytes)
    (output / (archive.stem + ".manifest.json")).write_text(manifest_bytes)
    print(f"{variant} DMG verified: {image_bytes:,} bytes download; {original['bundleBytes']:,} bytes installed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source-root", "app", "output", "archive"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--mode", choices=("preview", "adhoc", "sign", "notarize"), required=True)
    parser.add_argument("--variant", choices=tuple(VARIANTS), default="universal")
    args = parser.parse_args()
    create_image(args.source_root.resolve(), args.app.resolve(), args.output.resolve(), args.archive.resolve(), args.mode, args.variant)


if __name__ == "__main__":
    main()
