#!/usr/bin/env python3
"""MAOT-4 (#68) scale lane -- what the conservative posture costs a real app.

Usage: scale_m4.py <m4_dir> <out.json>

The m4 fixture is nine declarations. It can show that a rule fires; it cannot
say what the rule costs a program with a framework in it. This lane compiles a
representative Flutter application -- Material, state, animation, scrolling,
the paths a real app actually spends its time in -- and counts the same two
quantities #68 asks for:

  * prevented inlines: how many times the AOT inliner reached a mutable callee
    and was refused. Counted in the inliner itself (MaotRegistry::
    NoteInlineVerdict), carried through materialization, and read back from
    the precompile-time registry dump.
  * devirtualizations recorded: how many instance calls TFA turned into static
    calls whose target is mutable.

Both against a control: the identical program with nothing selected. No
threshold is compared. #68 asked for the counts; it did not agree a budget,
and inventing one here would be a contract nobody granted.

The selection population is the UPPER BOUND -- every non-SDK declaration with
a body, app and framework alike, via MAOT_SELECT_ALL_NON_SDK=1. A real patch
author selects far fewer, so a realistic posture costs less than this lane
reports. It is reported as an upper bound, not as a typical cost.

Nothing installs under this lane and it is not a correctness gate: the
application is not run. Every number here is a compile-time fact read out of
the precompiler's own registry dump.
"""
import json
import os
import subprocess
import sys
import time

FORK = os.environ.get('MAOT_FORK',
                      '/Volumes/build/route-b/flutter/engine/src/flutter/'
                      'third_party/dart')
OUT = os.environ.get('MAOT_OUT',
                     '/Volumes/build/route-b/flutter/engine/src/out/maot_host')
DART = os.environ.get(
    'DART', '/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart')
FLUTTER = os.environ.get('MAOT_FLUTTER_SDK', '/opt/homebrew/share/flutter')
NAMESPACE = os.environ.get(
    'MAOT_NAMESPACE',
    'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e')

# A representative Flutter application. Deliberately NOT a hello-world: the
# point is to pull in the framework paths an optimizer actually works on --
# build methods, state transitions, animation ticks, list delegates, painting.
APP = r'''
import 'package:flutter/material.dart';

void main() => runApp(const ScaleApp());

class ScaleApp extends StatelessWidget {
  const ScaleApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'maot scale',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..repeat();
  final List<int> _items = List<int>.generate(500, (i) => i);
  int _counter = 0;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _score(int i) => (i * 1.5 + _counter) % 97;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('items: ${_items.length}')),
      body: Column(
        children: <Widget>[
          FadeTransition(
            opacity: _c,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('$_counter', style: theme.textTheme.headlineMedium),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _items.length,
              itemBuilder: (BuildContext context, int i) => ListTile(
                leading: CircleAvatar(child: Text('${_items[i] % 10}')),
                title: Text('row ${_items[i]}'),
                subtitle: Text(_score(i).toStringAsFixed(2)),
                onTap: () => setState(() => _counter += i),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _counter++),
        child: const Icon(Icons.add),
      ),
    );
  }
}
'''


def package_config(workdir):
    """Resolve package:flutter and its transitive deps from the Flutter SDK.

    The SDK's own config uses rootUris relative to its .dart_tool directory,
    so they have to be resolved against THAT directory and written absolute.
    Copying them verbatim resolved them against the app instead, which made
    `flutter` and the app package claim the same root and left the app with
    no framework at all -- a corpus of one file, which is the fixture again
    under another name.
    """
    src = os.path.join(FLUTTER, '.dart_tool', 'package_config.json')
    if not os.path.exists(src):
        raise RuntimeError(f'no Flutter package config at {src}')
    base = os.path.dirname(src)
    pkgs = [{'name': 'scaleapp',
             'rootUri': f'file://{os.path.join(workdir, "pkg")}/',
             'packageUri': 'lib/', 'languageVersion': '3.9'}]
    for p in json.load(open(src)).get('packages', []):
        if p['name'] == 'scaleapp':
            continue
        root = p['rootUri']
        if not root.startswith('file:'):
            root = 'file://' + os.path.normpath(os.path.join(base, root))
        pkgs.append(dict(p, rootUri=root.rstrip('/') + '/'))
    out = os.path.join(workdir, 'pkg', '.dart_tool', 'package_config.json')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump({'configVersion': 2, 'packages': pkgs}, open(out, 'w'))
    return out


