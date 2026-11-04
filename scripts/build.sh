#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
configuration="${1:-Debug}"
case "$configuration" in Debug|Release) ;; *) echo "Usage: scripts/build.sh [Debug|Release] [arm64|x86_64|universal]" >&2; exit 2 ;; esac
architecture="${2:-$(uname -m)}"
if [[ "$configuration" == Release && $# -lt 2 ]]; then architecture=universal; fi
case "$architecture" in
  arm64|x86_64) architectures="$architecture"; destination="platform=macOS,arch=$architecture" ;;
  universal) architectures="arm64 x86_64"; destination='generic/platform=macOS' ;;
  *) echo "Architecture must be arm64, x86_64 or universal." >&2; exit 2 ;;
esac
if [[ "$architecture" != universal && "$architecture" != "$(uname -m)" ]]; then
  destination='generic/platform=macOS'
fi
derived_data="${WEGIT_DERIVED_DATA_PATH:-.build-app}"
if [[ "${WEGIT_SKIP_PROJECT_GENERATION:-0}" != 1 ]] && command -v xcodegen >/dev/null 2>&1; then xcodegen generate; fi
inject_base_entitlements=YES
if [[ "$configuration" == Release ]]; then inject_base_entitlements=NO; fi
xcodebuild -project WeGit.xcodeproj -scheme WeGit -configuration "$configuration" \
  -destination "$destination" -derivedDataPath "$derived_data" \
  ARCHS="$architectures" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS="$inject_base_entitlements" build
