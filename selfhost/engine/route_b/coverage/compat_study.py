#!/usr/bin/env python3
"""compat_study.py -- what fraction of REAL changes can Route B patch, and why not.

Measures; does not interpret. Every row keeps the analyzer's verbatim output
alongside the study's normalized category, and the two are never merged: if the
taxonomy changes, rows are reclassified from `raw` without recompiling a single
kernel. That separation is the whole reason this is a script and not a
spreadsheet.

The analyzer is FROZEN at v6 for the duration. A row whose analysis reports a
different version is refused rather than recorded, so a rebuild in another
session cannot move the thing being measured underneath the corpus.

Compiles reproduce the RELEASE's own order -- prepass, then the dynamic
interface, then base and patched against that interface. Skipping the interface
measures a compilation no release performs: `--aot` eliminates a parameter only
ever passed a constant, which already cost this repo one wrong conclusion.

  compat_study.py --source app --repo <path> --entry lib/main.dart \
      --target flutter --count 5 --jobs 3 --out rows.jsonl
"""
import argparse, concurrent.futures, json, os, pathlib, queue, re, subprocess, sys, time

SRC = os.environ.get('SRC', '/Volumes/build/route-b/flutter/engine/src')
OUT = os.environ.get('OUT', f'{SRC}/out/host_release_arm64')
DART_TREE = f'{SRC}/flutter/third_party/dart'
DART = f'{OUT}/dart-sdk/bin/dart'
GEN_KERNEL = f'{DART_TREE}/pkg/vm/bin/gen_kernel.dart'
KERNEL_PKGS = f'--packages={DART_TREE}/.dart_tool/package_config.json'
RB = pathlib.Path(__file__).resolve().parent.parent
CELL_HASH = 'aa9155840d6c1e71b015bbcff1e06eaea7e73e17'
CELL = pathlib.Path.home() / '.shorebird/bin/cache/artifacts/route-b-compiler' / CELL_HASH
FROZEN_VERSION = 6

# --- classification -------------------------------------------------------
#
# EXACT MATCH ONLY, against the closed set of strings analyze_coverage.dart can
# emit. Anything unmatched stays `other` and is printed; a classifier that
# quietly folds the unrecognized into a known bin is how a study reports
# confidence it has not earned.
#
# policy:
#   architectural  Route B cannot do this under the replacement model at all
#   deliberate     could be built; decided not to (see ROUTE_B.md, frozen surface)
#   not-yet        no decision, simply unbuilt
LOWERING_RULES = [
    (re.compile(r'^reads the private member '), 'private-app-member', 'architectural'),
    (re.compile(r'^assigns to the private member '), 'private-app-member', 'architectural'),
    (re.compile(r'^calls the private member '), 'private-app-member', 'architectural'),
    (re.compile(r'^reads `super\.'), 'super', 'deliberate'),
    (re.compile(r'^calls `super\.'), 'super', 'deliberate'),
    (re.compile(r'^assigns to `super\.'), 'super', 'deliberate'),
    (re.compile(r'^reads and writes .* in one expression'), 'compound-write', 'deliberate'),
    # Cascades land here too: `this..foo()` produces this exact string and is
    # NOT distinguishable from `this` being captured, passed or stored. Recorded
    # as one bucket because that is what the analyzer actually says.
    (re.compile(r'^uses `this` other than to read a member$'), 'this-escape', 'deliberate'),
    (re.compile(r'^invokes the getter .* on the receiver$'), 'getter-invocation', 'not-yet'),
    (re.compile(r'^the method is generic$'), 'signature-arity', 'architectural'),
    (re.compile(r'^the method takes parameters'), 'signature-arity', 'architectural'),
    (re.compile(r'^is the receiver$'), 'this-escape', 'deliberate'),
]
# The analyzer labels these itself, so they need no string matching.
REJECTION_CATEGORY = {
    'added': ('added-member', 'architectural'),
    'unreachable': ('unreachable', 'architectural'),
    'unknown': ('dispatch-table-unknown', 'not-yet'),
}


