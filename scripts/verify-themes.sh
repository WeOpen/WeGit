#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
check_run="$(mktemp -d "$project_root/.build/theme-checks-XXXXXX")"
swift build --product WeGitAskPass
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
library_path="$(swift build --show-bin-path)"
xcrun swiftc -sdk "$sdk_path" -target arm64-apple-macosx27.0 \
  -I "$library_path" "$library_path/WeGitCore.o" -framework AppKit -framework SwiftUI \
  WeGit/DesignSystem/CustomTheme.swift WeGit/DesignSystem/AppColors.swift \
  WeGit/DesignSystem/ThemeWindowBridge.swift WeGit/DesignSystem/AppPresentation.swift \
  WeGit/DesignSystem/BrandGeometry.swift WeGit/DesignSystem/AppStyle.swift \
  WeGit/DesignSystem/YinYangLoadingGlyph.swift WeGit/DesignSystem/YinYangLoadingStyle.swift \
  WeGit/App/AppPreferences.swift scripts/ThemeChecks.swift -o "$check_run/checks"
ditto "$library_path/WeGit_WeGitCore.bundle" "$check_run/WeGit_WeGitCore.bundle"
echo "Report: $check_run/result.json"
"$check_run/checks" "$check_run/result.json"
