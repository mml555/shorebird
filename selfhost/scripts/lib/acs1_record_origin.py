#!/usr/bin/env python3
"""ANDROID-CELL-SUPPLY-1 gate 1: a RECORDING artifact origin.

Serves every artifact the pinned toolchain asks for, so `precache` and
`release` run to completion and the FULL closure is observed — a refusing
origin only ever reveals the first request.

Bytes come from upstream, with the cell hash rewritten to the documented
fallback revision for `flutter_infra_release` paths (cell cd848320… publishes
no Android artifacts, and 404s upstream too). That is a MEASUREMENT device:
it discovers WHAT is required. It writes into a scratch tree and never into the
published cell namespace.

Every request is logged with its original path, so the closure is expressed in
the cell's own address space.
"""
import hashlib
import http.server
import json
import os
import socketserver
import sys
import threading
import urllib.request

PORT = int(sys.argv[1])
STORE = sys.argv[2]          # scratch tree; becomes gate 4's origin
LOG = sys.argv[3]
CELL = 'cd848320d605ff8af5060cabf9a8d1b35853f752'
FALLBACK = '69f9831c360d9152862ec3897c67fb09ae843f3b'
lock = threading.Lock()


OVERLAY = '/Users/mendell/shorebird/selfhost/cdn/overlay'


def upstream_for(path):
    """The real URL for a path, and whether the hash was rewritten.

    Mirrors the CDN's own rule (`selfhost/cdn/Caddyfile`): one
    `{stock_engine_hash}` from `experimental_hashes.map` applies to all three
    path shapes — `flutter_infra_release/flutter/<h>/`,
    `download.flutter.io/io/flutter/*/1.0.0-<h>/`, and `<bucket>/shorebird/<h>/`.
    The first two are served by `download.shorebird.dev`; the third by
    `storage.googleapis.com`, which is a real asymmetry and not a guess — the
    same object 404s on the other host.
    """
    rewritten = path.replace(CELL, FALLBACK)
    if '/shorebird/' in path:
        return 'https://storage.googleapis.com' + rewritten, rewritten != path
    return 'https://download.shorebird.dev' + rewritten, rewritten != path


def overlay_path(path):
    """The overlay file for a path, if the cell OWNS this artifact.

    Overlay-first, like the CDN: an artifact the cell owns must come from the
    cell, never from the fallback. Serving it from upstream would be exactly
    the substitution this lane exists to prevent.
    """
    candidate = os.path.join(OVERLAY, path.lstrip('/'))
    return candidate if os.path.isfile(candidate) else None


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def _log(self, rec):
        with lock, open(LOG, 'a') as fh:
            fh.write(json.dumps(rec) + '\n')

    def do_GET(self):
        cached = os.path.join(STORE, self.path.lstrip('/'))
        body = None
        owned = overlay_path(self.path)
        if os.path.isfile(cached):
            body = open(cached, 'rb').read()
            source = 'scratch-cache'
            status = 200
        elif owned:
            body = open(owned, 'rb').read()
            source = 'overlay(cell-owned)'
            status = 200
            os.makedirs(os.path.dirname(cached), exist_ok=True)
            with open(cached, 'wb') as fh:
                fh.write(body)
        else:
            url, rewritten = upstream_for(self.path)
            try:
                with urllib.request.urlopen(url, timeout=120) as r:
                    body = r.read()
                status = 200
                source = 'upstream(rewritten)' if rewritten else 'upstream'
                os.makedirs(os.path.dirname(cached), exist_ok=True)
                with open(cached, 'wb') as fh:
                    fh.write(body)
            except urllib.error.HTTPError as e:
                status, source, body = e.code, 'upstream-error', b''
            except Exception as e:                      # noqa: BLE001
                status, source, body = 599, f'error:{e}', b''
        self._log({
            'path': self.path,
            'method': self.command,
            'status': status,
            'bytes': len(body or b''),
            'sha256': hashlib.sha256(body).hexdigest() if body else None,
            'source': source,
        })
        self.send_response(status)
        self.send_header('Content-Length', str(len(body or b'')))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def log_message(self, *a):
        pass


class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


os.makedirs(STORE, exist_ok=True)
open(LOG, 'a').close()
print(f'recording origin :{PORT} store={STORE}', flush=True)
S(('127.0.0.1', PORT), H).serve_forever()
