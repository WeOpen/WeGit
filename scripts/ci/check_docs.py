#!/usr/bin/env python3
"""Validate changed documentation without scheduling application checks."""
import argparse
import json
import os
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

from change_scope import changed_paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", type=Path, required=True)
    args = parser.parse_args()
    root = Path.cwd()
    paths = changed_paths(root, json.loads(args.event.read_text()), os.environ["GITHUB_EVENT_NAME"])
    if paths is None:
        raise ValueError("Cannot determine changed documentation")
    checked = 0
    for relative in paths:
        path = root / relative
        if not path.is_file() or path.suffix.lower() not in {".md", ".txt", ".rst"}:
            continue
        for target in re.findall(r"\]\(([^)]+)\)", path.read_text()):
            url = urlsplit(target)
            if not url.scheme and url.path and not (path.parent / unquote(url.path)).exists():
                raise ValueError(f"{relative}: missing documentation link {target}")
        checked += 1
    print(f"Documentation links passed: {checked} changed files")


if __name__ == "__main__":
    main()
