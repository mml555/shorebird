#!/usr/bin/env python3
"""D-DEMAND-1 helper. Recovers the SOURCE shape of each super site in a changed
method, at the commit that introduced it.

WHY IT IS NOT READ FROM THE KERNEL. The kernels are `--aot --tfa`, as releases
are, and TFA rewrites argument counts -- which is why analysisVersion 10/11
refuse to report an arity at all. Shape is a SOURCE fact, and the product has
one fail-closed reader for it.

WHY IT IS NOT READ FROM THE WORKING TREE. The harness reuses ONE worktree and
checks out each commit in turn, so by the time the pairs are analysed the tree
is at some other commit and the census rows' `fileUri` no longer points at the
source that was compiled. Reading it now would classify the wrong text. The
source is therefore extracted from git by commit, `git show <sha>:<path>`, so
each site is classified against the bytes that actually produced it.
"""
import argparse
import json
import os
import re
import subprocess
import sys


def package_roots(package_config_path):
    """package name -> absolute directory its `package:` uris resolve against."""
    cfg = json.load(open(package_config_path))
    base = os.path.dirname(os.path.abspath(package_config_path))
    roots = {}
    for p in cfg['packages']:
        root = p['rootUri']
        if root.startswith('file://'):
            root = root[len('file://'):]
        elif not root.startswith('/'):
            root = os.path.normpath(os.path.join(base, root))
        pkg = p.get('packageUri', 'lib/')
        roots[p['name']] = os.path.normpath(os.path.join(root, pkg))
    return roots


def uri_to_repo_path(uri, roots, repo):
    """`package:wonders/a//b.dart` -> path relative to the repo, or None."""
    m = re.match(r'^package:([^/]+)/(.*)$', uri)
    if not m:
        return None
    name, rest = m.group(1), re.sub(r'/+', '/', m.group(2))
    root = roots.get(name)
    if not root:
        return None
    absolute = os.path.normpath(os.path.join(root, rest))
    repo = os.path.normpath(os.path.abspath(repo))
    if not absolute.startswith(repo + os.sep):
        return None
    return absolute[len(repo) + 1:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--work', required=True)
    ap.add_argument('--repo', required=True)
    ap.add_argument('--dart', required=True, help='dart to run the shape tool')
    ap.add_argument('--tool-dir', required=True, help='packages/shorebird_cli')
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    roots = package_roots(os.path.join(args.work, 'frozen_package_config.json'))
    full = [l.strip() for l in open(os.path.join(args.work, 'window.txt')) if l.strip()]
    by_prefix = {s[:8]: s for s in full}

    cache = os.path.join(args.work, 'srccache')
    os.makedirs(cache, exist_ok=True)
    rows, missing = [], []

    pairs_dir = os.path.join(args.work, 'pairs')
    for name in sorted(os.listdir(pairs_dir)):
        if not name.endswith('.json'):
            continue
        cand = by_prefix.get(name[:-5].split('_')[1])
        if not cand:
            continue
        doc = json.load(open(os.path.join(pairs_dir, name)))
        for target in doc.get('changed', []):
            low = (doc.get('lowering') or {}).get(target) or {}
            sites = low.get('superInvocations') or []
            if not sites:
                continue
            uri = target.split('#', 1)[0]
            rel = uri_to_repo_path(uri, roots, args.repo)
            if rel is None:
                missing.append((cand, target, 'uri_unmapped'))
                continue
            dest = os.path.join(cache, cand, rel)
            if not os.path.exists(dest):
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                r = subprocess.run(['git', '-C', args.repo, 'show', f'{cand}:{rel}'],
                                   capture_output=True)
                if r.returncode != 0:
                    missing.append((cand, target, 'git_show_failed'))
                    continue
                open(dest, 'wb').write(r.stdout)
            rows.append({
                'commit': cand,
                'target': target,
                'fileUri': 'file://' + dest,
                'superSites': [dict(s) for s in sites],
            })

    tmp_in = os.path.join(args.work, 'shapes.in.jsonl')
    tmp_out = os.path.join(args.work, 'shapes.out.jsonl')
    with open(tmp_in, 'w') as fh:
        fh.write(json.dumps({'header': 'demand-shapes'}) + '\n')
        for r in rows:
            fh.write(json.dumps(r) + '\n')

    if rows:
        proc = subprocess.run(
            [args.dart, 'run', 'tool/census_super_shape.dart', tmp_in, tmp_out],
            cwd=args.tool_dir, capture_output=True, text=True)
        if proc.returncode != 0:
            print(proc.stdout[-2000:], proc.stderr[-2000:], file=sys.stderr)
            sys.exit('shape tool failed')
        print(proc.stderr.strip(), file=sys.stderr)
        shaped = [json.loads(l) for l in open(tmp_out)][1:]
    else:
        shaped = []

    out = {}
    for r in shaped:
        for s in r['superSites']:
            out[f"{r['commit']}|{r['target']}|{s['offset']}"] = s.get('sourceArgs')
    json.dump({'shapes': out,
               'unmapped': [{'commit': c, 'target': t, 'why': w}
                            for c, t, w in missing]},
              open(args.out, 'w'), indent=1)
    print(f'  shapes: {len(out)}   unmapped: {len(missing)}')


if __name__ == '__main__':
    main()
