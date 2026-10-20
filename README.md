<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/wegit-v2/mark-dark.png">
    <img src="branding/wegit-v2/mark.png" width="104" height="104" alt="WeGit logo">
  </picture>
  <h1>WeGit</h1>
  <p><strong>A native Git workspace for macOS.</strong></p>
  <p>Read changes clearly. Shape your commits. Keep your workflow close.</p>
  <p>
    <img src="https://img.shields.io/badge/status-public_release-green?style=flat" alt="Public release">
    <img src="https://img.shields.io/badge/version-1.0.0-blue?style=flat" alt="Version 1.0.0">
    <img src="https://img.shields.io/badge/macOS-27%2B-111111?style=flat&amp;logo=apple&amp;logoColor=white" alt="macOS 27 or later">
    <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat&amp;logo=swift&amp;logoColor=white" alt="Swift 6">
    <img src="https://img.shields.io/badge/Git-2.46%2B-F05032?style=flat&amp;logo=git&amp;logoColor=white" alt="Git 2.46 or later">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3DA639?style=flat" alt="MIT license"></a>
  </p>
  <p><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>
  <p><a href="https://github.com/WeOpen/WeGit/releases">📦 Releases</a> · <a href="https://github.com/WeOpen/WeGit/issues">🐛 Report an issue</a> · <a href="docs/README.md">📚 Documentation</a></p>
</div>

---

## 👋 Meet WeGit

WeGit is a SwiftUI Git client built around the work you do every day: inspect a diff, stage the right changes, create a commit, browse history, manage branches, and sync with a remote.

It uses your existing Git installation, configuration, credential helpers, and SSH agent. Native windows, keyboard shortcuts, a menu bar panel, and light, dark, and custom themes keep the experience at home on macOS. The Git core has no third-party runtime dependencies.

