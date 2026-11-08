// MAOT-5 (#69) -- the FIRST REAL instance StageReplacement.
//
// Everything before this used Dart_MaotDiagnosticCellSwap, which writes both
// halves of the cell directly and bypasses StageReplacement entirely. That was
// right for proving ROUTING: it isolates "does this dispatch state converge on
// the trampoline" from "does policy allow the install". Those questions are
// now separated and both answered, so this fixture uses the production path
// and nothing else -- there is no diagnostic swap anywhere in it.
//
// The site is warmed into MegamorphicCache first, deliberately: it is the most
// indirect runtime representation on the dynamic surface, so a production
// install that is observed THROUGH it is the strongest available vertical
// slice. The cache is re-read across both installs to show the replacement is
// not observed BY rewriting it.
//
// The threshold is read off the VM, not guessed. DoICDataMissAOT captures
//   number_of_checks = ic_data.NumberOfChecks()
// BEFORE EnsureHasReceiverCheck adds the current receiver, then switches when
//   number_of_checks > FLAG_max_polymorphic_checks   (default 4)
// so the SIXTH distinct receiver at a site is the one that crosses. Eight are
// declared here so the crossing is unambiguous rather than exactly on the line.
//
// Every class declares its OWN v(). That is deliberate: if they shared an
// inherited target the SingleTargetCache branch would absorb them first and
// this state would never be reached.
//
// The cache is looked up as MegamorphicCacheTable::Lookup(name, descriptor) --
// keyed by SELECTOR, shared across call sites, not owned by one site. So the
// cross-wiring control below lives in the SAME cache object, which is a
// stronger control than an unrelated untouched cache would be.
import 'dart:ffi';
import 'dart:io' show Platform;

class Alpha {
  @pragma('maot:mutable')
  String v() => 'OLD-ALPHA';
}

class AlphaNew {
  @pragma('maot:mutable')
  String v() => 'NEW-ALPHA';
}

// Used ONLY to mutate AlphaNew's own cell in the cross-wiring regression --
// never installed over Alpha.
class Interloper {
  @pragma('maot:mutable')
  String v() => 'INTERLOPER';
}

class AlphaNew2 {
  @pragma('maot:mutable')
  String v() => 'NEW2-ALPHA';
}

// The cross-wiring control: a DIFFERENT mutable declaration that shares the
// selector, so it occupies its own entry in the SAME megamorphic cache.
class Beta {
  @pragma('maot:mutable')
  String v() => 'BETA';
}

class F1 { String v() => 'F1'; }
class F2 { String v() => 'F2'; }
class F3 { String v() => 'F3'; }
class F4 { String v() => 'F4'; }
class F5 { String v() => 'F5'; }
class F6 { String v() => 'F6'; }

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

// THE ONE SITE. All receivers cross it, so the check count accumulates here
// and the transition happens here.
@pragma('vm:never-inline')
dynamic site(dynamic d) => d.v();

const _lib = 'lib:package:m5prod/fixture_m5_prod.dart';

final _proc = DynamicLibrary.process();
final _malloc = _proc.lookupFunction<Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)>('malloc');
// The PRODUCTION install path. Not the diagnostic swap: this runs every check
// StageReplacement owns -- namespace, ABI, calling convention, version -- and
// then commits only the implementation half.
final _install = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>, Int64, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>, int,
        Pointer<Uint8>)>('Dart_MaotInstallForTesting');
final _version = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotCurrentVersionForTesting');
// Explicitly answers a stop condition: does the production install put a
// TRAMPOLINE into cell.implCode? The self-cycle guard only refuses THIS
// declaration's own trampoline, and the replacement is itself a selected
// declaration that may have one, so an extra hop would pass that guard.
// The diagnostic swap is used for ONE purpose here: to perturb a DIFFERENT
// declaration's cell (AlphaNew's), so that Alpha's independence from it can be
// tested. It is never used on Alpha.
final _swap = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>)>(
    'Dart_MaotDiagnosticCellSwap');
final _report = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>)>('Dart_MaotIdentityReport');
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
final _identOut =
    Platform.environment['M5_IDENT'] ?? '/tmp/maot_prod_ident.txt';
