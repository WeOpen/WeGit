import words from '../../data/translations.json'

export type Locale = 'en' | 'zh'
export type Mode = 'light' | 'dark'
export type Page = 'home' | 'themes' | 'privacy' | '404'
export function localeFromPath(path: string): Locale { return /^\/zh(?:\/|$)/.test(path) ? 'zh' : 'en' }
export function pageFromPath(path: string): Page {
  const clean = path.replace(/^\/zh/, '').replace(/\/$/, '') || '/'
  return clean === '/' ? 'home' : clean === '/themes' ? 'themes' : clean === '/privacy' ? 'privacy' : '404'
}
export function translate(locale: Locale, key: string): string { return (words[locale] as Record<string, string>)[key] ?? key }
export function route(locale: Locale, page: Page = 'home'): string {
  return (locale === 'zh' ? '/zh/' : '/') + ({ home: '', themes: 'themes/', privacy: 'privacy/', '404': '404.html' })[page]
}
export function pageHead(locale: Locale, page: Page) {
  const tr = (key: string) => translate(locale, key)
  const title = page === 'home' ? (locale === 'zh' ? 'WeGit — 原生 macOS Git 客户端' : 'WeGit — Native macOS Git Client') :
    page === 'themes' ? (locale === 'zh' ? 'WeGit — 主题中心' : 'WeGit — Theme Studio') : page === 'privacy' ? (locale === 'zh' ? '隐私 — WeGit' : 'Privacy — WeGit') : '404 — WeGit'
  const description = (page === 'themes' ? tr('themes.previewDesc') : page === '404' ? tr('error.meta') : page === 'privacy' ?
    (locale === 'zh' ? '主题导入在本地浏览器完成，本站没有广告 Cookie、主题上传或分析追踪。' : 'Theme import stays in your browser. No advertising cookies, theme uploads or analytics.') : tr('home.heroText')).replace(/<[^>]+>/g, ' ')
  const origin = (import.meta.env.VITE_SITE_ORIGIN ?? '').replace(/\/$/, '')
  return {
    meta: [{ title }, { name: 'description', content: description }, { property: 'og:title', content: title }, { property: 'og:description', content: description }, { property: 'og:image', content: origin + '/assets/brand/social-preview.png' }, { name: 'twitter:card', content: 'summary_large_image' }],
    links: [{ rel: 'canonical', href: origin + route(locale, page) }, ...(['en', 'zh'] as const).map(lang => ({ rel: 'alternate', hrefLang: lang === 'zh' ? 'zh-Hans' : 'en', href: origin + route(lang, page) }))],
  }
}
