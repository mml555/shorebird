#!/usr/bin/env python3
"""ANDROID-CELL-SUPPLY-1 gate 4: a STRICT origin.

Serves ONLY what is present in the tree it is given. Nothing falls back, and
there is no upstream at all — so "the closure is sufficient" cannot be true by
accident, and a missing member cannot be rescued from elsewhere.
"""
import http.server, json, os, socketserver, sys, threading

PORT, ROOT, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
lock = threading.Lock()


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_GET(self):
        f = os.path.join(ROOT, self.path.lstrip('/'))
        ok = os.path.isfile(f)
        body = open(f, 'rb').read() if ok else b'STRICT-ORIGIN-ABSENT'
        with lock, open(LOG, 'a') as fh:
            fh.write(json.dumps({'path': self.path, 'served': ok,
                                 'bytes': len(body) if ok else 0}) + '\n')
        self.send_response(200 if ok else 404)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_HEAD = do_GET

    def log_message(self, *a):
        pass


class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


open(LOG, 'a').close()
print(f'strict origin :{PORT} root={ROOT}', flush=True)
S(('127.0.0.1', PORT), H).serve_forever()
