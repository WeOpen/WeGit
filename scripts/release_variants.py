#!/usr/bin/env python3
"""Validate three already-built packages and prepare an unsigned update payload.

This never creates keys, releases, tags or uploads. Signing requires the separate
system-CryptoKit helper and an explicitly supplied existing private key.
"""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat

VARIANTS = {"universal": ["arm64", "x86_64"], "applesilicon": ["arm64"], "intel": ["x86_64"]}
DOWNLOAD_LIMIT = 30 * 1024 * 1024
INSTALL_LIMIT = 60 * 1024 * 1024
METADATA_LIMIT = 256 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_regular(path, limit=METADATA_LIMIT):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= limit,
            "Missing, linked or oversized file: " + path.name)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as handle:
        before = os.fstat(handle.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_size <= limit, "Invalid input file")
        data = handle.read(limit + 1)
        after = os.fstat(handle.fileno())
        require(len(data) == before.st_size and len(data) <= limit
                and (before.st_ino, before.st_dev, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                == (after.st_ino, after.st_dev, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                "Input changed during reading: " + path.name)
    return data


def digest(path, limit=DOWNLOAD_LIMIT):
    result = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as handle:
        require(stat.S_ISREG(os.fstat(handle.fileno()).st_mode), "Expected a regular input")
        total = 0
        for chunk in iter(lambda: handle.read(64 * 1024), b""):
            total += len(chunk)
            require(total <= limit, "Input exceeds its byte limit: " + path.name)
            result.update(chunk)
    return result.hexdigest()


def validate(directory, variant, *, manifest_name="manifest.json", allow_legacy=False):
    require(variant in VARIANTS, "Unknown package variant")
    require(Path(manifest_name).name == manifest_name, "Manifest must be a basename")
    path = directory / manifest_name
    manifest_bytes = read_regular(path)
    report = json.loads(manifest_bytes)
    require(isinstance(report, dict), "Expected a package manifest object")
    legacy = allow_legacy and variant == "universal" and "variant" not in report
    require((legacy or report.get("variant") == variant) and report.get("architectures") == VARIANTS[variant],
            "Package variant mismatch")
    if not legacy:
        require(report.get("distributionVariantSource") == "info-plist"
                or (variant == "universal" and report.get("distributionVariantSource") == "legacy-universal"),
                "Package must retain the inspected Info.plist variant source")
    tag = report.get("releaseTag", "")
    require(isinstance(tag, str) and re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?", tag),
            "Expected an explicit versioned release tag")
    require(tag[1:].split("-")[0] == report.get("version"), "Version and tag differ")
    basename = "WeGit-" + tag[1:] + "-macos-" + variant + "-adhoc"
    require(manifest_name in ("manifest.json", basename + ".manifest.json"), "Unexpected manifest filename")
    require(report.get("archive") == basename + ".dmg", "Unexpected package filename")
    image = directory / report["archive"]
    require(image.is_file() and not image.is_symlink(), "Missing or linked image")
    require(report.get("archiveFormat") == "dmg" and 512 <= image.stat().st_size <= DOWNLOAD_LIMIT,
            "DMG image size or format is invalid")
    with image.open("rb") as handle:
        handle.seek(-512, 2)
        require(handle.read(4) == b"koly", "Expected a verified UDIF image")
    require(report.get("imageBytes") == image.stat().st_size and report.get("archiveSHA256") == digest(image),
            "Image bytes differ from package evidence")
    require(type(report.get("bundleBytes")) is int and 0 < report["bundleBytes"] <= INSTALL_LIMIT,
            "Installed application exceeds its original budget")
    require(report.get("workspaceDirty") is False and re.fullmatch(r"[0-9a-f]{40}([0-9a-f]{24})?", report.get("gitCommit", "")),
            "Release packages require one clean source commit")
    if not legacy or "sourceFiles" in report:
        sources = report.get("sourceFiles")
        require(isinstance(sources, dict) and sources and all(isinstance(name, str) and isinstance(checksum, str)
                and re.fullmatch(r"[0-9a-f]{64}", checksum) for name, checksum in sources.items()),
                "Exact source input hashes are required")
    require(report.get("bundleIdentifier") == "com.willxue.wegit" and report.get("mode") == "adhoc"
            and report.get("signing") == "ad-hoc" and report.get("notarized") is False,
            "Unsupported or misleading signing identity")
    require(report.get("minimumSystemVersion") == "26.0", "Expected the frozen macOS minimum")
    if not legacy or "buildVersion" in report:
        require(isinstance(report.get("buildVersion"), str) and re.fullmatch(r"[1-9][0-9]{0,18}", report["buildVersion"]),
                "Missing positive build identity")
    require(all(report.get("diskImageVerification", {}).get(key) is True for key in
                ("hdiutilVerified", "readOnlyMountVerified", "applicationsShortcutVerified")),
            "Actual image verification is required")
    binaries = report.get("binaries", {})
    require({"Contents/MacOS/WeGit", "Contents/Helpers/WeGitAskPass"}.issubset(binaries), "Missing executable evidence")
    for value in binaries.values():
        require(isinstance(value, dict), "Invalid executable evidence")
        require(value.get("architectures") == VARIANTS[variant], "Embedded executable variant differs")
        minimums = value.get("minimumSystemVersions", {})
        require(set(minimums) == set(VARIANTS[variant]), "Missing embedded deployment evidence")
        for minimum in minimums.values():
            require(isinstance(minimum, str) and re.fullmatch(r"\d+\.\d+(\.\d+)?", minimum) and tuple(map(int, minimum.split("."))) <= (26, 0, 0),
                    "An executable requires a newer operating system")
    checksum = read_regular(directory / (image.name + ".sha256"), limit=4096).decode("utf-8").split()
    require(checksum == [report["archiveSHA256"], image.name], "Checksum must name only this exact image")
    if legacy:
        return report, path
    named_manifest = directory / (basename + ".manifest.json")
    require(read_regular(named_manifest) == manifest_bytes,
            "Versioned package manifest differs")
    alias = directory / "manifest.json"
    if variant == "universal" and alias.exists():
        require(read_regular(alias) == manifest_bytes, "Universal compatibility manifest differs")
    return report, named_manifest


def validate_set(directories, *, manifest_names=None, expected_tag=None, expected_commit=None):
    require(set(directories) == set(VARIANTS), "All three variants are required")
    if manifest_names is None and len({directory.resolve() for directory in directories.values()}) == 1:
        root = directories["universal"]
        alias = json.loads(read_regular(root / "manifest.json"))
        require(isinstance(alias, dict) and isinstance(alias.get("releaseTag"), str), "Invalid flat package index")
        manifest_names = {variant: "WeGit-" + alias["releaseTag"][1:] + "-macos-" + variant + "-adhoc.manifest.json"
                          for variant in VARIANTS}
    if manifest_names is not None:
        require(set(manifest_names) == set(VARIANTS), "All three package manifest names are required")
    packages = {variant: validate(directory, variant,
                manifest_name=manifest_names[variant] if manifest_names else "manifest.json")
                for variant, directory in directories.items()}
    first = packages["universal"][0]
    for report, _ in packages.values():
        for field in ("version", "releaseTag", "buildVersion", "gitCommit", "sourceFiles", "minimumSystemVersion"):
            require(report.get(field) == first.get(field), "Cross-version/build/source package mixture: " + field)
        require(expected_tag is None or report["releaseTag"] == expected_tag, "Package tag does not match requested release")
        require(expected_commit is None or report["gitCommit"] == expected_commit, "Package source does not match resolved tag")
    return packages


def artifact_metadata(report, manifest_path):
    base = "https://github.com/WeOpen/WeGit/releases/download/" + report["releaseTag"] + "/"
    return {"variant": report["variant"], "url": base + report["archive"], "sha256": report["archiveSHA256"],
            "downloadBytes": report["imageBytes"], "installedBytes": report["bundleBytes"],
            "manifestURL": base + manifest_path.name, "manifestSHA256": digest(manifest_path, METADATA_LIMIT)}


def prepare(directories, key_id, release_notes, now=None):
    require(re.fullmatch(r"[A-Za-z0-9._-]{1,80}", key_id), "Expected an explicit public-key ID")
    require(len(release_notes.encode()) <= 64 * 1024, "Release notes exceed their limit")
    packages = validate_set(directories)
    first = packages["universal"][0]
    now = now or datetime.now(timezone.utc)
    version = first["releaseTag"][1:]
    payload = {
        "format": 1, "version": version, "tag": first["releaseTag"],
        "channel": "candidate" if "-" in version else "stable", "build": int(first["buildVersion"]),
        "sourceCommit": first["gitCommit"], "minimumOS": first["minimumSystemVersion"],
        "publishedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expiresAt": (now + timedelta(days=14)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "keyID": key_id, "draft": False, "releaseNotes": release_notes, "artifacts": [],
    }
    for variant in VARIANTS:
        report, manifest_path = packages[variant]
        payload["artifacts"].append(artifact_metadata(report, manifest_path))
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    require(len(canonical) <= METADATA_LIMIT * 3 // 4 - 1024, "Signed metadata would exceed its envelope limit")
    return canonical


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for variant in VARIANTS:
        parser.add_argument("--" + variant, type=Path, required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--release-notes", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    data = prepare({variant: getattr(args, variant).resolve() for variant in VARIANTS},
                   args.key_id, args.release_notes.read_text())
    with args.output.open("xb") as handle:
        handle.write(data)
    print("Validated all three packages; unsigned canonical payload written to " + str(args.output))


if __name__ == "__main__":
    main()
