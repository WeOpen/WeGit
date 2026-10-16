import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from github_release import parse_tag, prepare, validate_package, validate_run

COMMIT = "a" * 40


class ReleaseTests(unittest.TestCase):
    def test_tag_policy_rejects_shell_input_wrong_versions_and_ambiguous_labels(self):
        self.assertEqual(parse_tag("v1.0.0"), ("1.0.0", False))
        self.assertEqual(parse_tag("v1.0.0-beta.2"), ("1.0.0", True))
        for tag in ["1.0.0", "v01.0.0", "v1.0.0-beta.01", "v1.0.0;echo x", "v1.0.0-anything", "../v1.0.0"]:
            with self.assertRaises(ValueError):
                parse_tag(tag)

    def test_release_gate_requires_exact_sha_workflow_main_and_executed_jobs(self):
        run = {"workflow_id": 7, "head_sha": COMMIT, "head_branch": "main", "event": "workflow_dispatch",
               "status": "completed", "conclusion": "success"}
        jobs = [{"name": "Full acceptance", "conclusion": "success"}]
        validate_run(run, 7, COMMIT, jobs, ["Full acceptance"])
        for change in [{"workflow_id": 8}, {"head_sha": "b" * 40}, {"head_branch": "feature"},
                       {"event": "pull_request"}, {"conclusion": "cancelled"}, {"status": "in_progress"}]:
            with self.assertRaises(ValueError):
                validate_run(run | change, 7, COMMIT, jobs, ["Full acceptance"])
        for altered in [[], [{"name": "Full acceptance", "conclusion": "skipped"}],
                        [{"name": "Full acceptance", "conclusion": "failure"}]]:
            with self.assertRaises(ValueError):
                validate_run(run, 7, COMMIT, altered, ["Full acceptance"])

    def fixture(self, root):
        name = "WeGit-0.1.0-beta.1-macos-arm64-adhoc.zip"
        with zipfile.ZipFile(root / name, "w") as handle:
            handle.writestr("WeGit.app/Contents/fixture.txt", "Release fixture")
        checksum = hashlib.sha256((root / name).read_bytes()).hexdigest()
        manifest = {"gitCommit": COMMIT, "workspaceDirty": False, "version": "0.1.0", "releaseTag": "v0.1.0-beta.1",
                    "mode": "adhoc", "signing": "ad-hoc", "notarized": False, "bundleIdentifier": "com.willxue.wegit",
                    "archive": name, "archiveSHA256": checksum}
        (root / "manifest.json").write_text(json.dumps(manifest))
        (root / (name + ".sha256")).write_text(checksum + "  " + name + "\n")
        return manifest

    def test_release_assets_retain_exact_bytes_and_honest_signing_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self.fixture(root)
            prepare(root, root / "upload", "WeOpen/WeGit", "v0.1.0-beta.1", COMMIT, "123", "")
            output = json.loads((root / "upload/release.json").read_text())
            self.assertEqual(output["commit"], COMMIT)
            self.assertFalse(output["notarized"])
            self.assertTrue(output["prerelease"])
            self.assertEqual((root / manifest["archive"]).read_bytes(), (root / "upload" / manifest["archive"]).read_bytes())
            note = (root / "upload/release-notes.md").read_text()
            self.assertIn("only creates a **draft**", note)
            self.assertIn("not notarized", note)

    def test_modified_archive_dirty_tree_wrong_id_tag_and_manifest_are_refused(self):
        mutations = [{"workspaceDirty": True}, {"gitCommit": "b" * 40}, {"version": "1.0.0"},
                     {"releaseTag": "v0.1.0"}, {"bundleIdentifier": "development"}, {"notarized": True},
                     {"archive": "../unsafe.zip"}, {"archiveSHA256": "0" * 64}, {"mode": "preview"}]
        for change in mutations:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                original = self.fixture(root)
                (root / "manifest.json").write_text(json.dumps(original | change))
                with self.assertRaises(ValueError):
                    validate_package(root, "v0.1.0-beta.1", COMMIT)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = self.fixture(root)
            (root / original["archive"]).write_bytes(b"tampered")
            with self.assertRaises(ValueError):
                validate_package(root, "v0.1.0-beta.1", COMMIT)

    def test_checksum_file_cannot_name_another_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = self.fixture(root)
            (root / (original["archive"] + ".sha256")).write_text(original["archiveSHA256"] + "  other.zip\n")
            with self.assertRaises(ValueError):
                validate_package(root, "v0.1.0-beta.1", COMMIT)

