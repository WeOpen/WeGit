import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'
import { readdirSync } from 'node:fs'
import { decodeTheme } from '../src/scripts/theme-model.js'

const site = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const root = resolve(site, '..')
const output = join(site, '.generated')
const marker = join(output, '.wegit-start-generated')
if (existsSync(output)) {
  if (lstatSync(output).isSymbolicLink() || !existsSync(marker) || readFileSync(marker, 'utf8') !== 'WeGit Start assets\n') throw new Error('Refusing to replace an unrelated .generated folder')
  rmSync(output, { recursive: true })
}
mkdirSync(output, { recursive: true })
writeFileSync(marker, 'WeGit Start assets\n')
const publicDir = join(output, 'public')
cpSync(join(site, 'public'), publicDir, { recursive: true })
mkdirSync(join(publicDir, 'assets/brand'), { recursive: true })
const brandRoot = realpathSync(join(root, 'design/brand'))
const manifest = JSON.parse(readFileSync(join(site, 'data/brand-assets.json'), 'utf8'))
for (const [name, source] of Object.entries(manifest)) {
  const path = realpathSync(join(root, source))
  if (relative(brandRoot, path).startsWith('..')) throw new Error('Brand input escaped canonical directory')
  cpSync(path, join(publicDir, 'assets/brand', name))
}
cpSync(join(root, 'design/brand/source/git-symbol.svg'), join(publicDir, 'assets/brand/git-symbol.svg'))
const catalog = JSON.parse(readFileSync(join(site, 'data/themes.json'), 'utf8'))
for (const entry of catalog) decodeTheme(readFileSync(join(site, 'public/themes', entry.id + '.json'), 'utf8'))
mkdirSync(join(output, 'styles'), { recursive: true })
for (const file of ['main.css', 'components.css', 'error.css', 'footer-effect.css']) {
  const css = readFileSync(join(site, 'src/styles', file), 'utf8').replaceAll("url('../", "url('/assets/")
  writeFileSync(join(output, 'styles', file), css)
}
cpSync(join(site, 'src/scripts/boot.js'), join(publicDir, 'appearance.js'))
const source = process.env.WEGIT_RELEASES_JSON
const releases = source ? JSON.parse(readFileSync(source, 'utf8')) : []
if (!Array.isArray(releases)) throw new Error('Release snapshot must be an array')
const snapshot = releases.filter(item => item.draft === false).map(item => ({
  tag_name: item.tag_name, draft: false, prerelease: item.prerelease,
  assets: (item.assets ?? []).map(asset => ({ name: asset.name, browser_download_url: asset.browser_download_url })),
}))
writeFileSync(join(publicDir, 'releases.json'), JSON.stringify(snapshot) + '\n')
writeFileSync(join(publicDir, '_headers'), ['/assets/brand/*', '  Cache-Control: public, max-age=0, must-revalidate', '/assets/illustrations/*', '  Cache-Control: public, max-age=0, must-revalidate', '/assets/screenshots/*', '  Cache-Control: public, max-age=0, must-revalidate', '/assets/icons/*', '  Cache-Control: public, max-age=0, must-revalidate', '/assets/*.js', '  Cache-Control: public, max-age=31536000, immutable', '/assets/*.css', '  Cache-Control: public, max-age=31536000, immutable', '/themes/*.json', '  Cache-Control: no-cache', '/releases.json', '  Cache-Control: no-cache'].join('\n') + '\n')
const digest = createHash('sha256')
function hashDirectory(folder) {
  for (const entry of readdirSync(folder, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const path = join(folder, entry.name)
    if (entry.isDirectory()) hashDirectory(path)
    else if (entry.name !== 'routeTree.gen.ts') digest.update(relative(site, path) + '\0').update(readFileSync(path))
  }
}
hashDirectory(join(site, 'src')); hashDirectory(join(site, 'data')); hashDirectory(publicDir)
digest.update(readFileSync(join(site, 'package-lock.json')))
digest.update(readFileSync(join(site, 'package.json'))).update(readFileSync(join(site, 'wrangler.jsonc'))).update(readFileSync(fileURLToPath(import.meta.url)))
const year = new Date().getUTCFullYear()
digest.update(process.env.VITE_SITE_ORIGIN || '').update(String(year))
writeFileSync(join(output, 'build-meta.json'), JSON.stringify({ revision: digest.digest('hex').slice(0, 20), year }) + '\n')
console.log('Prepared canonical brand, illustrations, native themes and local appearance bootstrap.')
