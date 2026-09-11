#!/usr/bin/env python3
"""MAOT-2 (#66) -- run the pipeline, exercise the bank, derive the verdict.

Drives the real chain every time: source -> Kernel -> gen_snapshot ->
dartaotruntime. Nothing here reads a cached artifact; a stale record cannot
survive a failed run because every run regenerates into a fresh directory.

usage: gate_m2.py <m2-dir> <out.json>
"""

import datetime
import hashlib
import json
import os
import shutil
import re
import subprocess
import sys
import time
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verdict_m2 as V          # noqa: E402

FORK = os.environ.get('MAOT_FORK',
                      '/Volumes/build/route-b/flutter/engine/src/flutter/'
                      'third_party/dart')
OUT = os.environ.get('MAOT_OUT',
                     '/Volumes/build/route-b/flutter/engine/src/out/maot_host')
DART = os.environ.get(
    'DART', '/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart')
NAMESPACE = os.environ.get(
    'MAOT_NAMESPACE',
    'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e')

# The fixture. Values are deliberately opaque to the compiler: an earlier
# all-literal version let TFA constant-fold every selected declaration into
# main, so the registry looked correct while its descriptors pointed at bodies
# the optimizer had dissolved.
FIXTURE = '''
import 'dart:io' show Platform;

@pragma('maot:mutable')
int mutableTopLevel(int seed) => seed + 1;

int notMutable(int seed) => seed + 2;

@pragma('maot:mutable')
String neverCalled(int seed) => 'release-$seed';

// Deliberately shares its VM Function name with Shapes.compute. A lookup that
// resolved by name instead of by DeclarationId would confuse these two, and
// without such a pair the arm that checks for it has nothing to run on.
@pragma('maot:mutable')
int compute(int seed) => seed * 7;

@pragma('maot:not-a-real-contract')
int bogusPragma(int seed) => seed + 99;

// ---- ABI discrimination pairs -------------------------------------------
// Each adjacent pair below differs in EXACTLY ONE dimension of the
// compatibility model, so the pairwise matrix can show that dimension is
// load-bearing. They are selected, so they reach the registry; they are never
// replaced, because #66 does not execute replacements.

@pragma('maot:mutable')
int posOne(int a) => a + 1;
@pragma('maot:mutable')
int posTwo(int a, int b) => a + b;            // vs posOne: positional count

@pragma('maot:mutable')
int posOptional(int a, [int b = 0]) => a - b;  // vs posTwo: required count

@pragma('maot:mutable')
int namedX(int a, {int x = 0}) => a + x;
@pragma('maot:mutable')
int namedY(int a, {int y = 0}) => a + y;       // vs namedX: named set

@pragma('maot:mutable')
int namedRequiredX(int a, {required int x}) => a + x;  // vs namedX: requiredness

@pragma('maot:mutable')
Object? genericNone(Object? a) => a;
@pragma('maot:mutable')
T genericOne<T>(T a) => a;                     // vs genericNone: type params

@pragma('maot:mutable')
T boundNum<T extends num>(T a) => a;
@pragma('maot:mutable')
T boundInt<T extends int>(T a) => a;           // vs boundNum: BOUND only

// vs Shapes.instanceOne: static vs instance, same shape.
@pragma('maot:mutable')
int staticOne(int a) => a + 5;

// Representation pair: same arity, different parameter and return types, so
// if the AOT unboxes either one the call-convention strings must differ.
@pragma('maot:mutable')
double doubleIdentity(double x) => x * 2.0;
@pragma('maot:mutable')
int intIdentity(int x) => x * 2;

// ---- generic-scope collision pairs --------------------------------------
// Each of these pairs renders IDENTICALLY under a type renderer that spells
// scopes by name instead of by position, or that drops a nested function
// type's own binder. Semantically they are different ABI shapes, so a renderer
// that collides them certifies a replacement that changes the contract.

class OwnerAB<A, B> {
  // bound refers to the owner's type parameter at position 0
  @pragma('maot:mutable')
  T byPosition<T extends A>(T x) => x;
}

class OwnerBA<B, A> {
  // the SAME source spelling `A`, but A is now at owner position 1
  @pragma('maot:mutable')
  T byPosition<T extends A>(T x) => x;
}

// Nested generic function type in the bound: the inner binder's own bound is
// the only difference, and it is inside a FunctionType.
@pragma('maot:mutable')
T nestedBoundNum<T extends X Function<X extends num>(X)>(T x) => x;
@pragma('maot:mutable')
T nestedBoundInt<T extends X Function<X extends int>(X)>(T x) => x;

// Positive control for the other direction: renaming a type parameter without
// changing structure must stay EQUAL, or the renderer is merely strict rather
// than injective.
@pragma('maot:mutable')
T renamedT<T extends num>(T x) => x;
@pragma('maot:mutable')
U renamedU<U extends num>(U x) => x;

class Shapes {
  int n;

  @pragma('maot:mutable')
  Shapes(this.n);                              // vs instanceOne: ctor vs method

  @pragma('maot:mutable')
  int instanceOne(int a) => a + n;

  @pragma('maot:mutable')
  int compute(int seed) => 3 + n + seed;       // name clash with top-level

  int untouched(int seed) => 4 + seed;
}

void main(List<String> args) {
  final seed = Platform.environment.length + args.length;
  final s = Shapes(seed);
  var acc = bogusPragma(seed) + mutableTopLevel(seed) + notMutable(seed) +
      compute(seed) + s.compute(seed) + s.untouched(seed) +
      posOne(seed) + posTwo(seed, 1) + posOptional(seed) +
      namedX(seed, x: 1) + namedY(seed, y: 1) + namedRequiredX(seed, x: 1) +
      genericOne<int>(seed) + boundNum<int>(seed) + boundInt<int>(seed) +
      staticOne(seed) + s.instanceOne(seed) + intIdentity(seed);
  acc += doubleIdentity(seed.toDouble()).toInt();
  acc += genericNone(seed) == null ? 0 : 1;
  // Explicit type arguments throughout: inference here would make the sum's
  // static type num and the fixture would stop compiling for a reason that
  // has nothing to do with what it is testing.
  acc += OwnerAB<int, String>().byPosition<int>(seed);
  acc += OwnerBA<String, int>().byPosition<int>(seed);
  acc += renamedT<int>(seed);
  acc += renamedU<int>(seed);
  final numBounded = nestedBoundNum<X Function<X extends num>(X)>(
      <X extends num>(X v) => v);
  final intBounded = nestedBoundInt<X Function<X extends int>(X)>(
      <X extends int>(X v) => v);
  acc += numBounded<int>(2) + intBounded<int>(3);
  print(acc);
}
'''

# The same program with every maot:mutable removed. It is the control for the
# cost measurements: the difference between these two builds is what selection
# costs, including the dead `neverCalled` that only selection keeps alive.
FIXTURE_CONTROL = FIXTURE.replace("@pragma('maot:mutable')\n", '')


