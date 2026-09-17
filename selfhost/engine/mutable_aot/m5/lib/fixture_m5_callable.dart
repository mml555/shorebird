// MAOT-5 (#69) -- callable-class call() vertical slice.
//
// Same production mechanism as the instance-method and getter slices. No
// callable-class call()-specific machinery: if the shared trampoline/cell design cannot
// represent this subject, that is a finding to report, not something to paper
// over with a second mechanism.
//
// NOTE ON IDENTITY. The #65 declaration id below was read out of the registry
// dump, not guessed. An earlier subject lost a full cycle to `getter:v` vs
// `get:v`, where every call returned -1 and the value stayed OLD -- which
// looks exactly like "this member kind is unsupported" and is the opposite.
//
// NOTE ON THE BODY. The bodies interpolate a runtime input on purpose, so the
// body Code carries real pc-relative static calls. A constant-returning body
// has an empty static-call table and never exercises the path that
// ProgramVisitor::WalkProgram stopped reaching once a trampoline became the
// declaration's CurrentCode.
import 'dart:ffi';
import 'dart:io' show Platform;

final int input = int.tryParse(Platform.environment['M5_INPUT'] ?? '') ?? 10;

class Alpha {
  @pragma('maot:mutable')
  String call(int x) => 'OLD:${x * 2}';
}

class AlphaNew {
  @pragma('maot:mutable')
  String call(int x) => 'NEW:${x * 3}';
}

class AlphaNew2 {
  @pragma('maot:mutable')
  String call(int x) => 'NEW2:${x + 7}';
}

// Cross-declaration isolation control: shares the selector, owns its own
// declaration, cell and trampoline.
class Beta {
  @pragma('maot:mutable')
  String call(int x) => 'BETA:${x * 5}';
}

// A statically wide receiver set, so the site is not devirtualised and can
// reach the megamorphic state.
class F1 { String call(int x) => 'F1'; }
class F2 { String call(int x) => 'F2'; }
class F3 { String call(int x) => 'F3'; }
class F4 { String call(int x) => 'F4'; }
class F5 { String call(int x) => 'F5'; }
class F6 { String call(int x) => 'F6'; }

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

// THE ONE SITE.
@pragma('vm:never-inline')
String site(dynamic d, int x) => d(x) as String;

String observe(dynamic d, int x) => site(d, x);

const _lib = 'lib:package:m5callable/fixture_m5_callable.dart';

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
const _decl = 'cls:Alpha::method:call';
int _stage(String i, int v) =>
    _install(_c('$_lib::$_decl'), _c('$_lib::$i'), v, _c(_ns));
final _siteOut =
    Platform.environment['M5_SITE_REPORT'] ?? '/tmp/maot_callable_site.txt';
int _look() => _inspect(_c('$_lib::$_decl'), _c(_siteOut));

const _states = [
  'instance-dispatch/UnlinkedCall-observed',
  'instance-dispatch/MonomorphicSmiableCall-observed',
  'instance-dispatch/monomorphic-observed',
  'instance-dispatch/SingleTargetCache-observed',
  'instance-dispatch/ICData-observed',
  'instance-dispatch/MegamorphicCache-observed',
  // Unfiltered: distinguishes 'this site is not a switchable call' from
  // 'it is, but its target is not a tracked declaration'.
  'any-dispatch/miss-observed',
];
List<int> _counts() => [for (final s in _states) _stateCount(_c(s))];

void main(List<String> args) {
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  _emit('input', input);

  // The replacements must be retained and reachable, or the install refuses
  // for a reason that has nothing to do with the subject under test.
  _emit('retain.new', observe(AlphaNew(), input));
  _emit('retain.new2', observe(AlphaNew2(), input));
  _emit('tramp.identity', _ident(_c('$_lib::$_decl')));

  // ---- WARM THE SITE TO MEGAMORPHIC ----
  final receivers = [for (var i = 0; i < 8; i++) mk(i)];
  for (var i = 0; i < 8; i++) {
    _emit('drive.$i', observe(receivers[i], input));
  }
  _emit('states.afterWarm', _counts());
  _emit('alpha.0', observe(receivers[0], input));
  _emit('beta.0', observe(receivers[1], input));
  _emit('version.0', _version(_c('$_lib::$_decl')));
  _emit('site.afterWarm', _look());
  final before = _counts();

  // ---- PRODUCTION INSTALL v2 ----
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_before.json'));
  _emit('install.v2', _stage('cls:AlphaNew::method:call', 2));
  _emit('alpha.v2', observe(receivers[0], input));
  _emit('version.v2', _version(_c('$_lib::$_decl')));
  _emit('site.afterV2', _look());
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v2.json'));

  // ---- PRODUCTION INSTALL v3 ----
  _emit('install.v3', _stage('cls:AlphaNew2::method:call', 3));
  _emit('alpha.v3', observe(receivers[0], input));
  _emit('version.v3', _version(_c('$_lib::$_decl')));
  _emit('site.afterV3', _look());

  final after = _counts();
  _emit('states.before', before);
  _emit('states.after', after);
  _emit('states.unchanged', '$before' == '$after');
  _emit('beta.after', observe(receivers[1], input));
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v3.json'));
}
