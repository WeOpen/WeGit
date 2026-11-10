import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "migration_checker", Path(__file__).resolve().parents[2] / "verify-application-migration.py")
migration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration)


class MigrationInputTests(unittest.TestCase):
    def test_source_and_resources_are_bound_without_external_discovery_tools(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = {"Package.swift": b"package", "WeGitCore/Domain/A.swift": b"source",
                      "WeGitCore/Resources/en.lproj/Localizable.strings": b"resource"}
            for name, data in inputs.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            with patch.object(migration, "ROOT", root), patch.object(
                    migration.subprocess, "run", side_effect=AssertionError("No external tool needed")):
                self.assertEqual(migration.core_inputs(), {
                    name: hashlib.sha256(data).hexdigest() for name, data in inputs.items()})
                (root / "WeGitCore/Domain/A.swift").write_bytes(b"changed")
                self.assertNotEqual(migration.core_inputs()["WeGitCore/Domain/A.swift"],
                                    hashlib.sha256(b"source").hexdigest())

    def test_missing_empty_and_redirected_sources_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Package.swift").write_text("package")
            with patch.object(migration, "ROOT", root):
                with self.assertRaises(RuntimeError):
                    migration.core_inputs()
                (root / "WeGitCore").mkdir()
                with self.assertRaises(RuntimeError):
                    migration.core_inputs()
                (root / "WeGitCore/source.swift").symlink_to(root / "Package.swift")
                with self.assertRaises(RuntimeError):
                    migration.core_inputs()
