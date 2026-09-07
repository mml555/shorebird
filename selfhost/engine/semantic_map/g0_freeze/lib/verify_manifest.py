"""Re-hash every frozen input and compare against the manifest.

No parallel inventory: the list comes from the manifest itself.
"""
import hashlib, json, os, sys

man, repo, here, an_ship, corpus_digest, base_dill = sys.argv[1:7]
d = json.load(open(man))
fails = 0


def sha(p):
    try:
        h = hashlib.sha256()
        with open(p, 'rb') as f:
            for c in iter(lambda: f.read(1 << 20), b''):
                h.update(c)
        return h.hexdigest()
    except OSError:
        return None


entries = d.get('frozen_inputs', [])
if not entries:
    print('  FAILED  the manifest records no frozen inputs')
    sys.exit(1)

drift = []
for e in entries:
    now = sha(os.path.join(repo, e['path']))
    if now is None:
        drift.append((e['path'], 'missing'))
    elif now != e['sha256']:
        drift.append((e['path'], f"{e['sha256'][:12]} -> {now[:12]}"))
if drift:
    for pth, how in drift:
        print(f'  FAILED  frozen input drifted: {pth} ({how})')
    fails += len(drift)
else:
    kinds = {}
    for e in entries:
        kinds[e['kind']] = kinds.get(e['kind'], 0) + 1
    print(f"  ok      all {len(entries)} frozen inputs re-hashed and unchanged "
          f"({', '.join(f'{v} {k}' for k, v in sorted(kinds.items()))})")

if d['analyzer']['shipped_sha256'] != an_ship:
    print('  FAILED  shipped analyzer drifted since the freeze'); fails += 1
else:
    print('  ok      shipped analyzer unchanged since the freeze')

if d.get('adversarial_corpus_digest') != corpus_digest:
    print('  FAILED  adversarial corpus aggregate digest drifted'); fails += 1
else:
    print('  ok      adversarial corpus aggregate digest unchanged')

rec = d.get('release_identity', {}).get('base_corpus_dill_sha256')
if base_dill:
    if rec != base_dill:
        print(f'  FAILED  base release dill drifted: {str(rec)[:12]} -> {base_dill[:12]}'); fails += 1
    else:
        print('  ok      base release dill matches the frozen release identity')
elif rec:
    print('  --      release dill not rebuilt this run (SKIP_DILL); its identity is unverified')

sys.exit(1 if fails else 0)
