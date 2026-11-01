# v1.1 M0 baseline integration

2026-10-20 · User authorized executing the accepted v1.1 plan. M0 integrates polish issues #31–#34, not the future Stash/Remote/Tag/history functions. Tasks #35–#39 track the accepted scope.

## Review fixes

- Direct Git fixture setup now removes inherited GIT_* variables before adding isolated configuration, preventing repository/index/worktree redirection by the invoking environment.
- Compact toolbar helper uses stable action identifiers. The native UI regression source now narrows a configured-upstream workspace and checks Pull 3 / Push 2.
- Diff map projects valid +0,0 beginning/whole-file deletion hunks and keeps its denominator positive. A newly added parsed-patch regression first failed with `Zero-context beginning deletion retains a map mark`; after the fix all 13 map checks passed.
- Literal Git pathspecs still recurse into directories. Replacing a tracked file with a same-named directory could stage an unselected untracked child or unstage a filtered-out indexed child. Service-level preflight rejects selected ancestors of unselected affected entries. Unstage considers only indexed/conflict descendants, so a merely untracked child does not falsely block it. For explicitly selected parent-and-child replacements, redundant child pathspecs are removed only after the scope check, avoiding Git restore's missing-source-child error.
- The selection regression initially failed before the guard. Adding the full explicit-selection case exposed a real Git `pathspec ... did not match any file(s) known to git` error; reducing already-covered child pathspecs resolved it. Final 30 tree/real-Git staging checks cover rejection without index mutation, allowed full selection, untracked-child preservation, file bytes and HEAD. `SelectionScopeTests` supplies the same behavioral regression for actual hosted core execution.

## Verification

Executed locally without XCTest:

- Native standalone behavior lane: 14 sync count + 30 file tree/staging + 13 map + 290 theme + 18 icon + 27 application menu checks, all passed.
- Localization: 1015 string keys, 7 plural keys, 1325 source literals.
- Python policy behavior: 30 passed; repository policy and strict source formatting passed.
- Original native component previews are retained in the preceding changes-list, sidebar-background and toolbar-surfaces acceptance records. They are not full-app XCTest evidence.

Core tests and UI tests are compiled only on this Mac; actual executions belong to hosted CI. No system protections or personal Git configuration/repositories were changed. Existing v1.0 tag/release and deployment rules are retained. Product version bump/package/release belongs to M5, not this M0 source-integration PR.

## Review boundary

Testing, maintainability, design, performance, security/adversarial and plan-completion reviews were performed in fresh contexts. Findings above were fixed and rechecked. Exact numeric coverage cannot be derived from source and preview records; no fabricated percentage is reported. Full-app negative orchestration, repository display-mode switch/restore and map click-to-selected-hunk assertions remain useful additional coverage; UI source compilation does not close those execution gaps.

PR/CI/main integration status is tracked by the pull request. This document does not declare those external steps passed before their final result exists.
