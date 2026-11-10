#!/usr/bin/env python3
"""Publish driver: acknowledged operations are recorded, then read back from API and DB.
Usage: drive.py BASE KEY OUTJSON RELEASES_PER_WORKER WORKERS MODE
MODE: plain | interrupt (abort some uploads midway, then retry) | resumable
"""
import sys, json, os, hashlib, random, threading, http.client, urllib.parse, uuid, time

base, key, out, per, workers, mode = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
u = urllib.parse.urlparse(base)
acked = {"apps": [], "releases": [], "patches": [], "promotes": [], "errors": []}
lock = threading.Lock()

def req(method, path, body=None, headers=None, raw=False, abort_after=None):
    h = {"Authorization": "Bearer " + key}
    h.update(headers or {})
    c = http.client.HTTPConnection(u.hostname, u.port, timeout=60)
    if isinstance(body, (dict, list)):
        body = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    if abort_after is not None:
        c.putrequest(method, path); 
        for k, v in h.items(): c.putheader(k, v)
        c.putheader("Content-Length", str(len(body))); c.endheaders()
        c.send(body[:abort_after]); c.close(); return 0, None
    for attempt in range(40):
        try:
            c = http.client.HTTPConnection(u.hostname, u.port, timeout=60)
            c.request(method, path, body=body, headers=h)
            r = c.getresponse(); data = r.read(); c.close(); break
        except (ConnectionError, http.client.HTTPException, OSError) as e:
            if method != "GET" and attempt >= 39: raise
            time.sleep(0.5)
    if raw: return r.status, data
    try: return r.status, (json.loads(data) if data else None)
    except Exception: return r.status, data

def multipart(fields, file=None):
    b = "----b" + uuid.uuid4().hex
    parts = []
    for k, v in fields.items():
        parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    if file is not None:
        parts.append(f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="f.bin"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode() + file + b"\r\n")
    parts.append(f'--{b}--\r\n'.encode())
    return b"".join(parts), {"Content-Type": "multipart/form-data; boundary=" + b}

def upload(url, data):
    p = urllib.parse.urlparse(url).path
    if mode == "resumable":
        # chunked PUT
        n = len(data); step = max(1, n // 3); off = 0
        while off < n:
            ch = data[off:off+step]
            s, _ = req("PUT", p, ch, {"Content-Range": f"bytes {off}-{off+len(ch)-1}/{n}", "Content-Type": "application/octet-stream"}, raw=True)
            if s not in (200, 201, 308): return s
            off += len(ch)
        return s
    body, h = multipart({}, data)
    if mode == "interrupt" and random.random() < 0.4:
        req("POST", p, body, h, abort_after=len(body)//2)
        time.sleep(0.05)
    for attempt in range(3):
        s, r = req("POST", p, body, h, raw=True)
        if s < 500: return s
    return s

def register(path, fields):
    for _ in range(3):
        body, h = multipart(fields)
        s, r = req("POST", path, body, h)
        if s < 500: return s, r
    return s, r

def err(what, s, r):
    with lock: acked["errors"].append([what, s, str(r)[:200]])

def worker(app, wid, chan):
    try: _worker(app, wid, chan)
    except Exception as e: err("worker-exception", 0, repr(e))

def _worker(app, wid, chan):
    for i in range(per):
        ver = f"1.{wid}.{i}+{i+1}"
        s, r = req("POST", f"/api/v1/apps/{app}/releases", {"version": ver, "flutter_revision": "abc123"})
        if s != 200: err("create_release", s, r); continue
        rid = r["release"]["id"]
        hashes = []
        bad = False
        for arch in ("aab", "aarch64"):
            data = os.urandom(random.randint(1000, 200000))
            fields = {"arch": arch, "platform": "android", "hash": hashlib.sha256(data).hexdigest(), "filename": "libapp.so", "size": len(data)}
            s, r = register(f"/api/v1/apps/{app}/releases/{rid}/artifacts", fields)
            if s != 200: err("reg_rel_art", s, r); bad = True; break
            s = upload(r["url"], data)
            if s not in (200, 201, 204): err("upload_rel", s, ""); bad = True; break
            hashes.append(fields["hash"])
        if bad: continue
        s, r = req("PATCH", f"/api/v1/apps/{app}/releases/{rid}", {"status": "active", "platform": "android", "metadata": {}}, raw=True)
        if s != 204: err("activate_release", s, r); continue
        with lock: acked["releases"].append({"id": rid, "version": ver, "app": app, "hashes": hashes})
        # patch
        s, r = req("POST", f"/api/v1/apps/{app}/patches", {"release_id": rid, "metadata": {}})
        if s != 200: err("create_patch", s, r); continue
        pid = r["id"]; pnum = r["number"]
        pd = os.urandom(random.randint(500, 50000))
        pf = {"arch": "aarch64", "platform": "android", "hash": hashlib.sha256(pd).hexdigest(), "size": len(pd)}
        s, r = register(f"/api/v1/apps/{app}/patches/{pid}/artifacts", pf)
        if s != 200: err("reg_patch_art", s, r); continue
        s = upload(r["url"], pd)
        if s not in (200, 201, 204): err("upload_patch", s, ""); continue
        with lock: acked["patches"].append({"id": pid, "number": pnum, "release_id": rid, "app": app, "hash": pf["hash"]})
        s, r = req("POST", f"/api/v1/apps/{app}/patches/promote", {"patch_id": pid, "channel_id": chan}, raw=True)
        if s != 204: err("promote", s, r); continue
        with lock: acked["promotes"].append({"patch": pid, "app": app})

s, r = req("POST", "/api/v1/apps", {"display_name": "repro-" + uuid.uuid4().hex[:6]})
if s != 200: print("app create failed", s, r); sys.exit(2)
app = r["id"] if "id" in r else r["app"]["id"]
acked["apps"].append(app)
s, r = req("POST", f"/api/v1/apps/{app}/channels", {"channel": "stable"})
chan = r["id"]
ts = [threading.Thread(target=worker, args=(app, w, chan)) for w in range(workers)]
[t.start() for t in ts]; [t.join() for t in ts]
json.dump(acked, open(out, "w"))
print({k: len(v) for k, v in acked.items()})
for e in acked["errors"][:10]: print(e)
