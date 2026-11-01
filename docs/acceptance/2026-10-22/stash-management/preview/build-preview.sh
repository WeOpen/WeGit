#!/bin/bash
set -euo pipefail
app=.build/v1-1-m1/StashPreview.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swift build --product WeGitAskPass
lib="$(swift build --show-bin-path)"
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macosx27.0 -I "$lib" "$lib/WeGitCore.o" -framework AppKit -framework SwiftUI WeGit/DesignSystem/CustomTheme.swift WeGit/DesignSystem/AppColors.swift WeGit/DesignSystem/ThemeWindowBridge.swift WeGit/DesignSystem/AppPresentation.swift WeGit/DesignSystem/BrandGeometry.swift WeGit/DesignSystem/AppStyle.swift WeGit/DesignSystem/GlassControls.swift WeGit/DesignSystem/Components.swift WeGit/App/AppPreferences.swift WeGit/Features/StashBrowser.swift .build/v1-1-m1/Preview.swift -o "$app/Contents/MacOS/StashPreview"
ditto "$lib/WeGit_WeGitCore.bundle" "$app/Contents/Resources/WeGit_WeGitCore.bundle"
python3 - <<'PY'
import plistlib
from pathlib import Path
p=Path('.build/v1-1-m1/StashPreview.app/Contents/Info.plist')
p.write_bytes(plistlib.dumps(dict(CFBundleExecutable='StashPreview',CFBundleIdentifier='com.willxue.wegit.stash-preview',CFBundleName='StashPreview',CFBundlePackageType='APPL',NSHighResolutionCapable=True)))
PY
codesign --force --sign - "$app"
