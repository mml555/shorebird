#!/usr/bin/env python3
"""A logging artifact origin for FLUTTER-STORAGE-AUTHORITY-1.

Records every request path and answers with a configurable status, so a run can
prove WHICH origin the CLI asked and that a refusal is not routed around.
"""
import http.server, json, os, socketserver, sys, threading

PORT = int(sys.argv[1])
MODE = sys.argv[2] if len(sys.argv) > 2 else '404'   # 404 | 500 | serve
LOG = sys.argv[3]
lock = threading.Lock()


class H(http.server.BaseHTTPRequestHandler):
    def _record(self):
        with lock, open(LOG, 'a') as fh:
            fh.write(json.dumps({'method': self.command,
                                 'path': self.path,
                                 'host': self.headers.get('Host', '')}) + '\n')

    def do_GET(self):
        self._record()
        if MODE == 'serve':
            body = b'FLUTTER-STORAGE-AUTHORITY-1-CANARY-BODY'
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        code = 500 if MODE == '500' else 404
        body = b'FLUTTER-STORAGE-AUTHORITY-1-DISTINCTIVE-REFUSAL'
        self.send_response(code)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_HEAD = do_GET

    def log_message(self, *a):
        pass


class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


open(LOG, 'w').close()
print(f'origin probe on {PORT} mode={MODE} log={LOG}', flush=True)
S(('127.0.0.1', PORT), H).serve_forever()
