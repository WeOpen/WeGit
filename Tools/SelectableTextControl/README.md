# Selectable Text AX-value control

`Tools/SelectableTextControl/build.sh` builds an independent AppKit window hosting three SwiftUI selectable texts. It does not open a repository, change preferences/security state, or run XCTest. The labels are Plain, Identity and Explicit value; Change toggles a long synthetic address from A to B.

Observed on the local macOS 27 / Xcode 27 runtime, 2026-10-23 through native UI:

| Stage | Plain AX value | `.id(value)` AX value | `.accessibilityValue(value)` AX value | Rendered texts |
| --- | --- | --- | --- | --- |
| Initial | A | A | A | A / A / A |
| After Change | A | B | B | B / B / B |

SwiftUI groups these adjacent texts into one AX text element; the ordered combined value exposes `A … B … B` after the change. The screenshot independently shows all three rendered B addresses. This reproduces the stale selectable-Text AX value independently of repository state and the Remote editor.

Hosted product run [39871992940](https://github.com/WeOpen/WeGit/actions/runs/39871992940) recorded the same mismatch: Git and the screenshot had fetch address B and push address A, while `remote-fetch-value.value` retained A. Remote address views now explicitly expose the current redacted value, preserving their native text identity and selection. The product workflow must be rerun; this control is diagnostic evidence, not a hosted XCTest or full accessibility acceptance pass.
