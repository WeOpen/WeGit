#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
mode="${1:-current}"
case "$mode" in baseline|current) ;; *) exit 2 ;; esac
destination="$root/.build/v111-catalog/$mode"
bundle="$destination/WeGit Catalog.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
library="$(swift build --show-bin-path)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
source_root="$root"
flags=(-parse-as-library)
if [[ "$mode" == baseline ]]; then
  source_root="$root/.build/v111-baseline-source"
  flags+=(-D V111_BASELINE)
fi
sources=(CustomTheme AppColors ThemeWindowBridge AppPresentation BrandGeometry AppStyle
  YinYangLoadingGlyph YinYangLoadingStyle GlassControls Components)
inputs=()
for name in "${sources[@]}"; do inputs+=("$source_root/WeGit/DesignSystem/$name.swift"); done
inputs+=("$source_root/WeGit/App/AppPreferences.swift")
if [[ "$mode" == current ]]; then
  inputs+=(WeGit/DesignSystem/HeritageArtwork.swift WeGit/App/OperationFeedbackState.swift
    WeGit/DesignSystem/OperationFeedback.swift)
fi
xcrun swiftc -sdk "$sdk" -target arm64-apple-macosx27.0 \
  -I "$library" "$library/WeGitCore.o" -framework AppKit -framework SwiftUI \
  "${flags[@]}" "${inputs[@]}" Tools/DesignSystemCatalog/main.swift \
  -o "$bundle/Contents/MacOS/WeGitCatalog"
ditto "$library/WeGit_WeGitCore.bundle" "$bundle/Contents/Resources/WeGit_WeGitCore.bundle"
if [[ "$mode" == current ]]; then
  xcrun actool WeGit/Resources/BrandAssets.xcassets --compile "$bundle/Contents/Resources" \
    --platform macosx --minimum-deployment-target 27.0 --target-device mac >/dev/null
fi
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.weopen.WeGit.V111Catalog.$mode</string>
<key>CFBundleExecutable</key><string>WeGitCatalog</string>
<key>CFBundleName</key><string>WeGit Catalog</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$bundle"
printf '%s\n' "$bundle"
