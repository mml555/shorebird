// MAOT-5 -- is the super divergence super-specific, or the same #67 hole the
// 2x2 just located?
//
// The 2x2 showed the failing combination is: a mutable declaration whose
// return is constant-inferable, reached through a NON-MUTABLE intermediary.
// `_callsMaotMutable` sees the intermediary, so the constant is suppressed on
// the direct edge and kept on the transitive one.
//
// The measured super fixture is exactly that shape: `Base.v() => 'OLD-BASE'`
// is constant, and it is reached only through `Sub.viaSuper()`. So is its
// paired control -- which is why both failed identically.
//
// This holds the super form, the never-inline intermediary and the diagnostic
// swap sequence FIXED, and varies only whether the returned value can be
// inferred as a constant. Arm CS keeps the constant; arm NS does not.
// If super is the variable, both arms fail. If constant-inferability is the
// variable, CS fails and NS observes the swap.
import 'dart:ffi';
import 'dart:io' show Platform;

final String _seed = Platform.environment['M5_SEED'] ?? '';

// ---- arm CS: constant return, reached through super ----
class BaseC {
  @pragma('maot:mutable')
  String v() => 'OLD-CS';
}

class SubC extends BaseC {
  @pragma('vm:never-inline')
  String viaSuper() => super.v();
  @override
  String v() => 'SUB-C';
}

class BaseCNew {
  @pragma('maot:mutable')
  String v() => 'NEW-CS';
}

// ---- arm NS: non-constant return, reached through super ----
class BaseN {
  @pragma('maot:mutable')
  String v() => 'OLD-NS$_seed';
}

class SubN extends BaseN {
  @pragma('vm:never-inline')
  String viaSuper() => super.v();
  @override
  String v() => 'SUB-N';
}

class BaseNNew {
  @pragma('maot:mutable')
  String v() => 'NEW-NS$_seed';
}

@pragma('vm:never-inline')
SubC makeSubC() => SubC();
@pragma('vm:never-inline')
SubN makeSubN() => SubN();

const _lib = 'lib:package:m5superfold/fixture_m5_superfold.dart';

final _proc = DynamicLibrary.process();
final _malloc = _proc.lookupFunction<Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)>('malloc');
final _swap = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>)>(
    'Dart_MaotDiagnosticCellSwap');

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
  // Retain the replacement bodies exactly as the measured super fixture does.
  _emit('retain.cs', BaseCNew().v());
  _emit('retain.ns', BaseNNew().v());

  final sc = makeSubC();
  final sn = makeSubN();

  _emit('CS.0', sc.viaSuper());
  _emit('NS.0', sn.viaSuper());
  _emit('CS.override', sc.v());
  _emit('NS.override', sn.v());

  _emit('swap.CS', _swapCell('cls:BaseC::method:v', 'cls:BaseCNew::method:v'));
  _emit('swap.NS', _swapCell('cls:BaseN::method:v', 'cls:BaseNNew::method:v'));

  _emit('CS.1', sc.viaSuper());
  _emit('NS.1', sn.viaSuper());
}