def compile_one(workdir, name, select_all, uri_prefix=''):
    d = os.path.join(workdir, name)
    os.makedirs(os.path.join(d, 'pkg', 'lib'), exist_ok=True)
    with open(os.path.join(d, 'pkg', 'lib', 'app.dart'), 'w') as fh:
        fh.write(APP)
    cfg = package_config(d)
    dill = os.path.join(d, 'app.dill')
    aot = os.path.join(d, 'app.aot')
    dump = os.path.join(d, 'registry_precompile.json')

    env = dict(os.environ)
    env.pop('MAOT_SELECT_URI_PREFIX', None)
    if select_all:
        env['MAOT_SELECT_ALL_NON_SDK'] = '1'
        if uri_prefix:
            env['MAOT_SELECT_URI_PREFIX'] = uri_prefix
    k = subprocess.run(
        [DART,
         f'--packages={os.path.join(FORK, ".dart_tool/package_config.json")}',
         os.path.join(FORK, 'pkg/vm/bin/gen_kernel.dart'),
         '--platform',
         os.path.join(OUT, 'flutter_patched_sdk', 'platform_strong.dill'),
         # The flutter target, not the vm target: the patched SDK dill is a
         # flutter-target platform, and reading it with the vm target crashes
         # inside DillLoader rather than reporting a mismatch.
         '--target=flutter',
         '--aot', '--packages', cfg, '-o', dill,
         'package:scaleapp/app.dart'],
        capture_output=True, text=True, timeout=3600, env=env)
    if k.returncode != 0:
        return {'stage': 'kernel', 'error': (k.stderr or k.stdout)[-1500:]}

    t = time.perf_counter()
    s = subprocess.run(
        [os.path.join(OUT, 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
         f'--elf={aot}', f'--maot_namespace={NAMESPACE}',
         f'--maot_dump_registry_precompile={dump}', dill],
        capture_output=True, text=True, timeout=3600)
    secs = round(time.perf_counter() - t, 2)
    if s.returncode != 0:
        return {'stage': 'snapshot', 'error': (s.stderr or s.stdout)[-1500:]}

    reg = json.load(open(dump)) if os.path.exists(dump) else {}
    entries = reg.get('entries', [])
    decs = reg.get('optimizer_decisions', [])
    sel = [e for e in entries if e.get('selected')]
    return {
        'compile_seconds': secs,
        'aot_elf_bytes': os.path.getsize(aot),
        'kernel_bytes': os.path.getsize(dill),
        'registry_entries': len(entries),
        'selected_declarations': len(sel),
        'prevented_inlines': sum(
            (e.get('inline_refusals') or 0) for e in entries),
        'inline_admissions': sum(
            (e.get('inline_admissions') or 0) for e in entries),
        'indirect_call_sites_total': sum(
            (e.get('indirect_call_sites_emitted') or 0) for e in entries),
        'devirtualizations_recorded': sum(
            1 for d in decs if d.get('optimization_class')
            == 'devirtualization'),
        'decisions_recorded': len(decs),
        'declarations_with_escapes': sum(
            1 for e in entries if (e.get('optimizer_escapes') or 0) > 0),
        # How much of the selected population is framework rather than app
        # code. A measurement dominated by the nine declarations of the app
        # itself would be the fixture again under another name.
        'framework_declarations_in_corpus': sum(
            1 for e in sel if 'package:flutter/' in e['declaration_id']),
        'app_declarations_in_corpus': sum(
            1 for e in sel if 'package:scaleapp/' in e['declaration_id']),
    }


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    work = os.path.join('/tmp', f'maot_scale_{os.getpid()}')
    os.makedirs(work, exist_ok=True)
    rec = {
        'issue': 68,
        'lane': 'scale',
        # Stamped so the gate can refuse a record measured against a
        # different fork revision. A measurement whose provenance is a
        # filename is not a measurement of this build.
        'fork_commit': subprocess.run(
            ['git', '-C', FORK, 'rev-parse', 'HEAD'],
            capture_output=True, text=True).stdout.strip() or None,
        'fork_dirty': bool(subprocess.run(
            ['git', '-C', FORK, 'diff', '--quiet', 'HEAD', '--',
             'runtime/vm', 'pkg/vm'],
            capture_output=True, text=True).returncode),
        'fork_tree': subprocess.run(
            ['git', '-C', FORK, 'rev-parse', 'HEAD^{tree}'],
            capture_output=True, text=True).stdout.strip() or None,
        'corpus': 'a representative Flutter application: MaterialApp, a '
                  'StatefulWidget with an AnimationController, a 500-row '
                  'ListView.builder with per-row painting and taps -- '
                  'compiled against the real package:flutter framework',
        'selection': 'MAOT_SELECT_ALL_NON_SDK=1 -- every non-SDK declaration '
                     'with a body, app and framework alike. This is the '
                     'UPPER BOUND, not a typical posture.',
        'not_claimed': [
            'the application is not run; every number is a compile-time fact '
            'read out of the precompiler registry dump',
            'no threshold is compared. #68 asked for the counts and did not '
            'agree a budget',
            'a real patch author selects a small subset, so a realistic '
            'posture costs strictly less than this',
        ],
    }
    try:
        # A measurement taken against a dirty worktree names a commit whose
        # bytes it did not measure. Recording `fork_dirty: true` and carrying
        # on is not enough -- the first version of this lane did exactly that,
        # and the number it produced was published under a commit that did not
        # contain the sources it measured.
        if rec['fork_dirty']:
            raise RuntimeError(
                f"the fork worktree differs from {(rec['fork_commit'] or '?')[:12]} "
                f"under runtime/vm or pkg/vm. Commit first: a scale record "
                f"naming a commit whose bytes were never measured is not a "
                f"measurement of that commit.")
        # Three configurations, not two. The upper bound alone invites the
        # reading that Mutable-AOT costs 3.7x the binary, when most of that
        # is retention of 7,000 framework declarations nothing selects in
        # practice. The app-only row is what an author who marks their own
        # code mutable actually pays.
        ctl = compile_one(work, 'control', False)
        app = compile_one(work, 'app_only', True, 'package:scaleapp/')
        sel = compile_one(work, 'selected', True)
        bad = next((x for x in (ctl, app, sel) if 'error' in x), None)
        if bad is not None:
            rec['error'] = bad
        else:
            rec.update(sel)
            rec['aot_elf_bytes_control'] = ctl['aot_elf_bytes']
            rec['compile_seconds_control'] = ctl['compile_seconds']
            rec['selected_declarations_control'] = (
                ctl['selected_declarations'])
            rec['prevented_inlines_control'] = ctl['prevented_inlines']
            rec['aot_elf_delta_bytes'] = (
                sel['aot_elf_bytes'] - ctl['aot_elf_bytes'])
            rec['compile_seconds_delta'] = round(
                sel['compile_seconds'] - ctl['compile_seconds'], 2)
            rec['app_only'] = dict(
                app,
                aot_elf_delta_bytes=(
                    app['aot_elf_bytes'] - ctl['aot_elf_bytes']),
                compile_seconds_delta=round(
                    app['compile_seconds'] - ctl['compile_seconds'], 2))
            rec['configurations'] = {
                'control': 'nothing selected -- stock AOT of the same program',
                'app_only': 'every declaration in package:scaleapp selected. '
                            'The realistic posture: an author marks their own '
                            'code mutable and leaves the framework alone.',
                'all_non_sdk': 'every non-SDK declaration selected, framework '
                               'included. The upper bound.',
            }
    except Exception as e:  # noqa: BLE001 -- recorded, never swallowed
        rec['error'] = {'stage': 'lane', 'error': f'{type(e).__name__}: {e}'}
    with open(argv[2], 'w') as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
    print(json.dumps(rec, indent=2, sort_keys=True))
    return 0 if 'error' not in rec else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
