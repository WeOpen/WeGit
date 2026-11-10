#!/usr/bin/env python3
"""Compile real migration/theme/model sources and run private non-XCTest controls."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    "WeGit/DesignSystem/CustomTheme.swift", "WeGit/DesignSystem/AppColors.swift",
    "WeGit/DesignSystem/ThemeWindowBridge.swift", "WeGit/DesignSystem/AppPresentation.swift",
    "WeGit/DesignSystem/BrandGeometry.swift", "WeGit/DesignSystem/AppStyle.swift",
    "WeGit/DesignSystem/HeritageArtwork.swift", "WeGit/DesignSystem/YinYangLoadingGlyph.swift",
    "WeGit/DesignSystem/YinYangLoadingStyle.swift", "WeGit/App/AppPreferences.swift",
    "WeGit/App/ApplicationMigrationState.swift", "WeGit/App/PreferenceMigration.swift",
]
V12_RECENT_SCHEMA_SHA = "566f64cf82955b2925ed1fa5e6ce193c648ff596f23ec09639e86f993f004980"


def run(command, log, *, environment=None):
    with log.open("w") as output:
        result = subprocess.run(command, cwd=ROOT, env=environment, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); retained log: {log}")


def core_inputs():
    directory = ROOT / "WeGitCore"
    if not directory.is_dir() or directory.is_symlink():
        raise RuntimeError("Core source directory is missing or redirected")
    names = []
    for path in directory.rglob("*"):
        if path.is_symlink():
            raise RuntimeError("Core source inputs must not use symbolic links")
        if path.is_file():
            names.append(str(path.relative_to(ROOT)))
    if not any(name.endswith(".swift") for name in names):
        raise RuntimeError("Core source inputs are empty")
    return {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sorted(names + ["Package.swift"])}


def tree_hashes(folder):
    if not folder.is_dir():
        raise RuntimeError(f"Missing compiled artifact directory: {folder}")
    return {str(path.relative_to(folder)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(folder.rglob("*")) if path.is_file()}


def module_hashes(library):
    for location in ["WeGitCore.swiftmodule", "Modules/WeGitCore.swiftmodule"]:
        module = library / location
        if module.is_dir():
            return {location + "/" + name: value for name, value in tree_hashes(module).items()}
        if module.is_file():
            artifacts = {}
            for suffix in ["swiftmodule", "swiftdoc", "swiftsourceinfo"]:
                path = module.with_suffix("." + suffix)
                if path.is_file():
                    artifacts[str(path.relative_to(library))] = hashlib.sha256(path.read_bytes()).hexdigest()
            return artifacts
    raise RuntimeError(f"Missing compiled Core module in {library}")


def library_receipt(library):
    return {
        "format": 1,
        "coreSourceSHA256": core_inputs(),
        "objectSHA256": hashlib.sha256((library / "WeGitCore.o").read_bytes()).hexdigest(),
        "moduleSHA256": module_hashes(library),
        "resourceSHA256": tree_hashes(library / "WeGit_WeGitCore.bundle"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library-path", type=Path, help="Reuse the batch's compiled matching Core module/object")
    parser.add_argument("--library-receipt", type=Path, help="Compiler receipt binding current Core inputs and actual library artifacts")
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    args = parser.parse_args()
    if bool(args.library_path) != bool(args.library_receipt):
        parser.error("--library-path requires --library-receipt; unverified compiled modules cannot be reused")
    (ROOT / ".build").mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="application-migration-", dir=ROOT / ".build"))
    source = output / "source"
    source.mkdir()
    hashes = {}
    compiled = []
    for name in SOURCES:
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        data = (ROOT / name).read_bytes()
        target.write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
        compiled.append(str(target))
    app = (ROOT / "WeGit/App/AppState.swift").read_text()
    begin = app.index("@Model\nfinal class RecentRepository")
    end_model = app.index("enum WorkspaceRoute", begin)
    actual_schema = app[begin:end_model].strip()
    schema_sha = hashlib.sha256(actual_schema.encode()).hexdigest()
    if schema_sha != V12_RECENT_SCHEMA_SHA:
        raise RuntimeError("RecentRepository schema changed from fixed v1.2; review migration compatibility before running.")
    end = app.index("@Observable @MainActor\nfinal class WorkspaceState", begin)
    models = source / "CurrentMigrationModels.swift"
    models.write_text("import Foundation\nimport SwiftData\nimport WeGitCore\n" + app[begin:end])
    compiled.append(str(models))
    hashes["CurrentMigrationModels.swift"] = hashlib.sha256(models.read_bytes()).hexdigest()
    control = source / "MigrationChecks.swift"
    control.write_bytes((ROOT / "scripts/MigrationChecks.swift").read_bytes())
    hashes["scripts/MigrationChecks.swift"] = hashlib.sha256(control.read_bytes()).hexdigest()
    if args.library_path:
        library = args.library_path.resolve()
        if args.library_receipt.stat().st_size > 1024 * 1024:
            raise RuntimeError("Core compiler receipt exceeds 1 MiB")
        receipt = json.loads(args.library_receipt.read_text())
        if receipt != library_receipt(library):
            raise RuntimeError("Core receipt/source/module/object/resource mismatch; compile a fresh private scratch instead")
        (output / "core-library-receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True))
    else:
        scratch = output / "core-build"
        before = core_inputs()
        run(["swift", "build", "--scratch-path", str(scratch), "-c", args.configuration, "--target", "WeGitCore"], output / "core-build.log")
        library = Path(subprocess.run(["swift", "build", "--scratch-path", str(scratch), "-c", args.configuration, "--show-bin-path"], cwd=ROOT, check=True, text=True, capture_output=True).stdout.strip())
        if core_inputs() != before:
            raise RuntimeError("Core inputs changed during private compilation; result is not reusable")
        (output / "core-library-receipt.json").write_text(json.dumps(library_receipt(library), indent=2, sort_keys=True))
    core_object = library / "WeGitCore.o"
    if not core_object.is_file():
        raise RuntimeError(f"Missing compiled Core object: {core_object}")
    hashes["WeGitCore.o"] = hashlib.sha256(core_object.read_bytes()).hexdigest()
    (output / "inputs.json").write_text(json.dumps(hashes, indent=2, sort_keys=True))
    command = ["xcrun", "swiftc", "-parse-as-library", "-whole-module-optimization", "-swift-version", "6", "-module-name", "WeGitMigrationControl", "-I", str(library), "-I", str(library / "Modules"), str(core_object)]
    command += ["-Onone", "-D", "DEBUG"] if args.configuration == "debug" else ["-O"]
    command += compiled + [str(control), "-o", str(output / "checks")]
    started = time.monotonic()
    run(command, output / "source-build.log")
    shutil.copytree(library / "WeGit_WeGitCore.bundle", output / "WeGit_WeGitCore.bundle")
    environment = os.environ.copy()
    environment.update({"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"})
    run([str(output / "checks"), str(output / "fixtures")], output / "run.log", environment=environment)
    results = sorted((output / "fixtures").glob("*/result.json"))
    if len(results) != 1:
        raise RuntimeError(f"Expected one actual migration result; retained artifacts: {output}")
    result = json.loads(results[0].read_text())
    if result.get("allPassed") is not True or result.get("xctestExecuted") is not False:
        raise RuntimeError(f"Migration result incomplete: {results[0]}")
    (output / "receipt.json").write_text(json.dumps({"configuration": args.configuration, "elapsedSeconds": time.monotonic() - started, "xctestExecuted": False, "recentSchemaSHA256": schema_sha, "result": str(results[0])}, indent=2, sort_keys=True))
    print(f"Migration controls: {result['checkCount']} passed; artifacts: {output}")


if __name__ == "__main__":
    main()
