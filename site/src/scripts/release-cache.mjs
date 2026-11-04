import { parseVersion } from './release.mjs';

export const RELEASE_SNAPSHOT_URL = 'https://weopen.github.io/WeGit/releases.json';
export const RELEASE_REFRESH_MS = 120000;
export const MAX_RELEASE_SNAPSHOT_BYTES = 262144;

async function representationETag(body) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(body));
  return '"' + [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('') + '"';
}

export async function boundedJSON(response) {
  if (!response.ok) throw new Error('Release snapshot request failed');
  if (Number(response.headers.get('Content-Length') || 0) > MAX_RELEASE_SNAPSHOT_BYTES) throw new Error('Release snapshot is too large');
  const reader = response.body?.getReader();
  if (!reader) throw new Error('Empty release snapshot');
  const chunks = []; let size = 0;
  try {
    while (true) {
      const next = await reader.read(); if (next.done) break;
      size += next.value.byteLength;
      if (size > MAX_RELEASE_SNAPSHOT_BYTES) { await reader.cancel(); throw new Error('Release snapshot is too large'); }
      chunks.push(next.value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  const values = JSON.parse(new TextDecoder().decode(bytes));
  if (!Array.isArray(values) || values.length > 100) throw new Error('Invalid release snapshot');
  return values.filter(item => item?.draft === false && parseVersion(item.tag_name)).map(item => ({
    tag_name: item.tag_name, draft: false, prerelease: item.prerelease, wegit: item.wegit,
    assets: (Array.isArray(item.assets) ? item.assets : []).slice(0, 30).map(asset => ({
      name: asset.name, browser_download_url: asset.browser_download_url, digest: asset.digest, size: asset.size, state: asset.state,
    })),
  }));
}

/** Pages already refreshes on release publish/edit/delete/unpublish. Workers
 * reads that public snapshot, never the GitHub API for each browser visitor. */
export function createReleaseCache({ fetcher = fetch, now = Date.now } = {}) {
  let pending = null;
  let snapshot = null;
  let refreshedAt = 0;
  let attemptedAt = 0;
  async function refresh(cached, env, cache, key) {
    if (pending) return pending;
    pending = (async () => {
      attemptedAt = now();
      const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 15000);
      try {
        const headers = { 'Accept': 'application/json', 'Cache-Control': 'no-cache' };
        const previousETag = new Headers(cached?.headers || {}).get('X-WeGit-Upstream-ETag');
        if (previousETag) headers['If-None-Match'] = previousETag;
        const response = await fetcher(RELEASE_SNAPSHOT_URL, { headers, signal: controller.signal, cf: { cacheTtl: 120, cacheEverything: true } });
        let values;
        if (response.status === 304 && cached) values = JSON.parse(cached.body);
        else values = await boundedJSON(response);
        const body = JSON.stringify(values) + '\n';
        const result = { body, status: 200, headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'public, max-age=86400',
          'ETag': await representationETag(body), 'X-WeGit-Refreshed-At': String(now()), 'X-WeGit-Attempted-At': String(now()), 'X-WeGit-Upstream-ETag': response.headers.get('ETag') || previousETag || '' } };
        snapshot = result; refreshedAt = now();
        await cache.put(key, new Response(result.body, { status: result.status, headers: result.headers }));
        return result;
      } catch {
        let previous = cached;
        if (!previous) {
          const response = await env.ASSETS.fetch(new Request(new URL('/releases.json', key.url)));
          previous = { body: JSON.stringify(await boundedJSON(response)) + '\n', status: response.status, headers: Object.fromEntries(response.headers) };
        }
        const headers = new Headers(previous.headers);
        // The fallback has been decoded and normalized into a new JSON body.
        // Transport headers and validators must describe these returned bytes.
        for (const name of ['Content-Encoding', 'Content-Length', 'Content-Range']) headers.delete(name);
        headers.set('Content-Type', 'application/json; charset=utf-8');
        headers.set('ETag', await representationETag(previous.body));
        headers.set('X-WeGit-Attempted-At', String(now()));
        headers.set('X-WeGit-Release-Source', 'last-valid');
        headers.set('Cache-Control', 'public, max-age=86400');
        const fallback = { body: previous.body, status: previous.status, headers: Object.fromEntries(headers) };
        snapshot = fallback;
        if (fallback.status === 200) await cache.put(key, new Response(fallback.body, { status: fallback.status, headers: fallback.headers }));
        return fallback;
      } finally { clearTimeout(timer); pending = null; }
    })();
    return pending;
  }
  return {
    async read(request, env, cache) {
      if (!['GET', 'HEAD'].includes(request.method)) return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
      const key = new Request(new URL('/__wegit_release_catalog/v1.json', request.url));
      let cached = snapshot;
      if (!cached) {
        const stored = await cache.match(key);
        if (stored) {
          cached = { body: await stored.text(), status: stored.status, headers: Object.fromEntries(stored.headers) };
          snapshot = cached;
          const headers = new Headers(cached.headers);
          refreshedAt = Number(headers.get('X-WeGit-Refreshed-At') || 0);
          attemptedAt = Number(headers.get('X-WeGit-Attempted-At') || refreshedAt);
        }
      }
      const response = cached && now() - attemptedAt < RELEASE_REFRESH_MS ? cached : await refresh(cached, env, cache, key);
      const headers = new Headers(response.headers); headers.set('Cache-Control', 'public, max-age=60, must-revalidate'); headers.set('X-Content-Type-Options', 'nosniff');
      if (request.headers.get('If-None-Match') && request.headers.get('If-None-Match') === headers.get('ETag')) return new Response(null, { status: 304, headers });
      return new Response(request.method === 'HEAD' ? null : response.body, { status: response.status, headers });
    },
  };
}
