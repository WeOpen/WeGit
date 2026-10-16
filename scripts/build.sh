#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
configuration="${1:-Debug}"
case "$configuration" in Debug|Release) ;; *) echo "Usage: scripts/build.sh [Debug|Release]" >&2; exit 2 ;; esac
if [[ "${WEGIT_SKIP_PROJECT_GENERATION:-0}" != 1 ]] && command -v xcodegen >/dev/null 2>&1; then xcodegen generate; fi
inject_base_entitlements=YES
if [[ "$configuration" == Release ]]; then inject_base_entitlements=NO; fi
xcodebuild -project WeGit.xcodeproj -scheme WeGit -configuration "$configuration" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-app \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS="$inject_base_entitlements" build
