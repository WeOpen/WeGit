import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class ToolchainTests(unittest.TestCase):
    def run_probe(self, version="27.0", system="27.0.1", architecture="arm64"):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            programs = {
                "xcodebuild": "#!/usr/bin/env python3\nimport sys,time\nsys.stdout.write('Xcode " + version
                + "\\n');sys.stdout.flush();time.sleep(0.05)\nsys.stdout.write('Build version 27A266a\\n');sys.stdout.flush()\n",
                "xcrun": "#!/bin/sh\necho 'Swift 6.4'\n",
                "uname": "#!/bin/sh\necho '" + architecture + "'\n",
                "sw_vers": "#!/bin/sh\necho '" + system + "'\n",
            }
            for name, source in programs.items():
                file = root / name
                file.write_text(source)
                file.chmod(0o755)
            script = Path(__file__).resolve().parents[1] / "check-toolchain.sh"
            return subprocess.run(["bash", str(script)], env=dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"]),
                                  text=True, capture_output=True)

    def test_delayed_second_version_line_is_drained_without_broken_pipe(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Build version 27A266a", result.stdout)
        self.assertNotIn("BrokenPipe", result.stderr)

    def test_wrong_xcode_system_and_architecture_remain_rejected(self):
        for arguments in [{"version": "26.4"}, {"version": "270.0"}, {"system": "26.0"}, {"architecture": "x86_64"}]:
            with self.subTest(arguments=arguments):
                self.assertNotEqual(self.run_probe(**arguments).returncode, 0)


if __name__ == "__main__":
    unittest.main()
