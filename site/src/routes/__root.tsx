import { createRootRoute, HeadContent, Outlet, Scripts, useLocation, useRouter } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { SiteShell } from '../components/Site'
import { NotFound } from '../pages/NotFound'
import { localeFromPath, pageFromPath } from '../lib/site'
import mainCss from '../../.generated/styles/main.css?url'
import componentsCss from '../../.generated/styles/components.css?url'
import footerCss from '../../.generated/styles/footer-effect.css?url'

export const Route = createRootRoute({
  head: () => ({
    meta: [{ name: 'viewport', content: 'width=device-width, initial-scale=1' }, { name: 'theme-color', content: '#f8f6f1' }],
    links: [{ rel: 'stylesheet', href: mainCss }, { rel: 'stylesheet', href: componentsCss }, { rel: 'stylesheet', href: footerCss }, { rel: 'icon', type: 'image/svg+xml', href: '/assets/brand/favicon.svg' }],
  }),
  component: Outlet,
  shellComponent: Document,
  notFoundComponent: NotFound,
  errorComponent: ({ reset }) => <main id="main" className="section"><div className="wrap"><h1>WeGit</h1><button className="button button-red" onClick={reset}>Retry / 重试</button></div></main>,
})
function Document({ children }: { children: ReactNode }) {
  const path = useLocation({ select: location => location.pathname })
  const locale = localeFromPath(path), page = pageFromPath(path)
  const nonce = useRouter().options.ssr?.nonce
  return <html lang={locale === 'zh' ? 'zh-CN' : 'en'} data-site-mode="light" suppressHydrationWarning><head><meta charSet="utf-8" /><meta name="csp-nonce" content={nonce} /><script src="/appearance.js" /><HeadContent /></head><body data-page={page} className={page === '404' ? 'error-page' : 'page-with-loader'}><SiteShell>{children}</SiteShell><Scripts /></body></html>
}
