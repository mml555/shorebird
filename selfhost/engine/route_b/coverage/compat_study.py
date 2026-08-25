#!/usr/bin/env python3
"""compat_study.py -- what fraction of REAL changes can Route B patch, and why not.

Measures; does not interpret. Every row keeps the analyzer's verbatim output
beside the study's derived classification, and the two are never merged: when the
taxonomy changes -- it changed twice around Phase 0 -- rows are rederived by
`compat_reclassify.py` without recompiling a kernel.

The analyzer is FROZEN at v6. A row whose analysis reports a different version is
refused rather than recorded, so a rebuild in another session cannot move the
thing being measured underneath the corpus.

SELECTION IS DETERMINISTIC AND PRE-REGISTERED: every eligible commit is filtered
mechanically, the survivors are shuffled with a fixed seed, and the first N are
taken. Phase 0 took the most recent N and drew this session's own commits;
seeded sampling makes the corpus reproducible and stops recent local history
dominating it. The seed, the eligible-set hash, the funnel and the selection all
go to a manifest.

Compiles reproduce the RELEASE's own order -- prepass, then the dynamic
interface, then base and patched against that interface. Skipping the interface
measures a compilation no release performs.

  compat_study.py --source app --repo <path> --entry lib/main.dart \
      --glob 'lib/**/*.dart' --target flutter --count 50 --seed 20260811 \
      --jobs 3 --worktrees w1 w2 w3 --workdir W --out rows.jsonl \
      --manifest app.manifest.json
"""
import argparse, concurrent.futures, hashlib, json, os, pathlib, queue
import random, re, subprocess, sys, time

from compat_taxonomy import blockers_for, outcomes_for

SRC = os.environ.get('SRC', '/Volumes/build/route-b/flutter/engine/src')
OUT = os.environ.get('OUT', f'{SRC}/out/host_release_arm64')
DART_TREE = f'{SRC}/flutter/third_party/dart'
DART = f'{OUT}/dart-sdk/bin/dart'
GEN_KERNEL = f'{DART_TREE}/pkg/vm/bin/gen_kernel.dart'
KERNEL_PKGS = f'--packages={DART_TREE}/.dart_tool/package_config.json'
RB = pathlib.Path(__file__).resolve().parent.parent
# BASELINE A. Frozen for the whole study; see COMPATIBILITY_STUDY.md.
# P1.5 runs against the cell that carries the member-only private capability
# model and the `dart:` CFE refusal. The ANALYZER did not move in that mint --
# `route_b_analyze.aot` is byte-identical (422dda43…) between 2c4443ce and this
# cell -- so analyzer verdicts stay comparable across the two, and FROZEN_VERSION
# below still holds. What moved is the interface generator and dart2bytecode,
# which is exactly what this phase is measuring the effect of.
CELL_HASH = '93a375665d637f999bbff028488301a510bb611e'
CELL = pathlib.Path.home() / '.shorebird/bin/cache/artifacts/route-b-compiler' / CELL_HASH
FROZEN_VERSION = 6

EXCLUDE_FILE = re.compile(
    r'(_test\.dart$|\.g\.dart$|\.freezed\.dart$|\.mocks\.dart$'
    r'|/generated_|/l10n/|^test/|/test/)')
EXCLUDE_TOUCH = re.compile(
    r'^(pubspec\.(yaml|lock)|ios/|android/|macos/|windows/|linux/|assets/)'
    r'|/pubspec\.(yaml|lock)$|/(ios|android|macos|windows|linux|assets)/')
MAX_LINES = 200
# The toolchain is pinned, so history is only eligible where it can be BUILT.
# Measured: 286 of the app's 400 most recent Dart-touching commits declare a
# Dart 2 constraint, which Dart 3.12.2 can never resolve. This is a real
# limitation on the corpus -- it restricts the population to the era the pinned
# toolchain supports -- and it is applied mechanically and reported in the
# funnel rather than left to fail as 100% compile errors.
PINNED_DART = (3, 12, 2)


