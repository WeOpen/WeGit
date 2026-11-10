#!/usr/bin/env python3
"""Validate exact-source release gates and prepare verifiable, non-notarized assets."""
import argparse
import hashlib
from itertools import islice
import json
import os
from pathlib import Path
import re
import subprocess
import stat
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_variants import (DOWNLOAD_LIMIT, METADATA_LIMIT, VARIANTS, artifact_metadata,
                              read_regular, validate as validate_variant, validate_set)

TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:alpha|beta|rc)\.(?:0|[1-9][0-9]*)))?")
SHA = re.compile(r"[0-9a-f]{40}([0-9a-f]{24})?")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def parse_tag(tag):
    match = TAG.fullmatch(tag)
    require(match is not None, "Use an existing vX.Y.Z or vX.Y.Z-{alpha,beta,rc}.N tag")
    return ".".join(match.group(i) for i in (1, 2, 3)), match.group(4) is not None


def api(repo, suffix, payload=None):
    command = ["gh", "api", "repos/" + repo + "/" + suffix]
    if payload is not None:
        command += ["--method", "POST", "--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


def validate_run(run, workflow_id, commit, jobs, required_jobs, events=("push", "workflow_dispatch")):
    require(run["workflow_id"] == workflow_id, "Validation came from a different workflow")
    require(run["head_sha"] == commit, "Validation does not match the tagged source")
    require(run["head_branch"] == "main", "Validation must run on trusted main")
    require(run["event"] in events, "PR results cannot authorize a release")
    require(run["status"] == "completed" and run["conclusion"] == "success", "Validation did not complete successfully")
    by_name = {job["name"]: job for job in jobs}
    for name in required_jobs:
        require(name in by_name and by_name[name]["conclusion"] == "success", "Required job missing, skipped or failed: " + name)


def resolve(repo, tag, acceptance_id):
    _, prerelease = parse_tag(tag)
    obj = api(repo, "git/ref/tags/" + tag)["object"]
    for _ in range(8):
        if obj["type"] == "commit":
            break
        require(obj["type"] == "tag", "Tag does not resolve to a commit")
        obj = api(repo, "git/tags/" + obj["sha"])["object"]
    commit = obj["sha"]
    require(obj["type"] == "commit" and SHA.fullmatch(commit), "Invalid release commit")
    comparison = api(repo, "compare/" + commit + "...main")
    require(comparison["merge_base_commit"]["sha"] == commit, "Tag must point to reviewed main history")
    workflow = api(repo, "actions/workflows/verify.yml")
    candidates = api(repo, "actions/workflows/verify.yml/runs?head_sha=" + commit + "&per_page=100")["workflow_runs"]
    ci = None
    for run in candidates:
        jobs = api(repo, "actions/runs/" + str(run["id"]) + "/jobs?filter=latest&per_page=100")["jobs"]
        try:
            validate_run(run, workflow["id"], commit, jobs, ["Repository policy", "Native macOS"])
            ci = run["id"]
            break
        except ValueError:
            pass
    require(ci is not None, "No successful main CI with both required jobs exists for this tag SHA")
    if not prerelease or acceptance_id:
        require(acceptance_id.isdigit() and int(acceptance_id) > 0, "Stable tags require a full acceptance run ID")
        expected = api(repo, "actions/workflows/acceptance.yml")
        run = api(repo, "actions/runs/" + acceptance_id)
        jobs = api(repo, "actions/runs/" + acceptance_id + "/jobs?filter=latest&per_page=100")["jobs"]
        validate_run(run, expected["id"], commit, jobs, ["Full acceptance"], events=("workflow_dispatch",))
    else:
        acceptance_id = ""
    return {"commit": commit, "prerelease": str(prerelease).lower(), "ci_run": str(ci), "acceptance_run": acceptance_id}


def validate_package(directory, tag, commit, *, variant=None, manifest_name="manifest.json"):
    """Read one package, including the pre-v2 Universal manifest schema."""
    version, _ = parse_tag(tag)
    require(isinstance(commit, str) and SHA.fullmatch(commit), "Invalid release commit")
    initial = json.loads(read_regular(directory / manifest_name))
    require(isinstance(initial, dict), "Expected a package manifest object")
    selected = variant or initial.get("variant", "universal")
    report, _ = validate_variant(directory, selected, manifest_name=manifest_name, allow_legacy=True)
    require(report["gitCommit"] == commit, "Package commit does not match resolved tag")
    require(report["version"] == version and report["releaseTag"] == tag, "App version or package tag mismatch")
    return report


def validate_packages(directory, tag, commit, *, variant_directories=None):
    """Load exactly three modern packages, or one explicit pre-v2 Universal input.

    Input can be a flat prepared/upload directory, a directory of package runs,
    or an explicit variant-to-directory mapping. V1 Universal delivery can carry
    either package schema. V2+ and partial three-variant sets never fall back.
    """
    version, _ = parse_tag(tag)
    require(isinstance(commit, str) and SHA.fullmatch(commit), "Invalid release commit")
    if variant_directories is not None:
        return validate_set(variant_directories, expected_tag=tag, expected_commit=commit), False
    names = {variant: f"WeGit-{tag[1:]}-macos-{variant}-adhoc.manifest.json" for variant in VARIANTS}
    alias = directory / "manifest.json"
    if int(version.split(".")[0]) < 2 and alias.exists() and not any((directory / names[variant]).exists() for variant in ("applesilicon", "intel")):
        report = validate_package(directory, tag, commit)
        require(report.get("variant", "universal") == "universal", "V1 single-package delivery must remain Universal")
        return {"universal": (report, alias)}, True
    if any((directory / name).exists() for name in names.values()):
        return validate_set({variant: directory for variant in VARIANTS}, manifest_names=names,
                            expected_tag=tag, expected_commit=commit), False
    if alias.exists():
        report = validate_package(directory, tag, commit)
        require("variant" not in report and int(version.split(".")[0]) < 2,
                "A modern release requires Universal, Apple Silicon and Intel packages")
        return {"universal": (report, alias)}, True
    entries = list(islice(directory.iterdir(), 65))
    require(len(entries) <= 64, "Package input directory exceeds its entry limit")
    candidates = [path for path in entries if path.is_dir() and not path.is_symlink()
                  and (path / "manifest.json").is_file()]
    require(len(candidates) == 3, "Expected exactly three package directories")
    directories = {}
    for path in candidates:
        report = json.loads(read_regular(path / "manifest.json"))
        require(isinstance(report, dict) and report.get("variant") in VARIANTS, "Invalid package variant")
        require(report["variant"] not in directories, "Duplicate package variant")
        directories[report["variant"]] = path
    return validate_set(directories, expected_tag=tag, expected_commit=commit), False


def release_metadata(packages, legacy, repo, tag, commit, ci_run, acceptance_run):
    version, prerelease = parse_tag(tag)
    require(isinstance(ci_run, str) and ci_run.isdigit() and int(ci_run) > 0, "Expected a positive CI run ID")
    require(not acceptance_run or (isinstance(acceptance_run, str) and acceptance_run.isdigit()
                                  and int(acceptance_run) > 0), "Invalid acceptance run ID")
    require(prerelease or acceptance_run, "Stable releases require an explicit full acceptance run")
    universal = packages["universal"][0]
    metadata = {"version": version, "tag": tag, "commit": commit, "prerelease": prerelease,
                "platform": "macOS 26+", "architecture": "universal", "architectures": universal["architectures"],
                "signing": "ad-hoc", "notarized": False,
                "archive": universal["archive"], "sha256": universal["archiveSHA256"],
                "ciRun": ci_run, "acceptanceRun": acceptance_run or None}
    if not legacy:
        require(repo == "WeOpen/WeGit", "Modern update artifacts use the fixed WeOpen/WeGit release source")
        metadata.update({"format": 2, "buildVersion": universal["buildVersion"], "build": int(universal["buildVersion"]),
                         "variants": list(VARIANTS), "channel": "candidate" if prerelease else "stable", "artifacts": []})
        for variant in VARIANTS:
            report, manifest_path = packages[variant]
            artifact = artifact_metadata(report, manifest_path)
            artifact.update({"archive": report["archive"], "architectures": report["architectures"], "manifest": manifest_path.name})
            metadata["artifacts"].append(artifact)
    return metadata


def copy_image(source, target, size, checksum):
    """Copy bounded immutable image bytes, checking the copy before it is uploaded."""
    descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    digest = hashlib.sha256()
    count = 0
    with os.fdopen(descriptor, "rb") as handle, target.open("xb") as output:
        info = os.fstat(handle.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_size == size and size <= DOWNLOAD_LIMIT,
                "Source image changed before copying")
        for chunk in iter(lambda: handle.read(64 * 1024), b""):
            count += len(chunk)
            require(count <= size, "Source image grew during copying")
            digest.update(chunk)
            output.write(chunk)
    require(count == size and digest.hexdigest() == checksum, "Copied image does not match package evidence")


def prepare(directory, output, repo, tag, commit, ci_run, acceptance_run, *, variant_directories=None):
    packages, legacy = validate_packages(directory, tag, commit, variant_directories=variant_directories)
    # Freeze the small manifests/checksums before creating output. Copy image bytes
    # separately with an exact size/digest check rather than buffering three DMGs.
    frozen = {}
    for variant, (report, manifest_path) in packages.items():
        data = read_regular(manifest_path)
        require(json.loads(data) == report, "Manifest changed before preparation")
        checksum = read_regular(manifest_path.parent / (report["archive"] + ".sha256"), limit=4096)
        require(checksum.decode("utf-8").split() == [report["archiveSHA256"], report["archive"]], "Checksum changed before preparation")
        frozen[variant] = (data, checksum)
    release_metadata(packages, legacy, repo, tag, commit, ci_run, acceptance_run)
    output.mkdir(parents=True, exist_ok=False)
    for variant, (report, manifest_path) in packages.items():
        copy_image(manifest_path.parent / report["archive"], output / report["archive"], report["imageBytes"], report["archiveSHA256"])
        (output / (report["archive"] + ".sha256")).write_bytes(frozen[variant][1])
        (output / manifest_path.name).write_bytes(frozen[variant][0])
        if legacy and "variant" in report:
            (output / (Path(report["archive"]).stem + ".manifest.json")).write_bytes(frozen[variant][0])
    # The compatibility alias always names the same Universal bytes; named
    # manifests keep Apple Silicon and Intel metadata from colliding with it.
    if not legacy:
        (output / "manifest.json").write_bytes(frozen["universal"][0])
    copied, copied_legacy = validate_packages(output, tag, commit)
    require(copied_legacy == legacy, "Prepared package schema changed")
    metadata = release_metadata(copied, legacy, repo, tag, commit, ci_run, acceptance_run)
    (output / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    downloads = "- macOS 26+, Apple Silicon and Intel (Universal: arm64 / x86_64)."
    manifests = "`manifest.json` and `release.json` describe this exact artifact."
    if not legacy:
        labels = {"universal": "Universal (arm64 / x86_64)", "applesilicon": "Apple Silicon (arm64)", "intel": "Intel (x86_64)"}
        downloads = "\n".join("- " + labels[item["variant"]] + ": [" + item["archive"] + "](" + item["url"] + ")."
                              for item in metadata["artifacts"])
        manifests = "Each DMG has a versioned package manifest and checksum; `release.json` lists all three. `manifest.json` is the Universal compatibility alias."
    note = f"""## 📦 macOS download

{downloads}
- **Ad-hoc signed; no Developer ID; not notarized by Apple.** macOS may block first launch.
- Download the matching DMG and verify its `.sha256` file. Open it and drag WeGit into Applications.
- If macOS says the app is damaged, verify the checksum, then run `xattr -dr com.apple.quarantine /Applications/WeGit.app` for this trusted download. See [Apple's safe-opening guidance](https://support.apple.com/102445).
- Source: `{commit}`. [CI evidence](https://github.com/{repo}/actions/runs/{ci_run}).
- Full acceptance: {('https://github.com/' + repo + '/actions/runs/' + acceptance_run) if acceptance_run else 'Not required for this prerelease; full release acceptance remains separate.'}
- {manifests} The website must link to these exact versioned bytes.
- This draft workflow does not generate the independent updater source signature.

## ✅ Maintainer sign-off before publishing

- Verify the downloaded packages on clean target Macs, installation instructions, data migration and rollback.
- Confirm milestone blockers, Beta feedback and known limitations against the tagged source.
- Review generated change notes below. This workflow only creates a **draft**.

"""
    (output / "release-notes.md").write_text(note)


def checked_upload(directory, repo, tag):
    info = json.loads(read_regular(directory / "release.json"))
    require(isinstance(info, dict) and info.get("tag") == tag, "Artifact release tag mismatch")
    packages, legacy = validate_packages(directory, tag, info.get("commit"))
    expected = release_metadata(packages, legacy, repo, tag, info["commit"], info.get("ciRun"), info.get("acceptanceRun") or "")
    if legacy:
        require(info.get("format") in (None, 1) and "artifacts" not in info, "Legacy metadata cannot masquerade as a modern set")
        require(all(info.get(key) == value for key, value in expected.items()), "Misleading legacy release metadata")
    else:
        require(info == expected, "Incomplete, mixed or misleading three-variant release metadata")
    read_regular(directory / "release-notes.md")
    assets = []
    for report, manifest_path in packages.values():
        assets.extend([report["archive"], report["archive"] + ".sha256", manifest_path.name])
        if legacy and "variant" in report:
            named = Path(report["archive"]).stem + ".manifest.json"
            require(read_regular(directory / named) == read_regular(manifest_path), "Versioned V1 manifest differs")
            assets.append(named)
    if not legacy:
        require(read_regular(directory / "manifest.json") == read_regular(packages["universal"][1]),
                "Universal compatibility manifest is missing or differs")
        assets.append("manifest.json")
    assets.append("release.json")
    require(len(assets) == len(set(assets)), "Duplicate release upload asset")
    return info, assets


def publish(directory, repo, tag):
    info, original_assets = checked_upload(directory, repo, tag)
    # Revalidate server-side gates and tag immediately before the write, then
    # recheck every prepared package and metadata byte after that network read.
    values = resolve(repo, tag, str(info.get("acceptanceRun") or ""))
    require(values["commit"] == info["commit"], "Tag moved after artifact creation")
    checked_info, assets = checked_upload(directory, repo, tag)
    require(checked_info == info and assets == original_assets, "Release metadata changed during server-side validation")
    command = ["gh", "release", "create", tag, "--repo", repo, "--verify-tag", "--draft",
               "--title", "WeGit " + tag[1:], "--notes-file", str(directory / "release-notes.md"), "--generate-notes"]
    if parse_tag(tag)[1]:
        command.append("--prerelease")
    command += [str(directory / name) for name in assets]
    subprocess.run(command, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    resolve_parser = sub.add_parser("resolve")
    resolve_parser.add_argument("--acceptance-run", default="")
    prepare_parser = sub.add_parser("prepare")
    prepare_parser.add_argument("--directory", type=Path, required=True)
    prepare_parser.add_argument("--variant-directory", action="append", default=[], metavar="VARIANT=PATH")
    prepare_parser.add_argument("--output", type=Path, required=True)
    prepare_parser.add_argument("--commit", required=True)
    prepare_parser.add_argument("--ci-run", required=True)
    prepare_parser.add_argument("--acceptance-run", default="")
    publish_parser = sub.add_parser("publish")
    publish_parser.add_argument("--directory", type=Path, required=True)
    for item in (resolve_parser, prepare_parser, publish_parser):
        item.add_argument("--repo", required=True)
        item.add_argument("--tag", required=True)
    args = parser.parse_args()
    require(re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo), "Invalid owner/repository")
    parse_tag(args.tag)
    if args.command == "resolve":
        values = resolve(args.repo, args.tag, args.acceptance_run)
        print(json.dumps(values, indent=2))
        with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
            for key, value in values.items():
                handle.write(key + "=" + value + "\n")
    elif args.command == "prepare":
        directories = None
        if args.variant_directory:
            directories = {}
            for value in args.variant_directory:
                require("=" in value, "Expected --variant-directory VARIANT=PATH")
                variant, path = value.split("=", 1)
                require(variant in VARIANTS and variant not in directories and path, "Invalid or duplicate variant directory")
                directories[variant] = Path(path)
        prepare(args.directory, args.output, args.repo, args.tag, args.commit, args.ci_run, args.acceptance_run,
                variant_directories=directories)
    else:
        publish(args.directory, args.repo, args.tag)


if __name__ == "__main__":
    main()
