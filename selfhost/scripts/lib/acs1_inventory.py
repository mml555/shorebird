#!/usr/bin/env python3
"""ANDROID-CELL-SUPPLY-1: the measured closure, classified.

Every row comes from an observed request. The policy columns are read from the
CDN's own Caddyfile matcher and the cell's v2 descriptor, not from convention.
"""
import json, os, re, hashlib

A = '/Volumes/build/route-b/acs1'
REPO = '/Users/mendell/shorebird'
CELL = 'cd848320d605ff8af5060cabf9a8d1b35853f752'
OVERLAY = f'{REPO}/selfhost/cdn/overlay'

# The @must_be_local matcher, transcribed from selfhost/cdn/Caddyfile:165.
MUST_LOCAL = re.compile(
    r'^/(flutter_infra_release/flutter/[0-9a-f]{40}/('
    r'android-arm64-release/|ios-release/|(linux|darwin|windows)-(x64|arm64)/artifacts\.zip$'
    r'|darwin-arm64/font-subset\.zip$|flutter_patched_sdk_product\.zip$'
    r'|flutter_patched_sdk\.zip$|dart-sdk-[a-z0-9-]+\.zip$|engine_stamp\.json$)'
    r'|download\.flutter\.io/io/flutter/'
    r'|[^/]+/shorebird/[0-9a-f]{40}/(patch-(darwin-arm64|darwin-x64|linux-x64)\.zip$'
    r'|aot-tools\.dill$|artifacts_manifest\.yaml$|route-b-compiler-[a-z0-9-]+\.zip$))')

# The v2 descriptor's addressed members, with %H for the hash.
addressed = set()
for line in open(f'{REPO}/selfhost/engine/route_b/cell_manifests/{CELL}.v2'):
    parts = line.split()
    if len(parts) == 2 and len(parts[1]) == 64:
        addressed.add(parts[0].replace('%H', CELL))


def load(path):
    if not os.path.exists(path):
        return []
    return [json.loads(l) for l in open(path)]


def classify(path, bytes_):
    """target platform / abi / mode / consumer / content, from the path shape."""
    m = re.match(r'^/flutter_infra_release/flutter/[0-9a-f]{40}/android-(arm64|arm|x64|x86)(?:-(profile|release))?/(.+)$', path)
    if m:
        abi, mode, obj = m.group(1), m.group(2) or 'debug', m.group(3)
        host = 'darwin-x64' if obj.startswith('darwin') else '-'
        content = 'gen_snapshot (host AOT compiler)' if obj.endswith('darwin-x64.zip') else 'flutter.jar (engine + embedding classes)'
        consumer = 'flutter precache / flutter build'
        return dict(group='android-engine', abi=abi, mode=mode, host=host,
                    content=content, consumer=consumer)
    m = re.match(r'^/download\.flutter\.io/io/flutter/([^/]+)/1\.0\.0-[0-9a-f]{40}/.*\.(pom|jar|pom\.sha1)$', path)
    if m:
        art, ext = m.group(1), m.group(2)
        abi = {'arm64_v8a_release': 'arm64', 'armeabi_v7a_release': 'arm',
               'x86_64_release': 'x64'}.get(art, '-')
        content = {'pom': 'maven descriptor (version-bound)',
                   'jar': 'AAR: lib/<abi>/libflutter.so — SHIPS IN THE APK',
                   'pom.sha1': 'checksum sidecar'}[ext]
        if art == 'flutter_embedding_release':
            content = ('maven descriptor (version-bound)' if ext == 'pom'
                       else 'embedding classes — SHIPS IN THE APK')
        return dict(group='android-maven', abi=abi, mode='release', host='-',
                    content=content, consumer='Gradle (flutter plugin)')
    if '/shorebird/' in path:
        return dict(group='shorebird', abi='-', mode='-', host='-',
                    content=os.path.basename(path), consumer='shorebird CLI')
    return dict(group='other', abi='-', mode='-', host='-',
                content=os.path.basename(path), consumer='?')


rows = {}
for src, tag in [('requests_precache.jsonl', 'precache'),
                 ('requests.jsonl', 'release')]:
    for r in load(f'{A}/{src}'):
        p = r['path']
        row = rows.setdefault(p, {'path': p, 'consumers': set(), 'status': r['status'],
                                  'bytes': r['bytes'], 'sha256': r['sha256'],
                                  'source': r['source']})
        row['consumers'].add(tag)
        if r['status'] == 200 and row['status'] != 200:
            row.update(status=200, bytes=r['bytes'], sha256=r['sha256'], source=r['source'])

out = []
for p, row in sorted(rows.items()):
    c = classify(p, row['bytes'])
    rel = p.lstrip('/')
    out.append({
        **row, **c,
        'consumers': sorted(row['consumers']),
        'required': row['status'] == 200,   # a 404 the build survived is incidental
        'must_be_local': bool(MUST_LOCAL.match(p)),
        'in_overlay': os.path.isfile(f'{OVERLAY}/{rel}'),
        'addressed_by_cell': rel in addressed,
    })
json.dump(out, open(f'{A}/closure.json', 'w'), indent=1)

req = [r for r in out if r['required']]
print(f'observed objects: {len(out)}   required: {len(req)}   incidental: {len(out)-len(req)}')
print()
hdr = f"{'group':16} {'abi':6} {'mode':8} {'local?':7} {'overlay?':9} {'addr?':6} {'bytes':>11}  object"
print(hdr); print('-'*len(hdr))
for r in sorted(out, key=lambda r: (r['group'], r['abi'], r['mode'], r['path'])):
    name = r['path'].split('/')[-1]
    parent = r['path'].split('/')[-2]
    print(f"{r['group']:16} {r['abi']:6} {r['mode']:8} "
          f"{('MUST' if r['must_be_local'] else 'fallback'):7} "
          f"{('yes' if r['in_overlay'] else 'NO'):9} "
          f"{('yes' if r['addressed_by_cell'] else 'no'):6} "
          f"{r['bytes']:>11}  {parent}/{name}"
          + ('' if r['required'] else '   [INCIDENTAL: 404, build survived]'))
