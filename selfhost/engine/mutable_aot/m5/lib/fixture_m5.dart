// MAOT-5 (#69) virtual-routing fixture.
//
// The question this program exists to answer is narrow: does a REAL AOT
// instance call reach the declaration's trampoline, and therefore its cell?
//
// m4's Shape has a single implementor, so TFA proves the receiver type and
// devirtualizes the call into a static one. That is #68 scaffolding and it
// says nothing about virtual dispatch. Here there are two implementors and
// the receiver is chosen from the environment, so neither CHA nor TFA can
// pin it and the call must stay a genuine instance call.
import 'dart:ffi';
import 'dart:io' show Platform;

abstract class Iface {
  String v();
  // A second member so the class is not degenerate and the selector table
  // has more than one row to distinguish.
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

// The replacement lives on the same class with the same shape: a top-level
// function cannot replace an instance method, because the ABI descriptor
// differs in memberKind and receiver, and #66 refuses it.
class AlphaNew {
  @pragma('maot:mutable')
  String v() => 'NEW-ALPHA';
}

class AlphaNew2 {
  @pragma('maot:mutable')
  String v() => 'NEW2-ALPHA';
}

// Not inlined and not const-foldable: the receiver identity has to survive to
// the call site as a real value.
@pragma('vm:never-inline')
Iface pick(String which) => which == 'b' ? Beta() : Alpha();

const _lib = 'lib:package:m5app/fixture_m5.dart';

final _proc = DynamicLibrary.process();
final _malloc = _proc.lookupFunction<Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)>('malloc');
final _swap = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>)>(
    'Dart_MaotDiagnosticCellSwap');
final _ident = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotTrampolineIdentityForTesting');
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
  // From the environment so nothing can constant-fold the receiver class.
  final which = Platform.environment['M5_RECEIVER'] ?? 'a';
  final Iface obj = pick(which);

  // Does the declaration carry a trampoline, and is it the Function's
  // current code? 1 = yes, 2 = present but Function points elsewhere,
  // 0 = no trampoline.
  _emit('tramp.identity', _ident(_c('$_lib::cls:Alpha::method:v')));

  // ---- cold, before any swap ----
  _emit('virt.0', obj.v());

  // ---- warm the instance call site so it reaches a linked dispatch state --
  var last = '';
  const warm = 200000;
  for (var i = 0; i < warm; i++) {
    last = obj.v();
  }
  _emit('virt.warm', last);

  // ---- ROUTING DIAGNOSTIC: swap the cell directly ----
  // This is not installation. It bypasses StageReplacement and every escape
  // check, on purpose, to ask whether the warmed instance call reaches this
  // declaration's cell at all.
  _emit('swap.1', _swapCell('cls:Alpha::method:v', 'cls:AlphaNew::method:v'));
  _emit('virt.1', obj.v());

  // the SAME warmed site, not a fresh one
  for (var i = 0; i < warm; i++) {
    last = obj.v();
  }
  _emit('virt.warm.1', last);

  _emit('swap.2', _swapCell('cls:Alpha::method:v', 'cls:AlphaNew2::method:v'));
  _emit('virt.2', obj.v());
  for (var i = 0; i < warm; i++) {
    last = obj.v();
  }
  _emit('virt.warm.2', last);

  // Beta must be untouched throughout: it shares the selector but is a
  // different declaration, so a shared-cell defect would move it too.
  _emit('beta.v', pick('b').v());

  if (dumpDir.isNotEmpty) {
    _dump(_c('$dumpDir/registry_after.json'));
  }
}
