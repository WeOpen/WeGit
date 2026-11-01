import { useSite, Icon, TextBlock, DownloadLink, NativeImage, SiteLink, HomeThemeTeasers, IconSizes, Workbench } from '../components/Site'
import { route } from '../lib/site'
import { catalog } from '../lib/catalog'

export function HomePage() {
  const { tr, locale, mode } = useSite()
  return (<main id="main" tabIndex={-1}>
<section className="hero hero-home ink-back">
<div className="wrap hero-grid">
<div className="hero-copy">
<p className="eyebrow hero-eyebrow">{tr("home.eyebrow")}</p>
<h1><TextBlock value={tr("home.heroTitle")} /></h1>
<p className="lead"><TextBlock value={tr("home.heroText")} /></p>
<div className="button-row"><DownloadLink className="button button-red"><Icon name="download" /><span>{tr("btn.downloadApp")}</span><Icon name="arrow" /></DownloadLink><SiteLink href={"#features"} className="button button-white"><span>{tr("btn.viewFeatures")}</span><Icon name="arrow" /></SiteLink></div>
<p className="microcopy">{tr("home.compat")}</p>
</div>
<div className="hero-visual"><div className="laptop laptop-hero"><div className="laptop-screen"><NativeImage /></div><div className="laptop-base"></div></div></div>
<img className="floating-seal" src="/assets/brand/seal-red.svg" width="120" height="120" alt="" aria-hidden="true" />
</div>
</section>
<section className="section features-section" id="features">
<div className="wrap"><div className="section-heading"><h2>{tr("home.featureTitle")}</h2><p>{tr("home.featureSubtitle")}</p></div>
<div className="feature-grid">
<article className="feature-card"><div className="feature-icon"><Icon name="window" /></div><h3>{tr("features.nativeTitle")}</h3><p>{tr("features.nativeText")}</p></article>
<article className="feature-card"><div className="feature-icon"><Icon name="history" /></div><h3>{tr("features.graphTitle")}</h3><p>{tr("features.graphText")}</p></article>
<article className="feature-card"><div className="feature-icon"><Icon name="branch" /></div><h3>{tr("features.branchTitle")}</h3><p>{tr("features.branchText")}</p></article>
<article className="feature-card"><div className="feature-icon"><Icon name="cloud" /></div><h3>{tr("features.flowTitle")}</h3><p>{tr("features.flowText")}</p></article>
</div></div>
</section>
<section className="section theme-showcase ink-back" id="themes">
<div className="wrap"><div className="section-heading"><h2>{tr("home.themeTitle")}</h2><p>{tr("home.themeSubtitle")}</p></div><HomeThemeTeasers /><div className="center-actions"><SiteLink href={route(locale, 'themes')} className="button button-outline"><span>{tr("btn.moreThemes")}</span><Icon name="arrow" /></SiteLink></div></div>
</section>
<section className="section brand-concept ink-soft">
<div className="wrap brand-concept-grid"><div><div className="eyebrow red-label">{"BRAND CONCEPT"}</div><h2><TextBlock value={tr("home.brandTitle")} /></h2><p>{tr("home.brandText")}</p></div><div className="brand-concept-mark"><img src="/assets/brand/symbol.png" alt="WeGit mark" /></div><div className="brand-quote"><h3><TextBlock value={tr("home.brandQuote")} /></h3><p><TextBlock value={tr("home.brandQuoteText")} /></p><img className="large-stamp" src="/assets/brand/seal-red.svg" width="120" height="120" alt="" aria-hidden="true" /></div></div>
</section>
<section className="section icon-display">
<div className="wrap"><div className="icon-heading"><h2>{tr("home.iconsTitle")}</h2><p>{tr("home.iconsDesc")}</p></div><IconSizes /></div>
</section>
<section className="final-cta ink-back" id="download"><div className="wrap final-cta-inner"><h2>{tr("home.ctaTitle")}</h2><p>{tr("home.ctaText")}</p><DownloadLink className="button button-red"><Icon name="download" /><span>{tr("btn.downloadApp")}</span><Icon name="arrow" /></DownloadLink><p className="microcopy">{"macOS 27+ · Apple silicon · Git 2.46+"}</p></div></section>
</main>)
}
