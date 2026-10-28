import { SiteLink, useSite } from '../components/Site'
import { route } from '../lib/site'
export function PrivacyPage() {
  const { locale } = useSite()
  return <main id="main" tabIndex={-1}><section className="section"><div className="wrap"><h1>{locale === 'zh' ? '隐私' : 'Privacy'}</h1><p>{locale === 'zh' ? '本站没有分析追踪、广告 Cookie 或主题上传服务。主题导入在浏览器本地完成。网站由 Cloudflare Workers 托管，客户端下载来自 GitHub Releases。' : 'No analytics, advertising cookies or theme upload service. Theme import stays in your browser. Cloudflare Workers hosts the website; client downloads come from GitHub Releases.'}</p><SiteLink href={route(locale)}>WeGit</SiteLink></div></section></main>
}
