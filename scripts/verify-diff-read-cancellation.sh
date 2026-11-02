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
swift format lint --strict scripts/DiffReadCancellationChecks.swift
mkdir -p .build
check_run="$(mktemp -d "$project_root/.build/diff-read-cancellation-checks-XXXXXX")"
app_objects=()
for object in "$objects"/*.o; do
  if [[ "$(basename "$object")" != WeGitApp.o ]]; then
    app_objects+=("$object")
  fi
done
test "${#app_objects[@]}" -gt 1
ditto "$products/WeGit.app/Contents/Resources/WeGit_WeGitCore.bundle" "$check_run/WeGit_WeGitCore.bundle"
xcrun swiftc -parse-as-library -I "$products" scripts/DiffReadCancellationChecks.swift \
  "${app_objects[@]}" "$products/WeGitCore.o" -o "$check_run/DiffReadCancellationChecks"
selected_git="$(xcrun --find git)"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_COUNT=0 GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 \
  "$check_run/DiffReadCancellationChecks" "$selected_git" "$check_run/result.json" \
  "$products/WeGit.app/Contents/Resources/build-source.json" --uitesting
