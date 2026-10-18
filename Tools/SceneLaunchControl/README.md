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

Both asynchronous launch routes also failed the visible-content assertion. The third selection is `appkit,hosting`: a plain AppKit window and an AppKit window containing the same SwiftUI text, both using ordinary XCTest launch. These independent controls distinguish window-server presentation, SwiftUI hosting and the SwiftUI App/Scene lifecycle. The earlier five failed cases are retained and are not automatically retried. A passing control additionally requires exactly one hittable window and retains its screenshot.

Both AppKit controls passed one executed test with no failures or skips in run 38995999775. The fourth selection is `defaultargs,marker,language`: the identical bare SwiftUI scene with XCTest default launch arguments, only `--uitesting`, or only `-language zh-Hans`. Git configuration isolation remains identical. An application startup receipt logs only boolean argument/isolation flags, never raw environment contents. These controls test whether caller-supplied arguments suppress the first SwiftUI scene; they do not change WeGit or its UI launcher.

The individual argument controls in run 39002210951 each executed and passed one test without skips. The next selection `combined,reordered,applelanguage` uses the identical instrumented bare scene source: original combined arguments, the same arguments reordered, or the marker plus standard AppleLanguages defaults. The original combination is tested again because the successful individual controls added an explicit initializer, so prior failures cannot yet be attributed to the arguments alone.

Run 39010111869 confirms an order-sensitive launch difference: original combined arguments fail, the reordered equivalent passes, and AppleLanguages with the leading marker fails. Each case executes one test with zero skips. The Foundation-only parser probe reads the language correctly in both orders, so it does not establish a parser-consumption mechanism. The product UI launcher is being verified with value-bearing settings before valueless test switches.

WeGit smoke 39010563892 passed after the shared test launcher moved value-bearing settings before the known valueless test switches. The driver now defaults to the passing `reordered` regression; the failed historical cases remain explicitly selectable. This verifies startup and the welcome/Clone form only, with all product application inputs unchanged.

The hosted workflow now defaults to a temporary 1920x1080 display session, after a read-only receipt showed the original 1024x768 desktop with only 1024x674 usable space. The helper is restricted to GitHub-hosted jobs, records the original/effective/restored modes, preserves child failure status and explicitly restores the original mode. `display=original` retains the historical profile. The mode also expires with the helper process per Core Graphics. Its actual switch/restoration evidence is retained separately; this does not change the scene assertions or qualify a product/release gate.


## Independent accessibility controls

`audit-native` and `audit-hosted` use separate bundle IDs, a plain AppKit window and either standard AppKit controls or an NSHostingView of standard SwiftUI controls. They have no WeGit UI, palette, model, persistence, repository, network or native-menu replacement. Only the hosted variant imports SwiftUI. Each one-test control launches Light and Dark appearances within its own window, requires a visible window, opens/selects a native scope menu and verifies a button updates its label before auditing.

The audit uses the same description/action/parent-child/contrast categories as the product audit, preserves every callback and screenshot, and returns false for every report. A failed audit remains a failed control; neither control establishes a product exception or changes a product gate. The ordinary scene regression remains separate. These controls are intended to investigate contradictory high-contrast text and standard menu reports; recorded original security state and actual test counts still apply. They never change OS authorization or system appearance settings.
