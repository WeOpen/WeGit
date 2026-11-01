# V12-07 Interactive Rebase

## Completion follow-up · 2026-11-01

The implementation now supports `pick`, `reword`, `edit`, `squash`, `fixup`, `drop` and explicit ordering for a fixed linear range. A private sequence manifest and content fingerprints bind the original HEAD, upstream, actions, message files and recovery editor. Pauses retain that editor across relaunch; external todo, message, HEAD and index changes refuse an obsolete recovery. The Changes composer permits commits/amend only at a verified edit pause and retains the separate push boundary.

The independent checks actually pass **75/75** (9 baseline plus 66 extended), including chained squash/fixup, supplied/default combined messages, edit with amendment/additional commits, repeated conflicts, relaunch, external mutations, queue cancellation, live process cancellation, timeout, hook failure and uncertain write replies. `swift build --build-tests` and the native `build-for-testing` pass; these are compilation evidence, with no local XCTest execution.

The new fixed native method is `RebaseWorkflowTests/testInteractiveSequenceEditsSquashesAndRecoversAfterRelaunch`. It exercises six actions and ordering, published confirmation, cancellation preserving HEAD/index, Chinese light/native focus, restored English dark edit pause, application staging/amend/continue, exact final messages/tree and the unchanged remote reference. PR #95 registers only that method after a passing smoke, with the existing 120/180-second limits. Actual trusted execution remains pending.

The initial ordinary Release Core run retains all 90 raw samples (10 files/5 commits, 5000 loose files/30 commits, and the packed counterpart, 30 each). First-read P95 was 112.370/698.600/685.476ms; execute P95 1585.841/4588.534/4232.277ms; cancellation below1ms; process high-water RSS below102MB. This run predates the final localization/script and main integration inputs and is diagnostic evidence. The final input report will be retained after those inputs are fixed. Budgets remain read/steady/recovery≤2000ms, live read cancellation≤500ms, execute≤10000ms, resident high-water≤256/512MiB.

PR #87 remains a development candidate until current required checks, trusted native evidence, final performance inputs and review are complete. Historical increments below retain their original scope; they are not the current action set. Final whole-application release performance and external acceptance follow the explicit deferrals in [v1.2 closeout](../../2026-11-01/v1-2-closeout/README.md).

## Earlier increment (historical)

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
