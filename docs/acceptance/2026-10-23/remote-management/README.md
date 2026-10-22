# v1.1 Remote management

2026-10-23 · Refs #37. Implements repository-scoped add/edit/remove, separate fetch/push addresses, origin/scope inspection, associated-branch confirmation, stale-plan rejection and conservative read-only handling. Usage: [REMOTE_MANAGEMENT.md](../../../REMOTE_MANAGEMENT.md).

## Safety and behavior

- Writes operate on an owned private copy of repository configuration, under Git's existing config.lock protocol. The final rename is anchored to an identity-checked Git-directory descriptor; a symlinked config is not overwritten, and a changed repository cannot redirect writes or lock cleanup.
- Config/HEAD are revalidated. Multi-URL, included/inherited or credential-bearing settings are read-only. Unknown keys/refspecs remain intact. Removing a remote clears only owned configuration/associations and retains local tracking refs, commits and working files.
- Previously confirmed pushes cannot silently use an edited address. Opaque URI query/fragment credentials are redacted in both configuration views and existing command diagnostics.
- An initially failing check proved `origin.child` was incorrectly included in the `origin` configuration group. Exact subsection grouping fixes it; the initial failure log is retained.

## Executed and pending verification

| Scope | Result |
| --- | --- |
| Isolated real Git | 40 checks in checks.json: config scope and byte preservation, custom keys, independent push URLs, actual bare-remote push, stale plans/snapshots/includes, multiple URLs, dotted names, credential redaction, owned-lock cleanup, invalid names, retained refs and symlink rejection. |
| Read cost | 30 samples with four remotes; performance.json contains raw times and median/p95. The explicit p95 backend-read budget is 2000 ms. This measures the configuration reader, not UI rendering or final Release acceptance. |
| Core / UI source | Six RemoteManagementTests and one full-application RemoteManagementWorkflowTests compile. They are not locally executed. Hosted execution remains pending. |
| Existing behavior | The current native feature behavior lane runs the remote checker plus all existing checks. Exact results are retained in verification.json. |
| Policy and localization | Strict formatting, repository policy, Python tools and localization checked before commit. No local XCTest ran. |

The private fixtures use their own global/system config paths, local bare remotes and synthetic identities; no real credentials or personal repositories are used. A test injected failure on the second private URL edit and verified the complete original config and foreign lock contents survived. A compiled core regression also replaces the Git directory with a symlink during candidate editing and checks that the outside file is untouched; its actual execution belongs to hosted CI.

The first attempt to export performance samples contained a duplicate dictionary key in the checker and failed before report creation. The report-only fault was corrected; the final successful lane is recorded separately. No production logic was changed to conceal that failure.

Pending: actual hosted UI add/edit/cancel/remove, broader application regression, large-config UI rendering, final-source Release performance, installation, Beta feedback and release gates. No version bump or release is claimed here.