> **WeGit 1.0.0** · [Download](https://github.com/WeOpen/WeGit/releases/tag/v1.0.0) · [Website](https://weopen.github.io/WeGit/). Ad-hoc signed, not notarized by Apple. Accessibility acceptance is deferred; see the [release notes and remaining validation limits](docs/releases/v1.0.0.md).

## ✨ Features

| | What you can do |
| --- | --- |
| 📂 **Repositories** | Open or clone repositories, drop folders into the app, and switch between recent and favorite repositories. |
| 🔍 **Diffs** | Read unified or split diffs with syntax highlighting, word changes, hunk navigation, expandable context, and exact source-text selection and copying. Large diffs use paged disk snapshots. |
| 🧩 **Commits** | Stage or unstage files and hunks, discard changes with confirmation, amend a commit, and keep a draft for each repository. |
| 🌿 **Branches & history** | Browse a paginated commit graph, compare commit files, copy a SHA, create a branch from a commit, or check out a detached HEAD. |
| 🔄 **Remotes & conflicts** | Fetch, pull, and push to explicit targets; choose merge, rebase, or fast-forward-only pulls; continue or abort supported merge/rebase conflicts. |
| 🛡️ **Operation recovery** | Reject stale changes, coordinate repository operations, preserve drafts on failures, and verify an uncertain push result before retrying. |
| 🎨 **Appearance** | Use native light/dark themes or save a separate custom palette with 17 color roles, live preview, contrast hints, and JSON import/export. |
| ⌨️ **Native workflow** | Use keyboard navigation, repository search, a command palette, configurable panels, and a menu bar quick-access panel. |
| 🌍 **Languages** | Switch between English, Simplified Chinese, and the system language without restarting the app. |

See the [product specification](docs/WeGit_PRD.md), [interface notes](docs/INTERFACE_POLISH.md), and [compatibility record](docs/COMPATIBILITY.md) for scope and evidence. Product capabilities and completed release acceptance are tracked separately.

**Development branch, 2026-10-20:** the v1.1 M0 baseline adds collapsible change groups, staging checkboxes, a folder display mode, a clickable change map for multi-hunk in-memory diffs, paired pane surfaces, and upstream commit counts on Pull/Push. These additions are pending PR/CI integration and are not part of the published 1.0.0 download. See the [usage and verification notes](docs/INTERFACE_POLISH.md#v11-m0-baseline--2026-10-20).

## 🖥️ Requirements

- **macOS 27 or later**. Current builds and acceptance evidence cover **Apple Silicon / arm64**.
- **Git 2.46 or later**. WeGit checks the required configuration-isolation and remote-address behavior at startup.
- To build: **Xcode 27**, including the macOS 27 SDK. The verified local toolchain is Swift 6.4.
- **XcodeGen 2.43+** is optional for normal builds; it is needed to regenerate the project after changing `project.yml`. The generated Xcode project is included.

## 📦 Downloads & distribution

WeGit is distributed through **GitHub Releases and the project website**. It is not planned for the Mac App Store or TestFlight.

Download [WeGit 1.0.0](https://github.com/WeOpen/WeGit/releases/tag/v1.0.0), including the ZIP, SHA-256 checksum and source manifest. The website links to these same versioned assets. See the [installation, data and rollback notes](docs/releases/v1.0.0.md).

There is currently no Apple Developer Program account for this project. Public packages use **ad-hoc signing** and are **not notarized by Apple**. Ad-hoc signing does not provide a verified developer identity, and macOS may block a downloaded build. For an app you have chosen to trust, consult [Apple’s guidance on opening apps safely](https://support.apple.com/102445). Downloaded-package installation on a clean Mac is still pending validation.

## 🚀 Build & run

```bash
git clone https://github.com/WeOpen/WeGit.git
cd WeGit
scripts/build.sh Debug
open .build-app/Build/Products/Debug/WeGit.app
```

You can also open `WeGit.xcodeproj` in Xcode, select the **WeGit** scheme, and run it. Local ad-hoc builds do not require Developer ID credentials.

To create a local Release preview:

```bash
scripts/build.sh Release
scripts/package-release.sh --preview
```

The package script checks the app’s build-source receipt, embedded AskPass helper, license, signature integrity, and exclusion of test entry points. It writes a ZIP, checksum, and manifest to `.build/releases/package-*`. This command creates a local development package; it does not publish a GitHub Release.

## ⌨️ Handy shortcuts

| Action | Shortcut |
| --- | --- |
| Open a repository | `⌘O` |
| Changes / History / Branches | `⌘1` / `⌘2` / `⌘3` |
| Refresh | `⌘R` |
| Commit staged changes | `⌘↩` |
| Pull / Push target form | `⌘⇧L` / `⌘⇧U` |
| Menu bar quick-access panel | `⌘⇧M` |
| Settings | `⌘,` |

🌍 Choose **Settings → General → Interface language** to change the app language. Repository names, paths, branches, commit messages, code, and patches retain their original content.

🎨 Choose **Settings → Appearance → Edit custom theme…** to create a full custom scheme. Built-in Light and Dark remain unchanged.

## 🧪 Development & validation

```bash
# Core unit tests and integration tests using real temporary repositories
swift test

# Strict formatting, migration/localization checks, core tests, and Debug build
scripts/verify.sh

# Also run native UI, appearance/menu/theme checks, and accessibility audit
# Requires a working interactive macOS login session
scripts/verify.sh --ui
```

Historical verification before M0 passed **183 tests in 32 suites** with both **Apple Git 2.54.0** and an isolated **Git 2.46.0** build. The 2026-10-18 record includes **278 theme checks** (including 216 role/background contrast pairs), alongside earlier **18 appearance/icon behaviors**, **27 native menu behaviors**, and **6 restored-startup combinations**. Dates and source boundaries remain in the [development record](docs/DEVELOPMENT.md); these results do not establish acceptance of the current development source.

The [2026-10-20 M0 checks](docs/acceptance/2026-10-20/v1-1-baseline/README.md) passed **14 sync-count, 30 file-tree/staging, 13 map, 290 theme, 18 icon, and 27 menu checks**, plus **30 Python policy tests**. Localization covered **1015 string keys, 7 plural keys, and 1325 source literals**. Core tests were compiled with `swift build --build-tests`; Debug and native UI tests were compiled with `xcodebuild build-for-testing`. No local XCTest ran, and the new `SelectionScopeTests` still needs hosted execution.

Hosted smoke **1/1**, the full native functional suite **45/45** (zero failures/skips), and the reading matrix **144/144** passed at `2c2533c` in [run 39137123756](https://github.com/WeOpen/WeGit/actions/runs/39137123756). This is functional evidence on the recorded source, not same-commit full acceptance of the release. Accessibility acceptance is deferred; final-source performance, protected-Mac installation and real Beta feedback remain incomplete. See the [release notes](docs/releases/v1.0.0.md) and [current checklist](docs/V1_RELEASE_CHECKLIST.md) for the retained limits.

Tests use isolated configuration files, temporary repositories, and separate preferences. Never run write tests against a repository you cannot afford to change.

## 🗺️ Scope & roadmap

V1.0 focuses on daily Git workflows and readable diffs. **Stash and Tag management, an integrated conflict editor, interactive rebase, Blame, linked worktree/submodule management, and hosting-provider integrations** remain outside the first release. Linked worktree and bare-repository layouts are not currently supported for opening.

The accepted [v1.1 plan](docs/V1_1_PLAN.md) requires Stash, Remote and Tag management, plus file history with targeted search. Single-commit Cherry-pick/Revert is conditional on completing those workflows and their recovery checks. M0 is baseline integration; M1–M5 remain future work, including Beta, versioning and release validation.

The app can hand conflicts to an external editor and continue or abort supported operations. It does not yet include an integrated three-way merge editor. Homebrew Git core and isolated noninteractive OpenPGP checks have passed. GitLab, interactive Pinentry/hardware keys, additional credential-helper setups, and other untested environments remain explicitly pending in the [compatibility matrix](docs/COMPATIBILITY.md).

## 📚 Explore the project

| Path | Contents |
| --- | --- |
| `WeGit/` | SwiftUI app, state, native presentation, design system, and features |
| `WeGitCore/` | Git domain services, process runner, repository queue, snapshots, and watchers |
| `WeGitAskPass/` | Bundled authentication helper |
| `WeGitTests/` · `WeGitUITests/` | Core/integration tests and native UI regression suites |
| `branding/` | Current logo/icon sources and retained earlier resources |
| `docs/` | Product, design, architecture, plans, and acceptance evidence; primarily in Chinese |

- 🧭 [Documentation index](docs/README.md)
- ✅ [V1.0 release checklist](docs/V1_RELEASE_CHECKLIST.md)
- 🏗️ [Architecture](docs/WeGit_Architecture.md)
- 📈 [Performance](docs/PERFORMANCE.md) · ♿ [Accessibility](docs/ACCESSIBILITY.md)
- 📋 [Changelog](CHANGELOG.md) · 📦 [Release procedure](docs/RELEASE.md)

## 🤝 Issue-driven development

Start with an [Issue](https://github.com/WeOpen/WeGit/issues/new/choose), define acceptance criteria, and deliver through a linked PR. See [CONTRIBUTING](CONTRIBUTING.md) and the [GitHub workflow guide](docs/GITHUB_WORKFLOW.md) for labels, CI and gated draft releases.

## 💬 Feedback & contributions

Use [GitHub Issues](https://github.com/WeOpen/WeGit/issues) to report a problem with reproduction steps, the app/macOS/Git versions, and the expected and actual results. For changes, describe the workflow and validation evidence in your pull request.

🔒 Diagnostic summaries are exported only when you request them in Settings. They exclude code, diffs, commit messages, repository paths, and credentials. Review any additional screenshots or logs before sharing them.

## 📄 License

[MIT](LICENSE) © 2026 WeOpen.
