#!/usr/bin/env python3
"""Route complete immutable Git ranges to site-only or full validation."""
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


def valid_path(path):
    return (isinstance(path, str) and bool(path) and "\0" not in path and not path.startswith("/")
            and not any(part in {"", ".", ".."} for part in path.split("/"))
            and not PurePosixPath(path).is_absolute())


def site_path(path):
    return path.startswith("site/") or path in SITE_ENTRIES


def classify(paths):
    paths = list(paths)
    if not all(valid_path(path) for path in paths):
        return {"site_only": False, "site_changed": True, "changed_file_count": len(paths)}
    actual_site = any(site_path(path) for path in paths)
    return {
        "site_only": actual_site and all(site_path(path) or path in SITE_COORDINATION for path in paths),
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
    try:
        paths = changed_paths(root, event, event_name)
    except subprocess.TimeoutExpired:
        paths = None
    if paths is None:
        return {"site_only": False, "site_changed": True, "changed_file_count": 0, "range_verified": False}
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
