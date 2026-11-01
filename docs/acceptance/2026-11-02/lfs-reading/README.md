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

## Executed ordinary Release Core measurement

All 90 samples passed, with 30 valid samples for each storage workload. The measured input hashes match implementation 69ddc181 and merged candidate d621cda2. Full raw arrays, budgets, Git version and source hashes are in [performance.json](performance.json); sourceRevision records the pre-commit base plus workspaceDirty, rather than falsely claiming a clean checkout.

| Fixture | First P95 ms | Steady P95 ms | Recovered P95 ms | Cancel P95 ms | Resident high-water bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| 10 files,1 initialized child,2 hydrated LFS objects |93.755|87.445|90.456|0.465|14499840|
| 5000 loose files,5 initialized children,32 hydrated objects |719.263|622.315|634.987|0.537|30081024|
| 5000 packed files,5 initialized children,32 hydrated objects |305.591|307.989|344.871|0.547|30097408|

The parent HEAD/raw index and every child raw index remain unchanged. Cancellation starts only after a real wrapper/child are alive, requires the complete process group to exit, and is followed by a full real resource read. The memory number is the maximum of current RSS and process-lifetime resident high water, excluding child Git RSS. This is Core backend evidence; it does not certify whole-application release performance or an external LFS service.

## Preserved initial measurement failure

The initial measurement retained 12 valid ordinary samples before the next cancellation group-exit assertion failed. The original report and fixture remain preserved. A shell trap that exits without waiting for its own child can leave an unreaped group; the fixture now terminates and waits for that child before exiting. The product ProcessRunner and budgets stay unchanged.

The rerun uses the original combined first/steady/recovered Inspector P95≤2000ms, live cancellation≤500ms and resident high-water≤256/512MiB budgets. Loose and packed object counts are recorded in the raw report; automatic maintenance is disabled only in the private fixtures.

Core and native test targets compile, with no local XCTest. Current required CI, trusted native screenshot/AX review and normal PR integration remain pending.
