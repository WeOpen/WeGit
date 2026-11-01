#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p .build
run_dir="$(mktemp -d "$project_root/.build/interactive-rebase-checks-XXXXXX")"
trap 'rm -r -- "$run_dir"' EXIT
swift build --product WeGitAskPass
library_path="$(swift build --show-bin-path)"
ditto "$library_path/WeGit_WeGitCore.bundle" "$run_dir/WeGit_WeGitCore.bundle"
for checker in InteractiveRebaseChecks InteractiveRebaseExtendedChecks; do
  xcrun swiftc -parse-as-library -I "$library_path" "$library_path/WeGitCore.o" \
    "scripts/$checker.swift" -o "$run_dir/$checker"
  "$run_dir/$checker"
done