def _selected_from_fixture(src, lib='lib:package:m2app/app.dart'):
    """The DeclarationIds the fixture's pragmas select, read off the source.

    Maintaining this list by hand next to the fixture is maintaining the same
    fact twice, and the copies drift -- which is how a stale five-element set
    outlived a nineteen-declaration fixture.
    """
    def strip_type_params(text):
        """Remove balanced <...> groups. Splitting on '<' instead leaves
        `class OwnerAB<A, B>` reading as the class `OwnerAB<A,`."""
        out, depth = [], 0
        for ch in text:
            if ch == '<':
                depth += 1
            elif ch == '>':
                depth = max(0, depth - 1)
            elif depth == 0:
                out.append(ch)
        return ''.join(out)

    ids, cls, pending = set(), None, False
    for raw in src.splitlines():
        line = raw.strip()
        indented = raw.startswith('  ')
        if line.startswith('class '):
            cls = strip_type_params(line[6:]).split('{')[0].strip()
            continue
        if line == '}' and not indented:
            cls = None
        if line == "@pragma('maot:mutable')":
            pending = True
            continue
        if not pending or not line:
            continue
        pending = False
        # Strip the type-parameter list FIRST. Splitting on '<' instead would
        # leave `T boundNum<T extends num>` reading as the declaration `num>`,
        # which is how two of these silently went missing.
        sig = strip_type_params(line.split('(')[0]).strip()
        name = sig.split()[-1] if ' ' in sig else sig
        if cls is not None and name == cls:
            ids.add(f'{lib}::cls:{cls}::ctor:')
        elif cls is not None:
            ids.add(f'{lib}::cls:{cls}::method:{name}')
        else:
            ids.add(f'{lib}::fn:{name}')
    return ids

# Each ABI dimension, named with the two fixture declarations that differ in
# EXACTLY that dimension. The gate requires every one of them to be refused by
# the pairwise matrix -- a dimension the descriptor does not represent shows up
# here as an ACCEPTED pair.
#
# The pairs are stated as declaration-id leaves; the gate resolves them against
# the real registry rather than assuming they are present.
ABI_DIMENSIONS = {
    'positional count': ('fn:posOne', 'fn:posTwo'),
    'required positional count': ('fn:posTwo', 'fn:posOptional'),
    'named parameter set': ('fn:namedX', 'fn:namedY'),
    'required named set': ('fn:namedX', 'fn:namedRequiredX'),
    'type parameter count': ('fn:genericNone', 'fn:genericOne'),
    'type parameter bound': ('fn:boundNum', 'fn:boundInt'),
    'instance vs static': ('fn:staticOne', 'cls:Shapes::method:instanceOne'),
    'owner type-parameter position': ('cls:OwnerAB::method:byPosition',
                                      'cls:OwnerBA::method:byPosition'),
    'nested function-type bound': ('fn:nestedBoundNum', 'fn:nestedBoundInt'),
    'constructor vs method': ('cls:Shapes::ctor:',
                              'cls:Shapes::method:instanceOne'),
}

# The fully-boxed, stack-based calling convention that EVERY selected
# declaration must have, and the source chain that forces it.
#
# This is not a coincidence and not an assumption. `@pragma('maot:mutable')`
# parses to a PragmaEntryPointType.Default, so TFA's NativeCodeOracle treats a
# selected member as referenced from native code:
#
#   pragma.dart            maot:mutable -> ParsedEntryPointPragma
#   unboxing_info.dart     _cannotUnbox(): isMemberReferencedFromNativeCode(m)
#                          -> unboxingInfo.setFullyBoxed()
#   metadata/unboxing_info.dart  setFullyBoxed(): argsInfo.length = 0,
#                          returnInfo = kBoxed,
#                          mustUseStackCallingConvention = true
#   object.cc              MaxNumberOfParametersInRegisters(): returns 0 when
#                          must_use_stack_calling_convention
#
# So selection itself pins every selected declaration to the boxed stack
# convention -- which is the calling-convention stability a patch system wants,
# arrived at by accident. An accident that load-bearing has to be CHECKED on
# every run rather than believed, which is what the condition below does.
CALLCONV_BOXED_STACK = {'regs': 'regs0', 'ret': 'rett'}


def callconv_is_boxed_stack(cc):
    """Whether a call-convention string is the fully boxed, stack-based form."""
    if not cc or cc == '<absent>':
        return False
    parts = cc.split(';')
    fields = {p[:4]: p for p in parts}
    args = next((p[4:] for p in parts if p.startswith('args')), None)
    ret = next((p[3:] for p in parts if p.startswith('ret')
                and not p.startswith('rets')), None)
    return (fields.get('regs') == CALLCONV_BOXED_STACK['regs']
            and args is not None and set(args) <= {'t'}
            and ret == 't')

# Dimensions the compatibility model deliberately does NOT represent, with the
# reason and the issue that owns them. Stated here so the gate can assert the
# list is honest rather than leaving a silent omission.
ABI_NOT_REPRESENTED = {
    'parameter/return representation, as a fixture pair': (
        'Represented in the call-convention string and compared on every '
        'staging attempt, but it CANNOT VARY within the selected population: '
        'selection forces the fully boxed stack convention through the chain '
        'documented at CALLCONV_BOXED_STACK, so no two selected declarations '
        'can differ in it. The component is not decorative -- the register/'
        'stack split does vary (an unselected declaration measures regs1 while '
        'every selected one measures regs0, same function, same run), and the '
        'invariant itself is checked by '
        'selected_calling_convention_is_boxed_stack with F26 as its '
        'falsification.'),
    'closure/context shape': (
        'Closures are not in the MAOT-2 selected population at all. Selection '
        'and indexing walk library.members and cls.members; a local function '
        'is not a Member, cannot carry the pragma, and never receives a '
        'DeclarationId. #75 (MAOT-11) owns closures, async/generators and '
        'isolates.'),
    'owner identity': (
        'Already supplied by the DeclarationId, which is '
        'lib:<importUri>::cls:<Name>::<kind>:<name>. Repeating the owner in '
        'the descriptor would be a second spelling of the same fact, and two '
        'spellings can disagree.'),
    'factory index shift': (
        'ComputeLocationsOfFixedParameters shifts the parameter index for a '
        'factory, and that is represented twice on purpose: memberKind '
        'separates a factory in the Kernel descriptor, and the call-convention '
        'string carries factory/nofactory so it stands alone as a '
        'fingerprint.'),
}

# Derived from the fixture rather than typed twice: a hand-maintained copy of
# this list is a second source of truth, and the two can disagree.
SELECTED_EXPECTED = _selected_from_fixture(FIXTURE)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b''):
            h.update(chunk)
    return h.hexdigest()


def git(root, *args):
    out = subprocess.run(['git', '-C', root] + list(args),
                         capture_output=True, text=True, timeout=60)
    return out.stdout.strip() if out.returncode == 0 else None


def available():
    return all(os.path.exists(p) for p in
               (FORK, DART, os.path.join(OUT, 'gen_snapshot'),
                os.path.join(OUT, 'dartaotruntime')))


# The MAOT surface in the fork. If a binary is older than any of these, the
# run measures a different program than the one this record names -- which is
# how a falsification arm once "failed" for a reason that had nothing to do
# with the defect it was probing.
# The MAOT surface in the fork, as build_maot.sh digests it. mtimes are not
# used: `git checkout` rewrites every mtime without changing a byte, and
# `touch` changes an mtime without changing anything at all. What the record
# needs to know is whether the binaries were built from these bytes.
MAOT_CXX_SOURCES = (
    'runtime/vm/maot_registry.cc',
    'runtime/vm/maot_registry.h',
    'runtime/vm/kernel_loader.cc',
    'runtime/vm/object_store.h',
    'runtime/vm/dart.cc',
    'runtime/vm/compiler/aot/precompiler.cc',
    'runtime/vm/compiler/aot/precompiler.h',
    'runtime/vm/compiler/frontend/kernel_translation_helper.cc',
    'runtime/vm/compiler/frontend/kernel_translation_helper.h',
)

