# v1.1 Tag management

2026-10-23 · Refs #38. [Usage](../../../TAG_MANAGEMENT.md).

Implemented: literal name search and bounded listing, exact target/annotation inspection, lightweight and annotated creation from HEAD or a historical commit, local deletion guarded by old object ID, and one confirmed endpoint/tag push. Signing uses Git configuration. Symbolic references and non-commit objects remain readable with restricted writes. Changed HEAD/config/ref/remote plans cannot silently retarget a confirmed operation.

Executed locally, without XCTest:

- 34 isolated real-Git checks (`checks.json`). Include same branch/tag name, annotation body, literal/nested/Unicode search, stale deletion/config, dangling and ordinary symbolic tags, selective bare-remote push with followTags/mirror enabled, same-commit different annotation conflict, lost push reply and failed post-push verification, missing signer, invalid names and pagination.
- First annotation check failed because Git stripped a `#` heading. `--cleanup=verbatim` fixes the actual write behavior; the same check then passed.
- 30 backend-read samples with 307 tags (`performance.json`): p95 about 25 ms against a 2000 ms budget. This is a Debug backend measurement, not final-source Release/UI performance acceptance.
- The whole native behavior lane passed 526 checks, including 32 native-menu checks. 31 Python checks passed. Four new core tests and two UI workflows compiled; none executed locally. English/Chinese source coverage and strict formatting were checked.
- Isolated full-application preview with a unique bundle identifier and synthetic repository: list/detail/diff, light/dark surfaces and create/cancel were inspected through native UI. It found the reused Stash accessibility wording and overly wide list, both corrected. Preview results do not replace hosted XCTest or full accessibility acceptance.

Real OpenPGP annotation signing was added to the existing private-GNUPGHOME compatibility checker, including `verify-tag --raw` against its ephemeral fingerprint and unchanged global-config bytes. The checker compiled locally but returned 78 because required Homebrew tools were absent; no fallback or installation occurred. Actual signing execution is pending hosted CI.

Pending: hosted core/UI/signing execution, final-source whole-app regression, Release performance, installation and Beta/release gates. No version or release is claimed. All write fixtures use private repositories, synthetic identity, isolated configuration and local bare remotes; no user credentials or personal repositories are used.
