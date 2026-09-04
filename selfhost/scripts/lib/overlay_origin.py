#!/usr/bin/env python3
# cspell:words getsockname
"""An operator-shaped artifact origin: overlay first, upstream fallthrough.

This is what selfhost/cdn's Caddy does for a mapped engine hash -- serve the
overlay when it has the path, fall through to upstream otherwise -- reduced to
the part a hydration test needs. A bare static server is NOT equivalent and
fails for the wrong reason: SELFHOST-CLEANROOM-2's first attempt died on
`flutter/fonts/<hash>/fonts.zip`, a general Flutter asset that no engine cell
contains and that the real CDN fetches from upstream.

It records, per request, whether the bytes came from the OVERLAY or from
UPSTREAM. That distinction is the measurement: a cell member served from
upstream would mean the distribution was not actually used, and an asset that
cannot fall through would mean the origin is not operator-shaped.

    overlay_origin.py <port> <overlayDir> <logPath> [upstreamBase]
"""
import hashlib
import http.server
import json
import os
import socketserver
import sys
import threading
import urllib.error
import urllib.request

PORT = int(sys.argv[1])
OVERLAY = sys.argv[2]
LOG = sys.argv[3]
UPSTREAM = (sys.argv[4] if len(sys.argv) > 4
            else 'https://storage.googleapis.com/download.shorebird.dev').rstrip('/')
lock = threading.Lock()


def record(entry):
    with lock, open(LOG, 'a') as fh:
        fh.write(json.dumps(entry) + '\n')


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def _local(self):
        rel = self.path.lstrip('/').split('?', 1)[0]
        # Refuse traversal outright rather than normalising it.
        if '..' in rel.split('/'):
            return None
        p = os.path.join(OVERLAY, rel)
        return p if os.path.isfile(p) else None

    def do_GET(self):
        p = self._local()
        if p:
            body = open(p, 'rb').read()
            record({'path': self.path, 'source': 'overlay', 'status': 200,
                    'bytes': len(body),
                    'sha256': hashlib.sha256(body).hexdigest()})
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('X-Origin-Source', 'overlay')
            self.end_headers()
            self.wfile.write(body)
            return
        url = UPSTREAM + '/' + self.path.lstrip('/')
        try:
            with urllib.request.urlopen(url, timeout=300) as r:
                body = r.read()
                status = r.status
        except urllib.error.HTTPError as e:
            body, status = e.read(), e.code
        except Exception as e:                        # noqa: BLE001
            body, status = str(e).encode(), 599
        record({'path': self.path, 'source': 'upstream', 'status': status,
                'bytes': len(body),
                'sha256': hashlib.sha256(body).hexdigest()})
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Origin-Source', 'upstream')
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        p = self._local()
        if p:
            record({'path': self.path, 'source': 'overlay', 'status': 200,
                    'bytes': os.path.getsize(p), 'sha256': ''})
            self.send_response(200)
            self.send_header('Content-Length', str(os.path.getsize(p)))
            self.send_header('X-Origin-Source', 'overlay')
            self.end_headers()
            return
        self.do_GET()

    def log_message(self, *a):
        pass


class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


open(LOG, 'w').close()
print(f'overlay origin :{PORT} overlay={OVERLAY} upstream={UPSTREAM}', flush=True)
S(('127.0.0.1', PORT), H).serve_forever()
