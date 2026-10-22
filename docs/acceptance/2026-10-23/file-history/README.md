# v1.1 File history

2026-10-23 · Refs #39. [Usage and boundaries](../../../FILE_HISTORY.md).

Implemented file context entry points and manual path lookup, literal author/message and commit-time filters, Git rename following, anchored pagination and per-file historical diffs. Reads are cancellable and protected against old query completions; retries and closing release request/cache state. No repository write is introduced by these readers.

## Executed locally

- 19 isolated checks: modification → rename → modification → deletion, exact Unicode/newline paths, paging, disabled rename following, filters excluding the rename itself, inclusive date bounds, immutable cursor contexts, external HEAD movement, nonexistent/invalid paths, real Merge first-parent comparison with feature commits retained, binary state, and 5000 unique records paged exactly once.
- The initial skip-based implementation missed the root commit on a later page; `initial-pagination-failure.log` retains it. A later message filter also missed pre-rename history. The implementation now snapshots bounded unfiltered path metadata before filtering exact OIDs with `--no-walk`.
- Thirty fresh query snapshots each for file history and existing history, on the same 5000-commit fixture (`performance.json`). File timings include path-chain creation and first-page object reading. The backend p95 budget is 2000 ms. Raw values are retained; these Debug measurements do not replace final-source Release/UI performance acceptance.
- The complete native behavior lane passed 545 checks, Python tools passed 31 checks, localization and strict format/policy were checked. Four new core tests and one native UI workflow compile. No XCTest ran locally.
- A full-application preview with a unique bundle identifier and private synthetic repository was inspected through native UI in light/dark modes. Manual deleted-path lookup returned all four commits; filtering `[literal]` reached the original `old.txt` and displayed its root-commit addition. The preview is separate from hosted execution evidence.

Fixtures have isolated Git global/system config, synthetic identities and private paths. Path metadata is NUL parsed; full commit contents are read only for each page. The snapshot has byte/record limits, supports cancellation, and releases when the sheet closes. Merge diff uses the first real parent, not path-rewritten ancestry.

Pending: hosted core/UI execution, final-source whole-app regression and Release performance, installation and Beta/release gates. No version bump or release is claimed. Git rename detection limitations, shallow-history boundaries and unusually large histories are not described as complete cross-file ancestry.
