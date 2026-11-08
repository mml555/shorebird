#!/usr/bin/env python3
# cspell:words getsockname newurl
"""A RECORDING, FORWARDING artifact origin for ANDROID-CELL-SUPPLY-2 gate 6.

Sits between the CLI/Gradle and the real self-hosted CDN, forwards every
request, and records for each one: path, upstream status, the number of HTTP
redirects the CDN answered with, the FINAL url the body came from, and the
sha256 of the body.

Why not read the CDN's own access log. Attribution is the whole question in this
gate -- "did this object come from the new cell or from the fallback revision?"
-- and a status line cannot answer it. The body digest can: an identity-bearing
object is from the new cell if and only if its bytes equal the staged member's.
A 200 proves only that something answered.

    acs2_recording_origin.py <port> <upstreamBase> <logPath>
"""
import hashlib
import http.server
import json
import socketserver
import sys
import threading
import urllib.error
import urllib.request

PORT = int(sys.argv[1])
UPSTREAM = sys.argv[2].rstrip('/')
LOG = sys.argv[3]
lock = threading.Lock()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Count redirects instead of following them blindly.

    The CDN answers a fallback-permitted path with a 302 to the pinned
    revision. Following it silently is exactly the substitution this gate has to
    detect, so redirects are followed explicitly and the hop chain is recorded.
    """

    def __init__(self):
        self.chain = []

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.chain.append((code, newurl))
        return urllib.request.HTTPRedirectHandler.redirect_request(
            self, req, fp, code, msg, headers, newurl)


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def _fetch(self):
        rd = NoRedirect()
        opener = urllib.request.build_opener(rd)
        url = UPSTREAM + self.path
        try:
            with opener.open(url, timeout=300) as r:
                body = r.read()
                return r.status, body, r.geturl(), rd.chain, dict(r.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read(), url, rd.chain, dict(e.headers)
        except Exception as e:                       # noqa: BLE001
            return 599, str(e).encode(), url, rd.chain, {}

    def do_GET(self):
        status, body, final, chain, headers = self._fetch()
        with lock, open(LOG, 'a') as fh:
            fh.write(json.dumps({
                'method': self.command,
                'path': self.path,
                'status': status,
                'bytes': len(body),
                'sha256': hashlib.sha256(body).hexdigest(),
                'redirects': [{'code': c, 'to': u} for c, u in chain],
                'final_url': final,
            }) + '\n')
        self.send_response(status)
        ct = headers.get('Content-Type')
        if ct:
            self.send_header('Content-Type', ct)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command == 'GET':
            self.wfile.write(body)

    def do_HEAD(self):
        status, body, final, chain, headers = self._fetch()
        with lock, open(LOG, 'a') as fh:
            fh.write(json.dumps({
                'method': 'HEAD', 'path': self.path, 'status': status,
                'bytes': len(body),
                'sha256': hashlib.sha256(body).hexdigest(),
                'redirects': [{'code': c, 'to': u} for c, u in chain],
                'final_url': final,
            }) + '\n')
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()

    def log_message(self, *a):
        pass


class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


open(LOG, 'w').close()
print(f'recording origin :{PORT} -> {UPSTREAM}  log={LOG}', flush=True)
S(('127.0.0.1', PORT), H).serve_forever()
