#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
check_run="$(mktemp -d "$project_root/.build/appearance-icons-XXXXXX")"
check_app="$check_run/AppearanceChecks.app"
mkdir -p "$check_app/Contents/MacOS" "$check_app/Contents/Resources"
trap 'rm -rf "$check_app"' EXIT
swift build --product WeGitAskPass
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
library_path="$(swift build --show-bin-path)"
xcrun swiftc -sdk "$sdk_path" -target arm64-apple-macosx27.0 \
  -I "$library_path" "$library_path/WeGitCore.o" -framework AppKit -framework SwiftUI \
  WeGit/DesignSystem/CustomTheme.swift WeGit/DesignSystem/AppColors.swift \
  WeGit/DesignSystem/AppPresentation.swift WeGit/App/AppPreferences.swift \
  scripts/AppearanceIconChecks.swift -o "$check_app/Contents/MacOS/AppearanceChecks"
ditto "$library_path/WeGit_WeGitCore.bundle" "$check_app/Contents/Resources/WeGit_WeGitCore.bundle"
cp branding/wegit-v2/WeGit.icns "$check_app/Contents/Resources/AppIcon.icns"
cp WeGit/Resources/AppearanceIcons/WeGitLight.icns "$check_app/Contents/Resources/WeGitLight.icns"
cp WeGit/Resources/AppearanceIcons/WeGitDark.icns "$check_app/Contents/Resources/WeGitDark.icns"
cat > "$check_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.willxue.wegit.AppearanceChecks</string>
<key>CFBundleExecutable</key><string>AppearanceChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
echo "Report: $check_run/result.json"
"$check_app/Contents/MacOS/AppearanceChecks" "$check_run/result.json"
