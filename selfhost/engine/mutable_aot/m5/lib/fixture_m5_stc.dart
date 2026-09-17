// MAOT-5 (#69) -- positively entering SingleTargetCache.
//
// Built from the VM's precondition, not from hope. DoMonomorphicMissAOT only
// installs this state when CanExtendSingleTargetRange succeeds, and that
// requires:
//
//   old_target.ptr() == target_function.ptr()
//
// -- literally the SAME Function object for both receiver classes, which means
// both must INHERIT the selector rather than override it -- and then
// IsSingleTarget over the cid gap between them.
//
// So: one mutable implementation on Base, two children that inherit it, and
// one dynamic site driven with both. The site goes
//   UnlinkedCall -> monomorphic (ChildA) -> miss on ChildB -> SingleTargetCache.
//
// The selector is `v`, deliberately NOT a name int has: a possibly-Smi
// receiver routes to MonomorphicSmiableCall instead, which is a different
// state and already proven separately.
import 'dart:ffi';
import 'dart:io' show Platform;

class Base {
  @pragma('maot:mutable')
  String v() => 'OLD-BASE';
}

// Both INHERIT v. Neither may override it, or the two receivers resolve to
// different Function objects and the range can never extend.
class ChildA extends Base {}

class ChildB extends Base {}

// The unrelated-override control: same hierarchy, its own implementation,
// read through its own site. It must not move when Base.v is replaced.
class Overrider extends Base {
  @override
  String v() => 'OVERRIDE';
}

// WHY THESE EXIST.
//
// The first version of this fixture had only Base + two inheriting children,
// and never reached the switchable machinery at all: every state counter read
// 0 and no transition was ever recorded, while behaviour still followed the
// swaps. The registry said why -- 5 devirtualization records and a single
// indirect call site. TFA proved one target and devirtualised the site onto
// #67's static cell route.
//
// That is not a tuning detail, it is a tension in the state itself: the
// condition CanExtendSingleTargetRange needs -- both receivers resolving to
// the SAME inherited Function -- is exactly the condition that lets TFA prove
// a single target. So the receiver set has to be STATICALLY WIDE (no
// devirtualisation) while staying RUNTIME NARROW (two classes sharing an
// inherited target, so the cid range can extend).
//
// These unrelated classes each declare their own `v`, and are fed to the same
// site behind a branch the environment never takes. The analysis must keep
// them; execution never sees them.
class Noise1 {
  String v() => 'N1';
}

class Noise2 {
  String v() => 'N2';
}

class Noise3 {
  String v() => 'N3';
}

final bool _feedNoise = Platform.environment['M5_FEED_NOISE'] == '1';

class BaseNew {
  @pragma('maot:mutable')
  String v() => 'NEW-BASE';
}

class BaseNew2 {
  @pragma('maot:mutable')
  String v() => 'NEW2-BASE';
}

@pragma('vm:never-inline')
dynamic mkA() => ChildA();
@pragma('vm:never-inline')
dynamic mkB() => ChildB();
@pragma('vm:never-inline')
dynamic mkOverrider() => Overrider();

// THE ONE SITE. Both child receivers go through this single call site, which
// is what gives the switchable-call machinery its chance to widen a cid range.
@pragma('vm:never-inline')
dynamic site(dynamic d) => d.v();

// A separate site for the override control, so it cannot perturb the state
// under measurement.
@pragma('vm:never-inline')
dynamic overrideSite(dynamic d) => d.v();

const _lib = 'lib:package:m5stc/fixture_m5_stc.dart';

final _proc = DynamicLibrary.process();
final _malloc = _proc.lookupFunction<Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)>('malloc');
final _swap = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>)>(
    'Dart_MaotDiagnosticCellSwap');
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
int _swapCell(String t, String i) => _swap(_c('$_lib::$t'), _c('$_lib::$i'));
final _siteOut =
    Platform.environment['M5_SITE_REPORT'] ?? '/tmp/maot_stc_site.txt';
int _look() => _inspect(_c('$_lib::cls:Base::method:v'), _c(_siteOut));

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
  _emit('retain.new', BaseNew().v());
  _emit('retain.new2', BaseNew2().v());
  _emit('tramp.identity', _ident(_c('$_lib::cls:Base::method:v')));

  final a = mkA();
  final b = mkB();
  final o = mkOverrider();

  // Reachable for the analysis, never taken at run time: keeps the site's
  // receiver set wide enough that it is not devirtualised.
  if (_feedNoise) {
    _emit('noise', '${site(Noise1())}${site(Noise2())}${site(Noise3())}');
  }

  // ChildA first: UnlinkedCall -> monomorphic on ChildA's cid.
  _emit('stc.a0', site(a));
  _emit('site.afterA', _look());
  // ChildB now misses that monomorphic check, and because it resolves to the
  // SAME Base.v Function the range can widen instead of degrading to ICData.
  _emit('stc.b0', site(b));
  _emit('site.afterB', _look());
  _emit('override.0', overrideSite(o));

  var last = '';
  for (var i = 0; i < 50000; i++) {
    last = site(i.isEven ? a : b) as String;
  }
  _emit('stc.warm', last);
  _emit('site.afterWarm', _look());
  final before = _counts();

  _emit('swap.1', _swapCell('cls:Base::method:v', 'cls:BaseNew::method:v'));
  _emit('stc.a1', site(a));
  _emit('stc.b1', site(b));
  _emit('site.after1', _look());

  _emit('swap.2', _swapCell('cls:Base::method:v', 'cls:BaseNew2::method:v'));
  _emit('stc.a2', site(a));
  _emit('stc.b2', site(b));
  _emit('site.after2', _look());

  _emit('swap.3', _swapCell('cls:Base::method:v', 'cls:BaseNew::method:v'));
  _emit('stc.a3', site(a));
  _emit('stc.b3', site(b));
  _emit('site.after3', _look());

  final after = _counts();
  _emit('states.before', before);
  _emit('states.after', after);
  _emit('states.unchanged', '$before' == '$after');
  _emit('override.after', overrideSite(o));

  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_after.json'));
}