def _ver(text):
    parts = re.findall(r'\d+', text)[:3]
    return tuple(int(x) for x in parts) + (0,) * (3 - len(parts))


def sdk_admits_pinned(constraint):
    c = (constraint or '').strip().strip('"\'')
    if not c:
        return False
    if c.startswith('^'):
        lo = _ver(c[1:])
        return lo <= PINNED_DART < (lo[0] + 1, 0, 0)
    lo = hi = None
    m = re.search(r'>=\s*([\d.]+)', c)
    if m:
        lo = _ver(m.group(1))
    m = re.search(r'<\s*([\d.]+)', c)
    if m:
        hi = _ver(m.group(1))
    if lo and PINNED_DART < lo:
        return False
    if hi and PINNED_DART >= hi:
        return False
    return lo is not None or hi is not None


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args],
                          capture_output=True, text=True).stdout


def eligible_commits(repo, source_glob):
    """One `git log` pass: commit, subject, date, and every file with its churn.

    Per-commit `git show` calls cost minutes over a thousand commits, and the
    whole eligible set has to be filtered before shuffling or the sample is not
    over the population it claims to be over.
    """
    # A unit separator, not NUL: git accepts either, but a NUL cannot be passed
    # in a subprocess argument at all.
    sep = '\x1f'
    raw = git(repo, 'log', '--no-merges', f'--format={sep}%H{sep}%s{sep}%cI',
              '--numstat', '--', source_glob)
    commits, cur = [], None
    for line in raw.split('\n'):
        if line.startswith(sep):
            _, sha, subject, date = line.split(sep, 3)
            cur = {'commit': sha, 'subject': subject, 'date': date, 'files': []}
            commits.append(cur)
        elif line.strip() and cur is not None:
            parts = line.split('\t')
            if len(parts) == 3:
                add, rem, path = parts
                cur['files'].append((path, int(add) if add.isdigit() else 0,
                                     int(rem) if rem.isdigit() else 0))
    return commits


def sdk_constraint_at(repo, commit, pubspec):
    blob = git(repo, 'show', f'{commit}:{pubspec}')
    grab = False
    for line in blob.split('\n'):
        if line.startswith('environment:'):
            grab = True
            continue
        if grab:
            if line.strip().startswith('sdk:'):
                return line.split('sdk:', 1)[1]
            if line and not line.startswith((' ', '\t')):
                break
    return ''


