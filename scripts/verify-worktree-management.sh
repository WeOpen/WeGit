#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p .build
check_run="$(mktemp -d "$project_root/.build/worktree-management-checks-XXXXXX")"
swift build --product WeGitAskPass
library_path="$(swift build --show-bin-path)"
ditto "$library_path/WeGit_WeGitCore.bundle" "$check_run/WeGit_WeGitCore.bundle"
xcrun swiftc -parse-as-library -I "$library_path" "$library_path/WeGitCore.o" scripts/WorktreeManagementChecks.swift -o "$check_run/checks"
"$check_run/checks" "$check_run/result.json"
