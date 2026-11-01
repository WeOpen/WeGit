# LFS bounded inspection and fixed cache fetch

Issue [#96](https://github.com/WeOpen/WeGit/issues/96) closes a missed v1.2 performance and write-scope boundary. The previous reader started one `cat-file` process per index entry. A same-fixture Debug diagnostic with 5000 ordinary tracked files and no pointers took **35103.010ms / 5000 cat-file processes**, preserving HEAD/index. This is a single diagnostic, not a Release percentile result.

The new reader queries blob metadata and eligible content in two batches. Git LFS pointer files are below 1024 bytes; aggregate object/worktree bytes, index metadata and result count are bounded. Gitlinks/symlinks are skipped, old index contexts are rejected, and read-only inspection cannot initiate lazy Git downloads.

Fetch object binds the selected index pointer and Remote/endpoint, then fetches a private commit containing only that pointer into the LFS cache. It preserves HEAD, original index and working files, disables recent-ref expansion/filter widening/prune, and performs no checkout. This also preserves literal comma/wildcard/Unicode/newline paths. Private object scaffolding never writes the user's Git object database or cache-tree index.

## Executed checks

- Existing submodule/LFS private checker: **15/15**.
- New real-Git boundary checker with a local LFS command fixture: **24/24**. Covers 5000-file batching, exact selected cache bytes, untouched other object/workfiles/index/HEAD/Git objects, stale pointer/index/HEAD refusal, live cancellation/timeout/group exit, recovered reads, and aggregate limits.
- Three Core regression methods compile; no local XCTest ran.
- Localization source coverage and argument matching pass; Inspector cache updates are tied to the current session/render context and cancellation.

The local command fixture checks real Git snapshot/configuration and filesystem effects. It does not certify real LFS service authentication/transfer; those external combinations remain in the approved #5 deferral.

## Final trusted native evidence

Combined UI/Core source `38dca23915362c3ca51f6bddd643a31a06b15c37` passed [41362962873](https://github.com/WeOpen/WeGit/actions/runs/41362962873). Direct smoke and Submodule/LFS summaries each report **1 total / 1 passed / 0 failed / 0 skipped**; focus duration is 21.768 seconds, summary 23.299 seconds. Artifact 13106127777 is 588273 bytes, SHA256 `cdd1886fa6e72363fb4579130e39452935a309e2328bf4ce90b8aa7feb965347`; all 77 ZIP entries pass CRC and all 194 build inputs match. The display was restored.

The [unmodified Inspector screenshot](screenshots/submodule-lfs-resources.png) and [AX tree](accessibility/submodule-lfs-resources.txt) were actually reviewed: configured `modules/child`, clean child state, `large.bin` pointer, missing-object state and Fetch object control are visible. [native-41362962873-verified.json](native-41362962873-verified.json) retains the source, counts, durations, archive and attachment hashes.

## Executed ordinary Release Core measurement

All 90 samples passed, with 30 valid samples for each storage workload, on the combined Interactive Rebase/LFS Core. All 94 measured input hashes match the combined Core. Full raw arrays, budgets, Git version and source hashes are in [performance.json](performance.json); sourceRevision records runtime starting revision a140e9aa446c13cbebeab55d9c65f83512aa2fe7 and workspaceDirty=true. The earlier 69ddc181/d621cda2 report remains in [performance-before-combined-source.json](performance-before-combined-source.json).

| Fixture | First P95 ms | Steady P95 ms | Recovered P95 ms | Cancel P95 ms | Resident high-water bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| 10 files,1 initialized child,2 hydrated LFS objects |94.420|96.971|100.443|0.610|14565376|
| 5000 loose files,5 initialized children,32 hydrated objects |689.663|675.415|673.970|0.639|30310400|
| 5000 packed files,5 initialized children,32 hydrated objects |326.827|327.996|335.939|0.618|31014912|

The parent HEAD/raw index and every child raw index remain unchanged. Cancellation starts only after a real wrapper/child are alive, requires the complete process group to exit, and is followed by a full real resource read. The memory number is the maximum of current RSS and process-lifetime resident high water, excluding child Git RSS. This is Core backend evidence; it does not certify whole-application release performance or an external LFS service.

## Preserved initial measurement failure

The [initial measurement](performance-first-failed.json) retained 12 valid ordinary samples before the next cancellation group-exit assertion failed. The original report and fixture remain preserved. A shell trap that exits without waiting for its own child can leave an unreaped group; the fixture now terminates and waits for that child before exiting. The product ProcessRunner and budgets stay unchanged.

The rerun uses the original combined first/steady/recovered Inspector P95≤2000ms, live cancellation≤500ms and resident high-water≤256/512MiB budgets. Loose and packed object counts are recorded in the raw report; automatic maintenance is disabled only in the private fixtures.

Core and native test targets compile, with no local XCTest. The earlier bc1c06b candidate passed current required CI (three Git regressions of 257 tests in 46 suites), and trusted smoke/Inspector focus (each 1/1/0/0). Its full artifact 13104608627, 588345 bytes/SHAe1cf0525beb7a89bdd00b36e450feba78cf33ff290b78a7c8a162e439da23196/77CRC, 191 build inputs, screenshot/AX and display restoration were verified.

The final combined candidate, current required CI, trusted native receipts and final main functional regression are tracked by [PR #87](https://github.com/WeOpen/WeGit/pull/87). PR #97's source remains intact in that candidate; final integration is verified before closing the draft and Issue #96. Whole-app Release performance and real LFS service/authentication retain the approved deferrals.
