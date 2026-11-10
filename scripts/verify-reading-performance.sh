#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mode="${1:-formal}"
case "$mode" in formal|--compile-only|--diagnostic) ;; *) exit 2 ;; esac
[[ "$#" -le 1 ]] || exit 2
mkdir -p .build
check_run="$(mktemp -d "$project_root/.build/reading-performance-XXXXXX")"
python3 - "$project_root" "$check_run/source-before.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]); paths={Path('Package.swift'),Path('project.yml'),
 Path('WeGit.xcodeproj/project.pbxproj'),Path('scripts/build.sh'),Path('scripts/ReadingPerformance.swift'),
 Path('scripts/verify-reading-performance.sh'),Path('scripts/verify-reading-performance.py'),
 Path('scripts/create-reading-performance-fixtures.py'),Path('scripts/create-benchmark-fixtures.py')}
for directory in ['WeGitCore','WeGitAskPass']:
 paths.update(p.relative_to(root) for p in (root/directory).rglob('*') if p.is_file())
inputs={str(p):hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sorted(paths)}
Path(sys.argv[2]).write_text(json.dumps(inputs,indent=2)+'\n')
PY
swift build -c release --scratch-path "$check_run/build" --product WeGitAskPass > "$check_run/build.log" 2>&1
library_path="$(swift build -c release --scratch-path "$check_run/build" --show-bin-path)"
test -s "$library_path/WeGitCore.o"
test -d "$library_path/WeGit_WeGitCore.bundle"
ditto "$library_path/WeGit_WeGitCore.bundle" "$check_run/WeGit_WeGitCore.bundle"
xcrun swiftc -O -swift-version 6 -parse-as-library -I "$library_path" "$library_path/WeGitCore.o" \
  scripts/ReadingPerformance.swift -o "$check_run/checks" > "$check_run/checker-build.log" 2>&1
python3 - "$project_root" "$check_run" "$library_path" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]); run=Path(sys.argv[2]); library=Path(sys.argv[3])
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
inputs=json.loads((run/'source-before.json').read_text())
if any(digest(root/p)!=sha for p,sha in inputs.items()):
 raise SystemExit('Source changed while compiling reading performance checker.')
receipt={'format':1,'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
 'workspaceDirty':bool(subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip()),
 'inputFiles':inputs,'optimization':'swiftc -O; Release WeGitCore',
 'toolchain':{'swift':subprocess.check_output(['xcrun','swiftc','--version'],text=True).strip(),
  'xcode':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),
  'architecture':subprocess.check_output(['uname','-m'],text=True).strip(),
  'runnerImage':__import__('os').environ.get('ImageVersion','local-unrecorded')},
 'coreObjectPath':str((library/'WeGitCore.o').relative_to(run)),
 'coreObjectSHA256':digest(library/'WeGitCore.o'),'checkerSHA256':digest(run/'checks'),
 'resourceFiles':{str(p.relative_to(run)):digest(p) for p in (run/'WeGit_WeGitCore.bundle').rglob('*') if p.is_file()}}
(run/'input-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
PY
if [[ "$mode" == --compile-only ]]; then
  printf 'Compiled reading checker only: %s\n' "$check_run"
  exit 0
fi
fixture_run="$(mktemp -d "${TMPDIR:-/tmp}/WeGitReadingPerformance-XXXXXX")"
printf '%s\n' "$fixture_run" > "$check_run/fixture-root.txt"
fixture_args=()
if [[ "$mode" == --diagnostic ]]; then fixture_args=(--diagnostic); fi
if [[ "$mode" == --diagnostic ]]; then
  python3 scripts/create-reading-performance-fixtures.py --git "${WEGIT_TEST_GIT:-/usr/bin/git}" \
    --destination "$fixture_run/repositories" "${fixture_args[@]}" > "$check_run/fixture.log" 2>&1
else
  python3 scripts/create-reading-performance-fixtures.py --git "${WEGIT_TEST_GIT:-/usr/bin/git}" \
    --destination "$fixture_run/repositories" > "$check_run/fixture.log" 2>&1
fi
cp "$fixture_run/repositories/fixtures.json" "$check_run/fixtures.json"
if "$check_run/checks" "$fixture_run/repositories/fixtures.json" "$check_run/result.json" \
    "$check_run/input-receipt.json" > "$check_run/runtime.log" 2>&1; then
  cat "$check_run/runtime.log"
else
  checker_status=$?
  cat "$check_run/runtime.log"
  printf 'Reading checker failed (%s); evidence retained: %s\n' "$checker_status" "$check_run" >&2
  exit "$checker_status"
fi
python3 scripts/verify-reading-performance.py "$check_run/result.json" --source-root "$project_root" \
  --fixtures "$check_run/fixtures.json" --artifact-root "$check_run" \
  > "$check_run/independent-verification.json" 2> "$check_run/verification.log"
cat "$check_run/independent-verification.json"
# Delete only this script's exact mkdtemp fixture after every assertion and
# independent sample/source verification passed. Failures retain all inputs.
python3 - "$fixture_run" <<'PY'
import shutil,sys
from pathlib import Path
root=Path(sys.argv[1]); assert root.name.startswith('WeGitReadingPerformance-') and root.is_dir()
shutil.rmtree(root)
PY
printf 'Reading result and immutable input receipt: %s\n' "$check_run"
