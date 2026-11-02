#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p .build
run_dir="$(mktemp -d "$project_root/.build/submodule-lfs-performance-XXXXXX")"
swift build -c release --product WeGitAskPass
library_path="$(swift build -c release --show-bin-path)"
test -s "$library_path/WeGitCore.o"
ditto "$library_path/WeGit_WeGitCore.bundle" "$run_dir/WeGit_WeGitCore.bundle"
xcrun swiftc -O -parse-as-library -I "$library_path" "$library_path/WeGitCore.o" scripts/SubmoduleLFSPerformance.swift -o "$run_dir/checks"
"$run_dir/checks" "$run_dir/result.json"
