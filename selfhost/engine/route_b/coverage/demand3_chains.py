#!/usr/bin/env python3
"""D-DEMAND-3 stage 2: the full blocker chain for every REFUSED observation.

Drives `tool/demand_blocker_chain.dart` once per refused target, with the
release's own manifest, the release import kernel, the CANDIDATE kernel (so an
admitted `super.` site is not refused for the harness having no verification
dill) and the measured `--super-capable` flag for the frozen cell.

Accepted observations are not probed: they have no blocker to attribute.
"""
import json, os, subprocess, sys
sys.path.insert(0, '/Users/mendell/shorebird/selfhost/engine/route_b/coverage')
from demand_report import analyse
from producer_report import load_producer

CLI = '/Users/mendell/shorebird/packages/shorebird_cli'
CORPORA = [('Wonderous', 'wonderous'), ('LocalSend', 'localsend')]


def window_map(work):
    return {l.strip()[:8]: l.strip()
            for l in open(os.path.join(work, 'window.txt')) if l.strip()}


def run(work, real, pair, target):
    base_p, cand_p = pair.split('_')
    wm = window_map(work)
    base, cand = wm[base_p], wm[cand_p]
    man = f'{real}/manifest13/{base_p}.manifest.json'
    imps = [f for f in os.listdir(f'{real}/import')
            if f.startswith(base_p) and f.endswith('.import.dill')]
    lock = {l.split()[0]: l.split()[1]
            for l in open(os.path.join(work, 'lockgroups.txt')) if l.strip()}
    # The producer reads the body's source from span.fileUri, which points into
    # the worktree -- so the worktree must be AT THE CANDIDATE, exactly as the
    # frozen replay does. Replaying at the base reads RELEASE text against
    # CANDIDATE spans and yields refusals that describe the harness.
    wt = f'{real}/wt'
    subprocess.run(['git', '-C', wt, 'checkout', '--quiet', '--force',
                    '--detach', cand], check=True)
    pkg = f'{real}/pkgcfg/{lock[cand]}/package_config.json'
    dst = f'{wt}/.dart_tool/package_config.json'
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(pkg):
        subprocess.run(['cp', pkg, dst], check=False)
    cmd = ['dart', 'run', 'tool/demand_blocker_chain.dart',
           f'{real}/pairs13/{pair}.json', '--target', target,
           '--manifest', man,
           '--patched-kernel', f'{real}/dills/{cand}.dill',
           '--super-capable']
    if imps:
        cmd += ['--release-import', f'{real}/import/{imps[0]}']
    r = subprocess.run(cmd, cwd=CLI, capture_output=True, text=True)
    return r.stdout, r.returncode


def parse(out):
    rec = {'blockers': []}
    for line in out.splitlines():
        parts = line.split('\t')
        if parts[0] == 'BLOCKER' and len(parts) >= 4:
            rec['blockers'].append({'i': int(parts[1]), 'relaxed': parts[2],
                                    'reason': parts[3]})
        elif len(parts) >= 2:
            rec[parts[0].lower()] = parts[1]
    return rec


def main():
    out = {}
    for label, app in CORPORA:
        real = f'/Volumes/build/route-b/demand1/{app}'
        work = f'/Volumes/build/route-b/demand1/d3/{app}'
        a = analyse(work, label)
        refused_map, _, seen = load_producer(work)
        obs = [o for o in a['obs'] if o['pair'] in seen]
        rows = []
        for o in obs:
            refused = (not o['admissible']) or o['target'] in refused_map
            if not refused:
                continue
            stdout, rc = run(work, real, o['pair'], o['target'])
            rec = parse(stdout)
            rec.update(pair=o['pair'], target=o['target'],
                       analyzer_admissible=o['admissible'],
                       analyzer_cats=sorted(o['cats']),
                       origin=(o['origin'] if isinstance(o['origin'], str)
                               else {k: v for k, v in o['origin'].items()}),
                       producer_first=refused_map.get(o['target']),
                       rc=rc)
            rows.append(rec)
            print(f"  {label} {o['target'].split('#')[-1][:40]:42s} "
                  f"blockers={len(rec['blockers'])} admitted={rec.get('admitted')}",
                  flush=True)
        out[label] = rows
    with open('/Volumes/build/route-b/demand1/chains.json', 'w') as fh:
        json.dump(out, fh, indent=1)
    print('==> /Volumes/build/route-b/demand1/chains.json')


main()
