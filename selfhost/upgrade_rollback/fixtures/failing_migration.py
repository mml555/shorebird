#!/usr/bin/env python3
"""Turn a COPY of packages/code_push_server into a successor whose migration
STARTS and then FAILS, for UPGRADE-ROLLBACK-1's failed-upgrade arm.

Migration 13 is two statements: one that must succeed, then one that must
fail. Whether the first survives is the whole question, and it is not the same
question on both backends -- SQLite and Postgres both claim transactional DDL,
but "claims" is not "measured", and the supported recovery contract depends on
the answer. If partial DDL can survive, retrying the upgrade is not a safe
instruction and the contract has to be "old image + pre-upgrade backup".

`probe_col` is the witness: present afterwards means the failed migration left
schema behind.
"""
import sys, pathlib

PROBE = 'ur1_failed_migration_probe'

def main(root: str) -> int:
    p = pathlib.Path(root) / 'lib' / 'src' / 'repository.dart'
    s = p.read_text()
    lines = s.split('\n')
    start = next(i for i, l in enumerate(lines) if '_migrations => [' in l)
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == '  ];')
    lines[end:end] = [
        '    // UPGRADE-ROLLBACK-1 fixture. NOT a shipped migration.',
        '    (',
        '      13,',
        '      [',
        f"        'ALTER TABLE channel_patches ADD COLUMN {PROBE} TEXT',",
        "        'ALTER TABLE ur1_no_such_table ADD COLUMN boom TEXT',",
        '      ],',
        '    ),',
    ]
    p.write_text('\n'.join(lines))
    print(f'applied: migration 13 adds {PROBE} then fails on a missing table')
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else '.'))
