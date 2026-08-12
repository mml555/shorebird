#!/usr/bin/env python3
"""compat_baseline.py -- capture the study's baseline tuple, atomically.

The baseline is recorded together or not at all. Hand-transcribing six hashes
across a mint, an audit and two corpus runs is how a study ends up reporting a
configuration that never existed -- which is the specific failure this study
already came close to once, by nearly pinning a post-G3.6c producer against
pre-G3.6d retention.

  compat_baseline.py --cell <engineHash> --out baseline_a.json
"""
import argparse, hashlib, json, pathlib, re, subprocess, zipfile

REPO = pathlib.Path(__file__).resolve().parents[4]
OVERLAY = REPO / 'selfhost/cdn/overlay/download.shorebird.dev/shorebird'
CELL_FILES = ['dart2bytecode.aot', 'dartaotruntime', 'vm_platform.dill',
              'route_b_analyze.aot', 'route_b_gen_kernel.aot',
              'route_b_gen_dynamic_interface.aot', 'flutter_platform_strong.dill']


def last_commit(path):
    out = subprocess.run(['git', '-C', str(REPO), 'log', '-1', '--format=%H %cI %s',
                          '--', path], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    sha, rest = out.split(' ', 1)
    date, subject = rest.split(' ', 1)
    return {'commit': sha, 'date': date, 'subject': subject}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cell', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()

    zp = OVERLAY / a.cell / 'route-b-compiler-darwin-arm64.zip'
    if not zp.exists():
        raise SystemExit(f'no published cell at {zp}')
    with zipfile.ZipFile(zp) as z:
        digests = {n: hashlib.sha256(z.read(n)).hexdigest() for n in CELL_FILES}
    # The cell ADDRESS: sha256 over the manifest, exactly as mint_route_b_cell.sh
    # computes it, so the tuple can be checked against the published hash rather
    # than trusted.
    manifest = '\n'.join(f'{n} {digests[n]}' for n in sorted(digests)) + '\n'
    address = hashlib.sha256(manifest.encode()).hexdigest()[:40]

    src = 'selfhost/engine/route_b/coverage/analyze_coverage.dart'
    version = re.search(r'const analysisVersion = (\d+)',
                        (REPO / src).read_text()).group(1)

    dirty = subprocess.run(['git', '-C', str(REPO), 'status', '--porcelain'],
                           capture_output=True, text=True).stdout.strip()

    # THE HARD PRECONDITION, carried in the object rather than remembered.
    # `R3` and the G3.6 status live in another session's document, whose format
    # is theirs to change -- so the rows are recorded VERBATIM and judged by a
    # human, rather than parsed into a boolean this script has no standing to
    # assert. A missing row is reported as missing, never as satisfied.
    parity = REPO / 'selfhost/PARITY.md'
    r3_rows, g36_rows = [], []
    if parity.exists():
        for line in parity.read_text().split('\n'):
            # The CLAIMS row only. A bare `R3` mention matches the resource
            # table, the traps table, the lanes table and every goal that wants
            # it -- eleven rows of noise around the one that says who holds it.
            if line.lstrip().startswith('| `R3`'):
                r3_rows.append(line.strip())
            if 'G3.6' in line and 'complete' in line.lower():
                g36_rows.append(line.strip())

    baseline = {
        'cell_hash_published': a.cell,
        'cell_address_recomputed': address,
        'cell_address_matches': address == a.cell,
        'cell_file_digests': digests,
        'analyzer': {'version': int(version), 'sha256': digests['route_b_analyze.aot'],
                     'source_commit': last_commit(src)},
        'gen_dynamic_interface': {
            'sha256': digests['route_b_gen_dynamic_interface.aot'],
            'source_commit': last_commit('selfhost/engine/route_b/gen_dynamic_interface.dart')},
        'producer_commit': last_commit('packages/shorebird_cli/lib/src/route_b_producer.dart'),
        'coverage_reader_commit': last_commit('packages/shorebird_cli/lib/src/route_b_coverage.dart'),
        'releaser_commit': last_commit('packages/shorebird_cli/lib/src/commands/release/ios_releaser.dart'),
        'patcher_commit': last_commit('packages/shorebird_cli/lib/src/commands/patch/ios_patcher.dart'),
        'working_tree_clean': dirty == '',
        'working_tree_dirty_paths': dirty.split('\n') if dirty else [],
        'preconditions': {
            'checked_at_repo_head': subprocess.run(
                ['git', '-C', str(REPO), 'rev-parse', 'HEAD'],
                capture_output=True, text=True).stdout.strip(),
            'parity_r3_rows_verbatim': r3_rows,
            'parity_g36_complete_mentions_verbatim': g36_rows,
            'note': 'R3 must read as unclaimed/released and G3.6 as complete '
                    'before this baseline is used. Read the rows above; this '
                    'script records them and does not decide them.',
        },
        # Filled from each source's manifest after selection.
        'corpus': {'seed': None, 'app_eligible_sha256': None,
                   'fork_eligible_sha256': None},
    }
    pathlib.Path(a.out).write_text(json.dumps(baseline, indent=2))
    print(f"cell address recomputed: {address}  matches published: "
          f"{baseline['cell_address_matches']}")
    print(f"analyzer v{version}  producer "
          f"{(baseline['producer_commit'] or {}).get('commit','?')[:10]}")
    print(f"working tree clean: {baseline['working_tree_clean']}")
    print('--- precondition evidence (judge these, do not assume):')
    for row in r3_rows or ['  <no R3 row found in PARITY.md>']:
        print(f'    R3   {row[:110]}')
    for row in g36_rows or ['  <no "G3.6 complete" line found in PARITY.md>']:
        print(f'    G3.6 {row[:110]}')
    print(f'wrote {a.out}')
    if dirty:
        raise SystemExit('REFUSING: the working tree is dirty. A baseline '
                         'captured over uncommitted changes describes a tree '
                         'nobody can check out again.')


if __name__ == '__main__':
    main()
