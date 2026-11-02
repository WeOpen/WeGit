#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p .build
check_run="$(mktemp -d "$project_root/.build/interactive-rebase-performance-XXXXXX")"
swift build -c release --product WeGitAskPass
library_path="$(swift build -c release --show-bin-path)"
test -s "$library_path/WeGitCore.o"
ditto "$library_path/WeGit_WeGitCore.bundle" "$check_run/WeGit_WeGitCore.bundle"
xcrun swiftc -O -parse-as-library -I "$library_path" "$library_path/WeGitCore.o" \
  scripts/InteractiveRebasePerformance.swift -o "$check_run/checks"
"$check_run/checks" "$check_run/result.json"
