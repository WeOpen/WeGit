import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from release_artifact import inspect_bundle
from release_variants import VARIANTS

ROOT = Path(__file__).resolve().parents[3]


class DistributionBuildArgumentTests(unittest.TestCase):
    def test_candidate_tag_is_retained_in_installed_version_without_a_real_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.sandbox(root, "package-release.sh", status=91)
            env["WEGIT_RELEASE_TAG"] = "v2.0.0-rc.1"
            result = subprocess.run(["/bin/bash", str(root / "scripts/package-release.sh"), "--adhoc", "--variant", "universal"], env=env, capture_output=True)
            self.assertEqual(result.returncode, 91, result.stderr)
            call = json.loads((root / "arguments.json").read_bytes())
            self.assertIn("WEGIT_RELEASE_VERSION=2.0.0-rc.1", call)

    def sandbox(self, root, script, status=0):
        (root / "scripts").mkdir()
        shutil.copyfile(ROOT / "scripts" / script, root / "scripts" / script)
        binary = root / "bin"
        binary.mkdir()
        tool = binary / "xcodebuild"
        tool.write_text("#!/usr/bin/env python3\nimport json,os,sys\nopen(os.environ['VARIANT_ARGUMENT_LOG'],'w').write(json.dumps(sys.argv[1:]))\nsys.exit(" + str(status) + ")\n")
        tool.chmod(0o755)
        uname = binary / "uname"
        uname.write_text("#!/bin/sh\nprintf 'arm64\\n'\n")
        uname.chmod(0o755)
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                   WEGIT_SKIP_PROJECT_GENERATION="1", VARIANT_ARGUMENT_LOG=str(root / "arguments.json"))
        return env

    def test_build_script_passes_explicit_installed_distribution_variant(self):
        for architecture, variant in [("arm64", "applesilicon"), ("x86_64", "intel"), ("universal", "universal"), (None, "universal")]:
            with self.subTest(architecture=architecture), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                env = self.sandbox(root, "build.sh")
                arguments = ["bash", str(root / "scripts/build.sh"), "Release"] + ([architecture] if architecture else [])
                subprocess.run(arguments, env=env, check=True, capture_output=True)
                call = json.loads((root / "arguments.json").read_bytes())
                self.assertIn("WEGIT_DISTRIBUTION_VARIANT=" + variant, call)
                self.assertIn("ARCHS=" + " ".join(VARIANTS[variant]), call)

    def test_all_packaging_signing_modes_pass_the_same_variant_without_building(self):
        for mode in ["--adhoc", "--sign", "--notarize"]:
            for variant in VARIANTS:
                with self.subTest(mode=mode, variant=variant), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    env = self.sandbox(root, "package-release.sh", status=91)
                    env.update(WEGIT_TEAM_ID="PrivateFixture", WEGIT_SIGNING_IDENTITY="Developer ID Application: Private Fixture",
                               WEGIT_NOTARY_PROFILE="PrivateFixture")
                    result = subprocess.run(["bash", str(root / "scripts/package-release.sh"), mode, "--variant", variant],
                                            env=env, capture_output=True)
                    self.assertEqual(result.returncode, 91)
                    call = json.loads((root / "arguments.json").read_bytes())
                    self.assertIn("WEGIT_DISTRIBUTION_VARIANT=" + variant, call)
                    self.assertIn("ARCHS=" + " ".join(VARIANTS[variant]), call)


class DistributionInfoInspectionTests(unittest.TestCase):
    def fixture(self, root, variant, installed_variant):
        app = root / "WeGit.app"
        for directory in ["MacOS", "Helpers", "Resources"]:
            (app / "Contents" / directory).mkdir(parents=True, exist_ok=True)
        info = {"LSMinimumSystemVersion": "26.0"}
        if installed_variant is not None:
            info["WeGitDistributionVariant"] = installed_variant
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        (app / "Contents/Resources/build-source.json").write_text(json.dumps({"architectures": VARIANTS[variant]}))
        (app / "Contents/Resources/AppIcon.icns").write_bytes(b"synthetic icon")
        for name in ["Contents/MacOS/WeGit", "Contents/Helpers/WeGitAskPass"]:
            (app / name).write_bytes(b"\xfe\xed\xfa\xcf" + b"synthetic Mach-O policy fixture")
        def command(arguments):
            if "/usr/bin/lipo" in arguments:
                return " ".join(VARIANTS[variant])
            if "vtool" in arguments:
                return "minos 26.0\n"
            return ""
        return app, command

    def test_inspected_info_variant_matches_all_three_bundles(self):
        for variant in VARIANTS:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app, command = self.fixture(root, variant, variant)
                with patch("release_artifact.verify_bundle"), patch("release_artifact.command", side_effect=command):
                    report = inspect_bundle(root, app, variant)
                self.assertEqual(report["variant"], variant)
                self.assertEqual(report["distributionVariantSource"], "info-plist")

    def test_missing_info_is_only_compatible_with_verified_universal_architecture(self):
        for variant in VARIANTS:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app, command = self.fixture(root, variant, None)
                with patch("release_artifact.verify_bundle"), patch("release_artifact.command", side_effect=command):
                    if variant == "universal":
                        report = inspect_bundle(root, app, variant)
                        self.assertEqual(report["distributionVariantSource"], "legacy-universal")
                    else:
                        with self.assertRaises(ValueError):
                            inspect_bundle(root, app, variant)

    def test_wrong_empty_unknown_and_unexpanded_info_variants_fail(self):
        for installed_variant in ["intel", "", "unknown", "$(WEGIT_DISTRIBUTION_VARIANT)"]:
            with self.subTest(installed_variant=installed_variant), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app, command = self.fixture(root, "applesilicon", installed_variant)
                with patch("release_artifact.verify_bundle"), patch("release_artifact.command", side_effect=command):
                    with self.assertRaises(ValueError):
                        inspect_bundle(root, app, "applesilicon")


if __name__ == "__main__":
    unittest.main()