class ReleaseResolutionTests(unittest.TestCase):
    def response(self, repo, suffix, payload=None):
        run = {"id": 10, "workflow_id": 7, "head_sha": COMMIT, "head_branch": "main", "event": "push",
               "status": "completed", "conclusion": "success"}
        if suffix.startswith("git/ref/tags/"):
            return {"object": {"type": "tag", "sha": "c" * 40}}
        if suffix.startswith("git/tags/"):
            return {"object": {"type": "commit", "sha": COMMIT}}
        if suffix.startswith("compare/"):
            return {"merge_base_commit": {"sha": COMMIT}}
        if suffix == "actions/workflows/verify.yml":
            return {"id": 7}
        if suffix.startswith("actions/workflows/verify.yml/runs?"):
            return {"workflow_runs": [run]}
        if suffix.startswith("actions/runs/10/jobs?"):
            return {"jobs": [{"name": name, "conclusion": "success"} for name in ["Repository policy", "Native macOS"]]}
        if suffix == "actions/workflows/acceptance.yml":
            return {"id": 8}
        if suffix == "actions/runs/20":
            return run | {"id": 20, "workflow_id": 8, "event": "workflow_dispatch"}
        if suffix.startswith("actions/runs/20/jobs?"):
            return {"jobs": [{"name": "Full acceptance", "conclusion": "success"}]}
        if suffix == "actions/runs/10":
            return run
        raise AssertionError(suffix)

    def test_stable_requires_canonical_full_acceptance_not_just_a_green_run(self):
        from unittest.mock import patch
        from github_release import resolve
        with patch("github_release.api", side_effect=self.response):
            self.assertEqual(resolve("WeOpen/WeGit", "v0.1.0-beta.1", "")["commit"], COMMIT)
            self.assertEqual(resolve("WeOpen/WeGit", "v0.1.0", "20")["acceptance_run"], "20")
            for candidate in ["", "10"]:
                with self.assertRaises(ValueError):
                    resolve("WeOpen/WeGit", "v0.1.0", candidate)

    def test_unreviewed_tag_cannot_authorize_release(self):
        from unittest.mock import patch
        from github_release import resolve
        def altered(repo, suffix, payload=None):
            if suffix.startswith("compare/"):
                return {"merge_base_commit": {"sha": "b" * 40}}
            return self.response(repo, suffix, payload)
        with patch("github_release.api", side_effect=altered), self.assertRaises(ValueError):
            resolve("WeOpen/WeGit", "v0.1.0-beta.1", "")

    def test_publication_is_always_draft_and_refuses_moved_tag_or_misleading_metadata(self):
        from unittest.mock import patch
        from github_release import publish
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ReleaseTests().fixture(root)
            prepare(root, root / "upload", "WeOpen/WeGit", "v0.1.0-beta.1", COMMIT, "10", "")
            with patch("github_release.resolve", return_value={"commit": COMMIT}), patch("github_release.subprocess.run") as run:
                publish(root / "upload", "WeOpen/WeGit", "v0.1.0-beta.1")
                command = run.call_args.args[0]
                self.assertIn("--draft", command)
                self.assertIn("--verify-tag", command)
                self.assertIn("--prerelease", command)
            with patch("github_release.resolve", return_value={"commit": "b" * 40}), patch("github_release.subprocess.run") as run:
                with self.assertRaises(ValueError):
                    publish(root / "upload", "WeOpen/WeGit", "v0.1.0-beta.1")
                run.assert_not_called()
            path = root / "upload/release.json"
            data = json.loads(path.read_text()); data["notarized"] = True; path.write_text(json.dumps(data))
            with patch("github_release.subprocess.run") as run, self.assertRaises(ValueError):
                publish(root / "upload", "WeOpen/WeGit", "v0.1.0-beta.1")
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
