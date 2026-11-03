#!/usr/bin/env python3
"""Schedule costly validation only for verified backend code changes."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess


SITE_ENTRIES = {"scripts/build_website.py", "scripts/ci/tests/test_website.py"}
SITE_COORDINATION = {"HANDOFF.MD"}
SITE_INFRASTRUCTURE = {
    ".github/workflows/verify.yml", ".github/workflows/pages.yml",
    ".github/workflows/workers.yml", "scripts/ci/change_scope.py",
    "scripts/ci/check_ci_results.py",
}
BACKEND_FILES = {
    "Package.swift", "WeGit/App/AppState.swift", "WeGit/App/SyncState.swift",
    "WeGit/App/WorktreeManagementState.swift", "WeGit/App/AuthenticationController.swift",
    "WeGit/App/AppPreferences.swift", "WeGit/App/PreferenceMigration.swift",
    "WeGit/Features/CloneViewModel.swift",
}
CORE_FRONTEND_FILES = {
    "WeGitCore/Domain/Localization.swift", "WeGitCore/Domain/CodeTextPresentation.swift",
    "WeGitCore/Domain/DiffPresentation.swift", "WeGitCore/Domain/UTF8DisplayPrefix.swift",
}
NATIVE_BUILD_FILES = {"project.yml", ".swift-format"}


def valid_path(path):
    return (isinstance(path, str) and bool(path) and "\0" not in path and not path.startswith("/")
            and not any(part in {"", ".", ".."} for part in path.split("/"))
            and not PurePosixPath(path).is_absolute())


def site_path(path):
    return path.startswith("site/") or path in SITE_ENTRIES


def backend_path(path):
    return (path in BACKEND_FILES
            or path.startswith("WeGitAskPass/") and path.endswith((".swift", ".c", ".h"))
            or path.startswith("WeGitCore/") and path.endswith(".swift") and path not in CORE_FRONTEND_FILES)


def classify(paths):
    paths = list(paths)
    if not all(valid_path(path) for path in paths):
        raise ValueError("Invalid changed paths; backend validation was not scheduled")
    actual_site = any(site_path(path) for path in paths)
    backend = any(backend_path(path) for path in paths)
    policy = backend or any(
        (path.startswith("scripts/") and not site_path(path) and not path.endswith(".md"))
        or path.startswith(".github/") and path.endswith((".yml", ".yaml", ".json"))
        for path in paths)
    frontend = not backend and any(
        path in CORE_FRONTEND_FILES or path in NATIVE_BUILD_FILES
        or path.startswith("WeGit.xcodeproj/")
        or path.startswith("WeGit/") and (path.endswith(".swift") or path.startswith("WeGit/Resources/"))
        or path.startswith(("WeGitUITests/", "WeGitCore/Resources/")) for path in paths)
    return {
        "site_only": actual_site and all(site_path(path) or path in SITE_COORDINATION for path in paths),
        "backend_changed": backend,
        "policy_changed": policy,
        "frontend_changed": frontend,
        "core_tests_changed": not backend and any(
            path.startswith(("WeGitTests/", "Benchmarks/")) and path.endswith((".swift", ".c", ".h")) for path in paths),
        "docs_only": bool(paths) and not actual_site and all(path.lower().endswith((".md", ".txt", ".rst")) for path in paths),
        "site_changed": actual_site or any(
            path.startswith("design/brand/") or path in SITE_INFRASTRUCTURE for path in paths),
        "changed_file_count": len(paths),
    }


def changed_paths(root, event, event_name):
    if event_name == "pull_request":
        pr = event.get("pull_request", {})
        base = pr.get("base", {}).get("sha", "")
        head = pr.get("head", {}).get("sha", "")
        separator = "..."
    elif event_name == "push":
        base, head = event.get("before", ""), event.get("after", "")
        separator = ".."
    else:
        return None
    if not all(re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", sha or "")
               and set(sha) != {"0"} for sha in [base, head]):
        return None
    result = subprocess.run(
        ["git", "-C", str(root), "diff", "--no-renames", "--name-only", "-z", base + separator + head, "--"],
        capture_output=True, timeout=30,
        env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
    if result.returncode != 0:
        return None
    if result.stdout and not result.stdout.endswith(b"\0"):
        return None
    return [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]


def scope_for_event(root, event, event_name):
    if event_name == "workflow_dispatch":
        backend = event.get("inputs", {}).get("backend_validation") in [True, "true"]
        site = event.get("inputs", {}).get("site_validation", True) in [True, "true"]
        return {"site_only": not backend and site, "backend_changed": backend,
                "policy_changed": backend, "frontend_changed": False,
                "core_tests_changed": False, "docs_only": False, "site_changed": site,
                "changed_file_count": 0, "range_verified": False}
    try:
        paths = changed_paths(root, event, event_name)
    except subprocess.TimeoutExpired:
        paths = None
    if paths is None:
        raise ValueError("Cannot verify the Git range; costly backend validation was not scheduled")
    return {**classify(paths), "range_verified": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", type=Path, required=True)
    parser.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME", ""))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    scope = scope_for_event(Path.cwd(), json.loads(args.event.read_text()), args.event_name)
    if args.output:
        with args.output.open("a") as output:
            for key, value in scope.items():
                output.write(f"{key}={str(value).lower() if isinstance(value, bool) else value}\n")
    print(json.dumps(scope, sort_keys=True))


if __name__ == "__main__":
    main()
