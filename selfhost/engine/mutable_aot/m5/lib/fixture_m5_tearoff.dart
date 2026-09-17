// MAOT-5 (#69) -- TEAR-OFF surface. Separate on purpose.
//
// Ordinary instance dispatch being established says nothing about tear-offs,
// and this fixture must not be read as inheriting it. A tear-off does not
// dispatch on a receiver at the call site at all: it allocates a Closure that
// captures the receiver, and the call site invokes the closure.
//
// The question is what FROZEN object retains the declaration/Code identity,
// and there are two materially different cases:
//
//   tearoff_pre  -- the closure is captured BEFORE the replacement. It is
//                   existing live state. Whether it must observe the new body
//                   is a SEMANTIC question, not a bug to be fixed by reflex.
//   tearoff_post -- the closure is taken AFTER the replacement. This one has
//                   no ambiguity: it must observe the new body.
//
// This fixture MEASURES both. It does not assert which answer tearoff_pre
// should give. What is not acceptable either way is an install that reports
// success while leaving a caller silently on OLD with no stated semantics.
//
// The bodies interpolate a runtime input so nothing constant-folds and the
// body Code carries real static calls.
import 'dart:ffi';
import 'dart:io' show Platform;

final int input = int.tryParse(Platform.environment['M5_INPUT'] ?? '') ?? 10;

class Alpha {
  @pragma('maot:mutable')
  String v(int x) => 'OLD:${x * 2}';
}

class AlphaNew {
  @pragma('maot:mutable')
  String v(int x) => 'NEW:${x * 3}';
}

class AlphaNew2 {
  @pragma('maot:mutable')
  String v(int x) => 'NEW2:${x + 7}';
}

class Beta {
  @pragma('maot:mutable')
  String v(int x) => 'BETA:${x * 5}';
}

class F1 { String v(int x) => 'F1'; }
class F2 { String v(int x) => 'F2'; }
class F3 { String v(int x) => 'F3'; }
class F4 { String v(int x) => 'F4'; }
class F5 { String v(int x) => 'F5'; }
class F6 { String v(int x) => 'F6'; }

@pragma('vm:never-inline')
dynamic mk(int i) {
  switch (i) {
    case 0: return Alpha();
    case 1: return Beta();
    case 2: return F1();
    case 3: return F2();
    case 4: return F3();
    case 5: return F4();
    case 6: return F5();
    default: return F6();
  }
}

// THE TEAR-OFF SITE: takes the closure off a dynamic receiver.
@pragma('vm:never-inline')
Function tear(dynamic d) => d.v;

// THE CALL SITE: invokes an already-captured closure. No receiver dispatch
// happens here at all, which is exactly what makes this a separate surface.
@pragma('vm:never-inline')
String callTorn(Function f, int x) => f(x) as String;

const _lib = 'lib:package:m5tearoff/fixture_m5_tearoff.dart';

final _proc = DynamicLibrary.process();
final _malloc = _proc.lookupFunction<Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)>('malloc');
final _install = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>, Int64, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>, int,
        Pointer<Uint8>)>('Dart_MaotInstallForTesting');
final _version = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotCurrentVersionForTesting');
final _stateCount = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotObservedStateCount');
final _ident = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotTrampolineIdentityForTesting');
final _dump = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotDumpForTesting');
final _inspect = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>)>(
    'Dart_MaotInspectSwitchableSite');

Pointer<Uint8> _c(String s) {
  final u = s.codeUnits;
  final p = _malloc(u.length + 1);
  for (var i = 0; i < u.length; i++) {
    p[i] = u[i];
  }
  p[u.length] = 0;
  return p;
}

void _emit(String k, Object v) => print('$k=$v');
final _ns = Platform.environment['MAOT_NAMESPACE'] ?? '';
const _decl = 'cls:Alpha::method:v';
int _stage(String i, int v) =>
    _install(_c('$_lib::$_decl'), _c('$_lib::$i'), v, _c(_ns));
final _siteOut =
    Platform.environment['M5_SITE_REPORT'] ?? '/tmp/maot_tearoff_site.txt';
int _look() => _inspect(_c('$_lib::$_decl'), _c(_siteOut));

const _states = [
  'instance-dispatch/UnlinkedCall-observed',
  'instance-dispatch/MonomorphicSmiableCall-observed',
  'instance-dispatch/monomorphic-observed',
  'instance-dispatch/SingleTargetCache-observed',
  'instance-dispatch/ICData-observed',
  'instance-dispatch/MegamorphicCache-observed',
  'any-dispatch/miss-observed',
];
List<int> _counts() => [for (final s in _states) _stateCount(_c(s))];

void main(List<String> args) {
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  _emit('input', input);
  _emit('retain.new', AlphaNew().v(input));
  _emit('retain.new2', AlphaNew2().v(input));
  _emit('tramp.identity', _ident(_c('$_lib::$_decl')));

  final receivers = [for (var i = 0; i < 8; i++) mk(i)];
  // Warm BOTH the tear-off site and the closure call site.
  for (var i = 0; i < 50000; i++) {
    final r = receivers[i % receivers.length];
    callTorn(tear(r), input);
  }
  _emit('states.afterWarm', _counts());
  _emit('site.afterWarm', _look());

  // The closure captured BEFORE any replacement -- the live state whose
  // semantics are the open question.
  final Function preAlpha = tear(receivers[0]);
  final Function preBeta = tear(receivers[1]);
  _emit('pre.alpha.0', callTorn(preAlpha, input));
  _emit('pre.beta.0', callTorn(preBeta, input));
  // Standard matrix keys, bound to the PRE closure on purpose: it is the arm
  // that could have gone stale, so the shared judge should be reading it.
  _emit('alpha.0', callTorn(preAlpha, input));
  _emit('beta.0', callTorn(preBeta, input));
  _emit('version.0', _version(_c('$_lib::$_decl')));
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_before.json'));

  _emit('install.v2', _stage('cls:AlphaNew::method:v', 2));
  // Same closure object, after the replacement. MEASURED, not asserted.
  _emit('pre.alpha.v2', callTorn(preAlpha, input));
  _emit('alpha.v2', callTorn(preAlpha, input));
  // A closure torn off AFTER the replacement. This one is unambiguous.
  _emit('post.alpha.v2', callTorn(tear(receivers[0]), input));
  _emit('direct.alpha.v2', (receivers[0] as dynamic).v(input) as String);
  _emit('version.v2', _version(_c('$_lib::$_decl')));
  _emit('site.afterV2', _look());
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v2.json'));

  _emit('install.v3', _stage('cls:AlphaNew2::method:v', 3));
  _emit('pre.alpha.v3', callTorn(preAlpha, input));
  _emit('alpha.v3', callTorn(preAlpha, input));
  _emit('post.alpha.v3', callTorn(tear(receivers[0]), input));
  _emit('direct.alpha.v3', (receivers[0] as dynamic).v(input) as String);
  _emit('version.v3', _version(_c('$_lib::$_decl')));
  _emit('site.afterV3', _look());

  _emit('pre.beta.after', callTorn(preBeta, input));
  _emit('beta.after', callTorn(preBeta, input));
  _emit('post.beta.after', callTorn(tear(receivers[1]), input));
  _emit('states.after', _counts());
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v3.json'));
}
