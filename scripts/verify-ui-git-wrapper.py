#!/usr/bin/env python3
"""Verify the native UI fixture forwards isolation, bytes and failure status."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=Path)
    parser.add_argument("--report", type=Path, default=Path(".build/ci/ui-git-wrapper.json"))
    args = parser.parse_args()
    helper = args.helper.resolve()
    git = subprocess.check_output(["/usr/bin/xcrun", "--find", "git"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="WeGitUIHelper-") as folder:
        root = Path(folder)
        key = "probe" + uuid.uuid4().hex
        global_config, system_config = root / "global", root / "system"
        for path, value in ((global_config, "global"), (system_config, "system")):
            path.write_text("[wegitwrapper]\n" + key + " = " + value + "\n")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        environment.update(GIT_CONFIG_GLOBAL=str(global_config), GIT_CONFIG_SYSTEM=str(system_config),
                           GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="wegitwrapper." + key,
                           GIT_CONFIG_VALUE_0="runtime", GIT_TERMINAL_PROMPT="0", LC_ALL="C")

        def run(binary, command, data=b""):
            return subprocess.run([str(binary), *command], input=data, cwd=root, env=environment,
                                  capture_output=True, timeout=10)

        for binary in (git, helper):
            probe = run(binary, ["config", "--get-all", "wegitwrapper." + key])
            if probe.returncode != 0 or probe.stdout != b"system\nglobal\nruntime\n":
                raise SystemExit("UI fixture Git did not preserve configuration isolation.")
        version = run(git, ["--version"])
        forwarded = run(helper, ["--version"])
        if version.returncode != 0 or (forwarded.returncode, forwarded.stdout) != (0, version.stdout):
            raise SystemExit("UI helper did not use the selected Xcode Git.")
        content = ("\tUnicode 中文🙂\r\nspaces  \n".encode() + b"\0" + bytes(range(256))) * 300
        result = run(helper, ["hash-object", "--stdin", "--no-filters"], content)
        expected = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest().encode() + b"\n"
        if result.returncode != 0 or result.stdout != expected:
            raise SystemExit("UI helper changed original stdin bytes or output.")
        failure = run(git, ["--wegit-fixture-invalid-option"])
        forwarded_failure = run(helper, ["--wegit-fixture-invalid-option"])
        if failure.returncode == 0 or (forwarded_failure.returncode, forwarded_failure.stderr) != (failure.returncode, failure.stderr):
            raise SystemExit("UI helper did not preserve failure status and stderr.")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps({"checks": 4, "passed": True, "git": git,
                                      "version": version.stdout.decode().strip(),
                                      "isolation": True, "stdinBytesPreserved": True,
                                      "failureStatusPreserved": True}, indent=2) + "\n")
    print("4 native UI Git helper behavior checks passed.")


if __name__ == "__main__":
    main()