# Read by gen_kernel at run time from the tree, so they cannot go stale inside
# a binary and are deliberately not part of the digest.
MAOT_DART_SOURCES = (
    'pkg/vm/lib/metadata/maot_declaration_id.dart',
    'pkg/vm/lib/transformations/type_flow/transformer.dart',
    'pkg/vm/lib/transformations/pragma.dart',
    'pkg/vm/lib/modular/target/vm.dart',
)

DIGEST_FILE = '.maot_source_digest'


def build_digests(sources=MAOT_CXX_SOURCES):
    """sha256 of each MAOT C++ source as it is on disk right now."""
    out = {}
    for f in sources:
        path = os.path.join(FORK, f)
        out[f] = sha256_file(path) if os.path.exists(path) else None
    return out


def recorded_digests(path=None):
    """What build_maot.sh recorded after the last successful build."""
    p = path or os.path.join(OUT, DIGEST_FILE)
    if not os.path.exists(p):
        return None
    rec = {'files': {}}
    for line in open(p):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        a, _, b = line.partition(' ')
        if a in ('fork_commit', 'fork_tree', 'built_at'):
            rec[a] = b
        else:
            rec['files'][b] = a
    return rec


def staleness(override=None):
    """How the built binaries disagree with the sources now on disk.

    `override` substitutes a digest map, so the guard can be shown to fire as
    well as to stay quiet.
    """
    rec = recorded_digests()
    if rec is None:
        return [{'problem': 'no build digest',
                 'detail': f'{os.path.join(OUT, DIGEST_FILE)} is absent, so '
                           f'nothing records what these binaries were built '
                           f'from. Build with m2/build_maot.sh.'}]
    now = override if override is not None else build_digests()
    out = []
    for f, want in sorted(rec['files'].items()):
        got = now.get(f)
        if got is None:
            out.append({'problem': 'source absent', 'file': f,
                        'detail': 'the binaries were built from a file that '
                                  'is no longer in the tree'})
        elif got != want:
            out.append({'problem': 'source differs from the build', 'file': f,
                        'built_from': want[:16], 'on_disk': got[:16]})
    for f in sorted(set(now) - set(rec['files'])):
        out.append({'problem': 'source not covered by the build digest',
                    'file': f})
    return out


class Run:
    """One end-to-end pipeline execution in a throwaway directory."""

    def __init__(self, workdir, fixture=FIXTURE):
        self.dir = workdir
        lib = os.path.join(workdir, 'pkg', 'lib')
        os.makedirs(lib, exist_ok=True)
        with open(os.path.join(lib, 'app.dart'), 'w') as fh:
            fh.write(fixture)
        tool = os.path.join(workdir, 'pkg', '.dart_tool')
        os.makedirs(tool, exist_ok=True)
        with open(os.path.join(tool, 'package_config.json'), 'w') as fh:
            json.dump({'configVersion': 2, 'packages': [{
                'name': 'm2app',
                'rootUri': f'file://{os.path.join(workdir, "pkg")}/',
                'packageUri': 'lib/', 'languageVersion': '3.9'}]}, fh)
        self.pkg_config = os.path.join(tool, 'package_config.json')
        self.dill = os.path.join(workdir, 'app.dill')
        self.aot = os.path.join(workdir, 'app.aot')

    def kernel(self, trace=True):
        cmd = [DART]
        if trace:
            cmd.append('-Dmaot.trace=true')
        cmd += [f'--packages={os.path.join(FORK, ".dart_tool/package_config.json")}',
                os.path.join(FORK, 'pkg/vm/bin/gen_kernel.dart'),
                '--platform', os.path.join(OUT, 'vm_platform_product.dill'),
                '--aot', '--packages', self.pkg_config,
                '-o', self.dill, 'package:m2app/app.dart']
        return subprocess.run(cmd, capture_output=True, text=True, timeout=1800)

    def snapshot(self, extra=(), namespace=NAMESPACE):
        cmd = [os.path.join(OUT, 'gen_snapshot'),
               '--snapshot_kind=app-aot-elf', f'--elf={self.aot}',
               f'--maot_namespace={namespace}'] + list(extra) + [self.dill]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=1800)

    def run_aot(self, dump=None, selftest=None, probes=None):
        cmd = [os.path.join(OUT, 'dartaotruntime')]
        if dump:
            cmd.append(f'--maot_dump_registry={dump}')
        if probes:
            cmd.append(f'--maot_probe_resolvers={probes}')
        if selftest:
            cmd.append(f'--maot_selftest={selftest}')
        cmd.append(self.aot)
        return subprocess.run(cmd, capture_output=True, text=True, timeout=600)


def _dart_selected(stdout):
    """Parse the Dart-side trace: selected count and selectedButAbsent."""
    selected, absent = None, None
    for line in stdout.splitlines():
        if '[maot-dart] selected=' in line:
            for tok in line.split():
                if tok.startswith('selected='):
                    selected = int(tok.split('=')[1])
                if tok.startswith('selectedButAbsent='):
                    body = line.split('selectedButAbsent=')[1].strip()
                    absent = [] if body == '[]' else \
                        [x.strip() for x in body.strip('[]').split(',') if x.strip()]
    return selected, absent


def registry_ids_list(registry):
    return [e['declaration_id'] for e in registry.get('entries', [])]


def _expected_vm_name(decl_id):
    """The VM Function name implied by a #65 DeclarationId, derived from it.

    fn:f -> f          cls:C::method:m -> m
    cls:C::ctor: -> C.   cls:C::ctor:n -> C.n
    """
    segments = decl_id.split('::')
    tail = segments[-1]
    if tail.startswith('fn:') or tail.startswith('method:'):
        return tail.split(':', 1)[1]
    if tail.startswith('ctor:'):
        cls = next((x[4:] for x in segments if x.startswith('cls:')), '?')
        return '%s.%s' % (cls, tail[5:])
    if tail.startswith('get:') or tail.startswith('set:'):
        return tail.split(':', 1)[1]
    return tail


