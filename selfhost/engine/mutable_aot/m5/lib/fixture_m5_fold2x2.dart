// MAOT-5 -- separating TWO variables that the paired A/B experiment held
// confounded.
//
// The paired run showed A (direct) observing replacement and B (through a
// never-inline wrapper) not observing it, with instruction-equivalent call
// sites and identical, correct post-install cell state. Disassembling main
// showed why the two are not comparable: at every B site the call result in
// x0 is DISCARDED and `x2` is reloaded from one fixed pool offset, while at
// every A site the result is used (`mov x2, x0`).
//
// That makes two candidate variables, and the paired fixture varied both at
// once:
//   V1  reached through a wrapper   vs   called directly from main
//   V2  return value is constant-inferable   vs   not
//
// Four arms, one binary, one install sequence. Under "the caller folded the
// wrapper's constant return", CD/ND/NW observe replacement and only CW does
// not. Under "wrapper-ness alone breaks dispatch", both CW and NW fail.
// The arms disagree, so the experiment can come out either way.
import 'dart:ffi';
import 'dart:io' show Platform;

// A seed the compiler cannot fold: a lazily-initialised top-level final read
// from the environment. Empty in practice, so the printed values stay legible.
final String _seed = Platform.environment['M5_SEED'] ?? '';

// ---- CD: constant return, called DIRECTLY from main (m3's control) ----
@pragma('maot:mutable')
String work() => 'OLD';

@pragma('maot:mutable')
String workNew() => 'NEW';

// ---- CW: constant return, reached through a wrapper ----
@pragma('maot:mutable')
String control() => 'OLD-CONTROL';

@pragma('maot:mutable')
String controlNew() => 'NEW-CONTROL';

@pragma('vm:never-inline')
String callControl() => control();

// ---- ND: non-constant return, called DIRECTLY from main ----
@pragma('maot:mutable')
String nwork() => 'OLD-ND$_seed';

@pragma('maot:mutable')
String nworkNew() => 'NEW-ND$_seed';

// ---- NW: non-constant return, reached through a wrapper ----
@pragma('maot:mutable')
String ncontrol() => 'OLD-NW$_seed';

@pragma('maot:mutable')
String ncontrolNew() => 'NEW-NW$_seed';

@pragma('vm:never-inline')
String callNControl() => ncontrol();

const _lib = 'lib:package:m5fold/fixture_m5_fold2x2.dart';

final _proc = DynamicLibrary.process();
final _malloc = _proc.lookupFunction<Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)>('malloc');
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

int _go(String ns, String from, String to) =>
    _install(_c('$_lib::fn:$from'), _c('$_lib::fn:$to'), 2, _c(ns));

void main(List<String> args) {
  final ns = Platform.environment['MAOT_NAMESPACE'] ?? '';

  _emit('CD.0', work());
  _emit('CW.0', callControl());
  _emit('ND.0', nwork());
  _emit('NW.0', callNControl());

  _emit('install.CD', _go(ns, 'work', 'workNew'));
  _emit('install.CW', _go(ns, 'control', 'controlNew'));
  _emit('install.ND', _go(ns, 'nwork', 'nworkNew'));
  _emit('install.NW', _go(ns, 'ncontrol', 'ncontrolNew'));

  _emit('CD.1', work());
  _emit('CW.1', callControl());
  _emit('ND.1', nwork());
  _emit('NW.1', callNControl());
}