def select(repo, source_glob, count, seed, exclude_path=None, pubspec='pubspec.yaml',
           window=None):
    all_commits = eligible_commits(repo, source_glob)
    funnel = {'touching Dart under the source root, no merges': len(all_commits)}
    selfre = re.compile(exclude_path) if exclude_path else None

    kept = []
    dropped_self = dropped_touch = dropped_generated = dropped_large = 0
    dropped_sdk = 0
    for c in all_commits:
        paths = [f[0] for f in c['files']]
        if selfre and any(selfre.search(p) for p in paths):
            dropped_self += 1
            continue
        if any(EXCLUDE_TOUCH.search(p) for p in paths):
            dropped_touch += 1
            continue
        dart = [f for f in c['files']
                if f[0].endswith('.dart') and not EXCLUDE_FILE.search(f[0])]
        if not dart:
            dropped_generated += 1
            continue
        churn = sum(a + r for _, a, r in dart)
        if churn > MAX_LINES:
            dropped_large += 1
            continue
        if not sdk_admits_pinned(sdk_constraint_at(repo, c['commit'], pubspec)):
            dropped_sdk += 1
            continue
        kept.append({'commit': c['commit'], 'subject': c['subject'],
                     'date': c['date'], 'files': [f[0] for f in dart],
                     'churn': churn})

    if exclude_path:
        funnel[f'dropped: matches --exclude-path {exclude_path}'] = dropped_self
    funnel['dropped: touches pubspec/native/assets'] = dropped_touch
    funnel['dropped: only generated or test Dart'] = dropped_generated
    funnel[f'dropped: over {MAX_LINES} changed Dart lines'] = dropped_large
    funnel[f'dropped: sdk constraint excludes Dart {".".join(map(str, PINNED_DART))}'] = dropped_sdk
    funnel['eligible after filtering'] = len(kept)

    if window:
        # A declared BUILD-COMPATIBILITY WINDOW: the N most recent eligible
        # commits, sampled within. Historical trees stop building against a
        # pinned toolchain at some depth, and pretending otherwise yields 0
        # analysable cases. Narrowing the population is a stated limitation;
        # silently sampling a population that cannot be measured is not.
        kept = kept[:window]
        funnel[f'window: most recent {window} eligible'] = len(kept)

    # Deterministic: same seed and same eligible set give the same sample. The
    # eligible set is hashed so a later rerun can PROVE it sampled the same
    # population rather than asserting it.
    eligible_hash = hashlib.sha256(
        '\n'.join(c['commit'] for c in kept).encode()).hexdigest()
    shuffled = list(kept)
    random.Random(seed).shuffle(shuffled)
    chosen = shuffled[:count]
    funnel['selected by seeded shuffle'] = len(chosen)

    for c in chosen:
        c['parent'] = git(repo, 'rev-parse', f"{c['commit']}^").strip()
    chosen = [c for c in chosen if c['parent']]

    manifest = {'seed': seed, 'eligible_count': len(kept),
                'eligible_sha256': eligible_hash,
                'eligible_commits': [c['commit'] for c in kept],
                'selected': [c['commit'] for c in chosen],
                'funnel': funnel, 'exclude_path': exclude_path,
                'max_lines': MAX_LINES, 'glob': source_glob, 'window': window,
                'cell': CELL_HASH, 'analysis_version': FROZEN_VERSION,
                'pinned_dart': '.'.join(map(str, PINNED_DART)), 'pubspec': pubspec}
    return chosen, funnel, manifest


def compile_kernel(worktree, entry, out_path, target, interface=None):
    platform = (f'{CELL}/flutter_platform_strong.dill' if target == 'flutter'
                else f'{OUT}/vm_platform.dill')
    cmd = [DART, GEN_KERNEL, '--platform', platform, '--aot',
           '--packages', f'{worktree}/.dart_tool/package_config.json',
           '-o', str(out_path)]
    if target == 'flutter':
        cmd += ['--target', 'flutter']
    if interface:
        cmd += ['--dynamic-interface', str(interface)]
    cmd.append(entry)
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=worktree)
    return r.returncode == 0, (r.stderr or r.stdout)[-800:]


