// MAOT-5 (#69) interface-form fixture.
//
// Deliberately separate from the dynamic fixture. The dynamic results cannot
// be inherited: an interface call on a statically known interface compiles to
// DispatchTableCallInstr -- a direct indexed branch with no miss handler --
// and never enters the switchable-call machinery the dynamic evidence covers.
//
// Four implementations and an environment-chosen receiver, so neither CHA nor
// TFA can narrow the interface to one target and devirtualize the call.
import 'dart:ffi';
import 'dart:io' show Platform;

abstract class Iface {
  String v();
  int weight();
}

class Alpha implements Iface {
  @pragma('maot:mutable')
  @override
  String v() => 'OLD-ALPHA';
  @override
  int weight() => 1;
}

class Beta implements Iface {
  @override
  String v() => 'BETA';
  @override
  int weight() => 2;
}

class Gamma implements Iface {
  @override
  String v() => 'GAMMA';
  @override
  int weight() => 3;
}

class Delta implements Iface {
  @override
  String v() => 'DELTA';
  @override
  int weight() => 4;
}

class AlphaNew {
  @pragma('maot:mutable')
  String v() => 'NEW-ALPHA';
}

class AlphaNew2 {
  @pragma('maot:mutable')
  String v() => 'NEW2-ALPHA';
}

@pragma('vm:never-inline')
Iface pick(String which) {
  switch (which) {
    case 'b':
      return Beta();
    case 'g':
      return Gamma();
    case 'd':
      return Delta();
    default:
      return Alpha();
  }
}

// ONE interface call site, statically typed as Iface. Not dynamic: the
// receiver's static type is the interface, which is what makes this the
// interface form rather than the dynamic form.
@pragma('vm:never-inline')
String _ifaceSite(Iface x) => x.v();

const _lib = 'lib:package:m5iface/fixture_m5_iface.dart';

final _proc = DynamicLibrary.process();
final _malloc = _proc.lookupFunction<Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)>('malloc');
final _swap = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>)>(
    'Dart_MaotDiagnosticCellSwap');
final _ident = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotTrampolineIdentityForTesting');
final _stateCount = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotObservedStateCount');
final _dump = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotDumpForTesting');

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

int _swapCell(String target, String impl) =>
    _swap(_c('$_lib::$target'), _c('$_lib::$impl'));

void main(List<String> args) {
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  // Retain the replacement bodies; the diagnostic swap points the cell at a
  // replacement's pinned body Code, so that body has to exist.
  _emit('retain.v2', AlphaNew().v());
  _emit('retain.v3', AlphaNew2().v());

  _emit('tramp.identity', _ident(_c('$_lib::cls:Alpha::method:v')));

  final a = pick(Platform.environment['M5_RECEIVER'] ?? 'a');
  final b = pick('b');
  final g = pick('g');
  final d = pick('d');

  // Warm the ONE interface site across all four implementations, so nothing
  // can have narrowed it to a single target.
  var last = '';
  for (var i = 0; i < 50000; i++) {
    last = _ifaceSite([a, b, g, d][i & 3]);
  }
  _emit('iface.warm.last', last);
  _emit('iface.0', _ifaceSite(a));

  // If the interface form entered the switchable-call machinery at all, these
  // would move. They are recorded to show it does not.
  const states = [
    'instance-dispatch/UnlinkedCall-observed',
    'instance-dispatch/monomorphic-observed',
    'instance-dispatch/ICData-observed',
    'instance-dispatch/MegamorphicCache-observed',
  ];
  final before = [for (final s in states) _stateCount(_c(s))];

  _emit('swap.1', _swapCell('cls:Alpha::method:v', 'cls:AlphaNew::method:v'));
  _emit('iface.1', _ifaceSite(a));
  _emit('swap.2', _swapCell('cls:Alpha::method:v', 'cls:AlphaNew2::method:v'));
  _emit('iface.2', _ifaceSite(a));
  _emit('swap.3', _swapCell('cls:Alpha::method:v', 'cls:AlphaNew::method:v'));
  _emit('iface.3', _ifaceSite(a));

  final after = [for (final s in states) _stateCount(_c(s))];
  _emit('iface.switchableStatesUsed', '$before -> $after');
  _emit('iface.noSwitchableTransition', '$before' == '$after');

  // The other implementations must be untouched: they share the selector and
  // the same dispatch table, so a shared-slot or shared-cell defect moves them.
  _emit('iface.beta', _ifaceSite(b));
  _emit('iface.gamma', _ifaceSite(g));
  _emit('iface.delta', _ifaceSite(d));

  if (dumpDir.isNotEmpty) {
    _dump(_c('$dumpDir/registry_after.json'));
  }
}
