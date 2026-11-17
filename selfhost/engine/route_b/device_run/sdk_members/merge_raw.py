#!/usr/bin/env python3
# cspell:words SDKPROBE
"""merge_raw.py <run_dir> <out raw_results.tsv> [log glob under <run_dir>/logs ...]

With no globs it reads the counter run's logs (iter*.txt, sweepF.txt, sweepH.txt); the kept run passes
`iterK*.txt sweepK*.txt`.

Collects every `SDKPROBE RESULT <probe> <result>` line of the device sweep logs the run kept
(first result per probe wins; an aborted launch resumes in the next one, and the app keeps
its own results.tsv on the phone, so the lines are spread over several logs).
"""
import glob, re, sys
run, out = sys.argv[1:3]
globs = sys.argv[3:]
res = {}
files = ([f for g in globs for f in sorted(glob.glob(f'{run}/logs/{g}'))] if globs else
         sorted(glob.glob(f'{run}/logs/iter*.txt')) + [f'{run}/logs/sweepF.txt', f'{run}/logs/sweepH.txt'])
for f in files:
    try:
        lines = open(f, errors='replace')
    except OSError:
        continue
    for l in lines:
        m = re.match(r'SDKPROBE RESULT (\S+) (.*)', l.strip())
        if m and m[1] not in res:
            res[m[1]] = m[2]
open(out, 'w').write(''.join(f'{k}\t{v}\n' for k, v in res.items()))
print(len(res), 'results')
