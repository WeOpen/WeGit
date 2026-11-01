#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p "$project_root/.build"
run_dir="$(mktemp -d "$project_root/.build/submodule-lfs-checks-XXXXXX")"
swift build --product WeGitCore
library_path="$(swift build --show-bin-path)"
xcrun swiftc -parse-as-library -I "$library_path" "$library_path/WeGitCore.o" scripts/SubmoduleLFSChecks.swift -o "$run_dir/checks"
ditto "$library_path/WeGit_WeGitCore.bundle" "$run_dir/WeGit_WeGitCore.bundle"
"$run_dir/checks"
xcrun swiftc -parse-as-library -I "$library_path" "$library_path/WeGitCore.o" scripts/LFSBoundaryChecks.swift -o "$run_dir/lfs-boundaries"
"$run_dir/lfs-boundaries"
