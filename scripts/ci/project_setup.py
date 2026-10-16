#!/usr/bin/env python3
"""Idempotent labels, milestones and opt-in migration of the existing V1 backlog."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import quote


def api(path, method="GET", payload=None, pages=False):
    command = ["gh", "api", path, "--method", method]
    if pages:
        command += ["--paginate", "--slurp"]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, check=True)
    data = json.loads(result.stdout) if result.stdout.strip() else None
    if pages:
        return [item for page in data for item in page]
    return data


def issue_marker(key):
    return "<!-- wegit-backlog:" + key + " -->"


def plan(labels, milestones, backlog, existing_labels, existing_milestones, existing_issues):
    operations = []
    known_labels = {x["name"]: x for x in existing_labels}
    for item in labels:
        old = known_labels.get(item["name"])
        if old is None:
            operations.append(("create-label", item))
        elif any((old.get(k) or "") != v for k, v in item.items()):
            operations.append(("update-label", item))
    known_milestones = {x["title"] for x in existing_milestones}
    for item in milestones:
        if item["title"] not in known_milestones:
            operations.append(("create-milestone", item))
    for item in backlog:
        if not any(issue_marker(item["key"]) in (issue.get("body") or "") for issue in existing_issues):
            operations.append(("create-issue", item))
    return operations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--seed-backlog", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo):
        parser.error("Expected owner/repository")
    root = Path(__file__).resolve().parents[2]
    read = lambda name: json.loads((root / ".github" / name).read_text())
    prefix = "repos/" + args.repo
    labels = api(prefix + "/labels?per_page=100", pages=True)
    milestones = api(prefix + "/milestones?state=all&per_page=100", pages=True)
    issues = api(prefix + "/issues?state=all&per_page=100", pages=True) if args.seed_backlog else []
    operations = plan(read("labels.json"), read("milestones.json"),
                      read("backlog.json") if args.seed_backlog else [], labels, milestones, issues)
    for kind, item in operations:
        print(kind + ": " + item.get("name", item.get("title", "")))
        if not args.apply:
            continue
        if kind == "create-label":
            api(prefix + "/labels", "POST", item)
        elif kind == "update-label":
            api(prefix + "/labels/" + quote(item["name"], safe=""), "PATCH", item)
        elif kind == "create-milestone":
            milestones.append(api(prefix + "/milestones", "POST", item))
        else:
            milestone = next(x for x in milestones if x["title"] == item["milestone"])
            if milestone["state"] != "open":
                raise ValueError("Cannot seed new work into a closed milestone")
            payload = {"title": item["title"], "body": issue_marker(item["key"]) + "\n\n" + item["body"],
                       "labels": item["labels"], "milestone": milestone["number"]}
            result = api(prefix + "/issues", "POST", payload)
            print(result["html_url"])
    print(f"{'Applied' if args.apply else 'Planned'} {len(operations)} operations; existing issues are never overwritten.")


if __name__ == "__main__":
    main()
