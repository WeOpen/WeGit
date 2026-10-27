#!/usr/bin/env python3
"""Build and serve the website locally, without installing dependencies."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]


class WebsiteHandler(SimpleHTTPRequestHandler):
    # Reuse browser connections instead of reconnecting for each SVG/image module.
    protocol_version = 'HTTP/1.1'

    def send_error(self, code, message=None, explain=None):
        path = urlsplit(self.path).path
        is_document = 'text/html' in self.headers.get('Accept', '') or not Path(path).suffix or path.endswith('.html')
        if code == 404 and is_document and self.command in ('GET', 'HEAD'):
            locale = 'zh/' if 'zh' in path.split('/') else ''
            target = Path(self.directory) / locale / '404.html'
            if target.is_file():
                data = target.read_bytes()
                self.send_response(404)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                if self.command != 'HEAD':
                    self.wfile.write(data)
                return
        super().send_error(code, message, explain)


class WebsiteServer(ThreadingHTTPServer):
    request_queue_size = 64
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=4173)
    parser.add_argument('--releases-json', type=Path)
    args = parser.parse_args()
    command = [sys.executable, str(ROOT / 'site/scripts/build.py'), '--base-path', '']
    if args.releases_json:
        command += ['--releases-json', str(args.releases_json.resolve())]
    subprocess.run(command, check=True)
    handler = partial(WebsiteHandler, directory=str(ROOT / '.build/website'))
    print(f'WeGit website: http://127.0.0.1:{args.port}/zh/', flush=True)
    try:
        WebsiteServer(('127.0.0.1', args.port), handler).serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
