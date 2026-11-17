#!/usr/bin/env python3
# cspell:words xids hostcrash notmeasured
"""compare.py <r1_safety_worktree> <result dir>

Compares the device matrix (result/results.tsv, result/members.json from tables.py) with the
allow-list in PR #209 (route_b_sdk_measurements.dart). Writes result/comparison.md.
Per key the device says one of
  SAFE       every probe ran and resolved (the member has compiled code and dispatch)
  CRASH      at least one probe aborted or segfaulted the process (host-aborted probes count)
  THROWS     no crash, but a probe got a NoSuchMethodError naming the member (no dispatch entry)
  PARTIAL    no crash and no throw, but some probes never ran (see the note)
"""
import collections, csv, json, re, sys
r1, d = sys.argv[1:3]
src = open(f'{r1}/packages/shorebird_cli/lib/src/route_b_sdk_measurements.dart').read()
acc = set(re.findall(r"^\s+'([^']+)',", src.split('routeBSdkMeasuredAccepted')[1].split('};')[0], re.M))
rows = list(csv.DictReader(open(f'{d}/results.tsv'), delimiter='\t'))
gen = f'{d}/gen'
xids = dict(l.rstrip('\n').split('\t') for l in open(f'{gen}/excluded_ids.tsv') if l.strip())
by = collections.defaultdict(list)
for r in rows:
    if r['key'] != '?':
        by[r['key']].append(r)
verdict = {}
for k, rs in sorted(by.items()):
    st = collections.Counter(r['result'] for r in rs)
    hostcrash = [r for r in rs if r['result'] == 'NOT-RUN' and 'aborted on the host' in r['detail']]
    if st['ABORTS'] or hostcrash: v = 'CRASH'
    elif st['THROWS'] or st['UNATTRIBUTED']: v = 'THROWS'
    elif st['NOT-RUN']: v = 'PARTIAL'
    else: v = 'SAFE'
    verdict[k] = v
with open(f'{d}/members.tsv', 'w') as f:
    f.write('key\tdevice_verdict\tpr209\tresolves\tthrows\taborts\tnot_run\tcrashing_runtime_classes_and_forms\n')
    for k, v in verdict.items():
        rs = by[k]; st = collections.Counter(r['result'] for r in rs)
        crashes = ';'.join(f"{r['runtime_class']}:{r['form']}" for r in rs if r['result'] == 'ABORTS' or (r['result'] == 'NOT-RUN' and 'aborted on the host' in r['detail']))
        f.write(f"{k}\t{v}\t{'accepted' if k in acc else 'refused'}\t{st['RESOLVES']}\t{st['THROWS']+st['UNATTRIBUTED']}\t{st['ABORTS']}\t{st['NOT-RUN']}\t{crashes}\n")
tot = collections.Counter(verdict.values())
refused = [k for k in verdict if k not in acc]
a = [k for k in refused if verdict[k] == 'SAFE']
b = [k for k in refused if verdict[k] == 'PARTIAL']
c = [k for k in refused if verdict[k] == 'THROWS']
e = [k for k in verdict if k in acc and verdict[k] == 'CRASH']
g = [k for k in verdict if k in acc and verdict[k] in ('THROWS', 'PARTIAL')]
notmeasured = sorted(acc - set(verdict))
with open(f'{d}/comparison.md', 'w') as f:
    f.write(f'# Device verdicts vs PR #209\n\nDevice keys {len(verdict)}: {dict(tot)}. #209 accepts {len(acc)} keys ({len(acc & set(verdict))} of them on the device matrix).\n\n')
    f.write(f'## Refused by #209, safe on the device ({len(a)})\n\n' + ''.join(f'- {k}\n' for k in a))
    f.write(f'\n## Refused by #209, no crash, but some probes never ran ({len(b)})\n\n' + ''.join(f'- {k}\n' for k in b))
    f.write(f'\n## Refused by #209, no crash but a NoSuchMethodError on some runtime class ({len(c)})\n\n' + ''.join(f'- {k}\n' for k in c))
    f.write(f'\n## Accepted by #209, crashing on the device ({len(e)})\n\n' + ''.join(f'- {k}\n' for k in e))
    f.write(f'\n## Accepted by #209, throwing or partly unmeasured on the device ({len(g)})\n\n' + ''.join(f'- {k}: {verdict[k]}\n' for k in g))
    f.write(f'\n## Accepted by #209, not on the device matrix ({len(notmeasured)})\n\n' + ''.join(f'- {k}\n' for k in notmeasured))
    f.write('\n## Crashing keys\n\n' + ''.join(f'- {k}  ({"accepted" if k in acc else "refused"} by #209)\n' for k, v in verdict.items() if v == 'CRASH' and not k.startswith('dynamic#')))
    f.write('\n## Crashing dynamic selectors\n\n' + ', '.join(k[8:] for k, v in verdict.items() if v == 'CRASH' and k.startswith('dynamic#')) + '\n')
print(dict(tot), len(acc), len(a), len(b), len(c), len(e), len(g), len(notmeasured))
