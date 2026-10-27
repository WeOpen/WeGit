# WeGit-Website migration

## Scope

The imported website supplies the page composition, ink landscape assets, responsive styling, bilingual content and theme-editing interaction. The application source tree and native Xcode project are outside this website migration.

The production source is organized under `site/src`, `site/public`, `site/data`, `site/scripts` and `site/tests`. Layout and interaction are preserved; integration changes replace placeholder branding, downloads and the prototype theme schema.

## Preserved inputs

Before migration, all 28 original files were copied byte for byte to `.build/website-migration/incoming-original`. Their SHA-256 receipt is `.build/website-migration/incoming-sha256.json`. The previous website is separately retained in `.build/website-migration/previous-site`.

The author's two original design references are also kept in `site/docs/references`. Landscape masters and the two original large ink PNGs are preserved under `site/design/source` for future asset work and are not published. Original preview screenshots and obsolete placeholder brand assets stay in the private import archive. The author's README and test report are retained as clearly marked historical documents in this folder.

The original `WeGit-Website` folder is removed only after current builds and browser verification, and only after verifying it still matches the archived input receipt. Later edits to that folder must be reconciled before removal.

## Integration decisions

- Reuse canonical R5 horizontal logos, App Icons, favicon, share image and seal paths from `design/brand`; do not typeset the seal or retain the prototype's three-node symbol.
- Keep static assets local; remove AOS/GSAP CDN dependencies and keep native CSS/IntersectionObserver animation.
- Preserve four incoming palette concepts, fill all 17 client roles and calibrate their text pairs. Preserve the earlier six client-compatible custom palettes as additional choices.
- Export only `version`, `name`, `controls` and all 17 `colors`. The author's example `format`, `appearance`, `preferences` and `generatedBy` fields are not a desktop protocol.
- Retain font/size controls as clearly labeled browser preview aids. Accent and contrast changes are real colors and are included in the file.
- Use the same-origin public release snapshot and strict original-release asset checks. Remove the installer placeholder dialog and unsupported Intel compatibility claim.
- Preserve root/Chinese routes and legacy theme HTML routes. Generate localized HTML before JavaScript runs, and keep no-script download access.

## Evidence boundaries

The author's `UPSTREAM-TEST-REPORT.md` used a different environment and page injection. It does not establish current browser, client import, release, performance or deployment acceptance. Current checks must run against the generated website through its local HTTP server; deployment remains a separate action.

## Completed local verification

The original folder was removed after all 28 files were rechecked against the archive receipt. `migration-result.json` in the private migration archive records completion. The checked source is `site/`, and the standard local preview uses `.build/website`.

Local checks passed: 6 Python build contracts, 6 JavaScript theme-model cases, 11 release-link cases, and 373 independent Swift theme behavior checks. The native checks use private preferences and do not execute XCTest. Chrome exercised desktop, 768px tablet and 390px mobile layouts, language/mode switching, accent/contrast/font controls, invalid and valid file import, literal-text imported names, 17-role export, and project-base `/WeGit` routes.

A single localhost cold-cache homepage trace at 1440 × 1000, 1× CPU and no network throttle measured LCP 86 ms and CLS 0.00. This is diagnostic local evidence, not production network or deployed-site acceptance. No deployment was performed.
