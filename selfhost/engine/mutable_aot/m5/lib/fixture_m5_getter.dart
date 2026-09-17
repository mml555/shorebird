// MAOT-5 (#69) -- getter vertical slice.
//
// Uses the mechanism established by the instance-method slice. The question is
// NOT whether the dispatch architecture works -- that is settled -- but
// whether a GETTER reaches one of the already-proven runtime representations,
// or exposes a new one. If it exposes a new one, that is a stop-and-report,
// not something to inherit by analogy.
//
// So the fixture does two things: it runs the production install sequence, and
// it records which dispatch state the site actually entered.
//
// NOTE ON IDENTITY. A getter's #65 declaration id is `cls:X::get:v`, not
// `cls:X::method:v` and not `cls:X::getter:v`. The first run of this fixture
// guessed `getter:v` and every call returned -1 (unknown declaration) --
// which reads exactly like "getters are unsupported" and is nothing of the
// kind. The id was read back out of the registry dump rather than guessed a
// second time.
import 'dart:ffi';
import 'dart:io' show Platform;

class Alpha {
  @pragma('maot:mutable')
  String get v => 'OLD-ALPHA';
}

class AlphaNew {
  @pragma('maot:mutable')
  String get v => 'NEW-ALPHA';
}

class AlphaNew2 {
  @pragma('maot:mutable')
  String get v => 'NEW2-ALPHA';
}

// Cross-declaration isolation control, sharing the selector.
class Beta {
  @pragma('maot:mutable')
  String get v => 'BETA';
}

// Receivers that keep the site from being devirtualised, exactly as the
// instance-method fixtures needed: a statically wide receiver set.
class F1 { String get v => 'F1'; }
class F2 { String get v => 'F2'; }
class F3 { String get v => 'F3'; }
class F4 { String get v => 'F4'; }
class F5 { String get v => 'F5'; }
class F6 { String get v => 'F6'; }

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

// THE ONE SITE -- a getter access, not a method call.
@pragma('vm:never-inline')
dynamic site(dynamic d) => d.v;

const _lib = 'lib:package:m5getter/fixture_m5_getter.dart';

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
int _stage(String t, String i, int v) =>
    _install(_c('$_lib::$t'), _c('$_lib::$i'), v, _c(_ns));
final _siteOut =
    Platform.environment['M5_SITE_REPORT'] ?? '/tmp/maot_getter_site.txt';
int _look(String decl) => _inspect(_c('$_lib::$decl'), _c(_siteOut));

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
  _emit('retain.new', AlphaNew().v);
  _emit('retain.new2', AlphaNew2().v);
  // FIRST GATE: does a getter declaration even get a trampoline?
  _emit('tramp.identity', _ident(_c('$_lib::cls:Alpha::get:v')));

  final receivers = [for (var i = 0; i < 8; i++) mk(i)];
  for (var i = 0; i < receivers.length; i++) {
    _emit('drive.$i', site(receivers[i]));
  }
  var last = '';
  for (var i = 0; i < 50000; i++) {
    last = site(receivers[i % receivers.length]) as String;
  }
  _emit('warm', last);
  _emit('alpha.0', site(receivers[0]));
  _emit('beta.0', site(receivers[1]));
  _emit('version.0', _version(_c('$_lib::cls:Alpha::get:v')));
  // WHICH representation did a getter site actually reach?
  _emit('states.afterWarm', _counts());
  _emit('site.afterWarm', _look('cls:Alpha::get:v'));
  final before = _counts();
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_before.json'));

  _emit('install.v2',
      _stage('cls:Alpha::get:v', 'cls:AlphaNew::get:v', 2));
  _emit('alpha.v2', site(receivers[0]));
  _emit('version.v2', _version(_c('$_lib::cls:Alpha::get:v')));
  _emit('site.afterV2', _look('cls:Alpha::get:v'));
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v2.json'));

  _emit('install.v3',
      _stage('cls:Alpha::get:v', 'cls:AlphaNew2::get:v', 3));
  _emit('alpha.v3', site(receivers[0]));
  _emit('version.v3', _version(_c('$_lib::cls:Alpha::get:v')));
  _emit('site.afterV3', _look('cls:Alpha::get:v'));

  final after = _counts();
  _emit('states.before', before);
  _emit('states.after', after);
  _emit('states.unchanged', '$before' == '$after');
  _emit('beta.after', site(receivers[1]));
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v3.json'));
}
