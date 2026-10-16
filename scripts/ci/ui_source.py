#!/usr/bin/env python3
"""Resolve a read-only UI diagnostic to main or an explicit same-repository PR."""
import argparse
import json
import os
import re
import subprocess


def choose_source(main_sha, repository, pull_request=None):
    if not re.fullmatch(r"[a-f0-9]{40}", main_sha):
        raise ValueError("Main workflow source must be an immutable commit")
    if pull_request is None:
        return main_sha
    head = pull_request.get("head") or {}
    base = pull_request.get("base") or {}
    if (pull_request.get("state") != "open" or base.get("ref") != "main"
            or (base.get("repo") or {}).get("full_name", "").casefold() != repository.casefold()
            or (head.get("repo") or {}).get("full_name", "").casefold() != repository.casefold()
            or not re.fullmatch(r"[a-f0-9]{40}", head.get("sha", ""))):
        raise ValueError("UI candidate must be an open same-repository PR targeting main with an immutable head")
    return head["sha"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", default="")
    parser.add_argument("--scope", choices=("smoke", "functional", "accessibility"), required=True)
    args = parser.parse_args()
    repo = os.environ["GITHUB_REPOSITORY"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise SystemExit("Invalid repository")
    candidate = None
    if args.candidate:
        if not re.fullmatch(r"[1-9][0-9]*", args.candidate) or args.scope != "smoke":
            raise SystemExit("Candidate PR diagnostics require a positive PR number and smoke scope")
        candidate = json.loads(subprocess.check_output(["gh", "api", f"repos/{repo}/pulls/{args.candidate}"], text=True))
    print("sha=" + choose_source(os.environ["GITHUB_SHA"], repo, candidate))


if __name__ == "__main__":
    main()
