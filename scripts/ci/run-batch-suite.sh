#!/bin/bash
set -euo pipefail
# Fixed commands, not a shell program supplied by a PR label/manual input.
case "${1:-}" in
  core)
    swift format lint --strict --recursive WeGitCore WeGitAskPass WeGitTests Benchmarks Package.swift
    swift test --no-parallel
    scripts/ci/prepare-git-246.sh
    env WEGIT_TEST_GIT="$(cat .build/git-246-path)" swift test --no-parallel
    env WEGIT_TEST_GIT="$(brew --prefix git)/bin/git" swift test --no-parallel | tee .build/ci/homebrew-core.log
    ;;
  signing) scripts/verify-gpg-compatibility.sh ;;
  behavior)
    scripts/verify-preference-migration.sh
    scripts/ci/native-behavior.sh behavior
    ;;
  performance) scripts/ci/native-behavior.sh performance ;;
  application)
    swift format lint --strict --recursive WeGit WeGitUITests WeGitPerformanceTests
    swift format lint --strict scripts/*Checks.swift scripts/*Performance.swift scripts/LocalizationSources.swift scripts/verify-inspector-startup.swift
    python3 scripts/verify-localization.py
    scripts/build.sh Debug
    xcodebuild -project WeGit.xcodeproj -scheme WeGit -configuration Debug \
      -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-app \
      -resultBundlePath .build/ci/native-build.xcresult build-for-testing
    python3 scripts/verify-ui-git-wrapper.py .build-app/Build/Products/Debug/WeGitTestGit
    ;;
  package)
    scripts/build.sh Release
    scripts/package-release.sh --preview
    git diff --exit-code
    ;;
  *) echo 'Unknown registered backend validation suite' >&2; exit 2 ;;
esac
