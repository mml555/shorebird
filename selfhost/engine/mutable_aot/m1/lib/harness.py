#!/usr/bin/env python3
"""MAOT-1 (#65) -- compile a program with the fork CFE and read its identities.

Runs the fork's tools FROM SOURCE rather than from a snapshot. A snapshot
bakes in the identity library at snapshot time, so an edit to the scheme could
be tested against yesterday's copy and pass -- the stale-artifact failure this
repository has paid for before. Four seconds a compile is worth not having
that class of bug.
"""

import hashlib
import json
import os
import shutil
import subprocess
import tempfile

# The fork worktree and the Dart SDK that runs its tools. Both are locations,
# never identity: identity is the commit/tree sha recorded in the evidence.
FORK = os.environ.get('MAOT_FORK', '/Volumes/build/maot/dart')
DART_SDK = os.environ.get(
    'DART_SDK', '/opt/homebrew/share/flutter/bin/cache/dart-sdk')
PLATFORM = os.environ.get(
    'MAOT_PLATFORM',
    '/Volumes/build/route-b/flutter/engine/src/out/host_release_arm64_nodm/'
    'vm_platform_product.dill')


class HarnessError(Exception):
    pass


def dart():
    return os.path.join(DART_SDK, 'bin', 'dart')


def available():
    return (os.path.isdir(FORK)
            and os.path.isfile(dart())
            and os.path.isfile(PLATFORM)
            and os.path.isfile(os.path.join(
                FORK, 'pkg/kernel/lib/maot_identity.dart')))


def fork_identity():
    """The fork's exact identity -- commit, tree, and the digests of the two
    files that define the scheme. Recorded so a result can never be quoted
    against a different compiler than the one that produced it."""
    def git(*args):
        out = subprocess.run(['git', '-C', FORK] + list(args),
                             capture_output=True, text=True, timeout=60)
        return out.stdout.strip() if out.returncode == 0 else None

    digests = {}
    for rel in ('pkg/kernel/lib/maot_identity.dart',
                'pkg/vm/bin/maot_identity_manifest.dart'):
        path = os.path.join(FORK, rel)
        if os.path.isfile(path):
            h = hashlib.sha256()
            with open(path, 'rb') as fh:
                h.update(fh.read())
            digests[rel] = h.hexdigest()

    return {
        'commit': git('rev-parse', 'HEAD'),
        'tree': git('rev-parse', 'HEAD^{tree}'),
        'branch': git('rev-parse', '--abbrev-ref', 'HEAD'),
        'dirty': bool(git('status', '--porcelain')),
        'source_digests': digests,
        'note': ('branch is transport, not provenance. commit and tree are '
                 'the identity; source_digests pin the two files that define '
                 'the scheme so an edited working tree cannot pass as the '
                 'committed one.'),
    }


def compile_and_manifest(sources, workdir, package_name='m1probe',
                         app_root=None, entry='a.dart', extra_args=()):
    """Write `sources`, compile to kernel, and emit the identity manifest.

    `sources` maps a path under lib/ to its content. Returns the parsed
    manifest, or raises HarnessError with the tool output.
    """
    if not available():
        raise HarnessError('fork worktree, Dart SDK or platform dill absent')

    pkg = os.path.join(workdir, 'pkg')
    lib = os.path.join(pkg, 'lib')
    os.makedirs(lib, exist_ok=True)
    for rel, content in sources.items():
        dest = os.path.join(lib, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, 'w', encoding='utf-8') as fh:
            fh.write(content)

    tool_dir = os.path.join(pkg, '.dart_tool')
    os.makedirs(tool_dir, exist_ok=True)
    with open(os.path.join(tool_dir, 'package_config.json'), 'w',
              encoding='utf-8') as fh:
        json.dump({
            'configVersion': 2,
            'packages': [{
                'name': package_name,
                'rootUri': f'file://{pkg}/',
                'packageUri': 'lib/',
                'languageVersion': '3.9',
            }],
        }, fh)

    dill = os.path.join(workdir, 'out.dill')
    fork_pkgs = os.path.join(FORK, '.dart_tool/package_config.json')

    entry_uri = (f'package:{package_name}/{entry}' if app_root is None
                 else f'file://{lib}/{entry}')

    comp = subprocess.run(
        [dart(), f'--packages={fork_pkgs}',
         os.path.join(FORK, 'pkg/vm/bin/gen_kernel.dart'),
         '--platform', PLATFORM, '--no-aot', '--no-link-platform',
         '--packages', os.path.join(tool_dir, 'package_config.json'),
         '-o', dill, entry_uri],
        capture_output=True, text=True, timeout=900)
    if comp.returncode != 0 or not os.path.isfile(dill):
        raise HarnessError(
            f'compile failed: {(comp.stderr or comp.stdout)[-1200:]}')

    ident = fork_identity()
    manifest_path = os.path.join(workdir, 'manifest.json')
    args = [dart(), f'--packages={fork_pkgs}',
            os.path.join(FORK, 'pkg/vm/bin/maot_identity_manifest.dart'),
            '--dill', dill,
            '--dart-commit', ident['commit'] or '',
            '--dart-tree', ident['tree'] or '',
            '-o', manifest_path]
    if app_root is not None:
        args += ['--app-root', app_root]
    args += list(extra_args)

    run = subprocess.run(args, capture_output=True, text=True, timeout=900)
    if not os.path.isfile(manifest_path):
        raise HarnessError(
            f'manifest tool produced nothing (exit {run.returncode}): '
            f'{(run.stderr or run.stdout)[-1200:]}')
    with open(manifest_path, encoding='utf-8') as fh:
        manifest = json.load(fh)
    manifest['_tool_exit'] = run.returncode
    manifest['_tool_stderr'] = run.stderr[-2000:]
    return manifest


def ids_of(manifest, addressable_only=True):
    entries = manifest['identity']['entries']
    return {e['id'] for e in entries
            if e['addressable'] or not addressable_only}


def entry_map(manifest):
    return {e['id']: e for e in manifest['identity']['entries']}


def run_in_temp(sources, **kwargs):
    """Compile in a throwaway directory. The directory name is deliberately
    random: any id that depends on it will differ between two calls, which is
    exactly what the path-stability case is looking for."""
    workdir = tempfile.mkdtemp(prefix='maot_m1_')
    try:
        return compile_and_manifest(sources, workdir, **kwargs)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