def _materialized(stderr):
    for line in stderr.splitlines():
        if 'materialized' in line and 'selected' in line:
            parts = line.replace('(', ' ').replace(')', ' ').split()
            try:
                return int(parts[2]), int(parts[4]), int(parts[6])
            except (IndexError, ValueError):
                pass
    return None, None, None


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    m2_dir, out_path = os.path.abspath(argv[1]), argv[2]
    repo = os.path.abspath(os.path.join(m2_dir, '..', '..', '..', '..'))
    run_id = datetime.datetime.now(datetime.timezone.utc).strftime(
        '%Y-%m-%dT%H:%M:%SZ')
    findings = []

    def finding(code, message):
        findings.append({'code': code, 'severity': 'blocking',
                         'message': message})

    if not available():
        finding('TOOLCHAIN_UNAVAILABLE',
                'the Dart fork or the built gen_snapshot/dartaotruntime is '
                'not reachable; nothing can be measured')
        record = {'schema': 'maot.m2.evidence/1', 'issue': 66,
                  'generated_by': {'run_id': run_id}, 'identities': {},
                  'observations': {}, 'selftest': {}, 'registry': {},
                  'falsification': [], 'falsification_bank': {},
                  'findings': findings,
                  'verdict': V.evaluate({}, findings), 'consumers': {}}
        with open(out_path, 'w') as fh:
            json.dump(record, fh, indent=2)
        print('TOOLCHAIN_UNAVAILABLE')
        return 1

    # The rig this lane builds in is shared, and it is handed back to its
    # owner between segments. When it is handed back the MAOT sources are not
    # in the tree at all, and the gate would then report a dozen arms failing
    # for a reason that has nothing to do with the implementation. Say the
    # actual reason instead.
    absent = [f for f in MAOT_CXX_SOURCES + MAOT_DART_SOURCES
              if not os.path.exists(os.path.join(FORK, f))]
    if absent:
        finding('FORK_NOT_ON_MAOT_REVISION',
                f'{FORK} is missing {len(absent)} Mutable-AOT source(s) '
                f'(first: {absent[0]}), so it is not on a Mutable-AOT '
                f'revision. The evidence record names the commit this lane '
                f'was measured at; check that out and rebuild with '
                f'm2/build_maot.sh before re-running. The rig is shared: see '
                f'rescued/R3_STATE_BEFORE_BORROW.txt for the borrow and '
                f'hand-back discipline before taking it.')

    stale = staleness()
    if stale:
        finding('BINARY_NOT_BUILT_FROM_THESE_SOURCES',
                'the built toolchain does not match the MAOT sources on disk, '
                'so this run would measure a different program than it names: '
                + '; '.join(f'{x["problem"]}'
                            + (f' ({x["file"]})' if 'file' in x else '')
                            for x in stale))

    work = tempfile.mkdtemp(prefix='maot_m2_')
    arms = []
    observations = {'expected_namespace': NAMESPACE,
                    'stale_binaries': stale,
                    'build_digest': recorded_digests() or {},
                    'missing_maot_sources': absent}
    selftest, registry = {}, {}
    try:
        # ---------------- the real run ----------------
        main_run = Run(os.path.join(work, 'main'))
        k = main_run.kernel()
        if k.returncode != 0:
            finding('KERNEL_FAILED', (k.stderr or k.stdout)[-800:])
        sel, absent = _dart_selected(k.stdout + k.stderr)
        observations['selected_count'] = sel
        observations['selected_but_absent'] = absent

        snap = main_run.snapshot(extra=['--maot_trace_registration'])
        if snap.returncode != 0 or not os.path.exists(main_run.aot):
            finding('SNAPSHOT_FAILED', (snap.stderr or snap.stdout)[-800:])
        got, of, dropped = _materialized(snap.stderr + snap.stdout)
        observations['materialized_count'] = got
        observations['materialized_dropped'] = dropped

        reg_path = os.path.join(work, 'registry.json')
        st_path = os.path.join(work, 'selftest.json')
        # SEPARATE PROCESS for the resolution probes. The self-test stages and
        # commits by design, so a probe sharing its invocation reads a
        # registry the test itself moved -- which is how the first version of
        # this arm ended up reporting Shapes.instanceOne under the name
        # "compute". Nothing in this process ever mutates the registry.
        probe_path = os.path.join(work, 'probes.json')
        pr = main_run.run_aot(dump=reg_path, probes=probe_path)
        if pr.returncode != 0:
            finding('PROBE_RUN_FAILED', (pr.stderr or pr.stdout)[-400:])
        r = main_run.run_aot(selftest=st_path)
        if r.returncode != 0:
            finding('RUNTIME_FAILED', (r.stderr or r.stdout)[-800:])
        if os.path.exists(reg_path):
            registry = json.load(open(reg_path))
        if os.path.exists(st_path):
            selftest = json.load(open(st_path))
        probes_doc = {}
        if os.path.exists(probe_path):
            probes_doc = json.load(open(probe_path))

        reg_ids = {e['declaration_id'] for e in registry.get('entries', [])}
        observations['registry_ids'] = sorted(reg_ids)
        observations['selected_minus_registry'] = sorted(
            SELECTED_EXPECTED - reg_ids)
        observations['registry_minus_selected'] = sorted(
            reg_ids - SELECTED_EXPECTED)
        observations['duplicate_ids'] = (
            len(reg_ids) != len(registry.get('entries', [])))
        observations['unselected_slots'] = sum(
            1 for e in registry.get('entries', []) if not e.get('selected'))
        # Each id must pair with the Function for THAT declaration. The
        # expected VM name is derived from the id's own structure -- not from a
        # table of the fixture's four answers, which would pass for any
        # permutation of them.
        pairs, mismatches = [], []
        for e in registry.get('entries', []):
            want = _expected_vm_name(e['declaration_id'])
            diag = e['current'].get('implementation_name_diagnostic', '')
            ok = diag.startswith("Function '%s'" % want)
            pairs.append({'declaration_id': e['declaration_id'],
                          'expected_vm_name': want, 'observed': diag,
                          'match': ok})
            if not ok:
                mismatches.append(e['declaration_id'])
        observations['binding_pairs'] = pairs
        observations['binding_pairs_correct'] = bool(pairs) and not mismatches
        observations['binding_mismatches'] = mismatches
        observations['address_used_as_identity'] = False

        # ---------------- live falsification arms ----------------
        # Each arm perturbs the pipeline, feeds the PERTURBED observations
        # through the same verdict module, and requires the verdict to flip.
        # "a number changed" is not the claim; "the gate would have refused"
        # is.
        def arm(aid, why, ok, observed, flipped=None):
            rec = {'id': aid, 'kind': V.BANK[aid][0],
                   'description': V.BANK[aid][1], 'why': why,
                   'result': 'pass' if ok else 'FAIL', 'observed': observed}
            if flipped is not None:
                rec['verdict_under_defect'] = flipped
            arms.append(rec)

        def perturbed(reg=None, st=None, **over):
            """The verdict this same module would return under a defect."""
            po = dict(observations)
            po.update(over)
            return V.evaluate(po, [],
                              registry=registry if reg is None else reg,
                              selftest=selftest if st is None else st)

        # F08 / F09 -- selection disconnected from the precompiler worklist.
        f8 = Run(os.path.join(work, 'f08'))
        f8.kernel(trace=False)
        s8 = f8.snapshot(extra=['--maot_disable_seeding',
                                '--maot_trace_registration'])
        g8, seen8, d8 = _materialized(s8.stderr + s8.stdout)
        v8 = perturbed(reg={}, materialized_count=g8, materialized_dropped=d8,
                       registry_ids=[],
                       selected_minus_registry=sorted(SELECTED_EXPECTED),
                       binding_pairs_correct=False)
        arm('F08', 'retention must be a decision this code makes, not a GC '
                   'side effect it inherits',
            g8 == 0 and (d8 or 0) > 0
            and v8['runtime_implementation_registry'] == 'NOT_ESTABLISHED',
            f'without seeding: materialized {g8} of {seen8} selected, '
            f'{d8} refused', v8['runtime_implementation_registry'])
        arm('F09', 'a selected Function the precompiler did not retain must be '
                   'REFUSED, not shipped as an empty slot',
            g8 == 0 and (d8 or 0) == seen8,
            f'all {d8} selected declarations refused as unretained/'
            f'non-executable; none became a slot')

        # F04 -- the constructor seam removed. An ordinary-procedure-only
        # registry must not read as complete.
        f4 = Run(os.path.join(work, 'f04'))
        f4.kernel(trace=False)
        s4 = f4.snapshot(extra=['--maot_disable_constructor_seam',
                                '--maot_trace_registration'])
        g4, seen4, d4 = _materialized(s4.stderr + s4.stdout)
        ctors = sum(1 for i in SELECTED_EXPECTED if i.endswith('::ctor:'))
        r4 = os.path.join(work, 'f04_registry.json')
        f4.run_aot(dump=r4)
        ids4 = set()
        if os.path.exists(r4):
            ids4 = {e['declaration_id']
                    for e in json.load(open(r4)).get('entries', [])}
        reg4 = json.load(open(r4)) if os.path.exists(r4) else {}
        v4 = perturbed(reg=reg4, materialized_count=g4,
                       materialized_dropped=d4 or 0,
                       registry_ids=sorted(ids4),
                       selected_minus_registry=sorted(SELECTED_EXPECTED - ids4),
                       registry_minus_selected=sorted(ids4 - SELECTED_EXPECTED))
        arm('F04', 'a missing binding seam must not read as "basically '
                   'complete" because the other three are present',
            g4 == len(SELECTED_EXPECTED) - ctors and (SELECTED_EXPECTED - ids4)
            and v4['runtime_implementation_registry'] == 'NOT_ESTABLISHED',
            f'{g4} of {len(SELECTED_EXPECTED)} bound with the constructor '
            f'seam removed ({ctors} constructor(s) expected to vanish); '
            f'missing {sorted(SELECTED_EXPECTED - ids4)}',
            v4['runtime_implementation_registry'])

        # F10 -- an unselected declaration reaching the final registry.
        f10 = Run(os.path.join(work, 'f10'))
        f10.kernel(trace=False)
        f10.snapshot(extra=['--maot_materialize_unselected'])
        r10 = os.path.join(work, 'f10_registry.json')
        f10.run_aot(dump=r10)
        ids10, unselected10 = set(), 0
        e10 = []
        if os.path.exists(r10):
            e10 = json.load(open(r10)).get('entries', [])
            ids10 = {e['declaration_id'] for e in e10}
            unselected10 = sum(1 for e in e10 if not e.get('selected'))
        # The same run answers a second question: is the call-convention
        # component a live measurement or a constant string? Unselected
        # declarations are not entry points, so they are not pinned to the
        # stack convention, and any difference here is the fingerprint
        # discriminating inside one run of one compiler.
        observations['callconv_unselected_probe'] = [
            {'declaration_id': e['declaration_id'],
             'selected': e.get('selected'),
             'call_convention': e.get('call_convention')}
            for e in e10 if not e.get('selected')]
        selected_ccs = {e.get('call_convention')
                        for e in e10 if e.get('selected')}
        unselected_ccs = {e.get('call_convention')
                          for e in e10 if not e.get('selected')}
        observations['callconv_varies_across_selection'] = bool(
            unselected_ccs - selected_ccs)
        reg10 = json.load(open(r10)) if os.path.exists(r10) else {}
        v10 = perturbed(reg=reg10, registry_ids=sorted(ids10),
                        unselected_slots=unselected10,
                        registry_minus_selected=sorted(ids10 -
                                                       SELECTED_EXPECTED),
                        selected_minus_registry=sorted(SELECTED_EXPECTED -
                                                       ids10))
        arm('F10', 'a slot is an authoritative promise of mutability; an '
                   'unselected declaration must never hold one',
            unselected10 > 0 and (ids10 - SELECTED_EXPECTED)
            and v10['runtime_implementation_registry'] == 'NOT_ESTABLISHED',
            f'filter removed: {len(ids10)} entries, {unselected10} of them '
            f'unselected, {len(ids10 - SELECTED_EXPECTED)} outside the '
            f'selected set', v10['runtime_implementation_registry'])

        # F01 -- the pragma unreachable at the VM target. Asserted against the
        # fork source rather than by editing it mid-run: the arm names the one
        # line whose removal makes the parser case dead code.
        target = os.path.join(FORK, 'pkg/vm/lib/modular/target/vm.dart')
        target_src = open(target).read() if os.path.exists(target) else ''
        gated = 'kMaotMutablePragmaName' in target_src
        arm('F01', 'a parser arm for a pragma the target rejects is dead code, '
                   'and nothing else in the pipeline says so',
            gated and sel == len(SELECTED_EXPECTED),
            f'VmTarget.isSupportedPragma accepts maot:mutable and {sel} were '
            f'selected' if gated else
            'VmTarget does NOT accept it; the parser case is unreachable')

        # F02 -- a selected declaration eliminated before metadata attachment.
        v2 = perturbed(selected_but_absent=['lib:package:m2app/app.dart::'
                                            'fn:neverCalled'])
        arm('F02', 'a selected declaration removed by tree shaking must be '
                   'reported, not silently absent from the registry',
            absent == [] and sel == len(SELECTED_EXPECTED)
            and v2['runtime_implementation_registry'] == 'NOT_ESTABLISHED',
            f'selected={sel} selectedButAbsent={absent}; a non-empty absence '
            f'list forces NOT_ESTABLISHED',
            v2['runtime_implementation_registry'])

        # F12..F17 -- proven by the in-VM self-test arms, which run inside the
        # precompiled runtime against the real registry.
        st_ok = {a['id']: a['result'] == 'pass'
                 for a in selftest.get('arms', [])}
        for aid, sids, why in (
                ('F12', ('D01',), 'two entities claiming one identity means a '
                                  'patch binds to the wrong one'),
                ('F13', ('N01',), 'a patch built against another release must '
                                  'not bind to a same-spelling declaration'),
                ('F14', ('S01', 'S02', 'S03', 'S04'),
                        'a staged replacement must be invisible to the current '
                        'lookup until an explicit commit'),
                ('F15', ('V03',), 'a version bump with no implementation '
                                  'change is not a replacement'),
                ('F16', ('V01',), 'an implementation change must advance the '
                                  'version'),
                ('F17', ('A01',), 'an incompatible ABI must be refused BEFORE '
                                  'any state changes'),
                ('F24', ('X01', 'X02'),
                        'a replacement that rewrites Function::CurrentCode() '
                        'directly leaves the registry describing an '
                        'implementation that is no longer running')):
            ok = all(st_ok.get(s) for s in sids)
            arm(aid, why, ok,
                ', '.join(f'{s}={"pass" if st_ok.get(s) else "FAIL/absent"}'
                          for s in sids))

        # F18 -- equal cardinality, different sets.
        fake_ids = (sorted(SELECTED_EXPECTED)[:len(SELECTED_EXPECTED) - 1]
                    + ['lib:package:m2app/app.dart::fn:notMutable'])
        v18 = perturbed(registry_ids=fake_ids,
                        selected_minus_registry=sorted(SELECTED_EXPECTED -
                                                       set(fake_ids)),
                        registry_minus_selected=sorted(set(fake_ids) -
                                                       SELECTED_EXPECTED))
        arm('F18', 'counts agreeing while the sets differ must not pass; this '
                   'is why no condition compares cardinality alone',
            not v18['conditions']['selected_set_exact']
            and v18['runtime_implementation_registry'] == 'NOT_ESTABLISHED',
            f'{len(fake_ids)} ids vs {len(SELECTED_EXPECTED)} selected, one '
            f'substituted; selected_set_exact = '
            f'{v18["conditions"]["selected_set_exact"]}',
            v18['runtime_implementation_registry'])

        # F19 -- a record from another run standing in for this one.
        v19 = perturbed(reg={}, st={}, registry_ids=[],
                        binding_pairs_correct=False)
        arm('F19', 'stale evidence must not survive a failed current run',
            v19['runtime_implementation_registry'] == 'NOT_ESTABLISHED',
            'with this run\'s registry and self-test empty the verdict is '
            f'{v19["runtime_implementation_registry"]}, regardless of what any '
            'previously written file says',
            v19['runtime_implementation_registry'])

        # ---------------- measurements ----------------
        # Diagnostic, not pass/fail: no threshold is compared anywhere. The
        # control is the identical program with the pragmas removed, so the
        # delta is the cost of selection rather than the cost of the fixture.
        # The control is also the F22 subject: a program with no
        # maot:mutable anywhere must still build, and must end with an empty
        # registry rather than a populated or broken one.
        ctl = Run(os.path.join(work, 'control'), fixture=FIXTURE_CONTROL)
        ck = ctl.kernel(trace=False)
        cs = ctl.snapshot()
        ctl_reg = os.path.join(work, 'control_registry.json')
        cr = ctl.run_aot(dump=ctl_reg) if cs.returncode == 0 else None
        ctl_entries = None
        if os.path.exists(ctl_reg):
            ctl_entries = len(json.load(open(ctl_reg)).get('entries', []))
        observations['control_build'] = {
            'kernel_rc': ck.returncode,
            'snapshot_rc': cs.returncode,
            'snapshot_stderr_tail': (cs.stderr or '')[-300:],
            'elf_bytes': os.path.getsize(ctl.aot)
                         if os.path.exists(ctl.aot) else 0,
            'runtime_rc': cr.returncode if cr is not None else None,
            'registry_entries': ctl_entries,
        }
        cb = observations['control_build']
        arm('F22', 'MAOT must be inert in a release that never used it; a '
                   'pragma-free app is the common case, not an edge case',
            cb['kernel_rc'] == 0 and cb['snapshot_rc'] == 0
            and cb['elf_bytes'] > 0 and cb['runtime_rc'] == 0
            and cb['registry_entries'] == 0,
            f"no-pragma build: kernel={cb['kernel_rc']} "
            f"snapshot={cb['snapshot_rc']} elf={cb['elf_bytes']}B "
            f"runtime={cb['runtime_rc']} registry_entries="
            f"{cb['registry_entries']}"
            + (f" :: {cb['snapshot_stderr_tail']}"
               if cb['snapshot_rc'] != 0 else ''))

        def median_ms(run, n=7):
            xs = []
            for _ in range(n):
                t = time.perf_counter()
                run.run_aot()
                xs.append((time.perf_counter() - t) * 1000.0)
            xs.sort()
            return round(xs[len(xs) // 2], 2)

        with_b = os.path.getsize(main_run.aot) \
            if os.path.exists(main_run.aot) else None
        # A failed control has no size, and 0 is not a size. Reporting a
        # delta against it would state the whole snapshot as MAOT's cost.
        without_b = cb['elf_bytes'] if cb['elf_bytes'] > 0 else None
        m = {
            'aot_elf_bytes_with_maot': with_b,
            'aot_elf_bytes_control_no_pragmas': without_b,
            'aot_elf_delta_bytes': (with_b - without_b)
                                   if (without_b and with_b) else None,
            'startup_ms_with_maot': median_ms(main_run),
            'startup_ms_control': median_ms(ctl) if without_b else None,
            'control_note': 'absent here means the control build failed, not '
                            'that it was skipped',
            'note': 'medians of 7 runs of the same program; the control is the '
                    'identical source with every maot:mutable removed, so the '
                    'delta includes keeping a dead selected declaration alive',
        }
        m.update({f'registry_{k}': v
                  for k, v in (selftest.get('measurements') or {}).items()})
        observations['measurements'] = m

        # F21 -- binaries that were not built from the sources on disk. Not
        # hypothetical: an earlier run measured a seven-minute-old
        # gen_snapshot because `ninja ... | tail` reports tail's exit status,
        # so the build had failed silently. Only a falsification arm noticed.
        # The guard compares content, because the first version compared
        # mtimes and a `git checkout` rewrites every mtime without changing a
        # byte.
        edited = dict(build_digests())
        victim = 'runtime/vm/maot_registry.cc'
        edited[victim] = 'f' * 64
        hypothetical = staleness(override=edited)
        arm('F21', 'a run that measures a different program than the one it '
                   'names is worse than a run that does not happen',
            observations['stale_binaries'] == [] and len(hypothetical) == 1
            and hypothetical[0].get('file') == victim,
            f'the toolchain matches all {len(MAOT_CXX_SOURCES)} sources now; '
            f'against one edited source the guard reports '
            f'{len(hypothetical)} mismatch '
            f'({hypothetical[0].get("file") if hypothetical else "none"})')

        # ---------------- ABI dimension discrimination ----------------
        # The matrix is measured, not asserted: the self-test attempted a real
        # StageReplacement for every ordered pair and recorded whether it was
        # accepted. Here each named dimension is checked against it.
        matrix = selftest.get('compatibility_matrix') or []
        by_pair = {(m['onto'], m['from']): m for m in matrix}
        full = {leaf: i for i in registry_ids_list(registry)
                for leaf in [i.split('::', 1)[1] if '::' in i else i]}

        dimension_rows, undiscriminated, missing_pairs = [], [], []
        for name, (a, b) in ABI_DIMENSIONS.items():
            ia, ib = full.get(a), full.get(b)
            if ia is None or ib is None:
                missing_pairs.append(f'{name}: {a if ia is None else b} '
                                     f'is not in the registry')
                continue
            fwd, rev = by_pair.get((ia, ib)), by_pair.get((ib, ia))
            if fwd is None or rev is None:
                missing_pairs.append(f'{name}: the matrix has no entry for '
                                     f'this pair')
                continue
            # Refused in BOTH directions, and the refusal must be because a
            # component differs -- not because some unrelated guard fired.
            differs = (not fwd['abi_equal']) or (not
                                                 fwd['call_convention_equal'])
            ok = differs and not fwd['accepted'] and not rev['accepted']
            dimension_rows.append({
                'dimension': name, 'a': ia, 'b': ib,
                'abi_equal': fwd['abi_equal'],
                'call_convention_equal': fwd['call_convention_equal'],
                'accepted_a_from_b': fwd['accepted'],
                'accepted_b_from_a': rev['accepted'],
                'discriminated': ok,
            })
            if not ok:
                undiscriminated.append(name)
        observations['abi_dimensions'] = dimension_rows
        observations['abi_dimensions_undiscriminated'] = undiscriminated
        observations['abi_dimension_pairs_missing'] = missing_pairs
        observations['abi_not_represented'] = ABI_NOT_REPRESENTED

        # The matrix as a whole must be an equivalence, not an implication:
        # every identical pair accepted, every differing pair refused. This is
        # what catches a dimension nobody thought to name.
        violations = [
            {'onto': m['onto'], 'from': m['from'],
             'abi_equal': m['abi_equal'],
             'call_convention_equal': m['call_convention_equal'],
             'accepted': m['accepted']}
            for m in matrix
            if m['accepted'] != (m['abi_equal'] and m['call_convention_equal'])
        ]
        observations['compatibility_matrix_size'] = len(matrix)
        observations['compatibility_matrix_violations'] = violations
        observations['compatibility_matrix_accepted'] = sum(
            1 for m in matrix if m['accepted'])

        arm('F25', 'a compatibility model missing a dimension accepts a '
                   'replacement that differs in it',
            not undiscriminated and not missing_pairs and not violations
            and len(matrix) > 0,
            f'{len(matrix)} ordered pairs attempted, '
            f'{observations["compatibility_matrix_accepted"]} accepted; '
            f'{len(dimension_rows)} named dimensions, '
            f'{len(undiscriminated)} not discriminated'
            + (f' ({", ".join(undiscriminated)})' if undiscriminated else '')
            + (f'; {len(violations)} matrix violations' if violations else ''))

        # ---------------- generic-scope injectivity ----------------
        # A renderer that spells scopes by NAME, or that drops a nested
        # function type's own binder, collides these pairs. The projection
        # below erases exactly the information the positional encoding adds --
        # the scope index, and the nested binder's declaration -- and shows the
        # pairs become indistinguishable under it while being distinct in
        # reality. So the positional encoding is what separates them, rather
        # than something else in the string happening to differ.
        def erase_positional_scope(abi):
            """The information a name-spelling, binder-dropping renderer kept.

            `otp0`/`otp1` both came back as the source name, so they collapse
            together; a nested `fn<N:bounds>` had no binder declaration at all,
            so that prefix is removed.
            """
            # No \b anchors: the bounds field is introduced by a bare `b`,
            # so `botp0` has no word boundary before `otp` and an anchored
            # pattern silently matches nothing -- which would make this
            # projection claim the pairs do not collide.
            out = re.sub(r'(otp|mtp)\d+', r'\1', abi)
            out = re.sub(r'ftp\d+\.\d+', 'ftp', out)
            out = re.sub(r'fn<\d+(?::[^>]*)?>', 'fn<>', out)
            return out

        abi_of = {e['declaration_id']: e['abi']
                  for e in registry.get('entries', [])}
        collision_rows = []
        for name in ('owner type-parameter position',
                     'nested function-type bound'):
            a, b = ABI_DIMENSIONS[name]
            ia, ib = full.get(a), full.get(b)
            if ia is None or ib is None:
                continue
            raw_a, raw_b = abi_of.get(ia, ''), abi_of.get(ib, '')
            collision_rows.append({
                'dimension': name,
                'a': ia, 'b': ib,
                'abi_a': raw_a, 'abi_b': raw_b,
                'distinct_now': raw_a != raw_b,
                'collides_without_positional_scope':
                    erase_positional_scope(raw_a)
                    == erase_positional_scope(raw_b),
                'projected': erase_positional_scope(raw_a),
            })
        observations['generic_scope_collisions'] = collision_rows

        # Under a colliding renderer the matrix would report these pairs as
        # abi_equal and accept them. Feed that state through the same
        # acceptance logic and require refusal.
        collided_dims = []
        for row in dimension_rows:
            if row['dimension'] in ('owner type-parameter position',
                                    'nested function-type bound'):
                collided_dims.append(dict(row, abi_equal=True,
                                          accepted_a_from_b=True,
                                          accepted_b_from_a=True,
                                          discriminated=False))
            else:
                collided_dims.append(row)
        v27 = perturbed(
            abi_dimensions=collided_dims,
            abi_dimensions_undiscriminated=['owner type-parameter position',
                                            'nested function-type bound'])
        arm('F27', 'a type renderer that spells generic scopes by name, or '
                   'drops a nested function type\'s own binder, canonicalizes '
                   'two different ABI shapes to one string',
            bool(collision_rows)
            and all(r['distinct_now'] for r in collision_rows)
            and all(r['collides_without_positional_scope']
                    for r in collision_rows)
            and not v27['conditions'][
                'abi_model_discriminates_every_dimension']
            and v27['runtime_implementation_registry'] == 'NOT_ESTABLISHED',
            f'{len(collision_rows)} pairs are distinct with positional scopes '
            f'and collide without them; under a colliding renderer the model '
            f'discriminates '
            f'{v27["conditions"]["abi_model_discriminates_every_dimension"]}',
            v27['runtime_implementation_registry'])

        # And the other direction: renaming a type parameter without changing
        # structure must stay EQUAL, or the renderer is strict rather than
        # injective and every replacement becomes impossible.
        rt = full.get('fn:renamedT')
        ru = full.get('fn:renamedU')
        rename_equal = (rt is not None and ru is not None
                        and abi_of.get(rt) == abi_of.get(ru))
        rename_accepted = bool(by_pair.get((rt, ru), {}).get('accepted'))
        observations['type_parameter_rename_is_invisible'] = rename_equal
        observations['type_parameter_rename_accepted'] = rename_accepted
        arm('F28', 'a renderer that encoded type-parameter NAMES would refuse '
                   'a pure rename, making the model strict rather than '
                   'injective and every replacement impossible',
            rename_equal and rename_accepted,
            f'renamedT and renamedU canonicalize equal={rename_equal} and the '
            f'matrix accepts the pair={rename_accepted}')

        # ---------------- the boxed-stack calling-convention invariant ----
        cc_rows = [{'declaration_id': e['declaration_id'],
                    'call_convention': e.get('call_convention'),
                    'boxed_stack': callconv_is_boxed_stack(
                        e.get('call_convention'))}
                   for e in registry.get('entries', [])]
        observations['selected_call_conventions'] = cc_rows
        observations['call_conventions_not_boxed_stack'] = [
            r['declaration_id'] for r in cc_rows if not r['boxed_stack']]

        # F26 -- a selected declaration whose convention is NOT the boxed stack
        # form. Perturb one measured entry and require the gate to refuse: the
        # invariant has to be enforced, not assumed, because everything that
        # makes replacement safe here rests on it.
        if registry.get('entries'):
            broken = json.loads(json.dumps(registry))
            victim_cc = broken['entries'][0].get('call_convention', '')
            broken['entries'][0]['call_convention'] = victim_cc.replace(
                ';argst', ';argsi').replace(';rett', ';reti')
            v26 = perturbed(
                reg=broken,
                selected_call_conventions=[
                    {'declaration_id': e['declaration_id'],
                     'call_convention': e.get('call_convention'),
                     'boxed_stack': callconv_is_boxed_stack(
                         e.get('call_convention'))}
                    for e in broken['entries']],
                call_conventions_not_boxed_stack=[
                    e['declaration_id'] for e in broken['entries']
                    if not callconv_is_boxed_stack(e.get('call_convention'))])
            arm('F26', 'a selected declaration escaping the boxed stack '
                       'convention would let a replacement be handed unboxed '
                       'values where the release expects tagged ones',
                observations['call_conventions_not_boxed_stack'] == []
                and not v26['conditions'][
                    'selected_calling_convention_is_boxed_stack']
                and v26['runtime_implementation_registry'] == 'NOT_ESTABLISHED',
                f"all {len(cc_rows)} selected declarations measure the boxed "
                f"stack form; with one entry's representation changed to "
                f"unboxed int the condition is "
                f"{v26['conditions']['selected_calling_convention_is_boxed_stack']}",
                v26['runtime_implementation_registry'])

        # ---------------- injected name-keyed resolver ----------------
        # The probes come from their own process, and they are not trusted on
        # the strength of that alone: each probe's Function name must agree
        # with the binding evidence in the registry dump before either
        # resolver's result is allowed to mean anything. A contaminated probe
        # is a blocking finding, not a quietly wrong number.
        probes = probes_doc.get('resolution_probes') or []
        diag_name = {}
        for e in registry.get('entries', []):
            d = e['current'].get('implementation_name_diagnostic', '')
            # "Function 'name': qualifiers." -> name
            if "'" in d:
                diag_name[e['declaration_id']] = d.split("'")[1]
        contaminated = [
            {'declaration_id': p['declaration_id'],
             'probe_function_name': p['function_name'],
             'binding_function_name': diag_name.get(p['declaration_id'])}
            for p in probes
            if diag_name.get(p['declaration_id']) is not None
            and p['function_name'] != diag_name[p['declaration_id']]
            and not diag_name[p['declaration_id']].endswith('.')]
        observations['probe_state_pristine'] = probes_doc.get('pristine')
        observations['probes_contaminated'] = contaminated
        if contaminated:
            finding('PROBE_STATE_CONTAMINATED',
                    f'{len(contaminated)} resolution probe(s) name a Function '
                    f'the declaration does not own according to the binding '
                    f'evidence; the probed state is not the release state')
        if probes and probes_doc.get('pristine') is not True:
            finding('PROBE_STATE_NOT_PRISTINE',
                    'the runtime reported that the registry had already been '
                    'staged or advanced when the probes were taken')

        by_id = [p for p in probes if p['resolver'] == 'declaration_id']
        by_name = [p for p in probes if p['resolver'] == 'function_name']
        id_wrong = [p for p in by_id if p['resolved_to'] != p['declaration_id']]
        name_aliased = [p for p in by_name
                        if p['resolved_to'] != p['declaration_id']]
        observations['resolution_probes'] = probes
        observations['declaration_id_resolver_mismatches'] = id_wrong
        observations['name_keyed_resolver_aliases'] = name_aliased

        # The defect really happened in the VM, over the real pristine
        # registry. Feed THOSE numbers through the same acceptance logic and
        # require refusal.
        v23 = perturbed(probe_state_pristine=probes_doc.get('pristine'),
                        probes_contaminated=contaminated,
                        resolution_probes=[dict(p, resolver='declaration_id')
                                           for p in by_name])
        arm('F23', 'a resolver keyed on the Function name aliases two '
                   'declarations that share one, and binds a patch to the '
                   'wrong body',
            bool(name_aliased) and not id_wrong
            and not v23['conditions']['identity_not_name_keyed']
            and v23['runtime_implementation_registry'] == 'NOT_ESTABLISHED',
            f'probes taken in a process that never mutated the registry '
            f'(pristine={probes_doc.get("pristine")}, '
            f'{len(contaminated)} contaminated against the binding evidence); '
            f'the name-keyed resolver aliased {len(name_aliased)} of '
            f'{len(by_name)} declarations '
            f'({", ".join(sorted({p["function_name"] for p in name_aliased}))}'
            f'); the DeclarationId resolver aliased {len(id_wrong)}',
            v23['runtime_implementation_registry'])

        # F20 is resolved after the record is assembled -- it is a claim
        # about the record's own shape, not about the pipeline.

    finally:
        shutil.rmtree(work, ignore_errors=True)

    live = sorted(k for k, (kind, _) in V.BANK.items() if kind == 'live')
    historical = sorted(k for k, (kind, _) in V.BANK.items()
                        if kind == 'historical')

    record = {
        'schema': 'maot.m2.evidence/1',
        'issue': 66,
        'generated_by': {
            'run_id': run_id,
            'gate_sha256': sha256_file(os.path.abspath(__file__)),
            'verdict_sha256': sha256_file(os.path.join(
                os.path.dirname(os.path.abspath(__file__)), 'verdict_m2.py')),
        },
        'identities': {
            'shorebird_revision': git(repo, 'rev-parse', 'HEAD'),
            'shorebird_tree': git(repo, 'rev-parse', 'HEAD^{tree}'),
            'fork_commit': git(FORK, 'rev-parse', 'HEAD'),
            'fork_tree': git(FORK, 'rev-parse', 'HEAD^{tree}'),
            'fork_branch': git(FORK, 'rev-parse', '--abbrev-ref', 'HEAD'),
            # The list, not a bool: "dirty" that turns out to be a Finder
            # .DS_Store is a different fact from "dirty" that is an unstaged
            # source edit, and only one of them means the record names a
            # revision that does not exist.
            'fork_worktree_entries': [
                l for l in (git(FORK, 'status', '--porcelain') or '').split('\n')
                if l.strip()],
            'fork_source_dirty': any(
                not l.endswith('.DS_Store')
                for l in (git(FORK, 'status', '--porcelain') or '').split('\n')
                if l.strip()),
            'namespace_identity': NAMESPACE,
            'note': 'a branch is transport; the commit and tree are identity',
        },
        'observations': observations,
        'selftest': selftest,
        'registry': registry,
        'falsification': None,          # filled below, after F20 resolves
        'falsification_bank': {
            'live': live, 'historical': historical,
            'historical_note':
                'defects this implementation actually hit. They are recorded '
                'with the reasoning that resolved them rather than as live '
                'arms, because the code can no longer express several of '
                'them -- an arm that cannot be built is not the same thing '
                'as a defect that never happened.',
        },
        'findings': findings,
        'consumers': None,              # filled below
        'verdict': None,                # filled below
    }

    # F20: every value this record computes must be read by some decision,
    # and every decision named must correspond to a value actually produced.
    produced = set(record)
    named = set(V.CONSUMERS)
    problems = [f'{k!r} computed but no decision declared to consume it'
                for k in sorted(produced - named)]
    problems += [f'CONSUMERS names {k!r}, which is not produced'
                 for k in sorted(named - produced)]
    arms.append({
        'id': 'F20', 'kind': V.BANK['F20'][0],
        'description': V.BANK['F20'][1],
        'why': 'a computed finding no decision reads is decoration; a named '
               'consumer with no value behind it is a dangling claim',
        'result': 'pass' if not problems else 'FAIL',
        'observed': f'{len(produced)} produced keys, {len(named)} declared '
                    f'consumers, {len(problems)} mismatches'
                    + (': ' + '; '.join(problems) if problems else ''),
    })
    for p in problems:
        finding('VALUE_NOT_CONSUMED', p)
    record['consumers'] = {'map': V.CONSUMERS,
                           'unconsumed_or_undeclared': problems}

    failed = [a['id'] for a in arms if a['result'] != 'pass']
    observations['falsifications_failed'] = failed
    if failed:
        finding('FALSIFICATION_ARM_FAILED',
                f'arms that did not demonstrate their defect: '
                f'{", ".join(failed)}')
    missing_live = [k for k in live if k not in {a['id'] for a in arms}]
    if missing_live:
        finding('FALSIFICATION_ARM_ABSENT',
                f'live bank entries with no arm: {", ".join(missing_live)}')
    stray = [a['id'] for a in arms if a['id'] not in V.BANK]
    if stray:
        finding('FALSIFICATION_ARM_UNBANKED',
                f'arms not in the bank: {", ".join(stray)}')

    record['falsification'] = arms
    record['verdict'] = V.evaluate(observations, findings,
                                   registry=registry, selftest=selftest)

    # A run that could not happen must not overwrite the record of a run that
    # did. Refusing to start is not the same failure as measuring something
    # and finding it wrong, and only the second one supersedes the evidence.
    refused = any(f['code'] == 'FORK_NOT_ON_MAOT_REVISION' for f in findings)
    if refused:
        out_path = out_path + '.attempted'
        print('the rig is handed back, so this run measured nothing; writing '
              f'to {out_path} rather than overwriting the record')

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, 'w') as fh:
        json.dump(record, fh, indent=2)
        fh.write('\n')

    v = record['verdict']
    blocking = [f for f in findings if f['severity'] == 'blocking']
    print(f'fork            {record["identities"]["fork_commit"]}')
    print(f'selected        {observations.get("selected_count")}')
    print(f'registry        {len(observations.get("registry_ids") or [])}')
    print(f'arms            {len(arms)} ({len(failed)} failed)')
    print(f'blocking        {len(blocking)}')
    print(f'conditions      {len(v["conditions"])} '
          f'({len(v["conditions_failed"])} failed)')
    for c in v['conditions_failed']:
        print(f'  unmet: {c}')
    for f in blocking[:8]:
        print(f'  {f["code"]}: {f["message"][:120]}')
    print(f'VERDICT         runtime_implementation_registry = '
          f'{v["runtime_implementation_registry"]}')
    return 0 if not blocking and not v['conditions_failed'] else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
