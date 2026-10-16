#!/usr/bin/env python3
"""Validate exact-source release gates and prepare verifiable, non-notarized assets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:alpha|beta|rc)\.(?:0|[1-9][0-9]*)))?")
SHA = re.compile(r"[0-9a-f]{40}")


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
    if not prerelease:
        require(acceptance_id.isdigit() and int(acceptance_id) > 0, "Stable tags require a full acceptance run ID")
        expected = api(repo, "actions/workflows/acceptance.yml")
        run = api(repo, "actions/runs/" + acceptance_id)
        jobs = api(repo, "actions/runs/" + acceptance_id + "/jobs?filter=latest&per_page=100")["jobs"]
        validate_run(run, expected["id"], commit, jobs, ["Full acceptance"], events=("workflow_dispatch",))
    else:
        acceptance_id = ""
    return {"commit": commit, "prerelease": str(prerelease).lower(), "ci_run": str(ci), "acceptance_run": acceptance_id}


def validate_package(directory, tag, commit):
    version, _ = parse_tag(tag)
    manifest = json.loads((directory / "manifest.json").read_text())
    require(manifest["gitCommit"] == commit and SHA.fullmatch(commit), "Package commit does not match resolved tag")
    require(manifest["workspaceDirty"] is False, "Refusing a release from a dirty checkout")
    require(manifest["version"] == version and manifest.get("releaseTag") == tag, "App version or package tag mismatch")
    require(manifest["mode"] == "adhoc" and manifest.get("signing") == "ad-hoc" and manifest["notarized"] is False,
            "Expected an explicit ad-hoc, non-notarized package")
    require(manifest["bundleIdentifier"] == "com.willxue.wegit", "Expected the confirmed production bundle ID")
    name = manifest["archive"]
    require(name == f"WeGit-{tag[1:]}-macos-arm64-adhoc.zip", "Unexpected archive name")
    archive = directory / name
    require(hashlib.sha256(archive.read_bytes()).hexdigest() == manifest["archiveSHA256"], "Archive checksum mismatch")
    with zipfile.ZipFile(archive) as handle:
        require(handle.testzip() is None, "Archive CRC failure")
    checksum = (directory / (name + ".sha256")).read_text().split()
    require(checksum == [manifest["archiveSHA256"], name], "Checksum file must reference only this archive basename")
    return manifest


def prepare(directory, output, repo, tag, commit, ci_run, acceptance_run):
    manifest = validate_package(directory, tag, commit)
    output.mkdir(parents=True, exist_ok=False)
    for name in [manifest["archive"], manifest["archive"] + ".sha256", "manifest.json"]:
        shutil.copyfile(directory / name, output / name)
    version, prerelease = parse_tag(tag)
    metadata = {"version": version, "tag": tag, "commit": commit, "prerelease": prerelease,
                "platform": "macOS 27+", "architecture": "arm64", "signing": "ad-hoc", "notarized": False,
                "archive": manifest["archive"], "sha256": manifest["archiveSHA256"],
                "ciRun": ci_run, "acceptanceRun": acceptance_run or None}
    (output / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    note = f"""## 📦 macOS download

- macOS 27+, Apple Silicon / arm64.
- **Ad-hoc signed; no Developer ID; not notarized by Apple.** macOS may block first launch.
- Download the ZIP and verify its `.sha256` file. See [Apple's safe-opening guidance](https://support.apple.com/102445).
- Source: `{commit}`. [CI evidence](https://github.com/{repo}/actions/runs/{ci_run}).
- Full acceptance: {('https://github.com/' + repo + '/actions/runs/' + acceptance_run) if acceptance_run else 'Not required for this prerelease; this is not V1.0 acceptance.'}
- `manifest.json` and `release.json` describe this exact artifact. The website must link to this same asset.

## ✅ Maintainer sign-off before publishing

- Verify the downloaded package on a clean target Mac, installation instructions, data migration and rollback.
- Confirm milestone blockers, Beta feedback and known limitations against the tagged source.
- Review generated change notes below. This workflow only creates a **draft**.

"""
    (output / "release-notes.md").write_text(note)


def publish(directory, repo, tag):
    info = json.loads((directory / "release.json").read_text())
    require(info["tag"] == tag, "Artifact release tag mismatch")
    manifest = validate_package(directory, tag, info["commit"])
    require(info.get("sha256") == manifest["archiveSHA256"] and info.get("archive") == manifest["archive"],
            "Website metadata does not match the artifact")
    require(info.get("notarized") is False and info.get("signing") == "ad-hoc"
            and info.get("prerelease") == parse_tag(tag)[1], "Misleading release metadata")
    # Revalidate server-side gates and tag immediately before the write.
    values = resolve(repo, tag, str(info.get("acceptanceRun") or ""))
    require(values["commit"] == info["commit"], "Tag moved after artifact creation")
    manifest = validate_package(directory, tag, info["commit"])
    command = ["gh", "release", "create", tag, "--repo", repo, "--verify-tag", "--draft",
               "--title", "WeGit " + tag[1:], "--notes-file", str(directory / "release-notes.md"), "--generate-notes"]
    if parse_tag(tag)[1]:
        command.append("--prerelease")
    command += [str(directory / name) for name in
                [manifest["archive"], manifest["archive"] + ".sha256", "manifest.json", "release.json"]]
    subprocess.run(command, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    resolve_parser = sub.add_parser("resolve")
    resolve_parser.add_argument("--acceptance-run", default="")
    prepare_parser = sub.add_parser("prepare")
    prepare_parser.add_argument("--directory", type=Path, required=True)
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
        prepare(args.directory, args.output, args.repo, args.tag, args.commit, args.ci_run, args.acceptance_run)
    else:
        publish(args.directory, args.repo, args.tag)


if __name__ == "__main__":
    main()
