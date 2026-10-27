#!/usr/bin/env python3
"""Build the static WeGit website with local assets, locale routes and native themes."""
import argparse
import hashlib
from html import escape
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import shutil
import tempfile
import xml.etree.ElementTree as ET
from urllib.parse import urljoin, urlsplit

SITE = Path(__file__).resolve().parents[1]
ROOT = SITE.parent
ROLES = 'accent canvas chrome sidebar surface border text secondaryText positive negative modified diffAdded diffRemoved keyword string number comment'.split()
ICON_NAMES = {node.get('id') for node in ET.parse(SITE / 'public/assets/icons/culture.svg').iter() if node.get('id')}
MODULE_IMPORTS = re.compile(r"""((?:\bfrom\s+|\bimport\s*(?:\(\s*)?)['"])(\.\.?/[^'"]+)(['"])""")


def luminance(color):
    channels = [int(color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    channels = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in channels]
    return sum(a * b for a, b in zip(channels, (.2126, .7152, .0722)))


def validate_theme(theme):
    if set(theme) != {'version', 'name', 'controls', 'colors'} or theme['version'] != 1:
        raise ValueError('Unsupported native theme document')
    if theme['controls'] not in ('light', 'dark') or not 1 <= len(theme['name'].strip()) <= 60:
        raise ValueError('Invalid theme name or controls')
    colors = theme['colors']
    if set(colors) != set(ROLES) or not all(re.fullmatch(r'#[0-9A-F]{6}', v) for v in colors.values()):
        raise ValueError('Theme must contain exactly 17 RGB roles')
    pairs = [(fg, bg) for bg in ('canvas', 'chrome', 'sidebar', 'surface', 'diffAdded', 'diffRemoved') for fg in ('text', 'secondaryText')]
    pairs += [(fg, bg) for bg in ('canvas', 'surface', 'diffAdded', 'diffRemoved') for fg in ('keyword', 'string', 'number', 'comment')]
    pairs += [(fg, bg) for bg in ('canvas', 'chrome', 'surface') for fg in ('positive', 'negative', 'modified')]
    for foreground, background in pairs:
        a, b = sorted((luminance(colors[foreground]), luminance(colors[background])))
        if (b + .05) / (a + .05) < 4.5:
            raise ValueError(f'{theme["name"]}: {foreground}/{background} contrast below 4.5:1')


def read_json(path):
    return json.loads(path.read_text())


def version_module_imports(output):
    scripts = sorted(path for path in (output / 'assets/js').iterdir() if path.suffix in ('.js', '.mjs'))
    digest = hashlib.sha256()
    for path in scripts:
        digest.update(path.name.encode() + b'\0' + path.read_bytes() + b'\0')
    version = digest.hexdigest()[:12]
    # A dependency-only edit must also invalidate every importer, including lazy imports.
    for path in scripts:
        source = MODULE_IMPORTS.sub(lambda match: f'{match[1]}{match[2]}?v={version}{match[3]}', path.read_text())
        path.write_text(source)


def route(base, lang, page='home'):
    return base + ('/zh/' if lang == 'zh' else '/') + ('themes/' if page == 'themes' else '')


def translate_html(source, words):
    pattern = re.compile(r'(<(?P<tag>[a-z][\w-]*)\b[^>]*\bdata-i18n(?P<html>-html)?="(?P<key>[^"]+)"[^>]*>)(.*?)(</(?P=tag)>)', re.S)
    def replace(match):
        value = words.get(match['key'])
        if value is None:
            raise ValueError('Missing translation: ' + match['key'])
        text = escape(value)
        if match['html']:
            text = re.sub(r'&lt;br\s*/?&gt;', '<br>', text)
        return match[1] + text + match[6]
    return pattern.sub(replace, source)


class Document(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.links = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if values.get('id'):
            if values['id'] in self.ids:
                raise ValueError('Duplicate element id: ' + values['id'])
            self.ids.add(values['id'])
        for key in ('src', 'href'):
            if values.get(key):
                self.links.append(values[key])


def verify_links(output, base):
    pages = {}
    for path in output.rglob('*.html'):
        document = Document()
        document.feed(path.read_text())
        pages[path] = document
    for page, document in pages.items():
        for link in document.links:
            url = urlsplit(link)
            if url.scheme:
                if url.scheme != 'https':
                    raise ValueError('Unexpected remote link: ' + link)
                continue
            if not url.path:
                if url.fragment and url.fragment not in document.ids:
                    raise ValueError('Missing fragment: ' + link)
                continue
            if base and not url.path.startswith(base + '/'):
                raise ValueError('Link escapes project path: ' + link)
            target = output / url.path.removeprefix(base).lstrip('/')
            if target.is_dir():
                target /= 'index.html'
            if not target.is_file():
                raise ValueError('Missing page or asset: ' + link)
            if url.fragment and target.suffix == '.html' and url.fragment not in pages[target].ids:
                raise ValueError('Missing destination fragment: ' + link)
    for css in output.rglob('*.css'):
        for target in re.findall(r'url\([\'"]?([^\)\'\"]+)', css.read_text()):
            if urlsplit(target).scheme:
                raise ValueError('CSS cannot depend on a runtime CDN')
            if not (css.parent / target).resolve().is_file():
                raise ValueError('Missing CSS asset: ' + target)
    for script in (output / 'assets/js').iterdir():
        for match in MODULE_IMPORTS.finditer(script.read_text()):
            target = match[2]
            if not (script.parent / urlsplit(target).path).resolve().is_file():
                raise ValueError('Missing module: ' + target)


def write_site(output, base, releases):
    shutil.copytree(SITE / 'public', output, dirs_exist_ok=True)
    (output / 'assets/css').mkdir(parents=True)
    (output / 'assets/js').mkdir(parents=True)
    for path in (SITE / 'src/styles').glob('*.css'):
        shutil.copy2(path, output / 'assets/css' / path.name)
    for path in (SITE / 'src/scripts').iterdir():
        shutil.copy2(path, output / 'assets/js' / path.name)
    brand = read_json(SITE / 'data/brand-assets.json')
    (output / 'assets/brand').mkdir()
    for name, source in brand.items():
        path = (ROOT / source).resolve()
        if not path.is_relative_to((ROOT / 'design/brand').resolve()):
            raise ValueError('Brand input must come from design/brand')
        shutil.copy2(path, output / 'assets/brand' / name)
    translations = read_json(SITE / 'data/translations.json')
    if translations['en'].keys() != translations['zh'].keys():
        raise ValueError('Translation keys do not match')
    (output / 'assets/js/translations.js').write_text('export const translations = ' + json.dumps(translations, ensure_ascii=False) + ';\n')
    catalog = read_json(SITE / 'data/themes.json')
    ids = [entry['id'] for entry in catalog]
    if len(set(ids)) != len(ids) or not all(re.fullmatch(r'[a-z][a-z0-9-]*', name) for name in ids):
        raise ValueError('Invalid theme identifiers')
    collection = []
    for entry in catalog:
        path = output / 'themes' / (entry['id'] + '.json')
        if path.stat().st_size > 65_536:
            raise ValueError('Theme is too large for the client')
        document = read_json(path)
        validate_theme(document)
        collection.append(dict(entry, document=document))
    if set(ids) != {p.stem for p in (output / 'themes').glob('*.json')}:
        raise ValueError('Theme catalog and downloadable files disagree')
    (output / 'assets/js/themes.js').write_text('export const collection = ' + json.dumps(collection, ensure_ascii=False) + ';\n')
    snapshot = [{'tag_name': item.get('tag_name'), 'draft': False, 'prerelease': item.get('prerelease'), 'assets': [{'name': asset.get('name'), 'browser_download_url': asset.get('browser_download_url')} for asset in item.get('assets', [])]} for item in releases if item.get('draft') is False]
    (output / 'releases.json').write_text(json.dumps(snapshot) + '\n')
    version_module_imports(output)
    asset_versions = {
        '/assets/' + path.relative_to(output / 'assets').as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()[:12]
        for folder in ('css', 'js')
        for path in (output / 'assets' / folder).iterdir()
        if path.is_file()
    }
    header = (SITE / 'src/partials/header.html').read_text()
    footer = (SITE / 'src/partials/footer.html').read_text()
    for lang in ('en', 'zh'):
        words = translations[lang]
        for page in ('home', 'themes', 'privacy', '404'):
            filename = {'themes': 'themes.html', '404': '404.html'}.get(page, 'index.html')
            source = (SITE / 'src/pages' / filename).read_text()
            source = source.replace('{{header}}', header).replace('{{footer}}', footer)
            active = ' class="active" aria-current="page"'
            source = source.replace('{{product_state}}', active if page == 'home' else '')
            source = source.replace('{{themes_state}}', active if page == 'themes' else '')
            if page == 'privacy':
                source = source.replace('data-page="home"', f'data-page="{page}"')
                chinese = lang == 'zh'
                title = ('隐私' if chinese else 'Privacy') if page == 'privacy' else '404'
                body = ('本站没有分析追踪、广告 Cookie 或主题上传服务。主题导入在浏览器本地完成；网站托管与下载由 GitHub 提供。' if chinese else 'No analytics, advertising cookies or theme upload service. Theme import stays in your browser. GitHub provides hosting and downloads.') if page == 'privacy' else ('页面不存在。' if chinese else 'This page does not exist.')
                main = f'<main id="main" tabindex="-1"><section class="section"><div class="wrap"><h1>{title}</h1><p>{body}</p><a href="{{{{home}}}}">WeGit</a></div></section></main>'
                source = re.sub(r'<main.*?</main>', lambda _: main, source, flags=re.S)
            source = translate_html(source, words)
            def render_icon(match):
                name = match[1]
                if name not in ICON_NAMES:
                    raise ValueError('Unknown cultural icon: ' + name)
                return f'<svg class="culture-icon icon-{name}" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><use href="{base}/assets/icons/culture.svg#{name}"></use></svg>'
            source = re.sub(r'\{\{icon:([a-z-]+)\}\}', render_icon, source)
            branch = (ROOT / 'design/brand/source/git-symbol.svg').read_text()
            branch = branch.replace('width="566" height="566"', 'width="50" height="50"')
            branch = branch.replace('role="img" aria-label="WeGit"', 'aria-hidden="true" focusable="false"')
            source = source.replace('{{branch_mark}}', branch)
            source = re.sub(r'<html lang="[^"]+"', '<html lang="' + ('zh-CN' if lang == 'zh' else 'en') + '"', source)
            title = ('WeGit — 主题中心' if lang == 'zh' else 'WeGit — Theme Studio') if page == 'themes' else ('WeGit — 原生 macOS Git 客户端' if lang == 'zh' else 'WeGit — Native macOS Git Client')
            if page in ('privacy', '404'):
                title = ('隐私' if page == 'privacy' and lang == 'zh' else page.title()) + ' — WeGit'
            source = re.sub(r'<title>.*?</title>', lambda _: '<title>' + title + '</title>', source)
            description = re.sub(r'<[^>]+>', ' ', words['themes.previewDesc'] if page == 'themes' else words['home.heroText']).strip()
            if page == 'privacy':
                description = body
            elif page == '404':
                description = words['error.meta']
            source = re.sub(r'<meta name="description" content="[^"]*"\s*/?>', lambda _: '<meta name="description" content="' + escape(description, quote=True) + '">', source, count=1)
            home = route(base, lang)
            if page in ('privacy', '404'):
                source = source.replace('href="#download"', f'href="{home}#download"').replace('href="#features"', f'href="{home}#features"')
            canonical = 'https://weopen.github.io' + (home + ('themes/' if page == 'themes' else page + '/' if page == 'privacy' else '404.html' if page == '404' else ''))
            csp = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'"
            suffix = {'home': '', 'themes': 'themes/', 'privacy': 'privacy/', '404': '404.html'}[page]
            alternates = f'<link rel="alternate" hreflang="en" href="https://weopen.github.io{base}/{suffix}"><link rel="alternate" hreflang="zh-Hans" href="https://weopen.github.io{base}/zh/{suffix}">'
            metadata = f'<meta http-equiv="Content-Security-Policy" content="{csp}"><link rel="canonical" href="{canonical}">{alternates}<meta property="og:title" content="{escape(title)}"><meta property="og:description" content="{escape(description, quote=True)}"><meta property="og:url" content="{canonical}"><meta property="og:image" content="https://weopen.github.io{base}/assets/brand/social-preview.png"><meta name="twitter:card" content="summary_large_image">'
            # CSP must precede resource requests. Appearance bootstrap precedes CSS.
            source = source.replace('{{metadata}}', '')
            source = source.replace('<head>', '<head>' + metadata + f'<script src="{base}/assets/js/boot.js"></script>', 1)
            source = source.replace('<link rel="preload" as="image" href="{{base}}/assets/illustrations/landscape-hero.webp"/>', '')
            source = re.sub(r'href="\{\{home\}\}(#[^"]+)?"', lambda match: 'data-route="home"' + (f' data-section="{match[1][1:]}"' if match[1] else '') + f' href="{home}{match[1] or ""}"', source)
            source = source.replace('href="{{themes}}"', f'data-route="themes" href="{route(base, lang, "themes")}"')
            source = source.replace('href="{{base}}/privacy/"', f'data-route="privacy" href="{home}privacy/"')
            source = source.replace('{{base}}', base).replace('{{home}}', home)
            # New HTML must not reuse a cached stylesheet or entry script from an older build.
            source = re.sub(
                r'((?:src|href)=")' + re.escape(base) + r'(/assets/(?:css|js)/[^"?]+)"',
                lambda match: f'{match[1]}{base}{match[2]}?v={asset_versions[match[2]]}"',
                source,
            )
            # Add static native-theme downloads and original release access for no-script users.
            fallback = '<noscript><div class="wrap"><a href="https://github.com/WeOpen/WeGit/releases">GitHub Releases</a> ' + ' '.join(f'<a href="{base}/themes/{entry["id"]}.json" download>{escape(entry["name"][lang])}</a>' for entry in catalog) + '</div></noscript>'
            if page != '404':
                source = source.replace('</main>', fallback + '</main>')
            source = source.replace('>EN</button>', ('>EN</button>' if lang == 'zh' else '>中文</button>'))
            relative = ('zh/' if lang == 'zh' else '') + ('' if page == 'home' else page + '/' if page != '404' else '404.html')
            path = output / relative
            if page != '404':
                path /= 'index.html'
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source)
            if page == 'themes':
                (output / ('zh/' if lang == 'zh' else '') / 'themes.html').write_text(source)
    verify_links(output, base)
    budgets = {'assets/css/main.css': 65_536, 'assets/css/components.css': 25_000, 'assets/js/app.js': 25_000, 'assets/js/theme-model.js': 10_000}
    budgets.update({'assets/css/error.css': 20_000, 'assets/illustrations/error404/hero-light.webp': 450_000, 'assets/illustrations/error404/hero-dark.webp': 450_000, 'assets/illustrations/error404/footer-light.webp': 300_000, 'assets/illustrations/error404/footer-dark.webp': 300_000})
    for name, limit in budgets.items():
        if (output / name).stat().st_size > limit:
            raise ValueError('Asset budget exceeded: ' + name)
    total = sum(path.stat().st_size for path in output.rglob('*') if path.is_file())
    if total > 3_000_000:
        raise ValueError('Static distribution exceeds 3 MB budget (including 404 art variants)')
    (output / '.nojekyll').write_text('')
    (output / '.wegit-site-build').write_text('WeGit static website\n')
    return len(collection), total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / '.build/website')
    parser.add_argument('--base-path', default='/WeGit')
    parser.add_argument('--releases-json', type=Path)
    args = parser.parse_args()
    base = args.base_path.rstrip('/')
    if base and not re.fullmatch(r'(?:/[A-Za-z0-9_-]+)+', base):
        raise SystemExit('Invalid project base path')
    output = args.output.resolve()
    if ROOT.is_relative_to(output) or output.is_relative_to(SITE):
        raise SystemExit('Output must not overwrite source directories')
    marker = output / '.wegit-site-build'
    owned = marker.is_file() and not marker.is_symlink() and marker.read_bytes() == b'WeGit static website\n'
    if output.exists() and any(output.iterdir()) and not owned:
        raise SystemExit('Refusing to replace a directory not generated by the website builder')
    releases = read_json(args.releases_json) if args.releases_json else []
    if not isinstance(releases, list):
        raise SystemExit('Expected a release JSON array')
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='wegit-website-', dir=output.parent))
    try:
        count, total = write_site(staging, base, releases)
        previous = None
        if output.exists():
            previous = Path(tempfile.mkdtemp(prefix='wegit-website-old-', dir=output.parent))
            previous.rmdir()
            output.rename(previous)
        try:
            staging.rename(output)
        except OSError:
            if previous:
                previous.rename(output)
            raise
        if previous:
            shutil.rmtree(previous)
        print(f'Website built: bilingual routes, {count} native themes, canonical brand assets, local links; {total:,} bytes at {output}')
    finally:
        if staging.exists():
            shutil.rmtree(staging)


if __name__ == '__main__':
    main()
