# V12-08 / V12-09 Submodule and Git LFS implementation increment

## Trusted native follow-up · 2026-11-01

PR #93 reached main `7494bf55886379f4b77523e4ec62c0c707c07bd0` after all three required checks passed. Trusted-main run [41301529397](https://github.com/WeOpen/WeGit/actions/runs/41301529397) actually passed the minimal smoke and allowlisted Submodule/LFS Inspector test, each with `total=1/passed=1/failed=0/skipped=0`. The focused outer command took 19.191 seconds. Its 191 application inputs match that commit, the ZIP digest/73 CRC entries pass, and the temporary display was restored.

The focused xcresult has no retained screenshot attachments. This follow-up adds a screenshot and accessibility-tree attachment on success; Issue #92 stays open until a new trusted run on the changed test retains reviewable artifacts. Counts alone do not complete its visual evidence requirement. The previous failed native runs and implementation-only receipt below remain historical evidence.

This branch adds configured submodule discovery and bounded Git LFS inspection to the Core service, plus a repository-resources tab in the existing Inspector. The implementation keeps all Git writes behind the existing repository session state checks.

## Verified locally

| Check | Result |
| --- | --- |
| Core build | `swift build --target WeGitCore` passed |
| Core tests compile | `swift build --build-tests` passed; no local XCTest ran |
| App build | `xcodebuild -project WeGit.xcodeproj -scheme WeGit -configuration Debug CODE_SIGNING_ALLOWED=NO build` passed |
| Formatting | Strict `swift format lint` passed for changed Swift files |
| Localization | `python3 scripts/verify-localization.py` passed: 1390 strings / 8 plurals |
| Private Git checker | `scripts/verify-submodule-lfs.sh` passed 15 checks |

The checker uses disposable repositories, a local child repository and `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null`. It covers clean, child-commit drift, tracked and ignored child changes, deinitialization, foreign-directory protection, parent HEAD/index preservation, malformed and missing `.gitmodules`, missing and hydrated LFS objects, malformed pointers, and tool-aware fetch refusal (missing-tool or invalid-timeout before any network operation).

## Implementation boundary

Submodule reads combine committed and index gitlinks with `.gitmodules`, classify uninitialized/clean/dirty/staged/child-changed/invalid states, and revalidate parent identity and snapshots around `submodule update --init --checkout`. LFS reads use the index blob as the pointer source, bound all worktree/object reads, skip gitlinks and symlinks, and compare hydrated content by SHA-256 when within the read budget.

## Open acceptance gates

This is an implementation increment. Required hosted Core/UI checks, trusted native UI smoke/focused evidence, Release performance samples, full Issue → PR integration and final M5 gates remain open. Issues #88 and #89 must remain open until those gates pass.
