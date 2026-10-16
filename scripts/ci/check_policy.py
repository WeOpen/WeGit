#!/usr/bin/env python3
"""Portable project contracts; actionlint separately validates Actions expressions."""
import argparse
import json
from pathlib import Path
import re
import os
import subprocess
from urllib.parse import unquote, urlsplit
import yaml


class Loader(yaml.SafeLoader):
    # GitHub uses YAML 1.2: `on` is a key, not the YAML 1.1 boolean True.
    yaml_implicit_resolvers = {
        key: [(tag, regex) for tag, regex in values if tag != "tag:yaml.org,2002:bool"]
        for key, values in yaml.SafeLoader.yaml_implicit_resolvers.items()
    }


Loader.add_implicit_resolver("tag:yaml.org,2002:bool", re.compile(r"^(true|false)$", re.I), list("tTfF"))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_workflow(workflow, name):
    events = workflow.get("on", {})
    require("pull_request_target" not in events, name + ": privileged PR trigger is prohibited")
    require(workflow.get("permissions") == {"contents": "read"}, name + ": default permissions must be read-only")
    require("concurrency" in workflow, name + ": missing concurrency policy")
    for key, job in workflow["jobs"].items():
        require(0 < job.get("timeout-minutes", 0) <= 120, name + ": missing bounded job timeout")
        runner = job.get("runs-on", [])
        if "self-hosted" in runner:
            require("pull_request" not in events, name + ": self-hosted jobs must not accept PR code")
            require("concurrency" in job, name + ": interactive resource needs a cross-workflow lock")
        if job.get("permissions", {}).get("contents") == "write":
            require(name == "release.yml" and key == "publish", "Only draft release publication may write contents")
        for step in job.get("steps", []):
            action = step.get("uses", "")
            if action and not action.startswith("./"):
                require(re.fullmatch(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}", action), name + ": unpinned action " + action)
            if action.startswith("actions/checkout@"):
                require(step.get("with", {}).get("persist-credentials") is False, name + ": checkout persists credentials")
            require("continue-on-error" not in step, name + ": checks must retain failure status")
            script = step.get("run", "")
            require(not re.search(r"\$\{\{\s*(github\.event\.|inputs\.)", script), name + ": pass untrusted values through env")


def check_pr(event):
    pr = event["pull_request"]
    title = pr["title"]
    require(re.match(r"^(feat|fix|docs|ci|test|build|perf|refactor|chore|revert)(\([\w./-]+\))?!?: .+", title),
            "PR title must use Conventional Commits, for example fix(diff): preserve tabs")
    if pr["user"]["login"] == "dependabot[bot]":
        return []
    body = re.sub(r"<!--.*?-->", "", pr.get("body") or "", flags=re.S)
    numbers = sorted({int(x) for x in re.findall(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?)\s+#([1-9][0-9]*)\b", body, re.I)})
    require(numbers, "Link a requirement using Closes #number or Refs #number")
    return numbers


def validate_issue_targets(numbers, lookup):
    issues = [lookup(number) for number in numbers]
    require(all("pull_request" not in issue for issue in issues), "Link an Issue rather than a pull request")
    require(any(issue["state"] == "open" for issue in issues), "At least one linked requirement must be an open Issue")


def check_repository(root):
    workflows = root / ".github/workflows"
    for path in sorted(workflows.glob("*.yml")):
        check_workflow(yaml.load(path.read_text(), Loader=Loader), path.name)
    labels = {item["name"] for item in json.loads((root / ".github/labels.json").read_text())}
    names = set()
    for path in sorted((root / ".github/ISSUE_TEMPLATE").glob("*.yml")):
        if path.name == "config.yml":
            continue
        form = yaml.load(path.read_text(), Loader=Loader)
        require(form["name"] not in names, "Duplicate issue form name")
        names.add(form["name"])
        require(set(form["labels"]) <= labels, "Issue form references an unknown label")
        fields = [field for field in form["body"] if field["type"] != "markdown"]
        require(len({field["id"] for field in fields}) == len(fields), "Duplicate form field IDs")
        require(any(f["id"] == "acceptance" and f["validations"]["required"] for f in fields), "Missing acceptance criteria")
    for name in ("README.md", "CONTRIBUTING.md", "docs/GITHUB_WORKFLOW.md"):
        source = root / name
        require(source.is_file(), "Missing project guide " + name)
        for target in re.findall(r"\]\(([^)]+)\)", source.read_text()):
            url = urlsplit(target)
            if not url.scheme and url.path:
                require((source.parent / unquote(url.path)).exists(), name + ": missing local link " + target)
    print("Workflow security contracts, issue forms and project guide links passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", type=Path)
    parser.add_argument("--verify-issues", action="store_true")
    args = parser.parse_args()
    if args.event:
        numbers = check_pr(json.loads(args.event.read_text()))
        if args.verify_issues and numbers:
            repo = os.environ["GITHUB_REPOSITORY"]
            require(re.fullmatch(r"[\w.-]+/[\w.-]+", repo), "Invalid repository name")
            def lookup(number):
                result = subprocess.run(["gh", "api", f"repos/{repo}/issues/{number}"],
                                        check=True, text=True, capture_output=True)
                return json.loads(result.stdout)
            validate_issue_targets(numbers, lookup)
        print("PR title and linked requirement passed.")
    else:
        check_repository(Path.cwd())


if __name__ == "__main__":
    main()
