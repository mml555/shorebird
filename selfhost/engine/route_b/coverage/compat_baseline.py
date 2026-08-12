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
    print(f'wrote {a.out}')


if __name__ == '__main__':
    main()
