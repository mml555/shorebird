// MAOT-5 (#69) -- positively entering MonomorphicSmiableCall.
//
// The earlier run reported 0/0/0/0 for this state and I refused to call it a
// pass: the state was never entered, so nothing was proven. This fixture is
// built from the VM's own precondition rather than from hope.
//
//   InstanceCallInstr::receiver_is_not_smi
//     -> ICData::receiver_cannot_be_smi
//     -> UnlinkedCall::can_patch_to_monomorphic
//
// and in DoUnlinkedCallAOT only the FALSE branch installs a
// MonomorphicSmiableCall; true gives the plain Smi-cid monomorphic form. So
// the site must be one where the analysis believes the receiver MAY BE AN
// INT. That is why the selector is `abs` -- a name int genuinely has, so an
// int flowing to the receiver keeps int in the receiver set instead of being
// narrowed away as a noSuchMethod target.
//
// The int path is reachable but never taken: `_passInt` is read from the
// environment, so the analysis must keep int, and at run time only Alpha ever
// reaches the site.
import 'dart:ffi';
import 'dart:io' show Platform;

final bool _passInt = Platform.environment['M5_PASS_INT'] == '1';

class Alpha {
  @pragma('maot:mutable')
  String abs() => 'OLD-ALPHA';
}

class AlphaNew {
  @pragma('maot:mutable')
  String abs() => 'NEW-ALPHA';
}

class AlphaNew2 {
  @pragma('maot:mutable')
  String abs() => 'NEW2-ALPHA';
}

// Beta is a SEPARATE declaration read through a SEPARATE site. Sharing the
// site would make it polymorphic and drive it to ICData, which is a different
// state and would destroy the thing being measured.
class Beta {
  @pragma('maot:mutable')
  String abs() => 'BETA';
}

@pragma('vm:never-inline')
dynamic mkAlpha() => Alpha();
@pragma('vm:never-inline')
dynamic mkBeta() => Beta();

// THE ONE SITE. Every read of Alpha goes through this single call site, so
// "the same site was warmed and then read" is structural rather than asserted
// -- three source expressions would be three sites.
@pragma('vm:never-inline')
dynamic site(dynamic d) => d.abs();

@pragma('vm:never-inline')
dynamic betaSite(dynamic d) => d.abs();

const _lib = 'lib:package:m5msc/fixture_m5_msc.dart';

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
// Re-reads the state object at the site the transition happened at, so the
// post-swap invariance is READ rather than inferred from "no miss occurred".
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
    Platform.environment['M5_SITE_REPORT'] ?? '/tmp/maot_msc_site.txt';
int _look() => _inspect(_c('$_lib::cls:Alpha::method:abs'), _c(_siteOut));

const _states = [
  'instance-dispatch/UnlinkedCall-observed',
  'instance-dispatch/MonomorphicSmiableCall-observed',
  'instance-dispatch/monomorphic-observed',
  'instance-dispatch/ICData-observed',
  'instance-dispatch/MegamorphicCache-observed',
];
List<int> _counts() => [for (final s in _states) _stateCount(_c(s))];

void main(List<String> args) {
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  // Retain the replacement bodies.
  _emit('retain.new', AlphaNew().abs());
  _emit('retain.new2', AlphaNew2().abs());
  _emit('tramp.identity', _ident(_c('$_lib::cls:Alpha::method:abs')));

  final alpha = mkAlpha();
  final beta = mkBeta();

  // Reachable for the analysis, never taken at run time.
  if (_passInt) {
    _emit('int.path', site(7));
  }

  _emit('msc.0', site(alpha));
  _emit('beta.0', betaSite(beta));

  var last = '';
  for (var i = 0; i < 50000; i++) {
    last = site(alpha) as String;
  }
  _emit('msc.warm', last);
  _emit('site.afterWarm', _look());
  final before = _counts();

  _emit('swap.1', _swapCell('cls:Alpha::method:abs', 'cls:AlphaNew::method:abs'));
  _emit('msc.1', site(alpha));
  _emit('site.after1', _look());
  _emit('swap.2',
      _swapCell('cls:Alpha::method:abs', 'cls:AlphaNew2::method:abs'));
  _emit('msc.2', site(alpha));
  _emit('site.after2', _look());
  _emit('swap.3', _swapCell('cls:Alpha::method:abs', 'cls:AlphaNew::method:abs'));
  _emit('msc.3', site(alpha));
  _emit('site.after3', _look());

  final after = _counts();
  _emit('states.before', before);
  _emit('states.after', after);
  _emit('states.unchanged', '$before' == '$after');
  _emit('beta.after', betaSite(beta));

  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_after.json'));
}
