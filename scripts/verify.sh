#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
swift format lint --strict --recursive WeGitCore WeGit WeGitAskPass WeGitTests WeGitUITests WeGitPerformanceTests Benchmarks Package.swift
swift test
scripts/build.sh Debug
if [[ "${1:-}" == "--ui" ]]; then
  xcodebuild -project WeGit.xcodeproj -scheme WeGit -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-app test
fi