def digest(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def run_case(case, worktree, entry, target, workdir, source, pub_get=None,
             pub_get_dir='.', producer_commit='', model='revert-onto-head',
             head='', applicability_only=False):
    d = pathlib.Path(workdir) / f"{source}-{case['commit'][:10]}"
    d.mkdir(parents=True, exist_ok=True)
    row = {'source': source, 'cell': CELL_HASH, 'producer_commit': producer_commit,
           **{k: case[k] for k in ('commit', 'parent', 'subject', 'date', 'churn')},
           'files': case['files']}
    t0 = time.time()

    def checkout(rev):
        # -f, AND VERIFIED. `flutter pub get` rewrites the tracked pubspec.lock,
        # so a plain checkout refuses -- and an unchecked failure is
        # indistinguishable from a real result: both compiles run on the same
        # tree, the dills come out identical, and the analyzer honestly reports
        # `inert`. Four of five Phase 0 app cases looked like a finding about
        # Flutter and were a bug here.
        subprocess.run(['git', '-C', worktree, 'checkout', '--detach', '-q', '-f', rev],
                       capture_output=True)
        at = subprocess.run(['git', '-C', worktree, 'rev-parse', 'HEAD'],
                            capture_output=True, text=True).stdout.strip()
        if at != rev:
            raise RuntimeError(f'checkout of {rev[:10]} left the worktree at {at[:10]}')

    # THE CORPUS MODEL. `historical-trees` is kept runnable and named rather than
    # deleted, because it is the model this study started with and its failure is
    # a measured result: 286 of the app's 400 most recent Dart-touching commits
    # declare a Dart 2 constraint, and the survivors fail version solving anyway.
    # `revert-onto-head` is the decided model -- see COMPATIBILITY_STUDY.md,
    # "DECIDED 2026-08-25". base = HEAD with C reverted, patched = HEAD.
    row['model'] = model
    if model == 'revert-onto-head':
        try:
            checkout(head)
        except RuntimeError as e:
            return {**row, 'outcome': 'checkout-failed', 'error': str(e)}
        # Mechanical exclusion, reported rather than silently dropped: a commit
        # whose revert does not apply to today's tree is not in this corpus.
        rv = subprocess.run(
            ['git', '-C', worktree, 'revert', '--no-commit', case['commit']],
            capture_output=True, text=True)
        if rv.returncode != 0:
            subprocess.run(['git', '-C', worktree, 'revert', '--abort'],
                           capture_output=True)
            subprocess.run(['git', '-C', worktree, 'checkout', '-f', '-q', head],
                           capture_output=True)
            return {**row, 'outcome': 'revert-does-not-apply',
                    'error': (rv.stderr or rv.stdout)[-400:]}
    else:
        try:
            checkout(case['parent'])
        except RuntimeError as e:
            return {**row, 'outcome': 'checkout-failed', 'error': str(e)}
    if pub_get:
        # Period-appropriate dependencies. HEAD's lockfile against year-old
        # source produces API errors that look like compile failures and are
        # really resolution drift.
        # In the package directory, not the worktree root: this fork's root has
        # no pubspec.yaml at older commits, because the workspace layout is
        # newer than much of the history. Running at the root there fails with
        # "Found no pubspec.yaml", which reads as a corpus problem and is not.
        r = subprocess.run(pub_get.split(), capture_output=True, text=True,
                           cwd=str(pathlib.Path(worktree) / pub_get_dir),
                           env={**os.environ,
                                'FLUTTER_STORAGE_BASE_URL':
                                'http://localhost:8085'})
        if r.returncode != 0:
            return {**row, 'outcome': 'dependency-resolution-failed',
                    'error': (r.stderr or r.stdout)[-500:]}
    # APPLICABILITY GATE. Stop here when that is all that was asked for: the
    # revert applied, which is the only thing this mode measures.
    if applicability_only:
        subprocess.run(['git', '-C', worktree, 'checkout', '-f', '-q', head],
                       capture_output=True)
        return {**row, 'outcome': 'revert-applies',
                'elapsed_s': round(time.time() - t0, 1)}

    ok, err = compile_kernel(worktree, entry, d / 'prepass.dill', target)
    if not ok:
        return {**row, 'outcome': 'toolchain-incompatible', 'stage': 'prepass',
                'error': err}

    # THE CELL'S generator, not the repo's source. The repo copy is live -- it
    # changed under this study on 2026-08-11 -- and using it would mean claiming
    # a frozen cell while running an unfrozen tool inside it. The cell ships
    # route_b_gen_dynamic_interface.aot precisely so this is pinned.
    subprocess.run([f'{OUT}/dartaotruntime',
                    str(CELL / 'route_b_gen_dynamic_interface.aot'),
                    '--dill', str(d / 'prepass.dill'), '--out', str(d / 'di.yaml'),
                    '--sdk-members', 'dart:core#print'], capture_output=True)
    if not (d / 'di.yaml').exists():
        return {**row, 'outcome': 'toolchain-incompatible', 'stage': 'interface'}

    ok, err = compile_kernel(worktree, entry, d / 'base.dill', target, d / 'di.yaml')
    if not ok:
        return {**row, 'outcome': 'toolchain-incompatible', 'stage': 'base',
                'error': err}

    # PATCHED. Under revert-onto-head that is plain HEAD, reached by discarding
    # the revert -- `checkout -f` restores the tree and clears the staged revert
    # in one step.
    try:
        checkout(head if model == 'revert-onto-head' else case['commit'])
    except RuntimeError as e:
        return {**row, 'outcome': 'checkout-failed', 'error': str(e)}
    ok, err = compile_kernel(worktree, entry, d / 'patched.dill', target, d / 'di.yaml')
    if not ok:
        return {**row, 'outcome': 'toolchain-incompatible', 'stage': 'patched',
                'error': err}

    # ITS OWN TERMINAL STATE, never acceptance or rejection: identical bytes mean
    # the change is not in the compiled program, or the checkout did not take.
    if digest(d / 'base.dill') == digest(d / 'patched.dill'):
        return {**row, 'outcome': 'identical-kernels',
                'error': 'base and patched compiled to the same bytes'}

    r = subprocess.run([f'{OUT}/dartaotruntime', str(CELL / 'route_b_analyze.aot'),
                        '--base-dill', str(d / 'base.dill'),
                        '--patched-dill', str(d / 'patched.dill'),
                        '--out', str(d / 'analysis.json')],
                       capture_output=True, text=True)
    if not (d / 'analysis.json').exists():
        return {**row, 'outcome': 'analyze-failed',
                'error': (r.stderr or r.stdout)[-800:]}

    raw = json.loads((d / 'analysis.json').read_text())
    if raw.get('analysisVersion') != FROZEN_VERSION:
        raise SystemExit(f'FROZEN VIOLATION: analysis reports '
                         f'v{raw.get("analysisVersion")}, study is pinned to '
                         f'v{FROZEN_VERSION}. Nothing recorded.')

    # RAW IS KEPT WHOLE AND NEVER OVERWRITTEN. Everything below is derived.
    row['raw'] = {k: raw.get(k) for k in
                  ('analysisVersion', 'verdict', 'changed', 'added', 'removed',
                   'patchable', 'conditional', 'unreachable', 'unknown',
                   'rejections', 'lowering', 'refusalSummary')}
    row['raw_path'] = str(d / 'analysis.json')

    blockers, _ = blockers_for(raw)
    row.update(outcomes_for(raw))
    cats = sorted({b['category'] for b in blockers})
    row.update(
        targets={'changed': len(raw.get('changed') or []),
                 'added': len(raw.get('added') or []),
                 'removed': len(raw.get('removed') or []),
                 'unreachable': len(raw.get('unreachable') or []),
                 'unknown': len(raw.get('unknown') or [])},
        blockers=blockers,
        blocking_categories=cats,
        blocking_policies=sorted({b['policy'] for b in blockers}),
        # Only when MECHANICALLY determinable. Several independent causes do not
        # get a winner chosen for them.
        primary_blocker=(cats[0] if len(cats) == 1 else None),
        # Otherwise-valid work killed by whole-patch refusal semantics.
        blocked_by_one=(not row['predicted_publishable']
                        and row['representable_and_lowerable'] > 0),
        seconds=round(time.time() - t0, 1),
    )
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', required=True)
    ap.add_argument('--repo', required=True)
    ap.add_argument('--entry', required=True)
    ap.add_argument('--glob', required=True)
    ap.add_argument('--exclude-path', default=None)
    ap.add_argument('--target', default='vm')
    ap.add_argument('--count', type=int, default=50)
    ap.add_argument('--seed', type=int, required=True)
    ap.add_argument('--jobs', type=int, default=1)
    ap.add_argument('--worktrees', nargs='+', required=True)
    ap.add_argument('--workdir', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--manifest', required=True)
    ap.add_argument('--pubspec', default='pubspec.yaml')
    ap.add_argument('--window', type=int, default=None,
                    help='restrict the population to the N most recent eligible '
                         'commits before sampling; a declared limitation')
    ap.add_argument('--pub-get', default=None)
    ap.add_argument('--producer-commit', required=True,
                    help='the pinned producer commit; recorded on every row so a '
                         'later baseline can be compared rather than confused')
    ap.add_argument('--applicability-only', action='store_true',
                    help='attempt ONLY the revert step and report the funnel. No '
                         'kernel, no interface, no analyzer -- so no run with '
                         'this flag can say anything about Route B blockers. '
                         'Exists because the exclusion rate is the cheap gate on '
                         'whether the corpus model is usable at all.')
    ap.add_argument('--model', default='revert-onto-head',
                    choices=['revert-onto-head', 'historical-trees'],
                    help='corpus model. revert-onto-head (decided 2026-08-25): '
                         'base = HEAD with C reverted, patched = HEAD. '
                         'historical-trees is the refuted original, kept '
                         'runnable because its failure is a measured result.')
    ap.add_argument('--head', default='',
                    help='the HEAD commit revert-onto-head rebases onto. '
                         'Recorded in the manifest so a run names the tree it '
                         'was evaluated against.')
    ap.add_argument('--pub-get-dir', default='.',
                    help='directory, relative to the worktree, to resolve in')
    a = ap.parse_args()

    # THE TREE EVERY CASE IS EVALUATED AGAINST, resolved once and recorded. Under
    # revert-onto-head the corpus is "diffs that still apply to THIS tree", so a
    # run that does not name the tree cannot be compared with another run.
    head = a.head or git(a.repo, 'rev-parse', 'HEAD').strip()

    cases, funnel, manifest = select(a.repo, a.glob, a.count, a.seed,
                                     a.exclude_path, a.pubspec, a.window)
    # Recorded beside the seed and the eligible-set digest, for the same reason
    # those are: a run that cannot say which model and which tree it used is not
    # comparable with any other run.
    manifest['corpus_model'] = a.model
    manifest['head'] = head
    print(f'--- {a.source}: selection funnel (seed {a.seed})')
    for k, v in funnel.items():
        print(f'    {v:>6}  {k}')
    print(f"    eligible sha256 {manifest['eligible_sha256'][:16]}")
    manifest['producer_commit'] = a.producer_commit
    pathlib.Path(a.manifest).write_text(json.dumps(manifest, indent=2))
    if not cases:
        sys.exit('no cases selected')

    if a.jobs > len(a.worktrees):
        sys.exit(f'--jobs {a.jobs} exceeds {len(a.worktrees)} worktrees')
    pool_wt = queue.Queue()
    for wt in a.worktrees:
        pool_wt.put(wt)

    def leased(case):
        # A worktree is LEASED, not assigned by index: two cases sharing one
        # concurrently would check out over each other, and the flakiness would
        # look like compile failure and be blamed on the corpus.
        wt = pool_wt.get()
        try:
            return run_case(case, wt, a.entry, a.target, a.workdir, a.source,
                            a.pub_get, a.pub_get_dir, a.producer_commit,
                            a.model, head, a.applicability_only)
        except Exception as e:                       # noqa: BLE001
            return {'source': a.source, 'commit': case['commit'],
                    'subject': case['subject'], 'outcome': 'harness-error',
                    'error': repr(e)}
        finally:
            pool_wt.put(wt)

    done = 0
    with open(a.out, 'a') as fh, \
            concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        for f in concurrent.futures.as_completed(
                [pool.submit(leased, c) for c in cases]):
            row = f.result()
            fh.write(json.dumps(row) + '\n')
            fh.flush()
            done += 1
            print(f"    [{done}/{len(cases)}] {row['commit'][:10]}  "
                  f"{row.get('outcome', '?'):18} {row.get('seconds', '')}s  "
                  f"{row.get('subject', '')[:44]}")
    print(f'--- wrote {done} rows to {a.out}')


if __name__ == '__main__':
    main()
