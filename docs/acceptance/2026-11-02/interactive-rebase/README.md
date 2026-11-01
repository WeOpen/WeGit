# Interactive Rebase final development evidence

The completed development implementation supports `pick`, `reword`, `edit`, `squash`, `fixup`, `drop` and ordering for a fixed linear range. Preparation and execution pin repository identity, branch/HEAD, upstream, index, sequence and message inputs. Edit pauses preserve private recovery data across relaunch and permit application staging/amend/continue; push remains separately guarded. External changes and uncertain write replies are reconciled before another write.

The combined candidate includes the bounded LFS reader/fetch implementation from PR #97. Integration is tracked in [PR #87](https://github.com/WeOpen/WeGit/pull/87), with full current required checks and review before normal squash. Historical native and fixture failures remain preserved.

## Executed isolated checks and compilation

- Interactive Rebase: **75/75** isolated real-Git checks (9 baseline plus 66 extended), including all actions, combined messages, repeated conflicts, edit amendment/additional commits, relaunch, external mutations, queued/live cancellation, timeout, hooks and uncertain replies.
- Submodule/LFS: **39/39** isolated checks on the same combined Core inputs.
- Core test targets and native `build-for-testing` compile. No local XCTest is executed.

## Executed ordinary Release Core measurement

[performance.json](performance.json) retains every raw sample, budget, source hash, Git version and actual object-storage statistics. All **90 valid samples** pass: 30 ordinary, 30 large loose and 30 large packed. The reports record the runtime starting revision `a140e9aa446c13cbebeab55d9c65f83512aa2fe7` and `workspaceDirty=true`; all 94 measured input hashes match the combined Core. UI column-width and documentation edits are outside this backend input set.

| Workload | First P95 ms | Steady P95 ms | Recovered P95 ms | Execute P95 ms | Cancel P95 ms | Maximum resident bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Ordinary, 10 files / 5 commits | 113.296 | 116.372 | 116.211 | 1173.377 | 0.633 | 15319040 |
| Large loose, 5000 files / 30 commits | 686.773 | 695.988 | 710.097 | 4399.962 | 0.496 | 105316352 |
| Large packed, 5000 files / 30 commits | 676.317 | 675.474 | 675.521 | 3787.132 | 0.443 | 105316352 |

Budgets stay read/steady/recovery P95≤2000ms, execution≤10000ms, live cancellation≤500ms and resident high-water≤256/512MiB. Cancellation starts after the real wrapper and child are alive, requires the entire group to exit, and is followed by real recovery and execution. Memory is Core process high water; child Git RSS is excluded. These measurements do not certify whole-application Release UI performance.

## Native evidence

The final UI input `38dca23915362c3ca51f6bddd643a31a06b15c37` passed [41362241163](https://github.com/WeOpen/WeGit/actions/runs/41362241163): smoke and Interactive focus each **1/1/0/0**. The focus method took **74.719 seconds**, summary **78.620 seconds**. Artifact 13106116402 is 116302263 bytes, SHA256 `e464ae56957f59d5a8341a93d7938253d59fdf10509d90b819610f2c127ccc07`; all 2021 ZIP entries pass CRC and all 194 build inputs match. Display restoration and six unmodified screenshots/AX pairs are verified in [native-41362241163-verified.json](native-41362241163-verified.json).

The [complete action label](screenshots/actions-and-messages-light.png), [preserved edit draft](screenshots/edit-pause-draft-light.png), [native amend dialog](screenshots/amend-confirmation-dark.png), [restored English edit pause](screenshots/restored-edit-after-amend-dark.png) and [clean completed sequence](screenshots/completed-sequence-dark.png) were actually viewed. The fixed-range screenshot and all AX text remain alongside them.

### Earlier combined pass and visual follow-up

The combined `a140e9a` candidate passed trusted-main run [41360792380](https://github.com/WeOpen/WeGit/actions/runs/41360792380): smoke and Interactive focus each executed **1 total / 1 passed / 0 failed / 0 skipped**. Focus duration is **77.763 seconds**, summary duration **82.265 seconds**, below the original 120/180-second limits. Artifact 13105231919 is 118150474 bytes, SHA256 `3fce75059ad1658c808dcc88b6dd8d4103935c22ecca6fce269973882f49f9ec`; all 2167 ZIP entries pass CRC, all 194 build inputs match, and display restoration is verified.

Six screenshots and six AX attachments were exported and reviewed: Chinese fixed range/cancel, all actions and edited messages, preserved edit draft, English native amend confirmation, restored edit pause after actual application amend, and final clean reordered sequence with unchanged remote reference. The original three failing runs retain their failing conclusions.

That review identified a visibly truncated fixup title in the 145pt Picker. The final UI candidate increases the fixed column to 224pt while preserving the 700pt sheet and keyboard ordering controls. The new screenshot confirms the complete title; the earlier pass retains its original input. Final main functional regression and current required CI are linked from PR #87's closeout record.

Formal distribution and the approved performance/device/account/VoiceOver/Beta deferrals remain in [v1.2 closeout](../../2026-11-01/v1-2-closeout/README.md).
