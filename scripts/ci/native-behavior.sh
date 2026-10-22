#!/bin/bash
set -euo pipefail
# Older revisions do not contain every feature. Once a feature is present its
# behavior check is mandatory; a missing checker is an error, not a silent skip.
for pair in \
  WeGitCore/GitCore/StashService.swift:scripts/verify-stash.sh \
  WeGit/Features/RepositorySyncCounts.swift:scripts/verify-sync-counts.sh \
  WeGitCore/Domain/ChangeFileTree.swift:scripts/verify-change-file-tree.sh \
  WeGit/Features/DiffChangeMap.swift:scripts/verify-diff-change-map.sh \
  WeGit/DesignSystem/CustomTheme.swift:scripts/verify-themes.sh \
  WeGit/DesignSystem/AppPresentation.swift:scripts/verify-appearance-icons.sh \
  WeGit/App/NativeApplicationMenu.swift:scripts/verify-native-application-menu.sh; do
  feature="${pair%%:*}"
  checker="${pair#*:}"
  if [[ -f "$feature" ]]; then
    test -x "$checker"
    "$checker"
  else
    printf 'Feature absent at this source revision: %s\n' "$feature"
  fi
done
