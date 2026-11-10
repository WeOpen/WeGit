#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
native_build="${WEGIT_NATIVE_BUILD_PATH:-$project_root/.build-app}"
products="$native_build/Build/Products/Debug"
objects="$native_build/Build/Intermediates.noindex/WeGit.build/Debug/WeGit.build/Objects-normal/arm64"
test -r "$products/WeGit.swiftmodule/arm64-apple-macos.swiftmodule"
test -r "$products/WeGitCore.o"
test -r "$objects/AppState.o"
test -r "$products/WeGit.app/Contents/Resources/build-source.json"
swift format lint --strict scripts/ThemeImportQueueChecks.swift
mkdir -p .build
check_run="$(mktemp -d "$project_root/.build/theme-import-queue-checks-XXXXXX")"
mkdir -m 700 "$check_run/tmp"
python3 - "$project_root" "$products/WeGit.app/Contents/Resources/build-source.json" "$check_run/input-receipt.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]); receipt=Path(sys.argv[2])
source=json.loads(receipt.read_text())
files=source.get('sourceFiles',{})
if not files or source.get('configuration')!='Debug':
 raise SystemExit('A populated Debug build-source receipt is required.')
for name,expected in files.items():
 p=root/name
 if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=expected:
  raise SystemExit('Compiled app source does not match current source: '+name)
inputs=dict(files)
for name in ['scripts/ThemeImportQueueChecks.swift','scripts/verify-theme-import-queue.sh']:
 inputs[name]=hashlib.sha256((root/name).read_bytes()).hexdigest()
Path(sys.argv[3]).write_text(json.dumps({'format':1,'configuration':'Debug','sourceFiles':inputs,
 'buildSourceSHA256':hashlib.sha256(receipt.read_bytes()).hexdigest(),
 'xctestExecuted':False,'nativeUIAcceptance':False},indent=2)+'\n')
PY
app_objects=()
for object in "$objects"/*.o; do
  if [[ "$(basename "$object")" != WeGitApp.o ]]; then
    app_objects+=("$object")
  fi
done
test "${#app_objects[@]}" -gt 1
ditto "$products/WeGit.app/Contents/Resources/WeGit_WeGitCore.bundle" "$check_run/WeGit_WeGitCore.bundle"
xcrun swiftc -parse-as-library -I "$products" scripts/ThemeImportQueueChecks.swift \
  "${app_objects[@]}" "$products/WeGitCore.o" -o "$check_run/ThemeImportQueueChecks" \
  > "$check_run/compile.log" 2>&1
python3 - "$check_run" "$products" "${app_objects[@]}" <<'PY'
import hashlib,json,sys
from pathlib import Path
run=Path(sys.argv[1]); products=Path(sys.argv[2])
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
objects={str(Path(p)):digest(Path(p)) for p in sys.argv[3:]}
objects[str(products/'WeGitCore.o')]=digest(products/'WeGitCore.o')
resources={str(p.relative_to(run)):digest(p) for p in (run/'WeGit_WeGitCore.bundle').rglob('*') if p.is_file()}
(run/'compiled-inputs.json').write_text(json.dumps({'objectFiles':objects,'resources':resources,
 'checkerSHA256':digest(run/'ThemeImportQueueChecks')},indent=2)+'\n')
PY
selected_git="$(xcrun --find git)"
env -u WEGIT_UI_TEST_PERSISTENCE_DIRECTORY -u WEGIT_UI_TEST_REPOSITORY \
  TMPDIR="$check_run/tmp/" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_COUNT=0 GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 \
  "$check_run/ThemeImportQueueChecks" "$selected_git" "$check_run/result.json" \
  "$products/WeGit.app/Contents/Resources/build-source.json" --uitesting \
  > "$check_run/runtime.log" 2>&1
cat "$check_run/runtime.log"
python3 - "$project_root" "$check_run/input-receipt.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]); receipt=json.loads(Path(sys.argv[2]).read_text())
if any(hashlib.sha256((root/name).read_bytes()).hexdigest()!=value for name,value in receipt['sourceFiles'].items()):
 raise SystemExit('Source changed while executing theme import queue controls.')
print('Current source and compiled app input mapping match before and after controls.')
PY
printf 'Theme import queue evidence: %s\n' "$check_run"