def classify(raw):
    for pattern, category, policy in LOWERING_RULES:
        if pattern.search(raw):
            return category, policy
    return 'other', 'unclassified'


# --- corpus selection -----------------------------------------------------
#
# Pre-registered and mechanical. Nothing inspects a diff's CONTENT before
# selecting it; the funnel is returned so every exclusion is visible.
EXCLUDE_FILE = re.compile(
    r'(_test\.dart$|\.g\.dart$|\.freezed\.dart$|\.mocks\.dart$'
    r'|/generated_|/l10n/|^test/|/test/)')
EXCLUDE_TOUCH = re.compile(
    r'^(pubspec\.(yaml|lock)|ios/|android/|macos/|windows/|linux/|assets/)'
    r'|/pubspec\.(yaml|lock)$|/(ios|android|macos|windows|linux|assets)/')
MAX_LINES = 200


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args],
                          capture_output=True, text=True).stdout


def select(repo, source_glob, count, exclude_path=None):
    funnel = {}
    commits = git(repo, 'log', '--no-merges', '--format=%H', '--', source_glob).split()
    funnel['touching Dart under the source root, no merges'] = len(commits)

    kept = []
    dropped_touch = dropped_generated = dropped_large = dropped_self = 0
    selfre = re.compile(exclude_path) if exclude_path else None
    for c in commits:
        files = [f for f in git(repo, 'show', '--name-only', '--format=', c).split('\n') if f]
        if selfre and any(selfre.search(f) for f in files):
            dropped_self += 1
            continue
        if any(EXCLUDE_TOUCH.search(f) for f in files):
            dropped_touch += 1
            continue
        dart = [f for f in files if f.endswith('.dart') and not EXCLUDE_FILE.search(f)]
        if not dart:
            dropped_generated += 1
            continue
        stat = git(repo, 'show', '--numstat', '--format=', c)
        churn = 0
        for line in stat.strip().split('\n'):
            parts = line.split('\t')
            if len(parts) == 3 and parts[2].endswith('.dart') and not EXCLUDE_FILE.search(parts[2]):
                for n in parts[:2]:
                    churn += int(n) if n.isdigit() else 0
        if churn > MAX_LINES:
            dropped_large += 1
            continue
        parent = git(repo, 'rev-parse', f'{c}^').strip()
        if not parent:
            continue
        kept.append({'commit': c, 'parent': parent, 'files': dart, 'churn': churn,
                     'subject': git(repo, 'log', '-1', '--format=%s', c).strip(),
                     'date': git(repo, 'log', '-1', '--format=%cI', c).strip()})
        if len(kept) >= count:
            break

    if exclude_path:
        funnel[f'dropped: matches --exclude-path {exclude_path}'] = dropped_self
    funnel['dropped: touches pubspec/native/assets'] = dropped_touch
    funnel['dropped: only generated or test Dart'] = dropped_generated
    funnel[f'dropped: over {MAX_LINES} changed Dart lines'] = dropped_large
    funnel['selected'] = len(kept)
    return kept, funnel


# --- one case -------------------------------------------------------------
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


