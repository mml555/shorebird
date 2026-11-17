#!/usr/bin/env python3
# cspell:words callform tcallform xids hostcrash notmeasured
"""compare.py <route_b_sdk_measurements.dart as in PR #209's head> <result dir>

Compares the device matrix (result/results.tsv, result/members.json from tables.py) with the
allow-list in PR #209 (route_b_sdk_measurements.dart at head 961889d35, the host-measured list:
`git show 961889d35:packages/shorebird_cli/lib/src/route_b_sdk_measurements.dart`). Writes result/comparison.md.
Per key the device says one of
  SAFE       every probe ran and resolved (the member has compiled code and dispatch)
  CRASH      at least one probe aborted or segfaulted the process on the device
  CRASH(host) no device abort, but a probe aborted on the host matrix and was not tried on the device
  THROWS     no crash, but a probe got a NoSuchMethodError naming the member (no dispatch entry)
  PARTIAL    no crash and no throw, but some probes never ran (see the note)
  UNCALLED   a tear-off key whose probes resolved but whose call-form key is not SAFE (the tear-off probe never calls the closure)
"""
import collections, csv, json, re, sys
meas, d = sys.argv[1:3]
# optional third argument: the scope line, for a run whose release is not the plain counter app
SCOPE = sys.argv[3] if len(sys.argv) > 3 else 'one bare `flutter create` app release at engine cell 2fc41d3f; SAFE means resolved in that release (see RESULT.md).'
src = open(meas).read()
acc = set(re.findall(r"^\s+'([^']+)',", src.split('routeBSdkMeasuredAccepted')[1].split('};')[0], re.M))
rows = list(csv.DictReader(open(f'{d}/results.tsv'), delimiter='\t'))
by = collections.defaultdict(list)
for r in rows:
    if r['key'] == '?':
        sys.exit(f"compare.py: unkeyed probe {r['probe']}")
    by[r['key']].append(r)
HOST = 'aborted on the host'
verdict, thin = {}, set()
for k, rs in sorted(by.items()):
    st = collections.Counter(r['result'] for r in rs)
    hostcrash = [r for r in rs if r['result'] == 'NOT-RUN' and HOST in r['detail']]
    if st['ABORTS']: v = 'CRASH'
    elif hostcrash: v = 'CRASH(host)'
    elif st['THROWS'] or st['UNATTRIBUTED']: v = 'THROWS'
    elif st['NOT-RUN']: v = 'PARTIAL'
    else: v = 'SAFE'
    verdict[k] = v
# A tear-off probe only creates the closure (`final Object? t = R.member; if (t is! Function) ...`) and never calls it. So a
# `#tearoff:` key whose probes all resolved says only that the closure could be made; it is SAFE only when the call form of the
# same member (`dart:core#String#tearoff:endsWith` -> `dart:core#String#endsWith`) is SAFE too. Otherwise it is UNCALLED, and
# `callform_verdict` says why. Follow-up: make the probe call the closure with suitable arguments and measure again.
callform = {}
for k in list(verdict):
    if '#tearoff:' in k:
        cf = k.replace('tearoff:', '')
        callform[k] = verdict.get(cf, 'none')
        if verdict[k] == 'SAFE' and callform[k] != 'SAFE':
            verdict[k] = 'UNCALLED'
for k, v in verdict.items():
    rs = by[k]
    if v == 'SAFE' and (len(rs) < 2 or len({r['runtime_class'] for r in rs}) < 2):
        thin.add(k)
def crashes(rs):
    return ';'.join(f"{r['runtime_class']}:{r['form']}" for r in rs if r['result'] == 'ABORTS' or (r['result'] == 'NOT-RUN' and HOST in r['detail']))
with open(f'{d}/members.tsv', 'w') as f:
    f.write('key\tdevice_verdict\tthin\tpr209\tprobes\truntime_classes\tresolves\tthrows\taborts\tnot_run\tcrashing_runtime_classes_and_forms\tcallform_verdict\n')
    for k, v in verdict.items():
        rs = by[k]; st = collections.Counter(r['result'] for r in rs)
        f.write(f"{k}\t{v}\t{'thin' if k in thin else ''}\t{'accepted' if k in acc else 'refused'}\t{len(rs)}\t{len({r['runtime_class'] for r in rs})}\t{st['RESOLVES']}\t{st['THROWS']+st['UNATTRIBUTED']}\t{st['ABORTS']}\t{st['NOT-RUN']}\t{crashes(rs)}\t{callform.get(k, '')}\n")
