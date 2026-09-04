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

    overlay_origin.py <port> <overlayDir> <logPath> [upstreamBase] [hashMap]

THE HASH REWRITE IS PART OF BEING OPERATOR-SHAPED. Upstream has never published
our cell, so a non-overridden artifact has to be resolved under the UPSTREAM
FLUTTER engine revision -- which is what the production CDN does, measured
directly:

    GET /flutter_infra_release/flutter/f85251f3…/android-arm-profile/darwin-x64.zip
    302 -> /gcs/flutter_infra_release/flutter/83675ed2…/android-arm-profile/darwin-x64.zip

Without that rewrite every CACHE/TRANSPORT object -- the ten that
ANDROID-CELL-SUPPLY-1 deliberately left out of cell identity -- 404s, and
Android hydration fails for a reason that has nothing to do with the
distribution.

The rewrite target is NOT outside knowledge: `flutter_engine_revision` lives in
the cell's own `artifacts_manifest.yaml`, which is one of the 30 distributed
members. Rewriting to experimental_hashes.map's FALLBACK engine instead was
measured and is wrong -- 404, because that engine's artifacts are not in the
flutter_infra_release bucket either.
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
# THE BUCKET IS THE FIRST PATH SEGMENT, so the upstream base is the GCS host
# and the request path passes through verbatim:
#   flutter_infra_release/...   -> storage.googleapis.com/flutter_infra_release/...
#   download.shorebird.dev/...  -> storage.googleapis.com/download.shorebird.dev/...
#   download.flutter.io/...     -> storage.googleapis.com/download.flutter.io/...
# Defaulting to .../download.shorebird.dev instead made every stock Flutter
# asset 404 twice over -- once locally and once upstream -- because Flutter's
# fonts live in the flutter_infra_release bucket, not beneath Shorebird's.
UPSTREAM = (sys.argv[4] if len(sys.argv) > 4
            else 'https://storage.googleapis.com').rstrip('/')
CELL = sys.argv[5] if len(sys.argv) > 5 else ''
FALLBACK = {}
if CELL:
    # Read the rewrite target out of the DISTRIBUTION itself.
    mf = os.path.join(OVERLAY, 'download.shorebird.dev', 'shorebird', CELL,
                      'artifacts_manifest.yaml')
    if os.path.isfile(mf):
        for line in open(mf):
            if line.startswith('flutter_engine_revision:'):
                FALLBACK[CELL] = line.split(':', 1)[1].strip()
                break
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
        rel = self.path.lstrip('/')
        rewritten = None
        for exp, pinned in FALLBACK.items():
            if exp in rel:
                rel = rel.replace(exp, pinned)
                rewritten = f'{exp[:12]}->{pinned[:12]}'
                break
        url = UPSTREAM + '/' + rel
        try:
            with urllib.request.urlopen(url, timeout=300) as r:
                body = r.read()
                status = r.status
        except urllib.error.HTTPError as e:
            body, status = e.read(), e.code
        except Exception as e:                        # noqa: BLE001
            body, status = str(e).encode(), 599
        record({'path': self.path, 'source': 'upstream', 'status': status,
                'bytes': len(body), 'rewritten': rewritten,
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
