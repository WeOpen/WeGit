import { useSite, Icon, TextBlock, DownloadLink, NativeImage, SiteLink, HomeThemeTeasers, IconSizes, Workbench } from '../components/Site'
import { route } from '../lib/site'
import { catalog } from '../lib/catalog'

export function ErrorContent({ setSearchOpen }: { setSearchOpen: (open: boolean) => void }) {
  const { tr, locale, mode } = useSite()
  return (<main id="main" tabIndex={-1}>
<section className="error-hero" aria-labelledby="error-title">
<picture className="error-hero-art"><source srcSet="/assets/illustrations/error404/hero-dark.webp" media={mode === 'dark' ? 'all' : 'not all'} /><img src="/assets/illustrations/error404/hero-light.webp" width="1468" height="1071" alt="" fetchPriority="high" /></picture>
<p className="error-code">{"ERROR 404"}</p>
<img className="error-seal" src="/assets/brand/seal-red.svg" width="120" height="120" alt="" aria-hidden="true" />
<div className="error-message"><h1 id="error-title">{tr("error.title")}</h1><p className="error-description"><TextBlock value={tr("error.description")} /></p><div className="error-actions"><SiteLink className="button error-home" href={route(locale) + ""}><Icon name="home" /><span>{tr("error.home")}</span><Icon name="chevron-right" /></SiteLink><SiteLink className="button error-themes" href={route(locale, 'themes')}><Icon name="themes" /><span>{tr("error.themes")}</span><Icon name="chevron-right" /></SiteLink></div><div className="error-recovery"><button className="error-reload" data-action="reload-page" onClick={() => location.reload()}><Icon name="reset" /><span>{tr("error.reload")}</span></button><button className="icon-button error-search-toggle" data-action="open-search" aria-label={tr('error.searchLabel')} onClick={() => setSearchOpen(true)}><Icon name="search" /></button></div></div>
</section>
<div className="error-bottom">
<picture className="error-footer-art"><source srcSet="/assets/illustrations/error404/footer-dark.webp" media={mode === 'dark' ? 'all' : 'not all'} /><img src="/assets/illustrations/error404/footer-light.webp" width="2172" height="724" alt="" decoding="async" fetchPriority="low" /></picture>
<section className="error-suggestions" aria-labelledby="error-suggestions-title"><div className="error-wrap"><h2 id="error-suggestions-title" className="error-section-title">{tr("error.moreTitle")}</h2><p className="error-more-description">{tr("error.moreDescription")}</p><div className="error-card-grid">
<SiteLink className="error-card" href={route(locale) + "#features"}><span className="error-card-icon"><Icon name="branch" /></span><h3>{tr("error.aboutTitle")}</h3><p><TextBlock value={tr("error.aboutBody")} /></p><span className="error-card-arrow"><Icon name="chevron-right" /></span></SiteLink>
<SiteLink className="error-card" href={route(locale, 'themes')}><span className="error-card-icon"><Icon name="themes" /></span><h3>{tr("error.themeTitle")}</h3><p><TextBlock value={tr("error.themeBody")} /></p><span className="error-card-arrow"><Icon name="chevron-right" /></span></SiteLink>
<SiteLink className="error-card" href={"https://github.com/WeOpen/WeGit/blob/main/docs/README.md"}><span className="error-card-icon"><Icon name="docs" /></span><h3>{tr("error.docsTitle")}</h3><p><TextBlock value={tr("error.docsBody")} /></p><span className="error-card-arrow"><Icon name="chevron-right" /></span></SiteLink>
<DownloadLink className="error-card"><span className="error-card-icon"><Icon name="download" /></span><h3>{tr("error.downloadTitle")}</h3><p><TextBlock value={tr("error.downloadBody")} /></p><span className="error-card-arrow"><Icon name="chevron-right" /></span></DownloadLink>
</div></div></section>
<section className="error-brand-scene" aria-label="WeGit"><div className="error-brand-content"><div className="error-brand-lockup"><img className="brand-light" src="/assets/brand/logo-light.webp" width="480" height="160" alt="WeGit" /><img className="brand-dark" src="/assets/brand/logo-dark.webp" width="480" height="160" alt="WeGit" /><p>{tr("error.brandWords")}</p><small>{"MACOS NATIVE GIT CLIENT"}</small></div><div className="error-brand-rule"></div><div className="error-brand-copy"><h3><TextBlock value={tr("error.brandTitle")} /></h3><p>{tr("error.brandBody")}</p></div></div></section>
</div>
</main>)
}
