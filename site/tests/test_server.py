"""Missing documents get the branded 404 without disguising missing asset requests."""
from functools import partial
import http.client
import importlib.util
from pathlib import Path
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('wegit_website_server', ROOT / 'site/scripts/serve.py')
server_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server_module)


class QuietHandler(server_module.WebsiteHandler):
    def log_message(self, *args):
        pass


class ErrorRouteTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='wegit-404-test-')
        root = Path(self.directory.name)
        (root / 'zh').mkdir()
        (root / '404.html').write_text('<h1>custom English 404</h1>')
        (root / 'zh/404.html').write_text('<h1>自定义中文 404</h1>')
        self.server = server_module.WebsiteServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(root)))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.directory.cleanup()

    def request(self, path, method='GET', accept='text/html'):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        connection.request(method, path, headers={'Accept': accept})
        response = connection.getresponse()
        result = (response.status, dict(response.getheaders()), response.read())
        connection.close()
        return result

    def test_missing_document_preserves_404_status_and_locale(self):
        for path, expected in [('/lost/path', 'custom English 404'), ('/zh/lost/path', '自定义中文 404')]:
            status, headers, body = self.request(path)
            self.assertEqual(status, 404)
            self.assertIn('text/html', headers['Content-Type'])
            self.assertEqual(int(headers['Content-Length']), len(body))
            self.assertIn(expected, body.decode())

    def test_head_and_missing_assets_keep_http_semantics(self):
        status, headers, body = self.request('/lost', method='HEAD')
        self.assertEqual(status, 404)
        self.assertGreater(int(headers['Content-Length']), 0)
        self.assertEqual(body, b'')
        status, _, body = self.request('/assets/missing.css', accept='text/css')
        self.assertEqual(status, 404)
        self.assertNotIn(b'custom English 404', body)
