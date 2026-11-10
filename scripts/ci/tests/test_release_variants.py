from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from release_variants import INSTALL_LIMIT, VARIANTS, prepare, validate


class ThreeVariantTests(unittest.TestCase):
    def fixture(self, root):
        directories = {}
        for variant, architectures in VARIANTS.items():
            directory = root / variant
            directory.mkdir()
            directories[variant] = directory
            basename = "WeGit-2.0.0-rc.1-macos-" + variant + "-adhoc"
            # Policy fixture only. Actual DMG creation, codesign, Mach-O/minos
            # and read-only mounts remain the macOS packaging acceptance.
            image = directory / (basename + ".dmg")
            image.write_bytes(b"fixture" + b"koly" + bytes(508))
            (directory / (image.name + ".sha256")).write_text(hashlib.sha256(image.read_bytes()).hexdigest() + "  " + image.name + "\n")
            report = {"variant": variant, "distributionVariantSource": "info-plist", "architectures": architectures,
                      "releaseTag": "v2.0.0-rc.1", "version": "2.0.0", "buildVersion": "2",
                      "gitCommit": "a" * 40, "workspaceDirty": False, "sourceFiles": {"source": "b" * 64},
                      "archive": image.name, "archiveFormat": "dmg", "archiveSHA256": hashlib.sha256(image.read_bytes()).hexdigest(),
                      "imageBytes": image.stat().st_size, "bundleBytes": 1024,
                      "bundleIdentifier": "com.willxue.wegit", "mode": "adhoc", "signing": "ad-hoc",
                      "notarized": False, "minimumSystemVersion": "26.0",
                      "diskImageVerification": {key: True for key in ("hdiutilVerified", "readOnlyMountVerified", "applicationsShortcutVerified")},
                      "binaries": {key: {"architectures": architectures,
                                         "minimumSystemVersions": {arch: "26.0" for arch in architectures}}
                                   for key in ("Contents/MacOS/WeGit", "Contents/Helpers/WeGitAskPass")}}
            encoded = json.dumps(report).encode()
            (directory / "manifest.json").write_bytes(encoded)
            (directory / (basename + ".manifest.json")).write_bytes(encoded)
        return directories

    def mutate(self, directory, change):
        report = json.loads((directory / "manifest.json").read_bytes())
        report.update(change)
        encoded = json.dumps(report).encode()
        (directory / "manifest.json").write_bytes(encoded)
        for path in directory.glob("*.manifest.json"):
            path.write_bytes(encoded)

    def test_same_source_build_three_variants_produce_unsigned_canonical_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            directories = self.fixture(Path(temporary))
            encoded = prepare(directories, "temporary-test-key", "中文说明", datetime(2026, 11, 6, tzinfo=timezone.utc))
            payload = json.loads(encoded)
            self.assertEqual([item["variant"] for item in payload["artifacts"]], list(VARIANTS))
            self.assertEqual(payload["channel"], "candidate")
            self.assertEqual(payload["build"], 2)
            self.assertEqual(encoded, json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode())
            self.assertNotIn("signature", payload)
            for item in payload["artifacts"]:
                self.assertIn("/v2.0.0-rc.1/WeGit-2.0.0-rc.1-macos-", item["url"])
                self.assertTrue(item["manifestURL"].endswith(".manifest.json"))

    def test_missing_variant_and_cross_source_or_build_are_refused(self):
        for mutation in [{"gitCommit": "c" * 40}, {"buildVersion": "3"}, {"sourceFiles": {"source": "c" * 64}}]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                directories = self.fixture(Path(temporary))
                self.mutate(directories["intel"], mutation)
                with self.assertRaises(ValueError):
                    prepare(directories, "temporary-test-key", "Notes")
        with tempfile.TemporaryDirectory() as temporary:
            directories = self.fixture(Path(temporary))
            directories.pop("intel")
            with self.assertRaises(ValueError):
                prepare(directories, "temporary-test-key", "Notes")

    def test_tampered_image_oversized_bundle_wrong_architecture_and_dirty_input_fail(self):
        for mutation in [{"bundleBytes": INSTALL_LIMIT + 1}, {"architectures": ["x86_64"]}, {"workspaceDirty": True},
                         {"notarized": True}, {"diskImageVerification": {}}, {"sourceFiles": {}}, {"sourceFiles": None}]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                directories = self.fixture(Path(temporary))
                self.mutate(directories["universal"], mutation)
                with self.assertRaises(ValueError):
                    validate(directories["universal"], "universal")
        with tempfile.TemporaryDirectory() as temporary:
            directories = self.fixture(Path(temporary))
            next(directories["intel"].glob("*.dmg")).write_bytes(b"truncated")
            with self.assertRaises(ValueError):
                validate(directories["intel"], "intel")

    def test_named_manifest_must_match_exact_asset_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            directories = self.fixture(Path(temporary))
            next(directories["intel"].glob("*.manifest.json")).write_text("{}")
            with self.assertRaises(ValueError):
                validate(directories["intel"], "intel")

    def test_no_implicit_signing_key_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            directories = self.fixture(Path(temporary))
            for identity in ["", "../../key", "key with space"]:
                with self.assertRaises(ValueError):
                    prepare(directories, identity, "Notes")


if __name__ == "__main__":
    unittest.main()
