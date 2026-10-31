# V12-07 Interactive Rebase

## Current increment

This branch adds a bounded Interactive Rebase Core service and a Branches entry point. Preparation requires a clean local branch, no active sequence, an ancestor upstream, a linear history without merge commits, a pinned HEAD/index/path snapshot, and a bounded commit count. The execution path owns private sequence/editor scripts, disables autostash/update-refs/autosquash, validates the sequence before writing, and returns to the existing Rebase recovery model on pause or conflict.

The first action set is `pick`, `reword`, and `drop`, with explicit order changes. `edit`, `squash`, and `fixup` stay unavailable until pause/recovery and combined-message behavior have dedicated verification. The verified execution increment covers all-drop refusal before writes, reordering independent picks, `reword`, `drop`, sequence identity checks, and clean result reconciliation. Message editing uses a private bounded editor file; no arbitrary shell command is accepted as a todo action.

## Verification

| Check | Result |
| --- | --- |
| Core build | `swift build --build-tests` passed; no local XCTest ran |
| UI build | macOS `build-for-testing` passed for the new Branches entry and sheet; no local XCTest ran |
| Private Git checker | `scripts/verify-interactive-rebase.sh` passed: prepare, all-drop refusal before writes, reordered independent picks, drop/reword output and clean worktree (9 checks) |
| Isolation | Disposable temporary Git repository with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_SYSTEM=/dev/null` |

## Open gates

This is an implementation increment, not V12-07 completion. Edit pause/recovery, squash/fixup message semantics, repeated conflicts, cancel/timeout/unknown replies, external sequence mutation, native XCTest evidence, Release performance, and normal Issue → PR → required CI integration remain open. V12-08 Submodule, V12-09 LFS, and final M5 remain open.
