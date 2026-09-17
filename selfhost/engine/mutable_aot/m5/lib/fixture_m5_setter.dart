// MAOT-5 (#69) -- setter vertical slice.
//
// THE SETTER TRAP. `obj.v = x` evaluates to x regardless of what the setter
// body did, so the value of the assignment expression proves nothing about
// which implementation ran. Every observation here comes from a side effect
// the setter BODY produced.
//
// The side effect is also derived from runtime INPUT, not a constant, so this
// is not another constant-result test wearing a different hat: each
// implementation applies a DIFFERENT arithmetic transformation, and the
// resulting number says which body ran.
//
//   release -> input * 2
//   v2      -> input * 3
//   v3      -> input + 7
//
// With input 10 that is 20 / 30 / 17 -- distinct, and none of them derivable
// without running the corresponding body.
import 'dart:ffi';
import 'dart:io' show Platform;

// The observable. Written only by setter bodies.
String marker = '<unset>';

// Runtime input: read from the environment so no implementation's result is a
// compile-time constant.
final int input = int.tryParse(Platform.environment['M5_INPUT'] ?? '') ?? 10;

class Alpha {
  @pragma('maot:mutable')
  set v(int x) {
    marker = 'OLD:${x * 2}';
  }
}

class AlphaNew {
  @pragma('maot:mutable')
  set v(int x) {
    marker = 'NEW:${x * 3}';
  }
}

class AlphaNew2 {
  @pragma('maot:mutable')
  set v(int x) {
    marker = 'NEW2:${x + 7}';
  }
}

// Cross-declaration isolation control, sharing the selector.
class Beta {
  @pragma('maot:mutable')
  set v(int x) {
    marker = 'BETA:${x * 5}';
  }
}

// Keep the site statically wide so it is not devirtualised.
class F1 { set v(int x) { marker = 'F1'; } }
class F2 { set v(int x) { marker = 'F2'; } }
class F3 { set v(int x) { marker = 'F3'; } }
class F4 { set v(int x) { marker = 'F4'; } }
class F5 { set v(int x) { marker = 'F5'; } }
class F6 { set v(int x) { marker = 'F6'; } }

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

// THE ONE SITE -- an assignment, and its value is deliberately discarded.
@pragma('vm:never-inline')
void site(dynamic d, int x) {
  d.v = x;
}

// Reads the side effect the BODY produced, never the assignment's value.
String observe(dynamic d, int x) {
  marker = '<unset>';
  site(d, x);
  return marker;
}

const _lib = 'lib:package:m5setter/fixture_m5_setter.dart';

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
// The #65 spelling for a setter, taken from the registry dump rather than
// guessed -- the getter subject lost a full cycle to `getter:v` vs `get:v`.
const _decl = 'cls:Alpha::set:v';
int _stage(String i, int v) =>
    _install(_c('$_lib::$_decl'), _c('$_lib::$i'), v, _c(_ns));
final _siteOut =
    Platform.environment['M5_SITE_REPORT'] ?? '/tmp/maot_setter_site.txt';
int _look() => _inspect(_c('$_lib::$_decl'), _c(_siteOut));

const _states = [
  'instance-dispatch/UnlinkedCall-observed',
  'instance-dispatch/MonomorphicSmiableCall-observed',
  'instance-dispatch/monomorphic-observed',
  'instance-dispatch/SingleTargetCache-observed',
  'instance-dispatch/ICData-observed',
  'instance-dispatch/MegamorphicCache-observed',
];
List<int> _counts() => [for (final s in _states) _stateCount(_c(s))];

void main(List<String> args) {
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  _emit('input', input);
  // Retain the replacement bodies.
  _emit('retain.new', observe(AlphaNew(), input));
  _emit('retain.new2', observe(AlphaNew2(), input));
  _emit('tramp.identity', _ident(_c('$_lib::$_decl')));

  final receivers = [for (var i = 0; i < 8; i++) mk(i)];
  for (var i = 0; i < receivers.length; i++) {
    site(receivers[i], input);
  }
  for (var i = 0; i < 50000; i++) {
    site(receivers[i % receivers.length], input);
  }
  _emit('alpha.0', observe(receivers[0], input));
  _emit('beta.0', observe(receivers[1], input));
  _emit('version.0', _version(_c('$_lib::$_decl')));
  _emit('states.afterWarm', _counts());
  _emit('site.afterWarm', _look());
  final before = _counts();
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_before.json'));

  _emit('install.v2', _stage('cls:AlphaNew::set:v', 2));
  _emit('alpha.v2', observe(receivers[0], input));
  _emit('version.v2', _version(_c('$_lib::$_decl')));
  _emit('site.afterV2', _look());
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v2.json'));

  _emit('install.v3', _stage('cls:AlphaNew2::set:v', 3));
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
