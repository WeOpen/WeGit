#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
check_scratch="${WEGIT_PRODUCTION_UPDATE_BUILD_PATH:-.build}"
mkdir -p .build
check_run="$(mktemp -d "$project_root/.build/production-update-checks-XXXXXX")"
python3 - "$project_root" "$check_run/inputs-before.json" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
files = [root / "Package.swift", root / "scripts/ProductionUpdateChecks.swift", root / "scripts/verify-production-update.sh"]
for name in ("WeGitCore", "WeGitAskPass"):
    files.extend(path for path in (root / name).rglob("*") if path.is_file() and path.name != ".DS_Store")
report = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(files)}
output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
PY
# Debug's incremental build reuses the batch Core cache. It never runs XCTest.
# Explicit enable-testing is necessary for the private control's testable import.
swift build --configuration debug --product WeGitAskPass -Xswiftc -enable-testing \
  --scratch-path "$check_scratch" > "$check_run/core-build.log" 2>&1
library_path="$(swift build --configuration debug --show-bin-path --scratch-path "$check_scratch")"
test -s "$library_path/WeGitCore.o"
test -d "$library_path/WeGit_WeGitCore.bundle"
xcrun swiftc -parse-as-library -enable-testing -I "$library_path" "$library_path/WeGitCore.o" \
  scripts/ProductionUpdateChecks.swift -o "$check_run/checks" > "$check_run/compile.log" 2>&1
ditto "$library_path/WeGit_WeGitCore.bundle" "$check_run/WeGit_WeGitCore.bundle"
"$check_run/checks" "$check_run/result.json" > "$check_run/run.log" 2>&1
python3 - "$project_root" "$check_run" "$library_path" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, run, products = map(Path, sys.argv[1:])
expected = json.loads((run / "inputs-before.json").read_text())
actual = {path: hashlib.sha256((root / path).read_bytes()).hexdigest() for path in expected}
if actual != expected:
    raise SystemExit("Source inputs changed during production update controls; retained logs are not a pass.")
result = json.loads((run / "result.json").read_text())
names = result.get("passed", [])
if result.get("total") != 30 or result.get("failed") != 0 or len(names) != 30 or len(set(names)) != 30:
    raise SystemExit("Expected exactly 30 distinct executed controls with zero failures.")
if result.get("actualProductionInstall") is not False or result.get("xctestExecuted") is not False:
    raise SystemExit("Control scope metadata is invalid.")
report = {"sourceFiles": actual, "total": 30, "failed": 0, "xctestExecuted": False,
          "coreObjectSHA256": hashlib.sha256((products / "WeGitCore.o").read_bytes()).hexdigest(),
          "controlBinarySHA256": hashlib.sha256((run / "checks").read_bytes()).hexdigest(),
          "resultSHA256": hashlib.sha256((run / "result.json").read_bytes()).hexdigest()}
(run / "inputs.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
print("30/30 isolated persistent update controls passed; " + str(run / "result.json"))
PY
echo "Retained update evidence: $check_run"
