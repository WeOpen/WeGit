#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$project_root/.build/selectable-text-control/TextControl.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "$project_root/Tools/SelectableTextControl/main.swift" -o "$app/Contents/MacOS/TextControl"
python3 - "$app" <<'PY'
from pathlib import Path
import plistlib,sys
p=Path(sys.argv[1])/'Contents/Info.plist'
p.write_bytes(plistlib.dumps(dict(CFBundleExecutable='TextControl',CFBundleIdentifier='com.willxue.wegit.selectableTextControl',CFBundleName='TextControl',CFBundlePackageType='APPL')))
PY
codesign --force --sign - "$app"
echo "$app"