tot = collections.Counter(verdict.values())
refused = [k for k in verdict if k not in acc]
a = [k for k in refused if verdict[k] == 'SAFE' and k not in thin]
at = [k for k in refused if verdict[k] == 'SAFE' and k in thin]
b = [k for k in refused if verdict[k] == 'PARTIAL']
c = [k for k in refused if verdict[k] == 'THROWS']
e = [k for k in verdict if k in acc and verdict[k].startswith('CRASH')]
g = [k for k in verdict if k in acc and verdict[k] in ('THROWS', 'PARTIAL', 'UNCALLED')]
un = [k for k in verdict if verdict[k] == 'UNCALLED']
notmeasured = sorted(acc - set(verdict))
safe_thin = sorted(thin)
def lst(ks): return ''.join(f'- {k}  ({len(by[k])} probes, {len({r["runtime_class"] for r in by[k]})} classes)\n' for k in ks)
with open(f'{d}/comparison.md', 'w') as f:
    f.write(f'# Device verdicts vs PR #209\n\nScope: {SCOPE}\n\nA `#tearoff:` key is SAFE only if its call-form key is SAFE too (the tear-off probe creates the closure and never calls it); otherwise it is UNCALLED.\n\n')
    f.write(f'Device keys {len(verdict)}: {dict(tot)}; {len(thin)} of the {tot["SAFE"]} SAFE keys are thin. #209 accepts {len(acc)} keys ({len(acc & set(verdict))} of them on the device matrix). All {len(rows)} probes are keyed.\n\n')
    f.write(f'## Refused by #209, SAFE on the device, not thin ({len(a)})\n\n' + lst(a))
    f.write(f'\n## Refused by #209, SAFE on the device but thin ({len(at)})\n\nFewer than 2 probes or fewer than 2 runtime classes.\n\n' + lst(at))
    f.write(f'\n## Refused by #209, no crash, but some probes never ran ({len(b)})\n\n' + lst(b))
    f.write(f'\n## Tear-off keys whose probes resolved but whose call form is not SAFE ({len(un)})\n\nThe tear-off probe only creates the closure, so these say nothing about calling it; the verdict is UNCALLED and the call form decides.\n\n' + ''.join(f'- {k}: call form {callform[k]}  ({"accepted" if k in acc else "refused"} by #209)\n' for k in un))
    f.write(f'\n## Refused by #209, no crash but a NoSuchMethodError on some runtime class ({len(c)})\n\n' + ''.join(f'- {k}\n' for k in c))
    f.write(f'\n## Accepted by #209, crashing on the device or host ({len(e)})\n\n' + ''.join(f'- {k}: {verdict[k]}\n' for k in e))
    f.write(f'\n## Accepted by #209, throwing, uncalled or partly unmeasured on the device ({len(g)})\n\n' + ''.join(f'- {k}: {verdict[k]}\n' for k in g))
    f.write(f'\n## Accepted by #209, not on the device matrix ({len(notmeasured)})\n\n' + ''.join(f'- {k}\n' for k in notmeasured))
    f.write(f'\n## Accepted by #209, SAFE but thin ({len([k for k in safe_thin if k in acc])})\n\n' + lst([k for k in safe_thin if k in acc]))
    f.write('\n## Crashing keys\n\n' + ''.join(f'- {k}: {v}  ({"accepted" if k in acc else "refused"} by #209)\n' for k, v in verdict.items() if v.startswith('CRASH') and not k.startswith('dynamic#')))
    f.write('\n## Crashing dynamic selectors\n\n' + ', '.join(f'{k[8:]}' + ('' if v == 'CRASH' else '(host)') for k, v in verdict.items() if v.startswith('CRASH') and k.startswith('dynamic#')) + '\n')
print(dict(tot), 'thin', len(thin), 'acc', len(acc), 'refusedSAFE', len(a), len(at), 'partial', len(b), 'throws', len(c), 'acc-crash', e, 'acc-thr', g)
