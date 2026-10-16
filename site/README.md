# WeGit project website

A static, bilingual site for GitHub Pages. English is the default; Simplified Chinese lives at `/zh/`. It uses the existing WeGit icon and an authentic development-build screenshot, system typography, responsive layouts, system light/dark appearance, visible keyboard focus and reduced-motion support. No analytics, external fonts, framework or package installation.

## Local preview

```bash
python3 scripts/build_website.py --base-path ''
node site/release.test.mjs
python3 -m http.server 4173 --bind 127.0.0.1 --directory .build/website
```

Open `http://127.0.0.1:4173/` and `/zh/`. For the deployed project path, build with `--base-path /WeGit` (the default). Generated output stays in `.build/website`.

The local default is an empty release list. To preview real published release metadata, save `gh api repos/WeOpen/WeGit/releases?per_page=30` to a private build file and pass `--releases-json <file>`. The builder copies only public tag, pre-release and asset-link metadata into `releases.json`.

## Deployment and release updates

`Project website` builds PR changes without deploying them. Main website changes and a manual main run publish via the official, SHA-pinned Pages actions. Publishing/editing/removing a GitHub Release refreshes the download metadata; these events resolve the current main commit explicitly before checkout, so a tag's source cannot replace the website.

The build job has read-only permissions. Only the deployment job obtains `pages:write` and `id-token:write`. Protect the `github-pages` environment for main and version-tag release events. Enable Pages with **GitHub Actions** as its build source. No custom domain or hosting account is required for the default GitHub project address.

Download links always point to GitHub's original assets, never a rebuilt website copy of the app. A direct-download button requires the same release's ZIP, SHA-256 and manifest, with HTTPS URLs belonging to this repository and tag. Drafts are ignored; stable releases take priority over pre-releases. Missing assets, no release and network errors have separate, honest states. The browser reads the same-origin snapshot, so it does not call GitHub's API or use a token.

V1.0 remains in validation. A working website does not complete the native UI, accessibility, performance, clean-machine installation or Beta gates, and Issue #8 stays open until a real published asset has been downloaded and checked.

## Assets

- `mark.svg`, `icon-light.png`, `icon-dark.png`: from `branding/wegit-v2` in application PR #15. The PNGs are resized to 288 px for a 144 pt Retina preview; the original assets and generated design archives are preserved.
- `workspace.png`: `docs/acceptance/2026-10-16/custom-themes/workspace-english.png`; original test-repository screenshot, identified as such on the page.
- Existing project MIT license applies. The site does not redistribute fonts.
