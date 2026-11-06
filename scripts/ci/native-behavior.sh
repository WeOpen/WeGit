#!/bin/bash
set -euo pipefail
scope="${1:-all}"
case "$scope" in all|behavior|performance) ;; *) exit 2 ;; esac
# Older revisions do not contain every feature. Once a feature is present its
# behavior check is mandatory; a missing checker is an error, not a silent skip.
for pair in \
  WeGitCore/GitCore/RecoveryService.swift:scripts/verify-recovery-performance.sh \
  WeGitCore/Infrastructure/ProductionUpdateInstaller.swift:scripts/verify-production-update.sh \
  WeGitCore/Domain/ApplicationDataMigration.swift:scripts/verify-application-migration.py \
  WeGitCore/GitCore/InteractiveRebaseService.swift:scripts/verify-interactive-rebase.sh \
  WeGitCore/GitCore/InteractiveRebaseService.swift:scripts/verify-interactive-rebase-performance.sh \
  WeGitCore/GitCore/ConflictEditorService.swift:scripts/verify-conflict-editor.sh \
  WeGitCore/GitCore/ConflictEditorService.swift:scripts/verify-conflict-editor-performance.sh \
  WeGitCore/GitCore/RebaseService.swift:scripts/verify-rebase.sh \
  WeGitCore/GitCore/RebaseService.swift:scripts/verify-rebase-performance.sh \
  WeGitCore/GitCore/WorktreeService.swift:scripts/verify-worktree-management.sh \
  WeGitCore/GitCore/WorktreeService.swift:scripts/verify-worktree-read-performance.sh \
  WeGitCore/GitCore/SelectedLinesService.swift:scripts/verify-selected-lines.sh \
  WeGit/App/AppState.swift:scripts/verify-diff-read-cancellation.sh \
  WeGitCore/GitCore/BlameService.swift:scripts/verify-blame.sh \
  WeGitCore/GitCore/SingleCommitService.swift:scripts/verify-single-commit.sh \
  WeGitTests/WorktreeTests.swift:scripts/verify-worktrees.sh \
  WeGitCore/GitCore/FileHistoryService.swift:scripts/verify-file-history.sh \
  WeGitCore/GitCore/TagService.swift:scripts/verify-tags.sh \
  WeGitCore/GitCore/RemoteManagementService.swift:scripts/verify-remote-management.sh \
  WeGitCore/GitCore/StashService.swift:scripts/verify-stash.sh \
  WeGitCore/GitCore/SubmoduleService.swift:scripts/verify-submodule-lfs.sh \
  WeGitCore/GitCore/SubmoduleService.swift:scripts/verify-submodule-lfs-performance.sh \
  WeGit/Features/RepositorySyncCounts.swift:scripts/verify-sync-counts.sh \
  WeGitCore/Domain/ChangeFileTree.swift:scripts/verify-change-file-tree.sh \
  WeGit/Features/DiffChangeMap.swift:scripts/verify-diff-change-map.sh \
  WeGit/DesignSystem/CustomTheme.swift:scripts/verify-themes.sh \
  WeGit/DesignSystem/AppPresentation.swift:scripts/verify-appearance-icons.sh \
  WeGit/App/NativeApplicationMenu.swift:scripts/verify-native-application-menu.sh; do
  feature="${pair%%:*}"
  checker="${pair#*:}"
  case "$checker" in
    *-performance.sh) if [[ "$scope" == behavior ]]; then continue; fi ;;
    *) if [[ "$scope" == performance ]]; then continue; fi ;;
  esac
  if [[ -f "$feature" ]]; then
    test -x "$checker"
    "$checker"
  else
    printf 'Feature absent at this source revision: %s\n' "$feature"
  fi
done
