#!/usr/bin/env python3
"""Create private comparison/query scale fixtures; never reuse a destination."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location("benchmark_fixtures", Path(__file__).with_name("create-benchmark-fixtures.py"))
isolation = module_from_spec(spec)
spec.loader.exec_module(isolation)

SCALES = (("ordinary", 10_000, 10_000, 100_000, 100),
          ("large", 100_000, 10_000, 100_000, 1_000))
DIAGNOSTIC_SCALES = (("ordinary", 250, 32, 512, 16), ("large", 400, 32, 512, 16))


def create(root, label, commits, references, paths, changed, git):
    root.mkdir(mode=0o700, exist_ok=False)
    environment = isolation.fixture_environment()

    def run(*arguments, input=None):
        return subprocess.run([git, "-C", str(root), *arguments], input=input,
                              env=environment, check=True, capture_output=True, timeout=300).stdout

    start = time.monotonic()
    run("init", "-b", "main")
    for key, value in (("user.name", "Reading Performance"), ("user.email", "fixture@example.invalid"),
                       ("commit.gpgsign", "false"), ("core.hooksPath", str(root / ".git/no-hooks")),
                       ("gc.auto", "0"), ("maintenance.auto", "false"), ("core.autocrlf", "false")):
        run("config", "--local", key, value)
    # Empty intermediate commits keep the complete 100k ancestry real without
    # multiplying 100k path trees. Final changes exercise diff/stat materialization.
    stream = root / ".git/reading-import"
    with stream.open("xb") as output:
        for mark, value in ((1, b"before\n"), (2, b"after\n")):
            output.write(f"blob\nmark :{mark}\ndata {len(value)}\n".encode() + value + b"\n")
        for number in range(1, commits + 1):
            message = f"Reading fixture commit {number:06d}"
            timestamp = 1_700_000_000 + number
            output.write((f"commit refs/heads/main\nmark :{number + 10}\n"
                          f"author Fixture <fixture@example.invalid> {timestamp} +0000\n"
                          f"committer Fixture <fixture@example.invalid> {timestamp} +0000\n"
                          f"data {len(message)}\n{message}\n").encode())
            if number > 1:
                output.write(f"from :{number + 9}\n".encode())
            if number == 1:
                for index in range(paths):
                    output.write(f"M 100644 :1 paths/group-{index // 1000:03d}/file-{index:06d}.txt\n".encode())
            if number == commits:
                for index in range(changed):
                    output.write(f"M 100644 :2 paths/group-{index // 1000:03d}/file-{index:06d}.txt\n".encode())
            output.write(b"\n")
        # The two comparison endpoints count toward the exact 10k references.
        output.write(b"reset refs/heads/base\nfrom :11\n\n")
        for index in range(references - 2):
            namespace = "heads" if index % 2 == 0 else "tags"
            number = 1 + index * (commits - 1) // max(1, references - 3)
            output.write(f"reset refs/{namespace}/fixture-{index:05d}\nfrom :{number + 10}\n\n".encode())
        output.write(b"done\n")
    with stream.open("rb") as source, (root / ".git/reading-import.log").open("xb") as log:
        subprocess.run([git, "-C", str(root), "fast-import", "--quiet"], stdin=source,
                       stdout=log, stderr=log, env=environment, check=True, timeout=300)
    stream.unlink()
    # Install only the index, so a 100k-path fixture does not create 100k real
    # files. Both services read immutable objects/index, never filesystem contents.
    run("read-tree", "HEAD")
    run("pack-refs", "--all", "--prune")
    base = run("rev-parse", "refs/heads/base").decode().strip()
    target = run("rev-parse", "HEAD").decode().strip()
    # A standard two-parent stash exercises the seventh all-scope query category
    # without checking out 100k paths or changing the measured HEAD ancestry.
    # The frozen reference scale counts heads/tags, as the query API does.
    environment.update(GIT_AUTHOR_DATE="1700000000 +0000", GIT_COMMITTER_DATE="1700000000 +0000")
    tree = run("rev-parse", "HEAD^{tree}").decode().strip()
    stash_index = run("commit-tree", tree, "-p", target, input=b"Reading fixture index\n").decode().strip()
    stash = run("commit-tree", tree, "-p", target, "-p", stash_index,
                input=b"Reading fixture task\n").decode().strip()
    run("update-ref", "--create-reflog", "-m", "On main: Reading fixture task", "refs/stash", stash)
    stash_entries = run("stash", "list", "--format=%H").decode().splitlines()
    if stash_entries != [stash]:
        raise RuntimeError(f"Fixture stash mismatch: {label}")
    observed = {
        "commits": int(run("rev-list", "--count", "HEAD")),
        "references": len(run("for-each-ref", "--format=%(refname)", "refs/heads", "refs/tags").splitlines()),
        "paths": len(run("ls-files", "--cached", "-z").split(b"\0")) - 1,
        "changedPaths": len(run("diff", "--name-only", "-z", base, target).split(b"\0")) - 1,
    }
    expected = dict(commits=commits, references=references, paths=paths, changedPaths=changed)
    if observed != expected:
        raise RuntimeError(f"Fixture scale mismatch: {label}: {observed} != {expected}")
    object_counts = run("count-objects", "-v").decode().strip()
    index_sha = hashlib.sha256((root / ".git/index").read_bytes()).hexdigest()
    # Independent bounded identity oracle for both 100-result mixed pages.
    # All heads/tags point into this linear ancestry; stash commits are excluded.
    expected_commits = run("rev-list", "--max-count=200", target).decode().splitlines()
    expected_references = {}
    for namespace in ("refs/heads", "refs/tags"):
        for row in run("for-each-ref", "--count=100", "--sort=refname",
                       "--format=%(refname)%00%(objectname)", namespace).decode().splitlines():
            reference, object_id = row.split("\0")
            expected_references[reference] = object_id
    return dict(name=label, repository=str(root), **observed, base=base, target=target,
                stashes=len(stash_entries), stashObjectID=stash,
                expectedQueryCommits=expected_commits, expectedQueryReferences=expected_references,
                preparedSeconds=time.monotonic() - start, indexSHA256=index_sha,
                objectCounts=object_counts,
                historyShape=f"linear; {references} varied heads/tags; empty intermediate commits",
                worktreeShape="index only; missing working files; worktree metadata queried; no status or working-file content reads")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--git", default="/usr/bin/git")
    parser.add_argument("--diagnostic", action="store_true")
    args = parser.parse_args()
    git = str(Path(args.git).resolve(strict=True))
    isolation.verify_isolation(git)
    root = args.destination.resolve()
    root.mkdir(mode=0o700, exist_ok=False)
    report = dict(format=1, diagnosticOnly=args.diagnostic, git=git, workloads=[], complete=False)
    try:
        for scale in DIAGNOSTIC_SCALES if args.diagnostic else SCALES:
            report["workloads"].append(create(root / scale[0], *scale, git))
        report["complete"] = True
    finally:
        (root / "fixtures.json").write_text(json.dumps(report, indent=2) + "\n")
    print(root / "fixtures.json")


if __name__ == "__main__":
    main()
