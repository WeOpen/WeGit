# Website validation

Changes to the website use `Site checks`: locked Node 24 dependencies, Node/Python tests, the TanStack/Workers and legacy static builds, original byte budgets, Wrangler dry-run and local production-Worker HTTP checks.

Website changes do not run native backend Core/Git/GPG, backend performance or client packaging. The required `Repository policy` check only confirms that the applicable site job succeeded. Failed, cancelled, skipped or missing required results cannot pass.

The general rule is backend-code-only costly validation. Native views use compilation, documentation uses link checks, CI/tooling uses its own checks, and test-only sources use compilation. Frontend, documentation, brand and CI edits do not automatically run backend suites.

The path mapping lives in `scripts/ci/change_scope.py`. Rename source and destination both count; PRs use three-dot comparison and pushes use the complete before-to-after range. An unverifiable range fails routing instead of starting costly fallback checks. Manual backend validation requires explicit selection.
