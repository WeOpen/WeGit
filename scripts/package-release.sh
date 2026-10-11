#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
release_mode="${1:---preview}"
case "$release_mode" in
  --preview|--sign|--notarize) ;;
  *) echo "Usage: scripts/package-release.sh [--preview|--sign|--notarize]" >&2; exit 2 ;;
esac
mkdir -p .build/releases
release_run="$(mktemp -d "$project_root/.build/releases/package-XXXXXX")"
release_source="$project_root/.build-app/Build/Products/Release/WeGit.app"

if [[ "$release_mode" != "--preview" ]]; then
  : "${WEGIT_TEAM_ID:?Set the Apple Developer team ID}"
  : "${WEGIT_SIGNING_IDENTITY:?Set an existing Developer ID Application identity}"
  release_bundle_id="${WEGIT_BUNDLE_ID:-com.willxue.WeGit}"
  [[ "$release_bundle_id" == "com.willxue.WeGit" ]] || {
    echo "The confirmed V1.0 bundle identifier is com.willxue.WeGit." >&2; exit 2;
  }
  if [[ "$release_mode" == "--notarize" ]]; then
    : "${WEGIT_NOTARY_PROFILE:?Set an existing notarytool Keychain profile name}"
  fi
  case "$WEGIT_SIGNING_IDENTITY" in
    "Developer ID Application:"*) ;;
    *) echo "Use the full name of a Developer ID Application identity; no ad-hoc fallback." >&2; exit 2 ;;
  esac
  if command -v xcodegen >/dev/null 2>&1; then xcodegen generate; fi
  xcodebuild -project WeGit.xcodeproj -scheme WeGit -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$release_run/build" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$WEGIT_SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$WEGIT_TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$release_bundle_id" \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp build
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
release_suffix=development
if [[ "$release_mode" != "--preview" ]]; then
  codesign -d --verbose=4 "$release_app" 2> "$release_run/signature.txt"
  /usr/bin/grep -q 'Authority=Developer ID Application:' "$release_run/signature.txt"
  /usr/bin/grep -q 'flags=.*runtime' "$release_run/signature.txt"
  release_suffix=signed
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
  release_suffix=notarized
fi

release_archive="$release_run/WeGit-${release_version}-${release_suffix}.zip"
ditto -c -k --keepParent "$release_app" "$release_archive"
shasum -a 256 "$release_archive" > "$release_archive.sha256"
python3 - "$project_root" "$release_run" "$release_archive" "$release_mode" <<'PY'
import hashlib, json, plistlib, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
root, output, archive = map(Path, sys.argv[1:4])
mode = sys.argv[4]
info = plistlib.loads((output / "WeGit.app/Contents/Info.plist").read_bytes())
paths = [root / "Package.swift", root / "project.yml", root / "LICENSE"]
for name in ("WeGitCore", "WeGit", "WeGitAskPass", "WeGitTests", "WeGitUITests", "WeGitPerformanceTests", "Benchmarks", "scripts"):
    paths.extend(p for p in (root / name).rglob("*") if p.is_file() and p.suffix in (".swift", ".c", ".h", ".sh", ".py", ".entitlements"))
sources = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
commit = subprocess.run(["git", "rev-parse", "--verify", "HEAD"], cwd=root, text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
report = {
    "createdAt": datetime.now(timezone.utc).isoformat(), "version": info["CFBundleShortVersionString"],
    "bundleIdentifier": info["CFBundleIdentifier"], "mode": mode.removeprefix("--"),
    "notarized": mode == "--notarize", "gitCommit": commit.stdout.strip() if commit.returncode == 0 else None,
    "workspaceDirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root)),
    "archive": archive.name, "archiveSHA256": hashlib.sha256(archive.read_bytes()).hexdigest(),
    "buildReceiptSHA256": hashlib.sha256((output / "WeGit.app/Contents/Resources/build-source.json").read_bytes()).hexdigest(),
    "sourceFiles": sources,
}
(output / "manifest.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
PY
echo "Package: $release_archive"
echo "Manifest: $release_run/manifest.json"
