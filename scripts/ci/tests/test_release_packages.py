import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from github_release import checked_upload, prepare, publish, validate_package, validate_packages
import test_release as legacy_fixtures
import test_release_variants as fixtures

TAG = "v2.0.0-rc.1"
COMMIT = "a" * 40
REPO = "WeOpen/WeGit"


class ReleasePackageSetTests(unittest.TestCase):
    def fixture(self, root):
        factory = fixtures.ThreeVariantTests("test_same_source_build_three_variants_produce_unsigned_canonical_payload")
        return factory.fixture(root), factory

    def prepare(self, root, **kwargs):
        return prepare(root, root / "upload", REPO, TAG, COMMIT, "10", "", **kwargs)

    def test_three_variant_preparation_preserves_bytes_and_matches_update_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directories, _ = self.fixture(root)
            self.prepare(root)
            upload = root / "upload"
            metadata = json.loads((upload / "release.json").read_bytes())
            self.assertEqual(metadata["format"], 2)
            self.assertEqual(metadata["variants"], list(fixtures.VARIANTS))
            self.assertEqual(metadata["buildVersion"], "2")
            self.assertEqual(metadata["build"], 2)
            self.assertEqual(metadata["channel"], "candidate")
            self.assertEqual(metadata["architecture"], "universal")
            for artifact in metadata["artifacts"]:
                directory = directories[artifact["variant"]]
                for name in [artifact["archive"], artifact["archive"] + ".sha256", artifact["manifest"]]:
                    self.assertEqual((upload / name).read_bytes(), (directory / name).read_bytes())
            self.assertEqual((upload / "manifest.json").read_bytes(), (directories["universal"] / "manifest.json").read_bytes())
            self.assertEqual(validate_package(upload, TAG, COMMIT)["variant"], "universal")
            payload = json.loads(fixtures.prepare({variant: upload for variant in fixtures.VARIANTS}, "temporary-key", "Notes"))
            for item, release in zip(payload["artifacts"], metadata["artifacts"]):
                self.assertEqual(item, {key: release[key] for key in item})
            _, assets = checked_upload(upload, REPO, TAG)
            self.assertEqual(len(assets), 11)
            self.assertEqual(len(set(assets)), 11)
            notes = (upload / "release-notes.md").read_text()
            self.assertIn("Apple Silicon (arm64)", notes)
            self.assertIn("Intel (x86_64)", notes)
            self.assertIn("independent updater source signature", notes)

    def test_explicit_package_directories_work_in_api_and_cli(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directories, _ = self.fixture(root)
            self.prepare(root, variant_directories=directories)
            script = Path(__file__).resolve().parents[1] / "github_release.py"
            arguments = [sys.executable, str(script), "prepare", "--repo", REPO, "--tag", TAG,
                         "--commit", COMMIT, "--ci-run", "10", "--directory", str(root), "--output", str(root / "cli-upload")]
            for variant, directory in directories.items():
                arguments.extend(["--variant-directory", variant + "=" + str(directory)])
            subprocess.run(arguments, capture_output=True, check=True)
            self.assertEqual((root / "upload/release.json").read_bytes(), (root / "cli-upload/release.json").read_bytes())

    def test_missing_duplicate_extra_and_unknown_variants_never_fall_back(self):
        for mode in ["missing", "duplicate", "extra", "unknown"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                directories, factory = self.fixture(root)
                if mode == "missing":
                    shutil.rmtree(directories["intel"])
                elif mode == "duplicate":
                    factory.mutate(directories["intel"], {"variant": "applesilicon"})
                elif mode == "unknown":
                    factory.mutate(directories["intel"], {"variant": "unknown"})
                else:
                    shutil.copytree(directories["universal"], root / "extra")
                with self.assertRaises(ValueError):
                    self.prepare(root)
                self.assertFalse((root / "upload").exists())

    def test_cross_build_source_and_info_variant_receipts_fail_before_output(self):
        for mutation in [{"buildVersion": "3"}, {"gitCommit": "b" * 40}, {"sourceFiles": {"source": "c" * 64}},
                         {"minimumSystemVersion": "27.0"}, {"distributionVariantSource": "legacy-universal"}]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                directories, factory = self.fixture(root)
                factory.mutate(directories["intel"], mutation)
                with self.assertRaises(ValueError):
                    self.prepare(root)
                self.assertFalse((root / "upload").exists())

    def test_versioned_manifest_and_checksum_must_match_the_same_image(self):
        for mode in ["manifest", "checksum", "linked-manifest"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                directories, _ = self.fixture(root)
                directory = directories["intel"]
                manifest = next(directory.glob("*.manifest.json"))
                if mode == "manifest":
                    manifest.write_bytes(manifest.read_bytes() + b" ")
                elif mode == "checksum":
                    next(directory.glob("*.sha256")).write_text("0" * 64 + "  wrong.dmg\n")
                else:
                    manifest.unlink()
                    manifest.symlink_to(directory / "manifest.json")
                with self.assertRaises(ValueError):
                    self.prepare(root)

    def test_upload_assembles_all_three_assets_and_retains_draft_gate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            self.prepare(root)
            upload = root / "upload"
            _, assets = checked_upload(upload, REPO, TAG)
            with patch("github_release.resolve", return_value={"commit": COMMIT}) as resolve, patch("github_release.subprocess.run") as run:
                publish(upload, REPO, TAG)
                self.assertEqual(run.call_count, 1)
                command = run.call_args.args[0]
                self.assertIn("--draft", command)
                self.assertIn("--verify-tag", command)
                self.assertIn("--prerelease", command)
                self.assertEqual(command[-len(assets):], [str(upload / name) for name in assets])
                resolve.assert_called_once_with(REPO, TAG, "")

    def test_modified_or_incomplete_release_metadata_cannot_reach_publish(self):
        mutations = [lambda info: info["artifacts"].pop(),
                     lambda info: info["artifacts"][1].update({"url": "https://evil.example/app.dmg"}),
                     lambda info: info["artifacts"][1].update({"manifestSHA256": "0" * 64}),
                     lambda info: info["artifacts"][1].update({"manifest": "../unsafe.json"}),
                     lambda info: info["artifacts"][1].update({"installedBytes": 61 * 1024 * 1024}),
                     lambda info: info.update({"buildVersion": "3"}),
                     lambda info: info.update({"format": 1}),
                     lambda info: info.update({"architecture": "intel"})]
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.fixture(root)
                self.prepare(root)
                upload = root / "upload"
                info = json.loads((upload / "release.json").read_bytes())
                mutation(info)
                (upload / "release.json").write_text(json.dumps(info))
                with patch("github_release.resolve") as resolve, patch("github_release.subprocess.run") as run:
                    with self.assertRaises(ValueError):
                        publish(upload, REPO, TAG)
                    resolve.assert_not_called()
                    run.assert_not_called()

    def test_missing_compatibility_alias_and_variant_image_stop_before_server_validation(self):
        for name in ["manifest.json", "WeGit-2.0.0-rc.1-macos-intel-adhoc.dmg"]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.fixture(root)
                self.prepare(root)
                upload = root / "upload"
                (upload / name).unlink()
                with patch("github_release.resolve") as resolve, patch("github_release.subprocess.run") as run:
                    with self.assertRaises(ValueError):
                        publish(upload, REPO, TAG)
                    resolve.assert_not_called()
                    run.assert_not_called()

    def test_moved_tag_changed_metadata_and_corrupted_intel_copy_stop_upload(self):
        for mode in ["tag", "metadata", "image"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.fixture(root)
                self.prepare(root)
                upload = root / "upload"
                def revalidate(*_):
                    if mode == "tag":
                        return {"commit": "b" * 40}
                    if mode == "metadata":
                        info = json.loads((upload / "release.json").read_bytes())
                        info["ciRun"] = "11"
                        (upload / "release.json").write_text(json.dumps(info))
                    else:
                        next(upload.glob("*-intel-adhoc.dmg")).write_bytes(b"truncated")
                    return {"commit": COMMIT}
                with patch("github_release.resolve", side_effect=revalidate), patch("github_release.subprocess.run") as run:
                    with self.assertRaises(ValueError):
                        publish(upload, REPO, TAG)
                    run.assert_not_called()

    def test_legacy_universal_reading_remains_compatible_but_v2_needs_three(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            legacy_fixtures.ReleaseTests("test_release_assets_retain_exact_bytes_and_honest_signing_metadata").fixture(root)
            report = validate_package(root, "v0.1.0-beta.1", COMMIT)
            self.assertNotIn("variant", report)
            _, legacy = validate_packages(root, "v0.1.0-beta.1", COMMIT)
            self.assertTrue(legacy)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directories, _ = self.fixture(root)
            modern = json.loads((directories["universal"] / "manifest.json").read_bytes())
            modern.pop("variant")
            shutil.copyfile(directories["universal"] / modern["archive"], root / modern["archive"])
            shutil.copyfile(directories["universal"] / (modern["archive"] + ".sha256"), root / (modern["archive"] + ".sha256"))
            (root / "manifest.json").write_text(json.dumps(modern))
            self.assertEqual(validate_package(root, TAG, COMMIT)["version"], "2.0.0")
            with self.assertRaises(ValueError):
                self.prepare(root)

    def test_v1_tag_with_backported_modern_packager_keeps_single_universal_compatibility(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directories, _ = self.fixture(root)
            single = directories["universal"]
            report = json.loads((single / "manifest.json").read_bytes())
            old_name = report["archive"]
            new_name = "WeGit-1.2.1-macos-universal-adhoc.dmg"
            (single / old_name).rename(single / new_name)
            (single / (old_name + ".sha256")).unlink()
            next(single.glob("*.manifest.json")).unlink()
            report.update(version="1.2.1", releaseTag="v1.2.1", archive=new_name)
            data = json.dumps(report).encode()
            (single / "manifest.json").write_bytes(data)
            (single / (Path(new_name).stem + ".manifest.json")).write_bytes(data)
            (single / (new_name + ".sha256")).write_text(report["archiveSHA256"] + "  " + new_name + "\n")
            output = root / "upload"
            prepare(single, output, REPO, "v1.2.1", COMMIT, "10", "20")
            metadata, assets = checked_upload(output, REPO, "v1.2.1")
            self.assertEqual(metadata["architecture"], "universal")
            self.assertNotIn("artifacts", metadata)
            self.assertEqual(len(assets), 5)
            self.assertEqual((output / "manifest.json").read_bytes(), data)
            self.assertEqual((output / (Path(new_name).stem + ".manifest.json")).read_bytes(), data)


if __name__ == "__main__":
    unittest.main()
