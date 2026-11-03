# 🤝 Contributing to WeGit

Use a GitHub Issue to describe work before starting a feature, fix, validation task or release change. English and Chinese are both welcome.

## 🧭 Issue → PR → release

1. Search existing Issues; use the bug, feature or task form. Include observable acceptance criteria and scope boundaries.
2. A maintainer adds a priority, an area, one status label and a milestone. Start work when the issue is `status:ready`.
3. Create a short-lived branch, for example `codex/42-diff-selection`. Keep unrelated app work out of the branch.
4. Open a PR with a Conventional Commit title, for example `fix(diff): preserve tabs when copying`. Include `Closes #42` for complete work or `Refs #42` for a partial delivery. At least one linked requirement must be an open Issue in this repository.
5. Supply test commands/results, UI evidence where appropriate, and documentation or migration notes. An unexecuted check remains pending.
6. Pass the applicable checks and resolve review conversations, then squash-merge. Only backend-code changes run the costly `Native macOS` suites. Site, native frontend, documentation and CI/tooling changes use their own checks; the required `Repository policy` result aggregates the applicable successful results. PR metadata policy is skipped outside backend changes. GitHub closes Issues linked with a closing keyword when the PR reaches `main`.
7. Stable releases additionally require full acceptance for the same commit. Release automation creates a draft; a maintainer reviews installation, Beta feedback and release blockers before publishing it. The maintainer explicitly authorized a one-time exception for [v1.0.0](docs/releases/v1.0.0.md#validation-and-known-limits--验证与已知限制); its incomplete checks remain recorded, and the default automation remains strict.

Dependabot PRs are exempt from the linked-Issue requirement. Their title and CI still need to pass. Other bots and human PRs use the normal workflow.

## 🧪 Local checks

Run costly Core/Git/GPG, backend performance and client-package checks only for backend-code changes. Site uses its Node/Python tests, both builds, original budgets and local Worker validation; native frontend uses build-only checks, documentation uses link checks, CI/tooling uses tooling checks, and test-only changes use compilation. Shared CI/brand or HANDOFF edits do not trigger backend validation. See [AGENTS.md](AGENTS.md), the explicit path mapping in [change_scope.py](scripts/ci/change_scope.py) and [the CI guide](docs/GITHUB_WORKFLOW.md).

The following tooling checks apply when repository/CI tools change:

```bash
python3 -m pip install -r scripts/ci/requirements.txt
python3 scripts/ci/check_policy.py
python3 -m unittest discover -s scripts/ci/tests -v
```

Application builds require macOS 27+, Apple Silicon and Xcode 27. Routine frontend validation compiles without executing XCTest. Backend suites run in hosted CI; local work must not run XCTest. Full acceptance is deliberately separate from routine CI; a green app build is not proof of VoiceOver, performance or clean-machine installation.

CI uses the committed Xcode project with `WEGIT_SKIP_PROJECT_GENERATION=1`. After a source/project configuration change, regenerate `WeGit.xcodeproj` from `project.yml` locally and review the generated diff before committing it.

## 🔒 Scope and shared data

- Tests must use private fixtures/configuration and must not write to personal repositories or global Git configuration.
- Preserve Git operation ordering, authoritative refreshes and draft recovery. Add behavior assertions for changes to these boundaries.
- Never commit tokens, private keys, signing material or private repository data. Diagnostic exports omit code, diffs, commit messages, paths and credentials; review extra logs and screenshots yourself.
- Keep pre-existing `.spec-workflow`, build output and unrelated uncommitted work outside the PR.

Detailed project operation, runner setup, label definitions and release commands: [GitHub workflow guide](docs/GITHUB_WORKFLOW.md).
