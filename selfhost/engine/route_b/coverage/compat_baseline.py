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
# The ENGINE tree is part of the baseline whether or not anyone says so: a cell
# is built FROM it. Checking only the repo's cleanliness let a mint proceed over
# 18 uncommitted files of half-finished CFE work that did not compile.
import os
ENGINE_DART = pathlib.Path(os.environ.get(
    'DART_TREE', '/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'))
OVERLAY = REPO / 'selfhost/cdn/overlay/download.shorebird.dev/shorebird'
# What Phase 0 was measured against. Recorded as constants so comparability is
# computed from the artifact, never from memory of what the pilot ran on.
PHASE0_ANALYSIS_VERSION = 6
PHASE0_ANALYZER_HASH = ('4023835b353908bbf5b1e15ee45b81cf'
                        'ff8a16c727d11e93314159c59cc95de6')

CELL_FILES = ['dart2bytecode.aot', 'dartaotruntime', 'vm_platform.dill',
              'route_b_analyze.aot', 'route_b_gen_kernel.aot',
              'route_b_gen_dynamic_interface.aot', 'flutter_platform_strong.dill']


def verify_engine_tree():
    """The evidence half of the precondition, run rather than remembered.

    An empty claims row is coordination metadata; `dart_patches.sh --verify` is
    evidence about the actual engine source state. Baseline A was minted over 18
    uncommitted files of half-finished CFE work because only the first was ever
    checked.
    """
    script = REPO / 'selfhost/engine/dart_patches.sh'
    r = subprocess.run([str(script), '--dest', str(ENGINE_DART), '--verify'],
                       capture_output=True, text=True)
    return {'ran': str(script), 'exit_code': r.returncode,
            'green': r.returncode == 0,
            'output_tail': (r.stdout + r.stderr)[-2000:]}


def patch_series():
    """Identity of every patch the engine tree is supposed to be carrying,
    and the exact set of files those patches touch."""
    out, touched = [], set()
    for d in ('selfhost/engine', 'selfhost/engine/route_b'):
        for f in sorted((REPO / d).glob('*.patch')):
            text = f.read_text(errors='replace')
            files = sorted({m.group(1) for m in
                            re.finditer(r'^\+\+\+ b/(\S+)', text, re.M)})
            touched.update(files)
            out.append({'patch': str(f.relative_to(REPO)),
                        'sha256': hashlib.sha256(f.read_bytes()).hexdigest(),
                        'files': files})
    return out, touched


