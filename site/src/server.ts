import handler from '@tanstack/react-start/server-entry'
import build from '../.generated/build-meta.json'

const publicPages = new Set(['/', '/zh/', '/themes/', '/zh/themes/', '/privacy/', '/zh/privacy/'])
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url)
    if (url.pathname === '/healthz') return Response.json({ status: 'ok' }, { headers: { 'Cache-Control': 'no-store' } })
    if (/\/themes\.html$/.test(url.pathname)) {
      url.pathname = url.pathname.replace(/themes\.html$/, 'themes/')
      return Response.redirect(url.href, 308)
    }
    if (url.pathname.startsWith('/assets/') || /^\/themes\/[^/]+\.json$/.test(url.pathname) || url.pathname === '/appearance.js' || url.pathname === '/releases.json') return env.ASSETS.fetch(request)
    const eligible = !import.meta.env.DEV && request.method === 'GET' && publicPages.has(url.pathname) && !request.headers.has('Cookie') && !request.headers.has('Authorization')
    const cacheKey = new Request(url.origin + '/__wegit_cache/' + build.revision + url.pathname + url.search)
    const cache = eligible ? await caches.open('wegit-public-pages') : null
    const cached = await cache?.match(cacheKey)
    if (cached) {
      const headers = new Headers(cached.headers)
      headers.set('Cache-Control', 'no-cache'); headers.set('Server-Timing', 'edge-cache;desc="hit"')
      return new Response(cached.body, { status: cached.status, headers })
    }
    const nonce = crypto.randomUUID().replaceAll('-', '')
    const incoming = new Headers(request.headers); incoming.set('x-wegit-csp-nonce', nonce)
    const response = await handler.fetch(new Request(request, { headers: incoming }))
    const headers = new Headers(response.headers)
    headers.set('Cache-Control', 'no-cache')
    headers.set('X-Content-Type-Options', 'nosniff')
    headers.set('Referrer-Policy', 'strict-origin-when-cross-origin')
    if (!import.meta.env.DEV) headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self' 'nonce-" + nonce + "'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
    const result = new Response(request.method === 'HEAD' ? null : response.body, { status: response.status, statusText: response.statusText, headers })
    if (cache && result.status === 200 && !headers.has('Set-Cookie') && headers.get('Content-Type')?.includes('text/html')) {
      const stored = result.clone()
      stored.headers.set('Cache-Control', 'public, max-age=300')
      ctx.waitUntil(cache.put(cacheKey, stored))
    }
    return result
  },
}
