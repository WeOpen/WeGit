# Independent scene launch controls

These diagnostic apps contain plain SwiftUI text. The bare baseline uses only a `WindowGroup`, with no app delegate, Settings scene or scene modifiers. Two matched controls add a single `Window` or `WindowGroup`, an app delegate and the same scene configuration used by WeGit. They have no WeGit dependency, repository, theme, persistence, menu replacement, user account or network operation. Their bundle IDs are separate from WeGit. Only the UI-test runners use the same debug entitlements as the product's test runner.

The checked-in Xcode project is generated with XcodeGen 2.43.0 from `project.yml`; the hosted run does not need XcodeGen. From the repository root:

```bash
python3 scripts/ci/scene_control.py
```

The driver first reads the real Aqua/console/developer-tools state. It then builds and tests each control serially with bounded deadlines. Each control must actually execute and pass exactly one test without skips. A failed control is retained; the other controls are independent and contain no larger WeGit regression. The result never marks a product or release gate complete.

The same-repository PR workflow checks out the explicit head SHA on a disposable hosted VM with a read-only token. Manual dispatch is restricted to main. No system permission, SIP, Gatekeeper, default Git configuration or user's WeGit data is modified. Raw xcresults, startup output, failure hierarchies and desktop screenshots remain in the corresponding Actions artifact. Results must be interpreted with the recorded original system protection state.
