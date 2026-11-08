#!/usr/bin/env python3
"""Turn a COPY of packages/code_push_server into a deliberately incompatible
successor, for UPGRADE-ROLLBACK-1's rollback proof.

Why a fixture and not a real migration: the point is to produce a schema the
PREVIOUS server binary cannot serve. Every migration this project actually
ships is additive, so an old binary survives them by accident -- which would
make a rollback test pass for the wrong reason. Manufacturing that break must
not pollute the permanent migration history, so it is applied to a scratch
source tree that is built, used, and thrown away.

The break: `channel_patches.rollout` is renamed. That column is read by
`patches/check` (rollout gating) and written by promote, so an old binary
running against this schema still boots and still answers /healthz while the
device update path fails -- the most dangerous shape, and the one worth
proving is refused.

Every edit is asserted. If the source has moved, this fails loudly rather than
silently producing a successor that is not actually incompatible.
"""
import sys, pathlib

NEW = 'rollout_percent'
EDITS = [
    # The runtime SQL. The v1 baseline CREATE TABLE deliberately keeps
    # `rollout`, so a fresh database is created the old way and then renamed by
    # migration 13 -- exactly as an upgraded database is.
    ("'SELECT c.name AS channel, cp.status, cp.rollout, cp.rolled_back '",
     f"'SELECT c.name AS channel, cp.status, cp.{NEW}, cp.rolled_back '"),
    ("'INSERT INTO channel_patches(channel_id, patch_id, status, rollout, rolled_back) '",
     f"'INSERT INTO channel_patches(channel_id, patch_id, status, {NEW}, rolled_back) '"),
    ("'UPDATE channel_patches SET rollout = @r WHERE channel_id = @c AND patch_id = @p AND status = @s',",
     f"'UPDATE channel_patches SET {NEW} = @r WHERE channel_id = @c AND patch_id = @p AND status = @s',"),
    # `SELECT *` feeds this mapper, so renaming the column in SQL is not
    # enough -- the map key moves with it. Missing this produced a successor
    # that applied the migration and then 500'd on its own device path, which
    # would have made the rollback negative meaningless.
    ("    rollout: _int(m['rollout']),",
     f"    rollout: _int(m['{NEW}']),"),
    # The other consumer of a renamed column: the deployment-state map built
    # from the query above. Aliasing the column back to `rollout` in SQL would
    # have hidden this, so the rename is carried through end to end instead.
    ("            'rollout': _int(m['rollout']),",
     f"            'rollout': _int(m['{NEW}']),"),
]

def main(root: str) -> int:
    p = pathlib.Path(root) / 'lib' / 'src' / 'repository.dart'
    s = p.read_text()

    for old, new in EDITS:
        if s.count(old) != 1:
            print(f'FIXTURE STALE: expected exactly one occurrence of:\n  {old}\n'
                  f'found {s.count(old)}', file=sys.stderr)
            return 1
        s = s.replace(old, new)

    # Append migration 13 to the list. Anchored on the list's closing bracket,
    # which is the line `  ];` that follows `_migrations => [`.
    lines = s.split('\n')
    start = next(i for i, l in enumerate(lines) if '_migrations => [' in l)
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == '  ];')
    lines[end:end] = [
        '    // UPGRADE-ROLLBACK-1 fixture. NOT a shipped migration.',
        '    (',
        '      13,',
        '      [',
        f"        'ALTER TABLE channel_patches RENAME COLUMN rollout TO {NEW}',",
        '      ],',
        '    ),',
    ]
    s = '\n'.join(lines)
    p.write_text(s)

    # Catch what is left, in both forms the column can appear in: SQL text and
    # a result-map key. A line-based SQL scan alone missed the map key, because
    # the `SELECT *` that produced the row is nowhere near the mapper.
    stale = []
    for i, l in enumerate(s.split('\n')):
        if NEW in l:
            continue
        if "m['rollout']" in l or 'm["rollout"]' in l:
            stale.append((i + 1, 'result-map key'))
        elif 'rollout' in l and any(k in l for k in ('SELECT', 'INSERT', 'UPDATE ', 'SET ')):
            stale.append((i + 1, 'SQL text'))
    if stale:
        print(f'FIXTURE INCOMPLETE: `rollout` still referenced at {stale}', file=sys.stderr)
        return 1
    # Neither scan can see a reference this fixture has not been taught about,
    # so the caller MUST also prove the successor serves its own device path
    # before trusting any negative result built on it.
    print(f'applied: renamed channel_patches.rollout -> {NEW}, added migration 13')
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else '.'))
