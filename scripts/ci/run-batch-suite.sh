#!/bin/bash
set -euo pipefail
# Fixed commands, not a shell program supplied by a PR label/manual input.
case "${1:-}" in
  core)
    swift format lint --strict --recursive WeGitCore WeGitAskPass WeGitUpdater WeGitTests Benchmarks Package.swift
    swift test --no-parallel
    scripts/ci/prepare-git-246.sh
    env WEGIT_TEST_GIT="$(cat .build/git-246-path)" swift test --no-parallel
    env WEGIT_TEST_GIT="$(brew --prefix git)/bin/git" swift test --no-parallel | tee .build/ci/homebrew-core.log
    ;;
  signing) scripts/verify-gpg-compatibility.sh ;;
  behavior)
    # AppState checks link the Debug module/objects and its source receipt.
    # A validation receipt is not a build artifact; build the prerequisite here.
    scripts/build.sh Debug
    scripts/verify-preference-migration.sh
    scripts/ci/native-behavior.sh behavior
    ;;
  performance) scripts/ci/native-behavior.sh performance ;;
  application)
    swift format lint --strict --recursive WeGit WeGitUpdater WeGitUITests WeGitPerformanceTests
    swift format lint --strict scripts/*Checks.swift scripts/*Performance.swift scripts/LocalizationSources.swift scripts/verify-inspector-startup.swift
    python3 scripts/verify-localization.py
    scripts/build.sh Debug
    xcodebuild -project WeGit.xcodeproj -scheme WeGit -configuration Debug \
      -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-app \
      -resultBundlePath .build/ci/native-build.xcresult build-for-testing
    python3 scripts/verify-ui-git-wrapper.py .build-app/Build/Products/Debug/WeGitTestGit
    ;;
  package)
    for variant in universal applesilicon intel; do
      case "$variant" in universal) architecture=universal ;; applesilicon) architecture=arm64 ;; intel) architecture=x86_64 ;; esac
      scripts/build.sh Release "$architecture"
      scripts/package-release.sh --preview --variant "$variant"
    done
    git diff --exit-code
    ;;
  *) echo 'Unknown registered backend validation suite' >&2; exit 2 ;;
esac
