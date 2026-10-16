#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p .build
check_run="$(mktemp -d "$project_root/.build/preference-migration-XXXXXX")"
xcrun swiftc WeGit/App/PreferenceMigration.swift scripts/PreferenceMigrationChecks.swift -o "$check_run/checks"
"$check_run/checks" "$check_run/result.json"
echo "Report: $check_run/result.json"
