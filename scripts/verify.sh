#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
swift format lint --strict --recursive WeGitCore WeGit WeGitAskPass WeGitTests WeGitUITests WeGitPerformanceTests Benchmarks Package.swift
swift format lint --strict scripts/PreferenceMigrationChecks.swift
swift format lint --strict scripts/NativeApplicationMenuChecks.swift
swift format lint --strict scripts/AppearanceIconChecks.swift
swift format lint --strict scripts/ThemeChecks.swift
swift format lint --strict scripts/DiffChangeMapChecks.swift
swift format lint --strict scripts/ChangeFileTreeChecks.swift
swift format lint --strict scripts/SyncCountsChecks.swift
swift format lint --strict scripts/StashChecks.swift
swift format lint --strict scripts/RemoteManagementChecks.swift
swift format lint --strict scripts/TagChecks.swift
swift format lint --strict scripts/FileHistoryChecks.swift
swift format lint --strict scripts/WorktreeChecks.swift
swift format lint --strict scripts/WorktreeManagementChecks.swift
swift format lint --strict scripts/WorktreeManagementPerformance.swift
swift format lint --strict scripts/WorktreeReadPerformance.swift
swift format lint --strict scripts/SingleCommitChecks.swift
swift format lint --strict scripts/BlameChecks.swift
swift format lint --strict scripts/RebaseChecks.swift scripts/RebasePerformance.swift
swift format lint --strict scripts/ConflictEditorChecks.swift
swift format lint --strict scripts/SubmoduleLFSChecks.swift
swift format lint --strict scripts/LFSBoundaryChecks.swift scripts/SubmoduleLFSPerformance.swift
swift format lint --strict scripts/ConflictEditorPerformance.swift
swift format lint --strict scripts/SelectedLinePatchChecks.swift scripts/SelectedLineSafetyChecks.swift scripts/SelectedLineFileChecks.swift
swift format lint --strict scripts/LocalizationSources.swift scripts/verify-inspector-startup.swift
scripts/verify-preference-migration.sh
python3 scripts/verify-localization.py
if [[ "${WEGIT_SERIAL_CORE_TESTS:-0}" == 1 ]]; then
  swift test --no-parallel
else
  swift test
fi
scripts/build.sh Debug
if [[ "${1:-}" == "--ui" ]]; then
  scripts/verify-themes.sh
  scripts/verify-appearance-icons.sh
  scripts/verify-native-application-menu.sh
  xcodebuild -project WeGit.xcodeproj -scheme WeGit -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-app test
fi
