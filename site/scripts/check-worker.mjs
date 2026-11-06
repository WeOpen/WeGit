import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
const origin = process.env.WEGIT_TEST_ORIGIN || 'http://127.0.0.1:4179'
assert.ok(['127.0.0.1', 'localhost'].includes(new URL(origin).hostname), 'Use a local Workers preview')
let checks = 0
async function request(path, options = {}) {
  const response = await fetch(origin + path, { redirect: 'manual', ...options })
  return { response, body: await response.text() }
}
const health = await request('/healthz')
assert.equal(health.response.status, 200); assert.equal(JSON.parse(health.body).status, 'ok'); checks++
const releaseHead = await request('/releases.json', { method: 'HEAD' })
assert.equal(releaseHead.response.status, 200); assert.equal(releaseHead.body, ''); checks++
const releaseFirst = await request('/releases.json'), releaseSecond = await request('/releases.json')
assert.equal(releaseFirst.response.status, 200); assert.equal(releaseSecond.response.status, 200)
assert.ok(Array.isArray(JSON.parse(releaseFirst.body))); assert.equal(releaseFirst.body, releaseSecond.body)
assert.equal(releaseFirst.response.headers.get('x-content-type-options'), 'nosniff'); checks++
const releaseETag = releaseFirst.response.headers.get('etag')
const releaseNotChanged = await request('/releases.json', { headers: { 'If-None-Match': releaseETag } })
assert.equal(releaseNotChanged.response.status, 304); assert.equal(releaseNotChanged.body, ''); checks++
const download = await request('/download/universal')
assert.equal(download.response.status, 302); assert.ok(download.response.headers.get('location').startsWith('https://github.com/WeOpen/WeGit/releases')); checks++
for (const prefix of ['', '/zh']) for (const page of ['/', '/themes/', '/privacy/']) {
  const { response, body } = await request(prefix + page)
  assert.equal(response.status, 200); assert.ok(body.includes('<main')); assert.ok(body.includes('footer-logo'))
  assert.ok(body.includes('lang="' + (prefix ? 'zh-CN' : 'en') + '"'))
  const nonce = response.headers.get('content-security-policy')?.match(/nonce-([^']+)/)?.[1]
  assert.ok(nonce); assert.ok(body.includes('nonce="' + nonce + '"'))
  if (page === '/themes/') assert.equal((body.match(/class="theme-card"/g) || []).length, 10)
  if (!prefix && page === '/') {
    const scripts = [...body.matchAll(/<script\b[^>]*\bsrc="([^"]+)"/g)].map(match => match[1])
    assert.ok(scripts.some(path => path.startsWith('/assets/') && path.endsWith('.js')), 'Page must reference its built client entry')
    for (const path of scripts) {
      const asset = new URL(path, origin)
      assert.equal(asset.origin, origin)
      const loaded = await request(asset.pathname + asset.search)
      assert.equal(loaded.response.status, 200, 'Referenced client script must load: ' + path)
      assert.ok(loaded.response.headers.get('content-type')?.includes('javascript'))
      assert.equal(loaded.body, readFileSync('dist/client' + asset.pathname, 'utf8'), 'HTML and client script must share this build')
      checks++
    }
  }
  checks++
}
for (const path of ['/missing-page/', '/zh/missing-page/']) {
  const { response, body } = await request(path)
  assert.equal(response.status, 404); assert.ok(body.includes('error-title')); checks++
}
const head = await request('/zh/', { method: 'HEAD' })
assert.equal(head.response.status, 200); assert.equal(head.body, ''); checks++
const missingAsset = await request('/assets/missing.css')
assert.equal(missingAsset.response.status, 404); assert.ok(!missingAsset.body.includes('error-title')); checks++
const legacy = await request('/zh/themes.html?theme=ink')
assert.equal(legacy.response.status, 308); assert.equal(new URL(legacy.response.headers.get('location')).pathname, '/zh/themes/'); assert.equal(new URL(legacy.response.headers.get('location')).search, '?theme=ink'); checks++
const theme = await request('/themes/ink.json')
assert.equal(theme.body, readFileSync('public/themes/ink.json', 'utf8')); checks++
const path = '/?cache-check=' + Date.now()
await request(path)
const cached = await request(path)
assert.ok(cached.response.headers.get('server-timing')?.includes('hit')); checks++
for (const headers of [{ Cookie: 'test=1' }, { Authorization: 'Bearer local-test' }]) {
  const bypass = await request(path, { headers })
  assert.ok(!bypass.response.headers.get('server-timing')?.includes('hit')); checks++
}
console.log(JSON.stringify({ checks, passed: checks, origin }))
