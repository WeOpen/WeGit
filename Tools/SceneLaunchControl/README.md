# Independent scene launch controls

These diagnostic apps contain plain SwiftUI text. The bare baseline uses only a `WindowGroup`, with no app delegate, Settings scene or scene modifiers. Two matched controls add a single `Window` or `WindowGroup`, an app delegate and the same scene configuration used by WeGit. They have no WeGit dependency, repository, theme, persistence, menu replacement, user account or network operation. Their bundle IDs are separate from WeGit. Only the UI-test runners use the same debug entitlements as the product's test runner.

The checked-in Xcode project is generated with XcodeGen 2.43.0 from `project.yml`; the hosted run does not need XcodeGen. From the repository root:

```bash
python3 scripts/ci/scene_control.py
# Reproduce the original three scene controls explicitly:
python3 scripts/ci/scene_control.py --controls bare,single,group
```

The driver first reads the real Aqua/console/developer-tools state. It then builds and tests each control serially with bounded deadlines. Each control must actually execute and pass exactly one test without skips. A failed control is retained; the other controls are independent and contain no larger WeGit regression. The result never marks a product or release gate complete.

The first hosted run executed and failed all three controls, including the bare baseline. The next comparison selects only `async,workspace`: two fresh bundle IDs use the identical bare app source and asynchronous test method, with XCTest or public NSWorkspace launch respectively. Both require the requested isolation arguments to reach the child and the window content to appear. Xcode's generated UI runners are sandboxed in the inspected build; that protection is unchanged, and argument receipt is a separate required assertion. The earlier unchanged failing controls are not automatically retried. NSWorkspace launch is diagnostic only; the WeGit test launcher is unchanged. See [Apple's launch configuration API](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration).

The same-repository PR workflow checks out the explicit head SHA on a disposable hosted VM with a read-only token. Manual dispatch is restricted to main. No system permission, SIP, Gatekeeper, default Git configuration or user's WeGit data is modified. Raw xcresults, startup output, failure hierarchies and desktop screenshots remain in the corresponding Actions artifact. Results must be interpreted with the recorded original system protection state.

Both asynchronous launch routes also failed the visible-content assertion. The current selection is `appkit,hosting`: a plain AppKit window and an AppKit window containing the same SwiftUI text, both using ordinary XCTest launch. These independent controls distinguish window-server presentation, SwiftUI hosting and the SwiftUI App/Scene lifecycle. The earlier five failed cases are retained and are not automatically retried. A passing control additionally requires exactly one hittable window and retains its screenshot.
