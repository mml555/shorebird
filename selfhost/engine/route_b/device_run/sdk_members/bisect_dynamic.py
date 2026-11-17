#!/usr/bin/env python3
# cspell:words killpg validat
"""bisect_dynamic.py <out.txt>

A patch that calls a member by NAME (a `dynamic` receiver) makes the patch build keep every
framework member of that name, and the CLI then refuses the whole patch ("N changed members cannot
be carried": the release tree-shook them). This finds which dynamic selectors cause that, by
dry-run patches of the generated app (needs $DEVRUN_ENV and a release made by release_probe.sh).
Writes the culprit selectors (one per line); the rest go into the patch.
"""
import os, re, subprocess, sys, time

R = os.environ['R']
HERE = os.path.dirname(os.path.abspath(__file__))
probes = [l.rstrip('\n').split('\t') for l in open(f'{R}/gen/probes.tsv')]
plain = lambda s: re.sub(r'^(get:|set:|tearoff:)', '', s)
known = set(filter(None, os.environ.get('BISECT_KNOWN', '').split(',')))  # culprits of earlier rounds
sels = sorted({plain(p[4]) for p in probes if 'dynamic' in p[3]} - known)
LOCK = os.path.expanduser('~/Developer/shorebird-wt/tmp/heavy.lock')
runs = 0


def refused(include):
    """True when a patch with only `include` selectors' dynamic probes is refused."""
    global runs
    runs += 1
    excl = ','.join([s for s in sels if s not in include] + sorted(known))
    g = f'{R}/gen_b'
    env = dict(os.environ, PATCH_EXCLUDE_DYNAMIC=excl, **({} if os.environ.get('BISECT_WITH_STATIC') else {'PATCH_ONLY_DYNAMIC': '1'}))
    subprocess.run([sys.executable, '-I', f'{HERE}/gen_device_probe.py', g], env=env, check=True, capture_output=True)
    while True:
        try:
            os.mkdir(LOCK); break
        except FileExistsError:
            time.sleep(10)
    try:
        app = f'{R}/work/untab'
        open(f'{app}/lib/main.dart', 'w').write(open(f'{g}/main_patched.dart').read())
        sh = (f'cd {app} && export PATH="$CLI/bin:$PATH" && nice -n 10 $SB patch ios --release-version $VERSION '
              f'--no-codesign --no-confirm --dry-run -v > {R}/logs/bisect_{runs}.log 2>&1')
        pr = subprocess.Popen(['bash', '-c', sh], env=os.environ, start_new_session=True)
        lg = f'{R}/logs/bisect_{runs}.log'
        while pr.poll() is None:
            time.sleep(3)
            # the refusal gates run before the first replacement body is compiled
            if os.path.exists(lg) and 'compiled p_' in open(lg, errors='replace').read():
                os.killpg(pr.pid, 15)
                time.sleep(3)
                break
        open(f'{app}/lib/main.dart', 'w').write(open(f'{R}/gen/main_release.dart').read())
    finally:
        os.rmdir(LOCK)
    log = open(f'{R}/logs/bisect_{runs}.log', errors='replace').read()
    bad = 'The whole patch is refused' in log or 'cannot be built' in log
    ok = 'dry' in log.lower() or 'Would' in log or 'validat' in log.lower()
    print(f'run {runs}: {len(include)} selectors -> {"REFUSED" if bad else "ok"}', flush=True)
    if not bad and 'Exited with code' in log and 'exit=' not in log:
        pass
    return bad


def find(s):
    if not refused(set(s)):
        return []
    if len(s) == 1:
        return list(s)
    m = len(s) // 2
    return find(s[:m]) + find(s[m:])


# static probes alone were accepted by the CLI (a full dry run reached the compile step)
bad = find(sels)
open(sys.argv[1], 'w').write(''.join(f'{b}\n' for b in bad))
rest = [s for s in sels if s not in bad]
print('culprits', bad, '\nfinal check with all others:', 'REFUSED' if refused(set(rest)) else 'ok', flush=True)
