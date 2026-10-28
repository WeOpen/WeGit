import { createContext, Fragment, memo, useCallback, useContext, useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from 'react'
import { flushSync } from 'react-dom'
import { createThemeTransition } from '../lib/theme-transition'
import { Link, useLocation, useNavigate } from '@tanstack/react-router'
import { localeFromPath, pageFromPath, route, translate, type Locale, type Mode } from '../lib/site'
import { selectRelease } from '../scripts/release.mjs'
import { workbenchHTML } from '../scripts/workbench.js'
import { previewProperties } from '../scripts/theme-model.js'
import { catalog, type ThemeDocument, type ThemeDraft } from '../lib/catalog'
import build from '../../.generated/build-meta.json'
import { topNavigationItem } from '../lib/navigation.mjs'

type SiteState = {
  locale: Locale; mode: Mode; tr: (key: string) => string; toggleMode: () => void
  notice: string; notify: (message: string) => void; overlay: boolean; setOverlay: (value: boolean) => void
  download: string; switchLanguage: () => void
  themeDraft: { current: ThemeDraft | null }
}
const SiteContext = createContext<SiteState | null>(null)
export function useSite() {
  const state = useContext(SiteContext)
  if (!state) throw new Error('Missing site provider')
  return state
}
const RELEASES = 'https://github.com/WeOpen/WeGit/releases'
function save(key: string, value: string) { try { localStorage.setItem(key, value) } catch { /* Storage is optional. */ } }
type SiteTo = '/' | '/zh/' | '/themes/' | '/zh/themes/' | '/privacy/' | '/zh/privacy/'
function knownRoute(path: string): SiteTo | null {
  const clean = path.replace(/\/$/, '') || '/'
  const paths: Record<string, SiteTo> = { '/': '/', '/zh': '/zh/', '/themes': '/themes/', '/zh/themes': '/zh/themes/', '/privacy': '/privacy/', '/zh/privacy': '/zh/privacy/' }
  return paths[clean] ?? null
}
export function SiteLink({ href, children, className, onClick, active, ...props }: { href: string; children: ReactNode; className?: string; onClick?: () => void; active?: boolean; 'aria-label'?: string; 'aria-current'?: 'page' }) {
  const [fullPath, hash] = href.split('#')
  const [path, query] = fullPath.split('?')
  const theme = new URLSearchParams(query).get('theme') ?? undefined
  const current = useLocation({ select: location => location.pathname })
  const to = knownRoute(path || current)
  const linkClass = [className, active ? 'active' : ''].filter(Boolean).join(' ') || undefined
  return to ? <Link to={to} hash={hash} search={theme ? { theme } : {}} activeOptions={{ exact: true, includeHash: true }} activeProps={active === undefined ? undefined : {}} className={linkClass} onClick={onClick} {...props}>{children}</Link> :
    <a href={href} className={className} onClick={onClick} {...props}>{children}</a>
}
export function Icon({ name }: { name: string }) {
  return <svg className={'culture-icon icon-' + name} viewBox="0 0 24 24" aria-hidden="true" focusable="false"><use href={'/assets/icons/culture.svg#' + name} /></svg>
}
export function TextBlock({ value }: { value: string }) {
  return value.split(/<br\s*\/?\s*>/i).map((text, i) => <Fragment key={i}>{i > 0 && <br />}{text}</Fragment>)
}
export function DownloadLink({ children, className }: { children: ReactNode; className?: string }) {
  const { download } = useSite()
  return <a href={download} className={className} data-action="app-download">{children}</a>
}
export function NativeImage() {
  const { mode, tr } = useSite()
  return <picture><source media={mode === 'dark' ? 'all' : 'not all'} srcSet="/assets/screenshots/wegit-dark.webp" /><img className="native-wegit-image" src="/assets/screenshots/wegit-light.webp" width="1920" height="1213" alt={tr('workbench.description')} fetchPriority="high" /></picture>
}
export const Workbench = memo(function Workbench({ theme, compact = false, font = 'system', fontSize = 13 }: { theme: ThemeDocument; compact?: boolean; font?: string; fontSize?: number }) {
  const { tr } = useSite()
  const markup = useMemo(() => ({ __html: workbenchHTML(tr, (path: string) => '/assets/' + path, { compact }) }), [tr, compact])
  const style = { ...previewProperties(theme), '--mock-font-size': fontSize + 'px' } as CSSProperties
  return <div className={'mock-host ' + (compact ? 'tiny-app' : 'modal-workbench')} aria-hidden={compact || undefined} data-preview-theme={theme.controls} data-app-font={font} style={style} dangerouslySetInnerHTML={markup} />
})
export function HomeThemeTeasers() {
  const { locale } = useSite()
  return <div className="theme-mini-grid" id="home-themes">{catalog.slice(0, 4).map(theme => <SiteLink key={theme.id} className="theme-mini-item" href={route(locale, 'themes') + '?theme=' + theme.id}><Workbench theme={theme.document} compact /><h3>{theme.name[locale]}</h3><p>{theme.name.en}</p></SiteLink>)}</div>
}
export function IconSizes() {
  const { mode, locale } = useSite()
  return <div className="icon-sizes" id="icon-sizes">{[[120, 512], [83, 256], [64, 128], [48, 64], [35, 32], [24, 16]].map(([display, pixels]) => <div className="icon-size-item" key={pixels} style={{ '--icon-size': display + 'px' } as CSSProperties}><img src={'/assets/brand/icon-' + mode + '-' + pixels + '.png'} width={pixels} height={pixels} alt={'WeGit ' + pixels + ' × ' + pixels} loading="lazy" /><small>{pixels} × {pixels}</small><small>{locale === 'zh' ? '应用图标' : 'App icon'}</small></div>)}</div>
}
export function Toast() {
  const { notice } = useSite()
  return <div className={'toast ' + (notice ? 'shown' : '')} id="toast" role="status" aria-live="polite">{notice}</div>
}
function Brand({ footer = false }: { footer?: boolean }) {
  const { locale } = useSite()
  return <SiteLink href={route(locale)} className={'brand' + (footer ? ' brand-footer' : '')} aria-label="WeGit"><img className="brand-logo brand-light" src="/assets/brand/logo-light.webp" width="480" height="160" alt="WeGit" /><img className="brand-logo brand-dark" src="/assets/brand/logo-dark.webp" width="480" height="160" alt="WeGit" /></SiteLink>
}
function Header() {
  const { locale, tr, mode, toggleMode, switchLanguage } = useSite()
  const pathname = useLocation({ select: location => location.pathname })
  const hash = useLocation({ select: location => location.hash })
  const currentItem = topNavigationItem(pathname, hash)
  const [menu, setMenu] = useState(false)
  const toggle = useRef<HTMLButtonElement>(null)
  useEffect(() => {
    const escape = (event: KeyboardEvent) => { if (event.key === 'Escape' && menu) { setMenu(false); toggle.current?.focus() } }
    const media = matchMedia('(min-width: 861px)')
    const changed = () => { if (media.matches) setMenu(false) }
    document.addEventListener('keydown', escape); media.addEventListener('change', changed)
    return () => { document.removeEventListener('keydown', escape); media.removeEventListener('change', changed) }
  }, [menu])
  return <header className="site-header" id="top"><div className="wrap header-inner"><Brand /><nav className={'main-nav' + (menu ? ' open' : '')} id="main-nav" aria-label="Primary navigation">
    <SiteLink href={route(locale)} active={currentItem === 'product'} aria-current={currentItem === 'product' ? 'page' : undefined} onClick={() => setMenu(false)}>{tr('nav.product')}</SiteLink>
    <SiteLink href={route(locale) + '#features'} active={currentItem === 'features'} aria-current={currentItem === 'features' ? 'page' : undefined} onClick={() => setMenu(false)}>{tr('nav.features')}</SiteLink>
    <SiteLink href={route(locale, 'themes')} active={currentItem === 'themes'} aria-current={currentItem === 'themes' ? 'page' : undefined} onClick={() => setMenu(false)}>{tr('nav.themes')}</SiteLink>
    <a href="https://github.com/WeOpen/WeGit" className="nav-source">GitHub</a></nav><div className="nav-actions">
    <button className="icon-button mode-toggle" data-action="toggle-mode" aria-label={tr(mode === 'dark' ? 'a11y.toLight' : 'a11y.toDark')} title={tr(mode === 'dark' ? 'a11y.toLight' : 'a11y.toDark')} aria-pressed={mode === 'dark'} onClick={toggleMode}><span className="mode-symbol"><Icon name="taiji" /></span></button>
    <button className="lang-toggle" aria-label="Change language" onClick={switchLanguage}>{locale === 'zh' ? 'EN' : '中文'}</button>
    <DownloadLink className="button button-red small header-download"><Icon name="download" /> {tr('nav.download')}</DownloadLink>
    <button className="icon-button menu-toggle" data-action="toggle-menu" aria-controls="main-nav" aria-expanded={menu} aria-label={tr(menu ? 'a11y.closeMenu' : 'a11y.openMenu')} ref={toggle} onClick={() => setMenu(!menu)}><span className="menu-symbol"><Icon name={menu ? 'close' : 'fan'} /></span></button>
  </div></div></header>
}
function Footer() {
  const { locale, tr } = useSite()
  const [year, setYear] = useState(build.year)
  useEffect(() => setYear(new Date().getFullYear()), [])
  const panel = useRef<HTMLDivElement>(null)
  useEffect(() => {
    let cancelled = false, dispose: (() => void) | undefined
    void import('../scripts/footer-effect.js').then(({ initParticleFooter }) => { if (!cancelled && panel.current) dispose = initParticleFooter(panel.current) }).catch(() => {})
    return () => { cancelled = true; dispose?.() }
  }, [])
  return <><footer className="site-footer"><div className="wrap footer-inner"><Brand footer /><span className="copyright">© <span id="year">{year}</span> WeGit. {tr('footer.motto')}</span><nav aria-label="Footer navigation"><SiteLink href={route(locale)}>{tr('nav.product')}</SiteLink><SiteLink href={route(locale) + '#features'}>{tr('nav.features')}</SiteLink><SiteLink href={route(locale, 'themes')}>{tr('nav.themes')}</SiteLink><SiteLink href={route(locale) + '#download'}>{tr('nav.download')}</SiteLink></nav></div></footer>
    <div ref={panel} id="footer-logo" className="footer-logo-panel" aria-hidden="true"><div className="wrap footer-wordmark" data-footer-particles data-footer-pixels="wordmark"><canvas /><p className="footer-word-fallback">WeGit</p></div></div></>
}
export function SiteShell({ children }: { children: ReactNode }) {
  const pathname = useLocation({ select: location => location.pathname })
  const locale = localeFromPath(pathname), page = pageFromPath(pathname)
  const navigate = useNavigate()
  const [mode, setMode] = useState<Mode>('light')
  const desiredMode = useRef<Mode | null>(null)
  const transition = useRef<ReturnType<typeof createThemeTransition> | null>(null)
  useEffect(() => {
    transition.current = createThemeTransition()
    return () => { transition.current?.dispose(); transition.current = null }
  }, [])
  useEffect(() => { document.dispatchEvent(new Event('wegit-route-change')) }, [pathname])
  const [notice, notify] = useState('')
  const [overlay, setOverlay] = useState(false)
  const [download, setDownload] = useState(RELEASES)
  const themeDraft = useRef<ThemeDraft | null>(null)
  const tr = useCallback((key: string) => translate(locale, key), [locale])
  useEffect(() => {
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) return
    let cancelled = false, dispose: (() => void) | undefined
    void import('../lib/page-motion').then(({ initPageMotion }) => {
      const root = document.querySelector<HTMLElement>('#main')
      if (!cancelled && root) dispose = initPageMotion(root)
    }).catch(() => {})
    return () => { cancelled = true; dispose?.() }
  }, [pathname])
  useEffect(() => {
    const actual = document.documentElement.dataset.siteMode === 'dark' ? 'dark' : 'light'
    setMode(actual)
    document.documentElement.lang = locale === 'zh' ? 'zh-CN' : 'en'
    document.body.dataset.page = page
  }, [locale, page])
  useEffect(() => {
    const controller = new AbortController()
    void fetch('/releases.json', { signal: controller.signal }).then(response => response.ok ? response.json() : []).then(value => { const release = selectRelease(value); setDownload(release?.download || release?.notes || RELEASES) }).catch(() => {})
    return () => controller.abort()
  }, [])
  useEffect(() => { if (!notice) return; const timer = setTimeout(() => notify(''), 4200); return () => clearTimeout(timer) }, [notice])
  useEffect(() => { document.querySelector('meta[name="theme-color"]')?.setAttribute('content', mode === 'dark' ? '#151719' : '#faf8f3') }, [mode])
  const toggleMode = () => {
    const next = (desiredMode.current ?? document.documentElement.dataset.siteMode) === 'light' ? 'dark' : 'light'
    desiredMode.current = next
    const update = () => { flushSync(() => { document.documentElement.dataset.siteMode = next; setMode(next) }); save('wegit-site-mode', next) }
    if (transition.current) transition.current.run(update)
    else update()
  }
  const switchLanguage = () => {
    const other = locale === 'zh' ? 'en' : 'zh'
    if (page === '404') { location.assign(route(other, '404')); return }
    const to = knownRoute(route(other, page))
    if (to) void navigate({ to, search: previous => previous, hash: window.location.hash.slice(1) })
  }
  return <SiteContext.Provider value={{ locale, mode, tr, toggleMode, notice, notify, overlay, setOverlay, download, switchLanguage, themeDraft }}><a className="skip-link" href="#main">{tr('a11y.skip')}</a><Header />{children}<Footer />{!overlay && <Toast />}</SiteContext.Provider>
}
