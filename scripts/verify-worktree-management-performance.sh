#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p .build
check_run="$(mktemp -d "$project_root/.build/worktree-performance-XXXXXX")"
swift build -c release --product WeGitAskPass
library_path="$(swift build -c release --show-bin-path)"
ditto "$library_path/WeGit_WeGitCore.bundle" "$check_run/WeGit_WeGitCore.bundle"
xcrun swiftc -O -parse-as-library -I "$library_path" "$library_path/WeGitCore.o" scripts/WorktreeManagementPerformance.swift -o "$check_run/probe"
"$check_run/probe" "$check_run/result.json"