def run_case(case, worktree, repo, entry, target, workdir, source):
    tag = case['commit'][:10]
    d = pathlib.Path(workdir) / f'{source}-{tag}'
    d.mkdir(parents=True, exist_ok=True)
    row = {'source': source, 'cell': CELL_HASH, **{k: case[k] for k in
           ('commit', 'parent', 'subject', 'date', 'churn')},
           'files': case['files'], 'compile': 'ok'}
    t0 = time.time()

    def checkout(rev):
        # -f, AND VERIFIED. `flutter pub get` rewrites the tracked pubspec.lock,
        # which makes a plain checkout refuse -- and the pilot showed that an
        # unchecked failure is indistinguishable from a real result: both
        # compiles run on the same tree, the dills are identical, and the
        # analyzer honestly reports `inert`. Four of five app cases looked like
        # a finding about Flutter and were a bug here.
        subprocess.run(['git', '-C', worktree, 'checkout', '--detach', '-q', '-f', rev],
                       capture_output=True)
        at = subprocess.run(['git', '-C', worktree, 'rev-parse', 'HEAD'],
                            capture_output=True, text=True).stdout.strip()
        if at != rev:
            raise RuntimeError(f'checkout of {rev[:10]} left the worktree at {at[:10]}')

    try:
        checkout(case['parent'])
    except RuntimeError as e:
        row.update(compile='checkout_failed', error=str(e))
        return row
    ok, err = compile_kernel(worktree, entry, d / 'prepass.dill', target)
    if not ok:
        row.update(compile='prepass_failed', error=err)
        return row
    subprocess.run([DART, KERNEL_PKGS, str(RB / 'gen_dynamic_interface.dart'),
                    '--dill', str(d / 'prepass.dill'), '--out', str(d / 'di.yaml'),
                    '--sdk-members', 'dart:core#print'],
                   capture_output=True, text=True)
    if not (d / 'di.yaml').exists():
        row.update(compile='interface_failed')
        return row
    ok, err = compile_kernel(worktree, entry, d / 'base.dill', target, d / 'di.yaml')
    if not ok:
        row.update(compile='base_failed', error=err)
        return row

    try:
        checkout(case['commit'])
    except RuntimeError as e:
        row.update(compile='checkout_failed', error=str(e))
        return row
    ok, err = compile_kernel(worktree, entry, d / 'patched.dill', target, d / 'di.yaml')
    if not ok:
        row.update(compile='patched_failed', error=err)
        return row

    # A harness failure must never be able to masquerade as `inert`. If the two
    # kernels are byte-identical the checkout did not take, whatever git said.
    import hashlib
    def digest(path):
        return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    if digest(d / 'base.dill') == digest(d / 'patched.dill'):
        row.update(compile='identical_kernels',
                   error='base and patched compiled to the same bytes; the '
                         'change is not in the compiled program, or the '
                         'checkout did not take')
        return row

    r = subprocess.run([f'{OUT}/dartaotruntime', str(CELL / 'route_b_analyze.aot'),
                        '--base-dill', str(d / 'base.dill'),
                        '--patched-dill', str(d / 'patched.dill'),
                        '--out', str(d / 'analysis.json')],
                       capture_output=True, text=True)
    if not (d / 'analysis.json').exists():
        row.update(compile='analyze_failed', error=(r.stderr or r.stdout)[-800:])
        return row

    raw = json.loads((d / 'analysis.json').read_text())
    if raw.get('analysisVersion') != FROZEN_VERSION:
        raise SystemExit(f'FROZEN VIOLATION: analysis reports v{raw.get("analysisVersion")}, '
                         f'study is pinned to v{FROZEN_VERSION}. Nothing recorded.')

    # RAW IS KEPT WHOLE AND NEVER OVERWRITTEN. Everything below is derived.
    row['raw'] = {k: raw.get(k) for k in
                  ('analysisVersion', 'verdict', 'changed', 'added', 'removed',
                   'patchable', 'conditional', 'unreachable', 'unknown',
                   'rejections', 'lowering', 'refusalSummary')}
    row['raw_path'] = str(d / 'analysis.json')

    blockers = []
    for rej in raw.get('rejections') or []:
        cat, pol = REJECTION_CATEGORY.get(rej.get('category'), ('other', 'unclassified'))
        blockers.append({'target': rej.get('target'), 'raw': rej.get('reason'),
                         'raw_category': rej.get('category'), 'category': cat, 'policy': pol})
    for target, low in (raw.get('lowering') or {}).items():
        for reason in low.get('unsupported') or []:
            cat, pol = classify(reason)
            blockers.append({'target': target, 'raw': reason,
                             'raw_category': 'lowering', 'category': cat, 'policy': pol})
    for target in raw.get('removed') or []:
        blockers.append({'target': target, 'raw': 'member removed by the change',
                         'raw_category': 'removed', 'category': 'removed-member',
                         'policy': 'architectural'})

    # THE VERDICT IS NOT PUBLISHABILITY. Measured in the pilot: the analyzer can
    # return `accept` for a patch the PRODUCER then refuses, because the verdict
    # is computed from unreachable/unknown/added targets only and does not
    # consider whether a representable target can actually be lowered. The
    # product is still safe -- the producer throws and the whole patch is
    # refused -- but it refuses later, with a different reason than the coverage
    # summary gives, and a study that trusted the verdict would overstate
    # acceptance.
    #
    # Publishable therefore means: the verdict accepts AND every target the
    # producer would emit can be lowered.
    emit = set(raw.get('patchable') or []) | set(raw.get('conditional') or [])
    representable = len(emit)
    unlowerable = {t for t, low in (raw.get('lowering') or {}).items()
                   if t in emit and (low.get('unsupported') or [])}
    accepted = raw.get('verdict') == 'accept' and not unlowerable
    row['verdict_accepts'] = raw.get('verdict') == 'accept'
    row['unlowerable_emit_targets'] = sorted(unlowerable)
    cats = sorted({b['category'] for b in blockers})
    row.update(
        verdict=raw.get('verdict'),
        patch_accepted=accepted,
        targets={'changed': len(raw.get('changed') or []),
                 'added': len(raw.get('added') or []),
                 'removed': len(raw.get('removed') or []),
                 'representable': representable,
                 'unreachable': len(raw.get('unreachable') or []),
                 'unknown': len(raw.get('unknown') or [])},
        blockers=blockers,
        blocking_categories=cats,
        # Only when it is MECHANICALLY determinable. Several independent causes
        # do not get a winner chosen for them.
        primary_blocker=(cats[0] if len(cats) == 1 else None),
        # Rejected while at least one target WAS representable and lowerable:
        # the whole-patch refusal cost something that could have shipped.
        blocked_by_one=(not accepted and (representable - len(unlowerable)) > 0),
        seconds=round(time.time() - t0, 1),
    )
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', required=True)
    ap.add_argument('--repo', required=True)
    ap.add_argument('--entry', required=True)
    ap.add_argument('--glob', required=True)
    ap.add_argument('--exclude-path', default=None,
                    help='regex of paths whose commits are excluded; used to keep '
                         'Route B\'s own source out of its corpus')
    ap.add_argument('--target', default='vm')
    ap.add_argument('--count', type=int, default=5)
    ap.add_argument('--jobs', type=int, default=1)
    ap.add_argument('--worktrees', nargs='+', required=True)
    ap.add_argument('--workdir', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()

    cases, funnel = select(a.repo, a.glob, a.count, a.exclude_path)
    print(f'--- {a.source}: selection funnel')
    for k, v in funnel.items():
        print(f'    {v:>6}  {k}')
    if not cases:
        sys.exit('no cases selected')

    # A worktree is LEASED, not assigned by index. Two cases sharing one
    # worktree concurrently would check out over each other -- the flakiness
    # would look like compile failure and be blamed on the corpus.
    if a.jobs > len(a.worktrees):
        sys.exit(f'--jobs {a.jobs} exceeds {len(a.worktrees)} worktrees')
    pool_wt = queue.Queue()
    for wt in a.worktrees:
        pool_wt.put(wt)

    def leased(case):
        wt = pool_wt.get()
        try:
            return run_case(case, wt, a.repo, a.entry, a.target, a.workdir, a.source)
        finally:
            pool_wt.put(wt)

    rows = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        futures = {pool.submit(leased, c): c for c in cases}
        for f in concurrent.futures.as_completed(futures):
            row = f.result()
            rows.append(row)
            print(f"    {row['commit'][:10]}  {row.get('compile'):15} "
                  f"{str(row.get('verdict')):8} {row.get('seconds', '')}s  "
                  f"{row['subject'][:52]}")

    with open(a.out, 'a') as fh:
        for row in rows:
            fh.write(json.dumps(row) + '\n')
    print(f'--- wrote {len(rows)} rows to {a.out}')


if __name__ == '__main__':
    main()
