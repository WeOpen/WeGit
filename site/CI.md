# Website validation

Changes confined to `site/` use the website checks. The legacy build entry and its dedicated test are also website inputs; a HANDOFF note accompanying a website change keeps the same scope.

The website checks install locked Node 24 dependencies, run Node and Python tests, build TanStack/Workers and the legacy static site, enforce the existing byte budgets, run Wrangler in dry-run mode, and exercise the production Worker locally. They do not run Swift/Core/XCTest, native UI, Git/GPG compatibility or client packaging.

PR metadata policy and general repository validation are skipped for this scope. The required Repository policy check only confirms that Site checks succeeded; failed, cancelled, skipped or missing website results cannot pass that gate.

Application, shared-brand and shared-CI changes use the full path. Rename source and destination paths both count, PRs use the three-dot Git range, and pushes include the complete before-to-after range. Unknown ranges keep full validation.