def unexpected_engine_edits(engine_files, touched):
    """Modified engine files the patch series does not account for.

    MEASURED, AND IT IS THE GAP THAT LET BASELINE A THROUGH:
    `dart_patches.sh --verify` returns GREEN on a tree carrying 18 modified
    files including a half-finished CFE feature, because it checks the base
    commit and that each patch IS applied -- not that nothing ELSE is. Green is
    necessary and not sufficient; this is the sufficient half.
    """
    modified = set()
    for line in engine_files:
        # Porcelain is 'XY <path>'; split on whitespace rather than slicing a
        # fixed width, which ate a leading character and put a truncated path
        # into the evidence.
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            modified.add(parts[1].strip('"'))
    # Patch paths are relative to the Dart checkout; series files under
    # selfhost/engine/ may target the engine src root instead, so match on
    # suffix as well as equality.
    unexplained = []
    for m in sorted(modified):
        if m in touched or any(t.endswith('/' + m) or m.endswith('/' + t)
                               for t in touched):
            continue
        unexplained.append(m)
    return unexplained


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
    ap.add_argument('--analyzer-change-proven-neutral', metavar='JUSTIFICATION',
                    help='ONLY for the same-version-different-hash case, and '
                         'only with evidence: the parity corpus rerun clean on '
                         'the new analyzer, or the diff shown to be non-semantic. '
                         'The justification is recorded verbatim in the baseline.')
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
    engine_dirty = subprocess.run(
        ['git', '-C', str(ENGINE_DART), 'status', '--porcelain'],
        capture_output=True, text=True).stdout.strip()
    engine_files = [l for l in engine_dirty.split('\n') if l]

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

    # DID G3.6 CHANGE ANALYZER SEMANTICS, OR ONLY CELL CONTENTS? This does not
    # gate Phase 1 -- baseline A measures whatever coherent product exists after
    # G3.6 closes. It exists to stop an invalid before/after claim being made
    # afterwards, when the pilot's numbers are the only ones lying around.
    baseline_version = int(version)
    baseline_hash = digests['route_b_analyze.aot']
    same_version = baseline_version == PHASE0_ANALYSIS_VERSION
    same_hash = baseline_hash == PHASE0_ANALYZER_HASH

    if baseline_version > PHASE0_ANALYSIS_VERSION:
        comparable, reason = 'no', (
            f'analyzer version moved {PHASE0_ANALYSIS_VERSION} -> '
            f'{baseline_version}. Phase 0 is pilot and historical evidence only; '
            f'no numerical Phase 0 <-> Phase 1 comparison is valid.')
    elif baseline_version < PHASE0_ANALYSIS_VERSION:
        comparable, reason = 'no', (
            f'analyzer version went BACKWARDS {PHASE0_ANALYSIS_VERSION} -> '
            f'{baseline_version}, which should not happen; investigate before '
            f'using this baseline at all.')
    elif same_version and same_hash:
        comparable, reason = 'yes', (
            'same analyzer version and same binary hash: Phase 0 is directly '
            'comparable.')
    elif a.analyzer_change_proven_neutral:
        comparable, reason = 'yes', (
            'same version, DIFFERENT binary hash, change asserted '
            'behaviour-neutral with justification: '
            + a.analyzer_change_proven_neutral)
    else:
        comparable, reason = 'no', (
            'same analyzer version but a different binary hash: the analyzer '
            'changed without a version bump. Not comparable unless the change '
            'is explicitly proven behaviour-neutral '
            '(--analyzer-change-proven-neutral).')

    verifier = verify_engine_tree()
    series, touched = patch_series()
    unexplained = unexpected_engine_edits(engine_files, touched)
    dart_base = subprocess.run(['git', '-C', str(ENGINE_DART), 'rev-parse', 'HEAD'],
                               capture_output=True, text=True).stdout.strip()

    # THE CHAIN, AND IT IS A CHAIN: approved Dart base + approved patch series ->
    # verified engine tree -> minted cell -> audited cell -> baseline -> corpus.
    # A break anywhere makes everything downstream describe a configuration that
    # was never built, so a baseline is VOID unless every link is evidenced.
    void_reasons = []
    if unexplained:
        void_reasons.append(
            f'{len(unexplained)} engine file(s) are modified but not accounted '
            f'for by the patch series: {", ".join(unexplained[:6])}'
            + (' …' if len(unexplained) > 6 else ''))
    if not verifier['green']:
        void_reasons.append(
            f"dart_patches.sh --verify exited {verifier['exit_code']}: the engine "
            f"tree is not the approved base plus the approved series")
    if dirty:
        void_reasons.append('the repo working tree is dirty')
    if not address == a.cell:
        void_reasons.append('the recomputed cell address does not match the '
                            'published hash')

    baseline = {
        'VOID': bool(void_reasons),
        'void_reasons': void_reasons,
        'engine_verification': verifier,
        'engine_edits_not_in_patch_series': unexplained,
        'dart_base_revision': dart_base,
        'patch_series': series,
        'phase0_analysis_version': PHASE0_ANALYSIS_VERSION,
        'baseline_analysis_version': baseline_version,
        'phase0_analyzer_hash': PHASE0_ANALYZER_HASH,
        'baseline_analyzer_hash': baseline_hash,
        'phase0_comparable': comparable,
        'reason': reason,
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
        'engine_tree': {
            'path': str(ENGINE_DART),
            'modified_file_count': len(engine_files),
            'modified_files': engine_files,
            'note': 'The Route B patch series lives as working-tree edits, so a '
                    'nonzero count is normal — but the CONTENT matters. Run '
                    'selfhost/engine/dart_patches.sh --verify and confirm the '
                    'set is exactly the patch series before minting.',
        },
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
    print(f"phase 0 comparable: {comparable}  -- {reason}")
    print(f"analyzer v{version}  producer "
          f"{(baseline['producer_commit'] or {}).get('commit','?')[:10]}")
    print(f"working tree clean: {baseline['working_tree_clean']}")
    print(f"engine tree modified files: {len(engine_files)}")
    print(f"dart base: {dart_base[:12]}  patch series: {len(series)} patches")
    print(f"engine edits NOT in the patch series: {len(unexplained)}"
          + (f'  {unexplained[:4]}' if unexplained else ''))
    print(f"dart_patches.sh --verify: "
          f"{'GREEN' if verifier['green'] else 'RED (exit ' + str(verifier['exit_code']) + ')'}")
    print('--- precondition evidence (judge these, do not assume):')
    for row in r3_rows or ['  <no R3 row found in PARITY.md>']:
        print(f'    R3   {row[:110]}')
    for row in g36_rows or ['  <no "G3.6 complete" line found in PARITY.md>']:
        print(f'    G3.6 {row[:110]}')
    print(f'wrote {a.out}')
    if void_reasons:
        raise SystemExit('BASELINE IS VOID — ' + '; '.join(void_reasons) +
                         '. The file was written so the failure is on record, '
                         'but it must not be used as a study baseline.')


if __name__ == '__main__':
    main()
