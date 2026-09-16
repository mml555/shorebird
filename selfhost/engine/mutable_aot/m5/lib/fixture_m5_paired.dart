// MAOT-5 — A/B in ONE binary: the accepted m3 positive control beside the
// failing subject. Same snapshot, same flags, trampolines OFF, and the REAL
// install API for both.
//
// A is imported from m3 verbatim in the shape that matters: `work()` declared
// exactly as m3 declares it, and CALLED DIRECTLY FROM main() exactly as m3
// calls it. It is not a function that resembles tiny; it is m3's control.
//
// B is the failing subject: same declaration shape, but reached through a
// never-inlined wrapper instead of directly from main.
import 'dart:ffi';
import 'dart:io' show Platform;

// ---- A: m3's positive control, verbatim ----
@pragma('maot:mutable')
String work() => 'OLD';

@pragma('maot:mutable')
String workNew() => 'NEW';

// ---- B: the failing subject ----
@pragma('maot:mutable')
String control() => 'OLD-CONTROL';

@pragma('maot:mutable')
String controlNew() => 'NEW-CONTROL';

// The one structural difference between A and B: B is reached through this.
@pragma('vm:never-inline')
String callControl() => control();

const _lib = 'lib:package:m5paired/fixture_m5_paired.dart';

final _proc = DynamicLibrary.process();
final _malloc = _proc.lookupFunction<Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)>('malloc');
final _report = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>)>('Dart_MaotIdentityReport');
final _install = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>, Int64, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>, int,
        Pointer<Uint8>)>('Dart_MaotInstallForTesting');

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

void main(List<String> args) {
  final ns = Platform.environment['MAOT_NAMESPACE'] ?? '';

  _emit('A.0', work());          // called directly from main, as m3 does
  _emit('B.0', callControl());   // called through a never-inline wrapper

  _emit('install.A',
      _install(_c('$_lib::fn:work'), _c('$_lib::fn:workNew'), 2, _c(ns)));
  _emit('A.1', work());
  _emit('B.1', callControl());

  _emit('install.B', _install(
      _c('$_lib::fn:control'), _c('$_lib::fn:controlNew'), 2, _c(ns)));
  _emit('A.2', work());
  _emit('B.2', callControl());

  final out = Platform.environment['M5_REPORT'] ?? '/tmp/maot_paired_ident.txt';
  _report(_c('$_lib::fn:work'), _c(out));
  _report(_c('$_lib::fn:control'), _c(out));
}
