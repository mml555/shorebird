#!/usr/bin/env python3
"""Edit the files that name a hash, for one engine and its cell.

  cell_edits.py derive <Caddyfile>
      Print the one hash that ends every protection group. Exit 1 when the
      groups end in different hashes or there are not exactly four of them.

  cell_edits.py protect <cdn dir> <prev> <hash>=<label> [<hash>=<label> ...] [--dry-run]
      Append each hash after <prev> in the four Caddyfile groups and in the three
      lists of check_protection_matchers.py. A hash already in the Caddyfile is
      skipped. Hashes are added in the order given, each after the one before.

  cell_edits.py dart-compat <dart_sdk_compatibility.dart> <dart> <hash>=<comment> ... [--dry-run]
      Add '<hash8>': '<dart8>' to expectedDartSdkRevisions.

Runs on the Mac and on ci-build (python3 only, no packages).
"""
import re
import sys
from pathlib import Path

GROUPS = 4  # Caddyfile protection groups that end in the newest hash
CHECKER_LISTS = 3  # lists in check_protection_matchers.py that carry it
TAIL = re.compile(r'([0-9a-f]{40})\)')
HASH = re.compile(r'^[0-9a-f]{40}$')


def die(msg):
    sys.exit('STOP: ' + msg)


def derive(caddyfile):
    tails = TAIL.findall(Path(caddyfile).read_text())
    if len(tails) != GROUPS or len(set(tails)) != 1:
        counts = {h: tails.count(h) for h in sorted(set(tails))}
        die('Caddyfile groups are ambiguous: expected %d groups ending in one hash, found %s. Set PREV=<hash> after fixing the file.'
            % (GROUPS, counts))
    return tails[0]


def protect(cdn, prev, adds, dry):
    cdn = Path(cdn)
    cf, ck = cdn / 'Caddyfile', cdn / 'check_protection_matchers.py'
    s, lines = cf.read_text(), ck.read_text().splitlines(True)
    # Drop a hash line that repeats the line above it (an old engine install wrote some three times).
    dedup = []
    for l in lines:
        if dedup and l == dedup[-1] and re.match(r"\s*'[0-9a-f]{40}',", l):
            continue
        dedup.append(l)
    lines = dedup
    for new, label in adds:
        if new in s:
            in_checker = sum(1 for l in lines if l.strip().startswith("'%s'" % new))
            if in_checker != CHECKER_LISTS:
                die('Caddyfile names %s but check_protection_matchers.py has it %d times, not %d' % (new, in_checker, CHECKER_LISTS))
            print('already protected: %s' % new)
            prev = new
            continue
        tail = prev + ')'
        if s.count(tail) != GROUPS:
            die('expected %d Caddyfile groups ending %s, found %d (is PREV right?)' % (GROUPS, prev, s.count(tail)))
        isprev = lambda l: l.strip().startswith("'%s'" % prev)
        n = sum(map(isprev, lines))
        if n != CHECKER_LISTS:
            die('check_protection_matchers.py: expected %d lines for %s, found %d' % (CHECKER_LISTS, prev, n))
        out = []
        for l in lines:
            out.append(l)
            if isprev(l):
                out.append("    '%s',   # %s\n" % (new, label))
        lines = out
        s = s.replace(tail, prev + '|' + new + ')')
        print('protect: %s after %s' % (new, prev))
        prev = new
    if not dry:
        cf.write_text(s)
        ck.write_text(''.join(lines))


def dart_compat(path, dart, adds, dry):
    p = Path(path)
    s = p.read_text()
    m = re.search(r'(expectedDartSdkRevisions\s*=\s*<String,\s*String>\{)(.*?)(\n  \};)', s, re.S)
    if not m:
        die('expectedDartSdkRevisions not found in %s' % path)
    body, add = m.group(2), ''
    for h, comment in adds:
        key = "'%s'" % h[:8]
        if key in body:
            if "'%s'" % dart[:8] not in body.split(key, 1)[1].split('\n', 1)[0]:
                die('%s is already in %s with another Dart revision' % (key, path))
            print('already listed: %s' % key)
            continue
        if comment:
            add += '\n    // %s' % comment
        add += "\n    %s: '%s'," % (key, dart[:8])
        print('dart-compat: %s -> %s' % (key, dart[:8]))
    if add and not dry:
        p.write_text(s[:m.end(2)] + add + s[m.end(2):])


def pairs(args):
    out = []
    for a in args:
        h, _, label = a.partition('=')
        if not HASH.match(h):
            die('not a 40-hex hash: %s' % h)
        out.append((h, label))
    return out


def main(argv):
    dry = '--dry-run' in argv
    argv = [a for a in argv if a != '--dry-run']
    if len(argv) >= 2 and argv[0] == 'derive':
        print(derive(argv[1]))
    elif len(argv) >= 4 and argv[0] == 'protect':
        if not HASH.match(argv[2]):
            die('prev is not a 40-hex hash')
        protect(argv[1], argv[2], pairs(argv[3:]), dry)
    elif len(argv) >= 4 and argv[0] == 'dart-compat':
        dart_compat(argv[1], argv[2], pairs(argv[3:]), dry)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
