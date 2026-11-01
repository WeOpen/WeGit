# LFS bounded inspection and fixed cache fetch

Issue [#96](https://github.com/WeOpen/WeGit/issues/96) closes a missed v1.2 performance and write-scope boundary. The previous reader started one `cat-file` process per index entry. A same-fixture Debug diagnostic with 5000 ordinary tracked files and no pointers took **35103.010ms / 5000 cat-file processes**, preserving HEAD/index. This is a single diagnostic, not a Release percentile result.

The new reader queries blob metadata and eligible content in two batches. Git LFS pointer files are below1024 bytes; aggregate object/worktree bytes, index metadata and result count are bounded. Gitlinks/symlinks are skipped, old index contexts are rejected, and read-only inspection cannot initiate lazy Git downloads.

Fetch object binds the selected index pointer and Remote/endpoint, then fetches a private commit containing only that pointer into the LFS cache. It preserves HEAD, original index and working files, disables recent-ref expansion/filter widening/prune, and performs no checkout. This also preserves literal comma/wildcard/Unicode/newline paths. Private object scaffolding never writes the user's Git object database or cache-tree index.

## Executed checks

- Existing submodule/LFS private checker: **15/15**.
- New real-Git boundary checker with a local LFS command fixture: **24/24**. Covers 5000-file batching, exact selected cache bytes, untouched other object/workfiles/index/HEAD/Git objects, stale pointer/index/HEAD refusal, live cancellation/timeout/group exit, recovered reads, and aggregate limits.
- Three Core regression methods compile; no local XCTest ran.
- Localization source coverage and argument matching pass; Inspector cache updates are tied to the current session/render context and cancellation.

The local command fixture checks real Git snapshot/configuration and filesystem effects. It does not certify real LFS service authentication/transfer; those external combinations remain in the approved #5 deferral.

## Release evidence still being collected

The initial measurement retained12 valid ordinary samples before the next cancellation group-exit assertion failed. The original report and fixture remain preserved. A shell trap that exits without waiting for its own child can leave an unreaped group; the fixture now terminates and waits for that child before exiting. The product ProcessRunner and budgets stay unchanged.

The complete run requires ordinary, 5000-file loose and packed fixtures, 30 valid samples each, initialized children and hydrated LFS objects. Combined first/steady/recovered Inspector reads P95≤2000ms, live cancellation≤500ms, resident high-water≤256/512MiB. All raw arrays, source hashes, actual object statistics and cancellation PIDs must be retained before this gate is complete.

Current required CI, trusted native screenshot/AX review and normal PR integration remain pending.
