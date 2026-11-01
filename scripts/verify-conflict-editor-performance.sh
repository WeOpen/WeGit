#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p "$project_root/.build"
run_dir="$(mktemp -d "$project_root/.build/conflict-editor-performance-XXXXXX")"
swift build -c release -Xswiftc -enable-testing --product WeGitCore
release_bin="$(swift build -c release -Xswiftc -enable-testing --show-bin-path)"
# WeGitCore.o is a linkable object file, not an executable.
test -s "$release_bin/WeGitCore.o"
test -d "$release_bin/WeGit_WeGitCore.bundle"
ditto "$release_bin/WeGit_WeGitCore.bundle" "$run_dir/WeGit_WeGitCore.bundle"
xcrun swiftc -parse-as-library -O -I "$release_bin" "$release_bin/WeGitCore.o" \
  scripts/ConflictEditorPerformance.swift -o "$run_dir/performance"
"$run_dir/performance" "$run_dir/result.json"
cp "$run_dir/result.json" .build/conflict-editor-performance-latest.json
cat .build/conflict-editor-performance-latest.json
