#!/usr/bin/env python3
"""Create deterministic, isolated Git fixtures. Refuses existing destinations."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


def fixture_environment() -> dict[str, str]:
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    environment.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null", LC_ALL="C")
    return environment


def verify_isolation(git: str) -> None:
    """Read only, before any fixture creation; never rely on an advertised version."""
    with tempfile.TemporaryDirectory(prefix="WeGitBenchmarkProbe-") as directory:
        root = Path(directory)
        key = "probe" + uuid.uuid4().hex
        for scope in ("system", "global"):
            (root / scope).write_text(f"[wegitisolation]\n{key} = {scope}\n")
        environment = fixture_environment()
        environment.update(GIT_CONFIG_SYSTEM=str(root / "system"),
                           GIT_CONFIG_GLOBAL=str(root / "global"), GIT_CONFIG_COUNT="1",
                           GIT_CONFIG_KEY_0="wegitisolation." + key, GIT_CONFIG_VALUE_0="runtime")
        result = subprocess.run([git, "config", "--get-all", "wegitisolation." + key],
                                cwd=root, env=environment, capture_output=True, timeout=10)
        if result.returncode != 0 or result.stdout != b"system\nglobal\nruntime\n":
            raise RuntimeError("Git does not honor isolated configuration; no fixtures were created.")


def create(root: Path, label: str, files: int, commits: int, git: str) -> None:
    root.mkdir(parents=True, exist_ok=False)
    environment = fixture_environment()

    def run(*arguments: str) -> None:
        subprocess.run([git, "-C", str(root), *arguments], env=environment, check=True,
                       stdout=subprocess.DEVNULL, timeout=300)

    run("init", "-b", "main")
    for key, value in (("user.name", "WeGit Benchmark"), ("user.email", "benchmark@example.invalid"),
                       ("commit.gpgsign", "false"), ("core.hooksPath", str(root / ".git/no-hooks")),
                       ("gc.auto", "0")):
        run("config", "--local", key, value)
    ordinary = "".join(f"let value{line:03d} = {line}\n" for line in range(1, 81)).encode()
    giant = None
    if label == "large":
        giant = "".join(f"let before{line:06d} = \"{'a' * 96}\"\n" for line in range(100_000)).encode()
    with (root / ".git/fixture-import.log").open("wb") as log:
        process = subprocess.Popen([git, "-C", str(root), "fast-import", "--quiet"],
                                   stdin=subprocess.PIPE, stdout=log, stderr=log, env=environment)
        assert process.stdin is not None
        stream = process.stdin

        def write(text: str) -> None:
            stream.write(text.encode())

        write(f"blob\nmark :1\ndata {len(ordinary)}\n")
        stream.write(ordinary)
        write("\n")
        if giant is not None:
            write(f"blob\nmark :2\ndata {len(giant)}\n")
            stream.write(giant)
            write("\n")
        for number in range(1, commits + 1):
            message = f"Benchmark commit {number}"
            timestamp = 1_700_000_000 + number
            write(f"commit refs/heads/main\nmark :{number + 10}\n"
                  f"author Benchmark <benchmark@example.invalid> {timestamp} +0000\n"
                  f"committer Benchmark <benchmark@example.invalid> {timestamp} +0000\n"
                  f"data {len(message)}\n{message}\n")
            if number > 1:
                write(f"from :{number + 9}\n")
            else:
                for index in range(files):
                    write(f"M 100644 :1 sources/group-{index // 1000:03d}/file-{index:06d}.swift\n")
                if giant is not None:
                    write("M 100644 :2 large.swift\n")
            write("\n")
            if number % 10_000 == 0:
                print(f"{label}: imported {number}/{commits} commits", flush=True)
        for branch in range(1, 21):
            write(f"reset refs/heads/topic-{branch:02d}\nfrom :{commits + 10 - branch}\n\n")
        write("done\n")
        stream.close()
        if process.wait(timeout=300) != 0:
            raise RuntimeError(f"Fixture import failed; inspect {root / '.git/fixture-import.log'}")
    run("reset", "--hard", "HEAD")
    for index in range(20):
        path = root / f"sources/group-{index // 1000:03d}/file-{index:06d}.swift"
        path.write_bytes(ordinary.replace(b"let value040 = 40", b"let value040 = 4040"))
    if giant is not None:
        with (root / "large.swift").open("wb") as output:
            for line in range(100_000):
                output.write(f"let after{line:06d} = \"{'b' * 96}\"\n".encode())
    manifest = {
        "format": 1, "generator": "WeGit benchmark fixture", "label": label,
        "trackedFiles": files + (1 if giant is not None else 0), "commits": commits,
        "branches": 21, "modifiedFiles": 20 + (1 if giant is not None else 0),
        "diffPath": "sources/group-000/file-000000.swift", "largeDiffPath": "large.swift" if giant else None,
        "ordinaryFileLines": 80, "largeFileLines": 100_000 if giant else None,
        "historyShape": "linear history; 20 refs point to older commits; deterministic timestamps",
    }
    (root / ".git/wegit-benchmark.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{label}: ready ({manifest['trackedFiles']} files, {commits} commits)", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--git", default="/usr/bin/git")
    parser.add_argument("--check-only", action="store_true", help="Verify isolation without creating fixtures")
    arguments = parser.parse_args()
    if not arguments.check_only and arguments.destination is None:
        parser.error("--destination is required unless --check-only is used")
    git = str(Path(arguments.git).resolve())
    verify_isolation(git)
    if arguments.check_only:
        print("Git configuration isolation verified; no fixtures created.")
        return
    base = arguments.destination.resolve()
    base.mkdir(parents=True, exist_ok=False)
    create(base / "normal", "normal", 1000, 1000, git)
    create(base / "large", "large", 100_000, 100_000, git)


if __name__ == "__main__":
    main()
