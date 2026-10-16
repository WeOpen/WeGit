#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
swift format lint --strict --recursive WeGitCore WeGit WeGitAskPass WeGitTests WeGitUITests WeGitPerformanceTests Benchmarks Package.swift
if [[ "${WEGIT_SERIAL_CORE_TESTS:-0}" == 1 ]]; then
  swift test --no-parallel
else
  swift test
fi
scripts/build.sh Debug
if [[ "${1:-}" == "--ui" ]]; then
  xcodebuild -project WeGit.xcodeproj -scheme WeGit -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-app test
fi