int _ident2(String stage) =>
    _report(_c('$_lib::cls:Alpha::method:v'), _c('$_identOut.$stage'));
int _stage(String t, String i, int v) =>
    _install(_c('$_lib::$t'), _c('$_lib::$i'), v, _c(_ns));
final _siteOut =
    Platform.environment['M5_SITE_REPORT'] ?? '/tmp/maot_mega_site.txt';
int _look(String decl) => _inspect(_c('$_lib::$decl'), _c(_siteOut));

const _states = [
  'instance-dispatch/UnlinkedCall-observed',
  'instance-dispatch/monomorphic-observed',
  'instance-dispatch/SingleTargetCache-observed',
  'instance-dispatch/ICData-observed',
  'instance-dispatch/MegamorphicCache-observed',
];
List<int> _counts() => [for (final s in _states) _stateCount(_c(s))];

void main(List<String> args) {
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  _emit('retain.new', AlphaNew().v());
  _emit('retain.new2', AlphaNew2().v());
  _emit('tramp.identity', _ident(_c('$_lib::cls:Alpha::method:v')));

  final receivers = [for (var i = 0; i < 8; i++) mk(i)];

  // Drive the one site with eight distinct receiver classes. The sixth is the
  // one that crosses number_of_checks > 4.
  for (var i = 0; i < receivers.length; i++) {
    _emit('drive.$i', site(receivers[i]));
  }
  _emit('states.afterDrive', _counts());

  // Warm, all receivers, so the cache is fully formed and settled.
  var last = '';
  for (var i = 0; i < 50000; i++) {
    last = site(receivers[i % receivers.length]) as String;
  }
  _emit('mega.warm', last);
  _emit('alpha.0', site(receivers[0]));
  _emit('beta.0', site(receivers[1]));
  _emit('version.0', _version(_c('$_lib::cls:Alpha::method:v')));
  _emit('site.afterWarm.alpha', _look('cls:Alpha::method:v'));
  _emit('site.afterWarm.beta', _look('cls:Beta::method:v'));
  final before = _counts();

  // ---- INSTALL v2 THROUGH THE PRODUCTION PATH ----
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_before.json'));
  _emit('install.v2',
      _stage('cls:Alpha::method:v', 'cls:AlphaNew::method:v', 2));
  _emit('alpha.v2', site(receivers[0]));
  _emit('version.v2', _version(_c('$_lib::cls:Alpha::method:v')));
  _emit('ident.v2', _ident2('v2'));
  _emit('site.afterV2', _look('cls:Alpha::method:v'));
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v2.json'));

  // ---- INSTALL v3, so a second advance is exercised too ----
  _emit('install.v3',
      _stage('cls:Alpha::method:v', 'cls:AlphaNew2::method:v', 3));
  _emit('alpha.v3', site(receivers[0]));
  _emit('version.v3', _version(_c('$_lib::cls:Alpha::method:v')));
  _emit('ident.v3', _ident2('v3'));
  _emit('site.afterV3', _look('cls:Alpha::method:v'));

  // ---- CROSS-WIRING REGRESSION ----
  // After v3 Alpha runs AlphaNew2's body. Now perturb AlphaNew2's OWN cell. If
  // Alpha's cell still held AlphaNew2's trampoline, Alpha would follow this
  // and start returning INTERLOPER. It must not: Alpha's cell pins the BODY.
  _emit('xwire.swapAlphaNewCell',
      _swap(_c('$_lib::cls:AlphaNew2::method:v'),
            _c('$_lib::cls:Interloper::method:v')));
  _emit('xwire.alphaAfter', site(receivers[0]));  // must stay NEW2-ALPHA
  _emit('xwire.retainInterloper', Interloper().v());

  final after = _counts();
  _emit('states.before', before);
  _emit('states.after', after);
  _emit('states.unchanged', '$before' == '$after');
  _emit('beta.after', site(receivers[1]));
  _emit('site.afterAll.beta', _look('cls:Beta::method:v'));

  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_v3.json'));
}
