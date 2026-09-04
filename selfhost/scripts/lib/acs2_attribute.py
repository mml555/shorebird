#!/usr/bin/env python3
# cspell:words armeabi embedding canonicalize canonicalizer reqlog lstrip
"""ANDROID-CELL-SUPPLY-2 gate 6 attribution: WHICH bytes answered each request.

Reads the recording origin's log and decides, per identity-bearing member,
whether the bytes served were the ones the cell address commits to. A 200 proves
only that something answered; the digest is what distinguishes the new cell from
the fallback revision.

Separate from the harness on purpose: the answer has to be re-derivable from the
banked request log alone, without re-running a 6-minute Android build.

    acs2_attribute.py <requests.jsonl> <stageDir> <cell> <policy> <canonicalizer>
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

reqlog, stage, cell, policy, canon = sys.argv[1:6]

members = []
for line in open(policy):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    f = line.split(None, 4)
    if len(f) < 4:
        continue
    if f[0] in ('macos-ios-android', 'both') and (
            f[2] == 'required' or 'route-b-compiler-' in f[3]):
        members.append(f[3])
members = sorted(set(members))

# The identity-bearing Android subset this gate is about: the 6 release engine
# objects and the 8 Maven objects.
android = [m for m in members
           if re.search(r'android-(arm|arm64|x64)-release/', m)
           or 'download.flutter.io' in m]

rows = [json.loads(l) for l in open(reqlog) if l.strip()]
by_path = {}
for r in rows:
    by_path.setdefault(r['path'].lstrip('/'), []).append(r)

print(f'    requests recorded: {len(rows)}   distinct paths: {len(by_path)}')


def expected_digest(member, served_body):
    """The digest the cell commits to, for a member of this kind.

    A POM is RENDERED: the staged template holds `1.0.0-%H` and the published
    file holds `1.0.0-<cell>`, so their raw digests differ BY DESIGN. Comparing
    raw bytes there reported four correct members as WRONG BYTES on the first
    run. The defined comparison is the canonical form -- the same inverse the
    address itself was computed through.
    """
    p = os.path.join(stage, member)
    if not os.path.exists(p):
        return None, None
    staged = hashlib.sha256(open(p, 'rb').read()).hexdigest()
    if not member.endswith('.pom'):
        return staged, hashlib.sha256(served_body).hexdigest()
    # Canonicalize the SERVED bytes back to the template and hash that. The
    # canonicalizer dispatches on the file name, so the temp file keeps it.
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, os.path.basename(member).replace('%H', cell))
        open(f, 'wb').write(served_body)
        out = subprocess.run(
            [sys.executable, canon, f, cell, '--digest'],
            capture_output=True, text=True)
        if out.returncode != 0:
            return staged, f'REFUSED: {out.stderr.strip()}'
        return staged, out.stdout.strip()


missing, wrong, good = [], [], []
for m in android:
    key = m.replace('%H', cell)
    hits = by_path.get(key, [])
    if not hits:
        missing.append(key)
        continue
    ok200 = [h for h in hits if h['status'] == 200]
    if not ok200:
        wrong.append((key, f"no 200 (statuses {[h['status'] for h in hits]})"))
        continue
    # The recording origin logs the digest but not the body, so re-fetch the
    # published file from the overlay for the canonical comparison. For binary
    # members the logged digest IS the comparison.
    if m.endswith('.pom'):
        pub = os.path.join(os.path.dirname(canon), '..', '..', '..',
                           'cdn', 'overlay', key)
        pub = os.path.normpath(pub)
        if not os.path.exists(pub):
            wrong.append((key, 'published file not found for the canonical compare'))
            continue
        body = open(pub, 'rb').read()
        if hashlib.sha256(body).hexdigest() != ok200[-1]['sha256']:
            wrong.append((key, 'the bytes served are not the bytes published'))
            continue
        exp, got = expected_digest(m, body)
    else:
        exp, got = expected_digest(m, b'')
        got = ok200[-1]['sha256']
    if exp is None:
        wrong.append((key, 'not present in the stage'))
    elif got != exp:
        wrong.append((key, f'served {str(got)[:16]}… != addressed {exp[:16]}…'))
    else:
        good.append(key)

print(f'    android identity members: {len(android)}   from the new cell: {len(good)}'
      f'   not requested: {len(missing)}   mismatched: {len(wrong)}')
for k in missing:
    print(f'    NOT REQUESTED {k}')
for k, why in wrong:
    print(f'    WRONG BYTES   {k}: {why}')

# NO identity-bearing object may have been answered via a redirect. The CDN
# answers a fallback-permitted path with a 302 to the pinned revision, so a
# redirect on an identity path IS the substitution this gate exists to refuse.
red = [r for r in rows
       if r['redirects']
       and re.search(r'android-(arm|arm64|x64)-release/|download\.flutter\.io',
                     r['path'])]
print(f'    identity requests answered via a redirect: {len(red)}')
for r in red[:6]:
    print(f"    REDIRECTED {r['path']} -> {r['redirects']}")

fb = sorted({r['path'].lstrip('/') for r in rows if r['redirects']})
print(f'    fallback-served paths: {len(fb)}')
for p in fb:
    print(f'      fallback  {p}')

absent = sorted({f"{r['status']} {r['path']}" for r in rows
                 if r['status'] not in (200, 302, 301)})
print(f'    non-200/302 answers: {len(absent)}')
for a in absent:
    print(f'      {a}')

sys.exit(1 if (missing or wrong or red) else 0)
