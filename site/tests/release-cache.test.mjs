import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { boundedJSON, createReleaseCache, RELEASE_SNAPSHOT_URL } from '../src/scripts/release-cache.mjs';

const payload = [{ tag_name: 'v1.2.0-rc.1', draft: false, prerelease: true, assets: [] }];
function fixtures() {
  const values = new Map();
  return { cache: { match: async key => values.get(key.url)?.clone(), put: async (key, response) => values.set(key.url, response) },
    env: { ASSETS: { fetch: async () => Response.json(payload) } } };
}
test('cold parallel readers coalesce one bounded public Pages fetch', async () => {
  const { cache, env } = fixtures(); let calls = 0;
  const catalog = createReleaseCache({ now: () => 1000, fetcher: async url => { assert.equal(url, RELEASE_SNAPSHOT_URL); calls++; return Response.json(payload, { headers: { ETag: 'upstream' } }); } });
  const responses = await Promise.all(Array.from({ length: 20 }, () => catalog.read(new Request('https://site.test/releases.json'), env, cache)));
  assert.equal(calls, 1);
  for (const response of responses) assert.deepEqual(await response.json(), payload);
  await catalog.read(new Request('https://site.test/releases.json'), env, cache); assert.equal(calls, 1);
});
test('refresh uses ETag and a successful empty snapshot withdraws old downloads', async () => {
  const { cache, env } = fixtures(); let clock = 1000, calls = 0;
  const catalog = createReleaseCache({ now: () => clock, fetcher: async (_url, options) => {
    calls++; if (calls === 1) return Response.json(payload, { headers: { ETag: 'upstream' } });
    assert.equal(options.headers['If-None-Match'], 'upstream'); return Response.json([]);
  } });
  await catalog.read(new Request('https://site.test/releases.json'), env, cache);
  clock += 121000;
  const response = await catalog.read(new Request('https://site.test/releases.json'), env, cache);
  assert.deepEqual(await response.json(), []); assert.equal(calls, 2);
});
test('failed refresh retains valid data and throttles further attempts', async () => {
  const { cache, env } = fixtures(); let clock = 1000, calls = 0;
  const catalog = createReleaseCache({ now: () => clock, fetcher: async () => { calls++; throw new Error('offline'); } });
  const first = await catalog.read(new Request('https://site.test/releases.json'), env, cache);
  assert.deepEqual(await first.json(), payload);
  for (let index = 0; index < 20; index++) await catalog.read(new Request('https://site.test/releases.json'), env, cache);
  assert.equal(calls, 1);
  clock += 121000; await catalog.read(new Request('https://site.test/releases.json'), env, cache); assert.equal(calls, 2);
});
test('HTTP validators, HEAD and unsupported methods retain correct semantics', async () => {
  const { cache, env } = fixtures();
  const catalog = createReleaseCache({ now: () => 1000, fetcher: async () => Response.json(payload) });
  const first = await catalog.read(new Request('https://site.test/releases.json'), env, cache);
  const etag = first.headers.get('ETag');
  const conditional = await catalog.read(new Request('https://site.test/releases.json', { headers: { 'If-None-Match': etag } }), env, cache);
  assert.equal(conditional.status, 304); assert.equal(await conditional.text(), '');
  const head = await catalog.read(new Request('https://site.test/releases.json', { method: 'HEAD' }), env, cache);
  assert.equal(await head.text(), '');
  assert.equal((await catalog.read(new Request('https://site.test/releases.json', { method: 'POST' }), env, cache)).status, 405);
});
test('oversized and malformed snapshots cannot replace valid cache data', async () => {
  await assert.rejects(() => boundedJSON(new Response('x'.repeat(262145))), /too large/);
  await assert.rejects(() => boundedJSON(Response.json({})), /Invalid/);
});
test('normalized static fallback drops old transport headers and validates its actual bytes', async () => {
  const { cache } = fixtures();
  const source = [...payload.map(item => ({ ...item, ignoredMetadata: 'removed during normalization' }))];
  const env = { ASSETS: { fetch: async () => Response.json(source, { headers: {
    'Content-Encoding': 'gzip', 'Content-Length': '9999', 'Content-Range': 'bytes 0-9998/9999', 'ETag': 'old-raw-json',
  } }) } };
  const catalog = createReleaseCache({ now: () => 1000, fetcher: async () => { throw new Error('offline'); } });
  const response = await catalog.read(new Request('https://site.test/releases.json'), env, cache);
  const body = await response.text();
  assert.deepEqual(JSON.parse(body), payload);
  for (const name of ['Content-Encoding', 'Content-Length', 'Content-Range']) assert.equal(response.headers.get(name), null);
  assert.equal(response.headers.get('ETag'), '"' + createHash('sha256').update(body).digest('hex') + '"');
});
