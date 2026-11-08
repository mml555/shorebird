// MAOT-5 (#69) — Stage-2 integration probe, static only.
//
// Super is removed. This is ONE top-level mutable declaration reached by one
// never-inlined static caller: the #67 configuration, run with declaration
// trampolines both OFF and ON. The question is where the call goes after a
// diagnostic cell swap, and whether the two configurations diverge.
import 'dart:ffi';
import 'dart:io' show Platform;

@pragma('maot:mutable')
String control() => 'OLD-CONTROL';

@pragma('maot:mutable')
String controlNew() => 'NEW-CONTROL';

@pragma('vm:never-inline')
String callControl() => control();

const _lib = 'lib:package:m5static/fixture_m5_static.dart';

final _proc = DynamicLibrary.process();
final _malloc = _proc.lookupFunction<Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)>('malloc');
final _swap = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>)>(
    'Dart_MaotDiagnosticCellSwap');
final _report = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>)>('Dart_MaotIdentityReport');
final _ident = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotTrampolineIdentityForTesting');
// The REAL install path -- the one m3/#67 proves green. Running both against
// one fixture separates "this instrument is broken" from "this fixture never
// routed through the cell".
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
  final out = Platform.environment['M5_REPORT'] ?? '/tmp/maot_identity.txt';
  _emit('tramp.control', _ident(_c('$_lib::fn:control')));
  _emit('tramp.controlNew', _ident(_c('$_lib::fn:controlNew')));

  // Retain the replacement body.
  _emit('retain', controlNew());

  _emit('call.0', callControl());
  _report(_c('$_lib::fn:control'), _c(out));
  _report(_c('$_lib::fn:controlNew'), _c(out));

  _emit('swap', _swap(_c('$_lib::fn:control'), _c('$_lib::fn:controlNew')));
  _emit('call.1', callControl());

  _report(_c('$_lib::fn:control'), _c(out));
  _report(_c('$_lib::fn:controlNew'), _c(out));

  // Now the production path on the SAME declaration in the SAME process.
  final ns = Platform.environment['MAOT_NAMESPACE'] ?? '';
  _emit('install', _install(_c('$_lib::fn:control'),
      _c('$_lib::fn:controlNew'), 2, _c(ns)));
  _emit('call.2', callControl());
}
