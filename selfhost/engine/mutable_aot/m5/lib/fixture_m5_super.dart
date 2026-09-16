// MAOT-5 (#69) super-form fixture.
//
// The question is narrow: how does `super.v()` actually lower and execute?
// The hypothesis is that it is a STATIC invocation and therefore already
// travels #67's mutable-cell path, in which case #69 must not invent a
// super-specific mechanism.
//
// `Base.v` is reached ONLY through `super.v()` here. Nothing calls it
// virtually, so any dispatch-cell call site recorded against it can only have
// come from the super call.
import 'dart:ffi';
import 'dart:io' show Platform;

class Base {
  @pragma('maot:mutable')
  String v() => 'OLD-BASE';
}

class Sub extends Base {
  // Not inlined: the super call site has to survive to code generation as a
  // real call, or there is nothing to measure.
  @pragma('vm:never-inline')
  String viaSuper() => super.v();

  // Overridden, so `super.v()` is genuinely a different target from what a
  // virtual call on a Sub receiver would select. If super were resolved by
  // ordinary virtual dispatch this would return the override instead.
  @override
  String v() => 'SUB-OVERRIDE';
}

class BaseNew {
  @pragma('maot:mutable')
  String v() => 'NEW-BASE';
}

class BaseNew2 {
  @pragma('maot:mutable')
  String v() => 'NEW2-BASE';
}

@pragma('vm:never-inline')
Sub makeSub() => Sub();

const _lib = 'lib:package:m5super/fixture_m5_super.dart';

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
int _swapCell(String t, String i) => _swap(_c('$_lib::$t'), _c('$_lib::$i'));

void main(List<String> args) {
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  _emit('retain.v2', BaseNew().v());
  _emit('retain.v3', BaseNew2().v());
  _emit('tramp.identity', _ident(_c('$_lib::cls:Base::method:v')));

  final sub = makeSub();

  // The override must NOT be what super selects.
  _emit('super.0', sub.viaSuper());
  _emit('virtual.onSub', sub.v());

  var last = '';
  for (var i = 0; i < 50000; i++) {
    last = sub.viaSuper();
  }
  _emit('super.warm', last);

  const states = [
    'instance-dispatch/UnlinkedCall-observed',
    'instance-dispatch/monomorphic-observed',
    'instance-dispatch/ICData-observed',
    'instance-dispatch/MegamorphicCache-observed',
  ];
  final before = [for (final s in states) _stateCount(_c(s))];

  _emit('swap.1', _swapCell('cls:Base::method:v', 'cls:BaseNew::method:v'));
  _emit('super.1', sub.viaSuper());
  _emit('swap.2', _swapCell('cls:Base::method:v', 'cls:BaseNew2::method:v'));
  _emit('super.2', sub.viaSuper());
  _emit('swap.3', _swapCell('cls:Base::method:v', 'cls:BaseNew::method:v'));
  _emit('super.3', sub.viaSuper());

  final after = [for (final s in states) _stateCount(_c(s))];
  _emit('super.switchableStatesUsed', '$before -> $after');
  _emit('super.noSwitchableTransition', '$before' == '$after');
  _emit('virtual.onSub.after', sub.v());

  if (dumpDir.isNotEmpty) {
    _dump(_c('$dumpDir/registry_after.json'));
  }
}
