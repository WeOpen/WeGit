"""Static publication, canonical-brand and desktop-theme compatibility contracts."""
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / 'site'
spec = importlib.util.spec_from_file_location('wegit_website_build', SITE / 'scripts/build.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class WebsiteBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='wegit-website-test-')
        cls.outputs = []
        for index, base in enumerate(('', '/WeGit', '/nested/WeGit')):
            output = Path(cls.temporary.name) / str(index)
            subprocess.run([sys.executable, str(ROOT / 'scripts/build_website.py'), '--base-path', base, '--output', str(output)], check=True, capture_output=True)
            cls.outputs.append((base, output))

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_both_locales_and_legacy_theme_routes_exist(self):
        for base, output in self.outputs:
            for prefix, language in (('', 'en'), ('zh/', 'zh-CN')):
                html = (output / prefix / 'themes/index.html').read_text()
                self.assertIn(f'<html lang="{language}"', html)
                self.assertIn('id="theme-live-preview"', html)
                self.assertIn(f'src="{base}/assets/js/app.js?v=', html)
                self.assertIn('id="theme-file-input"', html)
                self.assertIn('<dialog class="theme-preview-dialog"', html)
                self.assertIn('aria-labelledby="current-theme-label"', html)
                self.assertNotIn('class="section live-section"', html)
                self.assertNotIn('href="#preview"', html)
                self.assertIn(f'{base}/assets/css/components.css', html)
                self.assertEqual((output / prefix / 'themes.html').read_text(), html)
                self.assertTrue((output / prefix / 'privacy/index.html').is_file())
                self.assertTrue((output / prefix / '404.html').is_file())
                error = (output / prefix / '404.html').read_text()
                self.assertIn('class="error-hero"', error)
                self.assertEqual(error.count('class="error-card"'), 4)
                self.assertIn('hero-light.webp', error)
                self.assertIn('data-action="reload-page"', error)
                self.assertIn('id="error-search-dialog"', error)

    def test_brand_assets_match_the_current_canonical_sources(self):
        manifest = json.loads((SITE / 'data/brand-assets.json').read_text())
        for _, output in self.outputs:
            for name, source in manifest.items():
                self.assertEqual((output / 'assets/brand' / name).read_bytes(), (ROOT / source).read_bytes())
            for html in output.rglob('*.html'):
                text = html.read_text()
                self.assertNotIn('brand-stamp', text)
                self.assertNotIn('>庫<', text)
                self.assertNotIn('wegit-mark.svg', text)

    def test_all_downloads_are_original_native_documents(self):
        catalog = json.loads((SITE / 'data/themes.json').read_text())
        self.assertEqual(len(catalog), 10)
        for _, output in self.outputs:
            for entry in catalog:
                name = entry['id'] + '.json'
                data = (SITE / 'public/themes' / name).read_bytes()
                self.assertEqual((output / 'themes' / name).read_bytes(), data)
                builder.validate_theme(json.loads(data))
                self.assertLessEqual(len(data), 65_536)

    def test_site_is_self_contained_and_does_not_invent_releases(self):
        for _, output in self.outputs:
            self.assertEqual(json.loads((output / 'releases.json').read_text()), [])
            self.assertLess(sum(p.stat().st_size for p in output.rglob('*') if p.is_file()), 3_000_000)
            for html in output.rglob('*.html'):
                text = html.read_text()
                self.assertIn('Content-Security-Policy', text)
                self.assertIn('id="main"', text)
                self.assertNotIn('src="https://', text)
                self.assertNotIn('href="https://unpkg', text)
                self.assertNotIn('Intel', text)
            self.assertFalse((output / 'references').exists())
            self.assertFalse((output / 'previews-v2').exists())

    def test_module_only_updates_refresh_cached_entry_and_dependency_urls(self):
        with tempfile.TemporaryDirectory(prefix='wegit-module-cache-test-') as temporary:
            root = Path(temporary)
            source = root / 'source'
            for name in ('src', 'public', 'data'):
                shutil.copytree(SITE / name, source / name)
            original_app = (source / 'src/scripts/app.js').read_text()
            snapshots = []
            with patch.object(builder, 'SITE', source):
                for index in range(3):
                    if index == 1:
                        module = source / 'src/scripts/error-page.js'
                        module.write_text(module.read_text() + '\n// Updated recovery behavior.\n')
                    output = root / f'build-{index}'
                    output.mkdir()
                    builder.write_site(output, '', [])
                    page = builder.Document()
                    page.feed((output / '404.html').read_text())
                    app_url = next(link for link in page.links if urlsplit(link).path == '/assets/js/app.js')
                    css_url = next(link for link in page.links if urlsplit(link).path == '/assets/css/components.css')
                    app = (output / 'assets/js/app.js').read_text()
                    recovery_url = re.search(r"import\(['\"]([^'\"]*error-page\.js[^'\"]*)", app)[1]
                    snapshots.append((app_url, recovery_url, css_url))
                    self.assertTrue(urlsplit(recovery_url).query)
                    self.assertEqual((output / 'assets/js' / urlsplit(recovery_url).path).read_text(), (source / 'src/scripts/error-page.js').read_text())
            self.assertNotEqual(snapshots[0][0], snapshots[1][0])
            self.assertNotEqual(snapshots[0][1], snapshots[1][1])
            self.assertEqual(snapshots[0][2], snapshots[1][2])
            self.assertEqual(snapshots[1], snapshots[2])
            self.assertEqual((source / 'src/scripts/app.js').read_text(), original_app)

    def test_native_screens_and_cultural_icons_replace_placeholder_ui(self):
        for base, output in self.outputs:
            for prefix in ('', 'zh/'):
                for name in ('index.html', 'themes/index.html'):
                    html = (output / prefix / name).read_text()
                    self.assertIn('data-native-image', html)
                    self.assertIn(f'{base}/assets/screenshots/wegit-light.webp', html)
                    self.assertIn('culture.svg#taiji', html)
                    self.assertNotIn('class="wrap release-links"', html)
                    self.assertNotIn('class="pavilion"', html)
            for mode in ('light', 'dark'):
                data = (output / f'assets/screenshots/wegit-{mode}.webp').read_bytes()
                self.assertEqual(data[:4], b'RIFF')
                self.assertEqual(data[8:12], b'WEBP')
            self.assertFalse((output / 'assets/js/mockups.js').exists())

    def test_unreadable_and_incompatible_catalogs_fail_validation(self):
        for mutate in (lambda t: t.update(version=2), lambda t: t['colors'].pop('canvas'), lambda t: t['colors'].update(comment=t['colors']['diffAdded'])):
            theme = json.loads((SITE / 'public/themes/light.json').read_text())
            mutate(theme)
            with self.assertRaises(ValueError):
                builder.validate_theme(theme)

    def test_build_refuses_to_replace_unrelated_content(self):
        target = Path(self.temporary.name) / 'user-files'
        target.mkdir(exist_ok=True)
        original = target / 'keep.txt'
        original.write_text('preserve')
        for marker in (None, '.nojekyll', '.wegit-site-build'):
            if marker:
                (target / marker).write_text('unrelated website')
            result = subprocess.run([sys.executable, str(SITE / 'scripts/build.py'), '--output', str(target)], capture_output=True)
            self.assertNotEqual(result.returncode, 0, marker)
            self.assertEqual(original.read_text(), 'preserve')

    def test_build_can_replace_its_own_generated_output(self):
        target = Path(self.temporary.name) / 'generated-website'
        command = [sys.executable, str(SITE / 'scripts/build.py'), '--output', str(target)]
        for _ in range(2):
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual((target / '.wegit-site-build').read_text(), 'WeGit static website\n')
            self.assertTrue((target / 'index.html').is_file())


if __name__ == '__main__':
    unittest.main()
