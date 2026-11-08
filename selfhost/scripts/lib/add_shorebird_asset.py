#!/usr/bin/env python3
"""Add `shorebird.yaml` to a pubspec's flutter assets, the way `shorebird init`
does.

Exists because a harness that writes only `shorebird.yaml` is refused by
`ShorebirdYamlAssetValidator` -- and a run that fails there has measured the
harness, not the thing under test.
"""
import sys

path = sys.argv[1]
lines = open(path).read().split('\n')
if any('shorebird.yaml' in l for l in lines):
    print('  shorebird.yaml already a flutter asset')
    sys.exit(0)
out, done = [], False
for line in lines:
    out.append(line)
    if not done and line.rstrip() == 'flutter:':
        out.append('  assets:')
        out.append('    - shorebird.yaml')
        done = True
if not done:
    out += ['flutter:', '  assets:', '    - shorebird.yaml']
    done = True
open(path, 'w').write('\n'.join(out))
print('  added shorebird.yaml to flutter assets')
