# Toolbar, paired pane surfaces and upstream counts

2026-10-20 · Issue #34 · `codex/visual-hierarchy-polish`

## Result

Toolbar icon buttons, action capsules, menus and the sidebar toggle now own the same 36pt surface and use a shared 14pt symbol font. Previously ordinary native glass buttons sized themselves from their labels while menus and the sidebar owned fixed surfaces; adding an 18pt badge enlarged the native Push/Pull capsules by about 2pt. The toolbar-specific styles now reserve the shared height inside their labels and paint their own glass, with the existing solid fallback for reduced transparency/increased contrast. In-window controls retain their existing sizing. Existing symbols and action semantics remain.

The built-in palette has two pane levels: both outer sidebars use `sidebar`; canvas, surface and chrome share one central work color. The inspector passes its sidebar background through `ThemedForm`, so the form cannot repaint the inspector with the central canvas. Grouped inspector cards retain their native form appearance. Explicit custom palette values are preserved.

Rendered blank-area samples, left to right:

| Appearance | Navigation | Changed files | Diff | Inspector |
| --- | --- | --- | --- | --- |
| Light | RGB 240,240,240 | RGB 255,255,255 | RGB 255,255,255 | RGB 240,240,240 |
| Dark | RGB 25,25,25 | RGB 30,30,30 | RGB 30,30,30 | RGB 25,25,25 |

Push now displays ahead; Pull displays behind, relative to the current branch's configured upstream. Known zero remains visible as 0. Unloaded/stale, detached, unborn, no upstream or incomplete counts hide the badge and expose pending state. Tooltips explain that numbers reflect the locally fetched upstream and that Fetch is required to check the server. The compact native menu also includes the counts in its visible and announced titles. No new network request or sync operation was added; confirmation and enablement still use the existing app/session paths.

## Executed verification

- `scripts/verify-sync-counts.sh`: **14 passed**, including actual isolated Git divergent history (Push 2 / Pull 3), upstream ref update to 0/0, unborn and detached states. Process-local Git configuration and private temporary fixture, removed on exit; no XCTest.
- `scripts/verify-themes.sh`: **290 passed**, including paired surfaces across four appearance/contrast variants and existing foreground/background contrast, syntax hue, custom palette and persistence assertions. The previous four-distinct-surfaces assertion was replaced with the newly requested paired-surface behavior.
- Native preview through CUA: actual product `GlassControls`, `WindowStateBridge`, `WorkspaceToolbar`, `ThemedForm`, palette and appearance sources, injected with minimal observable app/session stubs and UUID private preferences. Count transitions unknown → 0/0 → 12/3 → stale → 12/3 updated without reopening. Push triggered the stub action; disabled buttons exposed disabled state and dimmed; native menu rendered and announced Pull 3 / Push 12. Four sidebar toggles retained state and background.
- Screenshots at 2×: toolbar painted upper/lower edges align within 0.5pt across ten control samples in both appearances. Pixel threshold extents vary by a boundary pixel with background and antialiasing; the shared layout surface is 36pt. See [pixel samples](pixels.json).
- Debug app build and final `xcodebuild ... build-for-testing`: succeeded. The new UI regression source checks real fixture counts, refresh to zero/unknown, toolbar heights and vertical centers. **Local XCTest execution was not performed**, as requested; this compilation is not an executed UI test result.
- Localization: **1014 string keys, 7 plural keys, 1324 source literals** verified. Strict Swift format, diff whitespace, repository policy and **30 Python policy tests** passed.

The preview is an isolated composition, not full-app acceptance. It never instantiates the production AppState or reads personal repositories. It was closed after capture and its private preference domains were cleaned. System appearance/accessibility/security settings, main and the released v1.0.0 tag were not changed.

## Evidence

- [Light preview](after-light.png), [dark preview](after-dark.png), [native menu](menu-counts.png)
- [Count transitions](count-states.json), [menu announced titles](menu-ax.txt), [Git/count checks](sync-counts.json), [theme checks](theme-checks.json)
- [Private preview source](Preview.swift). It compiles with the product sources named above, `AppPreferences`, `AppStyle`, `CustomTheme`, `ThemeWindowBridge`, `AppPresentation`, `BrandGeometry`, `RepositorySyncCounts` and the built `WeGitCore.o`/resource bundle. Source uses stub sync actions; its repository paths and contents are illustrative.
