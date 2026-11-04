# Universal DMG release verification

[WeGit 1.2.0-rc.1](https://github.com/WeOpen/WeGit/releases/tag/v1.2.0-rc.1) was published on 2026-11-04 at 12:57:45 Asia/Shanghai from reviewed main commit `127b553f9c35bb5bff7a1c66fa14eacced7d5798`. The same DMG contains WeGit and AskPass for arm64/x86_64, with macOS 26.0 as the minimum deployment version. It is ad-hoc signed and not notarized by Apple.

## Verified artifact

- Download: [Universal DMG](https://github.com/WeOpen/WeGit/releases/download/v1.2.0-rc.1/WeGit-1.2.0-rc.1-macos-universal-adhoc.dmg), [SHA-256](https://github.com/WeOpen/WeGit/releases/download/v1.2.0-rc.1/WeGit-1.2.0-rc.1-macos-universal-adhoc.dmg.sha256).
- SHA-256: `baf14b0ac8f9921f151fe822c0d36bc49a51961f522d93afe3a9337ff4f708d1`.
- Download/installed bytes: **20,984,079 / 59,508,178**, within **30 / 60 MiB** budgets.
- Production ID: `com.willxue.wegit`; app version/build: **1.2.0 / 5**.
- Every bundled Mach-O has both native slices and minimum macOS 26.0. Signatures passed deep/strict verification; signing entitlements are empty.
- The downloaded DMG passed `hdiutil verify`, read-only mount, complete source/receipt/resource checks and the Applications shortcut check. The inspection mount was detached.

[Distribution receipt](distribution.json), [original manifest](manifest.json) and [release metadata](release.json) retain the exact package hashes and source inputs. No local XCTest was executed.

The system returned the new R5 icon before the application process launched:

<img src="startup-icon.png" width="256" alt="Launch Services startup icon from the final downloaded DMG">

## Exact-source validation

[Main CI 41769132434](https://github.com/WeOpen/WeGit/actions/runs/41769132434) completed successfully, including actual Native macOS and Repository policy jobs. Native macOS took 48 minutes 59 seconds. [Draft release 41774630275](https://github.com/WeOpen/WeGit/actions/runs/41774630275) rebuilt the tagged source as a production-ID Universal DMG, revalidated the same-source main gate and created a draft before manual publication.

| Check | Actual result |
| --- | --- |
| Package/application source inputs | 365 / 195, each compared with the tagged Git blobs |
| Apple, minimum Git 2.46, Homebrew core regressions | Each 266 tests / 47 suites passed |
| Isolated OpenPGP | Apple/Homebrew each 9 checks; private fixtures and services cleaned up |
| Backend performance | 450 valid raw samples; 3 workloads × 30 samples × 5 reports |
| Native UI regression sources | Compiled in hosted main CI |
| Hosted startup smoke | 1 total / 1 passed / 0 failed / 0 skipped; all 195 app inputs equivalent to the tag; display restored |
| Main native artifact | 19,880,050 bytes / 39 CRC entries, complete SHA-256 verified |

[Main receipt](main-ci.json), [CI artifact hashes](ci-artifacts.json), [independent performance recomputation](performance.json) and [smoke equivalence](smoke.json) retain their separate scopes. The original performance arrays are preserved in [raw-performance](raw-performance/rebase.json), with a file for each of Interactive Rebase, conflict editor, Rebase, Submodule/LFS and Worktree reading. Original percentile, cancellation and memory budgets remain unchanged.

The earlier [CI 41746732092](https://github.com/WeOpen/WeGit/actions/runs/41746732092) failed at the old Rebase cancellation fixture's 16th attempt, retaining 15 valid samples. Its original artifact, arrays and fixture remain in `.build/release-1.2-preflight/`. The corrected fixture terminates and reaps its own child; the old failure is not relabeled as a passing run.

## Website and limits

[The published release snapshot](published-release.json) contains the four canonical tag asset URLs, excluding draft `untagged-*` placeholders. Cloudflare build `cf0d248a-a690-4273-89d7-8dbfe8ce392f` deployed version `afe3a881-7d28-4b0c-93f8-ac8a24e60678` after fetching that snapshot during the build. Worker startup was 24 ms. Existing site resource budgets remain required; no runtime GitHub API request was added.

[Website receipt](website.json) records the actual production build: **2,721,824 public bytes / 61,844 CSS bytes / 142,839 client gzip bytes / 255,711 Worker gzip bytes**, within the existing limits. Both English and Chinese buttons point to the published Universal DMG. [The actual browser download](public-download.json) from the Chinese homepage was **20,984,079 bytes**, with the same SHA-256 as the inspected production artifact. The complete production log remains in `.build/release-1.2-preflight/cloudflare-publication-build.log`.

Intel hardware/macOS 26 runtime, protected-Mac installation, complete VoiceOver, whole-app Release performance and external Beta remain unverified. The earlier 69-test native functional result belongs to its dated source. This public candidate preserves the stable release workflow's canonical exact-commit Full acceptance requirement.
