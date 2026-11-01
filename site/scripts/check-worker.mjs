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
for (const prefix of ['', '/zh']) for (const page of ['/', '/themes/', '/privacy/']) {
  const { response, body } = await request(prefix + page)
  assert.equal(response.status, 200); assert.ok(body.includes('<main')); assert.ok(body.includes('footer-logo'))
  assert.ok(body.includes('lang="' + (prefix ? 'zh-CN' : 'en') + '"'))
  const nonce = response.headers.get('content-security-policy')?.match(/nonce-([^']+)/)?.[1]
  assert.ok(nonce); assert.ok(body.includes('nonce="' + nonce + '"'))
  if (page === '/themes/') assert.equal((body.match(/class="theme-card"/g) || []).length, 10)
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
