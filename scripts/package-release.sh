#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
release_mode="${1:---preview}"
case "$release_mode" in
  --preview|--adhoc|--sign|--notarize) ;;
  *) echo "Usage: scripts/package-release.sh [--preview|--adhoc|--sign|--notarize]" >&2; exit 2 ;;
esac
mkdir -p .build/releases
release_run="$(mktemp -d "$project_root/.build/releases/package-XXXXXX")"
release_source="$project_root/.build-app/Build/Products/Release/WeGit.app"

if [[ "$release_mode" == "--sign" || "$release_mode" == "--notarize" ]]; then
  : "${WEGIT_TEAM_ID:?Set the Apple Developer team ID}"
  : "${WEGIT_SIGNING_IDENTITY:?Set an existing Developer ID Application identity}"
  release_bundle_id="${WEGIT_BUNDLE_ID:-com.willxue.wegit}"
  [[ "$release_bundle_id" == "com.willxue.wegit" ]] || {
    echo "The confirmed V1.0 bundle identifier is com.willxue.wegit." >&2; exit 2;
  }
  if [[ "$release_mode" == "--notarize" ]]; then
    : "${WEGIT_NOTARY_PROFILE:?Set an existing notarytool Keychain profile name}"
  fi
  case "$WEGIT_SIGNING_IDENTITY" in
    "Developer ID Application:"*) ;;
    *) echo "Use the full name of a Developer ID Application identity; no ad-hoc fallback." >&2; exit 2 ;;
  esac
  if [[ "${WEGIT_SKIP_PROJECT_GENERATION:-0}" != 1 ]] && command -v xcodegen >/dev/null 2>&1; then xcodegen generate; fi
  xcodebuild -project WeGit.xcodeproj -scheme WeGit -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$release_run/build" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$WEGIT_SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$WEGIT_TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$release_bundle_id" \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp build
  release_source="$release_run/build/Build/Products/Release/WeGit.app"
fi

if [[ "$release_mode" == "--adhoc" ]]; then
  if [[ "${WEGIT_SKIP_PROJECT_GENERATION:-0}" != 1 ]] && command -v xcodegen >/dev/null 2>&1; then xcodegen generate; fi
  xcodebuild -project WeGit.xcodeproj -scheme WeGit -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$release_run/build" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    PRODUCT_BUNDLE_IDENTIFIER=com.willxue.wegit \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp=none build
  release_source="$release_run/build/Build/Products/Release/WeGit.app"
fi

[[ -d "$release_source" ]] || { echo "Build the Release application first: scripts/build.sh Release" >&2; exit 1; }
python3 scripts/build_provenance.py --source-root "$project_root" --verify-bundle "$release_source"
release_app="$release_run/WeGit.app"
ditto "$release_source" "$release_app"
[[ -x "$release_app/Contents/Helpers/WeGitAskPass" ]] || { echo "AskPass helper is missing" >&2; exit 1; }
[[ -f "$release_app/Contents/Resources/LICENSE" ]] || { echo "MIT license is missing from the bundle" >&2; exit 1; }
[[ ! -e "$release_app/Contents/MacOS/WeGit.debug.dylib" ]] || { echo "Refusing to package a Debug application" >&2; exit 1; }
if /usr/bin/strings "$release_app/Contents/MacOS/WeGit" | /usr/bin/grep -E -- 'WEGIT_UI_TEST_REPOSITORY|WEGIT_HISTORY_DELAY_MARKER|WEGIT_PERFORMANCE_REPORT|--uitesting' >/dev/null; then
  echo "Refusing to package an application with UI-test entry points" >&2
  exit 1
fi
codesign --verify --deep --strict "$release_app"
release_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$release_app/Contents/Info.plist")"
[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a three-part release version" >&2; exit 1; }
release_suffix=macos-universal-development
if [[ "$release_mode" == "--sign" || "$release_mode" == "--notarize" ]]; then
  codesign -d --verbose=4 "$release_app" 2> "$release_run/signature.txt"
  /usr/bin/grep -q 'Authority=Developer ID Application:' "$release_run/signature.txt"
  /usr/bin/grep -q 'flags=.*runtime' "$release_run/signature.txt"
  release_suffix=macos-universal-signed
fi

if [[ "$release_mode" == "--notarize" ]]; then
  ditto -c -k --keepParent "$release_app" "$release_run/notary-upload.zip"
  xcrun notarytool submit "$release_run/notary-upload.zip" --keychain-profile "$WEGIT_NOTARY_PROFILE" \
    --wait --output-format json > "$release_run/notarization.json"
  python3 - "$release_run/notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get("status") != "Accepted":
    raise SystemExit("Notarization was not accepted; inspect the saved result.")
PY
  xcrun stapler staple "$release_app"
  xcrun stapler validate "$release_app"
  spctl --assess --type execute --verbose "$release_app"
  release_suffix=macos-universal-notarized
fi

archive_version="$release_version"
if [[ "$release_mode" == "--adhoc" ]]; then
  codesign -d --verbose=4 "$release_app" 2> "$release_run/signature.txt"
  /usr/bin/grep -q 'Signature=adhoc' "$release_run/signature.txt"
  release_suffix=macos-universal-adhoc
  archive_version="$(python3 - "$release_version" "${WEGIT_RELEASE_TAG:-}" <<'PYTAG'
import re, sys
version, tag = sys.argv[1:]
if tag and not re.fullmatch(r"v" + re.escape(version) + r"(?:-(?:alpha|beta|rc)\.(?:0|[1-9][0-9]*))?", tag):
    raise SystemExit("Release tag must match the app version (vX.Y.Z or vX.Y.Z-beta.N).")
print(tag[1:] if tag else version)
PYTAG
)"
fi
release_archive="$release_run/WeGit-${archive_version}-${release_suffix}.dmg"
python3 scripts/release_artifact.py --source-root "$project_root" --app "$release_app" \
  --output "$release_run" --archive "$release_archive" --mode "${release_mode#--}"
echo "Package: $release_archive"
echo "Manifest: $release_run/manifest.json"
