#!/usr/bin/env python3
# cspell:words acked ACKED DBDIR pnum
"""verify.py ACKED_JSON DBDIR: every acknowledged op must be in a read-only copy of the DB and storage.

Checks, and exits 1 if any fails:
- every release or patch the server acknowledged creating exists (even if the client's sequence failed later);
- every fully published release is `ready`, its artifacts are `verified` and the stored bytes match the sha256;
- every fully published patch is `ready` with a verified artifact whose bytes match;
- every acknowledged promote has a channel_patches row for that patch AND the channel promoted to;
- ids are dense (max(id) = count) in releases, patches and artifacts.
"""
import sys, json, sqlite3, hashlib, os
a = json.load(open(sys.argv[1])); d = sys.argv[2]
db = sqlite3.connect(f"file:{d}/code_push.db?mode=ro", uri=True)
q = lambda s, *p: db.execute(s, p).fetchall()
miss = []
def check_art(kind, oid, h, who):
    art = q("select status, storage_key from artifacts where owner_kind=? and owner_id=? and hash=? and status='verified'", kind, oid, h)
    if not art: miss.append((kind + "-artifact-row", who)); return
    p = os.path.join(d, "artifacts", art[0][1].split("artifacts/", 1)[-1]) if not art[0][1].startswith("/") else art[0][1]
    if not os.path.exists(p): p = os.path.join(d, "artifacts", art[0][1])
    if not os.path.exists(p): miss.append((kind + "-artifact-bytes-missing", who, art)); return
    if hashlib.sha256(open(p, "rb").read()).hexdigest() != h: miss.append((kind + "-artifact-bytes-corrupt", who))
for r in a.get("created_releases", []):
    if not q("select 1 from releases where id=? and app_id=? and version=?", r["id"], r["app"], r["version"]): miss.append(("created-release", r))
for p in a.get("created_patches", []):
    if not q("select 1 from patches where id=? and release_id=?", p["id"], p["release_id"]): miss.append(("created-patch", p))
for r in a["releases"]:
    row = q("select lifecycle from releases where id=? and app_id=? and version=?", r["id"], r["app"], r["version"])
    if not row: miss.append(("release", r)); continue
    if row[0][0] != "ready": miss.append(("release-lifecycle", r, row))
    for h in r["hashes"]: check_art("release", r["id"], h, r)
for p in a["patches"]:
    row = q("select status from patches where id=? and release_id=?", p["id"], p["release_id"])
    if not row: miss.append(("patch", p)); continue
    if row[0][0] != "ready": miss.append(("patch-status", p, row))
    check_art("patch", p["id"], p["hash"], p)
for pr in a["promotes"]:
    if not q("select 1 from channel_patches where patch_id=? and channel_id=?", pr["patch"], pr["channel"]): miss.append(("promote", pr))
for t in ("releases", "patches", "artifacts"):
    if not q(f"select coalesce(max(id)=count(*), 1) from {t}")[0][0]: miss.append(("ids-not-dense", t))
print("acked releases", len(a["releases"]), "patches", len(a["patches"]), "promotes", len(a["promotes"]),
      "(created releases", len(a.get("created_releases", [])), "patches", len(a.get("created_patches", [])) , ")")
print("db releases", q("select count(*) from releases")[0][0], "patches", q("select count(*) from patches")[0][0])
print("MISSING", len(miss))
for m in miss[:10]: print(m)
sys.exit(1 if miss else 0)
