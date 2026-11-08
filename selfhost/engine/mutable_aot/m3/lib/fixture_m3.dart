// The canonical #67 release program. Compiled once, into the release; every
// call below is a call site the release compiler emitted, and none of them is
// recompiled after installation.
import 'dart:ffi';
import 'dart:io' show Platform;

// ---- the declarations under replacement ---------------------------------
@pragma('maot:mutable')
String work() => 'OLD';

class StaticTarget {
  @pragma('maot:mutable')
  static String work() => 'OLD-STATIC';
}

// Replacement implementations. For #67 the chosen replacement form is another
// AOT-compiled Dart implementation present in the release image, selected by
// descriptor; delivering an externally-built body is #72/#77.
@pragma('maot:mutable')
String workNew() => 'NEW';
@pragma('maot:mutable')
String workNew2() => 'NEW2';
@pragma('maot:mutable')
String staticNew() => 'NEW-STATIC';
@pragma('maot:mutable')
String staticNew2() => 'NEW2-STATIC';

// Selected but never replaced: installation must be scoped to one declaration.
@pragma('maot:mutable')
String untouchedMutable() => 'UNTOUCHED';

// Not selected at all: must be unaffected and must have no descriptor.
String notMutable() => 'PLAIN';

// ---- microbenchmark controls --------------------------------------------
// Not selected, so they are called through an ordinary pc-relative direct
// branch -- and marked never-inline, because a control the optimizer inlines
// is not measuring a call at all and would make the indirection look
// arbitrarily expensive.
@pragma('vm:never-inline')
String plainTop() => 'CTL';

class PlainTarget {
  @pragma('vm:never-inline')
  static String plainStatic() => 'CTL-STATIC';
}

/// Nanoseconds per call, over `iters` direct calls to a top-level function.
@pragma('vm:never-inline')
int benchTopMutable(int iters) {
  var n = 0;
  final w = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    n += work().length;
  }
  w.stop();
  return _perCall(w, iters, n);
}

@pragma('vm:never-inline')
int benchTopControl(int iters) {
  var n = 0;
  final w = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    n += plainTop().length;
  }
  w.stop();
  return _perCall(w, iters, n);
}

@pragma('vm:never-inline')
int benchStaticMutable(int iters) {
  var n = 0;
  final w = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    n += StaticTarget.work().length;
  }
  w.stop();
  return _perCall(w, iters, n);
}

@pragma('vm:never-inline')
int benchStaticControl(int iters) {
  var n = 0;
  final w = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    n += PlainTarget.plainStatic().length;
  }
  w.stop();
  return _perCall(w, iters, n);
}

/// A HOT observation: the value a heavily-executed call site still sees.
///
/// The cold observations above are a handful of calls. These loops run the
/// same precompiled call sites a million times, which is as warm as an AOT
/// call site gets, and return what the last one observed. Without this, "hot"
/// would be inferred from the benchmark's iteration count rather than
/// measured -- and the benchmark never looks at what it calls.
@pragma('vm:never-inline')
String hotObserveTop(int iters) {
  var last = 'unset';
  for (var i = 0; i < iters; i++) {
    last = work();
  }
  return last;
}

@pragma('vm:never-inline')
String hotObserveStatic(int iters) {
  var last = 'unset';
  for (var i = 0; i < iters; i++) {
    last = StaticTarget.work();
  }
  return last;
}

/// Total elapsed MICROSECONDS, not a per-call figure.
///
/// Dividing here threw the measurement away: at two nanoseconds per call,
/// integer division of microseconds by two million iterations rounds every
/// arm to 0 or 1. The gate divides, in floating point, with the iteration
/// count beside it.
///
/// The accumulator is folded into the result so the loop cannot be dropped as
/// dead; without it a sufficiently clever optimizer could delete the thing
/// being measured and report zero honestly.
int _perCall(Stopwatch w, int iters, int sink) =>
    w.elapsedMicroseconds + (sink < 0 ? 1 : 0);

// A declaration whose ABI differs, for the refusal arm.
@pragma('maot:mutable')
String wrongAbi(int a, int b) => 'WRONG-ABI';

const _lib = 'lib:package:m3app/fixture_m3.dart';
const _top = '$_lib::fn:work';
const _static = '$_lib::cls:StaticTarget::method:work';

final _proc = DynamicLibrary.process();
final _malloc = _proc.lookupFunction<Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)>('malloc');
final _install = _proc.lookupFunction<
    Int64 Function(Pointer<Uint8>, Pointer<Uint8>, Int64, Pointer<Uint8>),
    int Function(Pointer<Uint8>, Pointer<Uint8>, int,
        Pointer<Uint8>)>('Dart_MaotInstallForTesting');
final _version = _proc.lookupFunction<Int64 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('Dart_MaotCurrentVersionForTesting');
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

/// kind+version as one number: positive is AOT, -(version)-100 is PATCH_CODE.
String _v(String id) {
  final raw = _version(_c(id));
  if (raw == -1) return 'absent';
  return raw >= 0 ? 'AOT:v$raw' : 'PATCH_CODE:v${-(raw + 100)}';
}

int _pid = 0;

void _emit(String k, Object v) => print('$k=$v');

void main(List<String> args) {
  final ns = Platform.environment['MAOT_NAMESPACE'] ?? '';
  final dumpDir = Platform.environment['MAOT_DUMP_DIR'] ?? '';
  _pid = pid;
  _emit('process.pid', _pid);

  // ---- before any installation ----
  _emit('top.call.0', work());
  _emit('static.call.0', StaticTarget.work());
  _emit('untouched.call.0', untouchedMutable());
  _emit('plain.call.0', notMutable());
  _emit('top.version.0', _v(_top));
  _emit('static.version.0', _v(_static));
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_before.json'));

  // ---- refusals, before any visible mutation ----
  _emit('refuse.unknown.id',
      _install(_c('$_lib::fn:doesNotExist'), _c('$_lib::fn:workNew'), 2,
          _c(ns)));
  _emit('refuse.wrong.namespace',
      _install(_c(_top), _c('$_lib::fn:workNew'), 2,
          _c('0000000000000000000000000000000000000000000000000000000000000000')));
  _emit('refuse.abi.mismatch',
      _install(_c(_top), _c('$_lib::fn:wrongAbi'), 2, _c(ns)));
  _emit('refuse.version.not.advancing',
      _install(_c(_top), _c('$_lib::fn:workNew'), 1, _c(ns)));
  // Nothing above may have changed anything.
  _emit('top.call.after_refusals', work());
  _emit('top.version.after_refusals', _v(_top));

  // ---- top-level arm: OLD -> NEW -> NEW2 ----
  _emit('install.top.v2', _install(_c(_top), _c('$_lib::fn:workNew'), 2, _c(ns)));
  _emit('top.call.1', work());
  _emit('top.call.1.repeat', work());
  _emit('top.version.1', _v(_top));
  _emit('static.call.after_top_install', StaticTarget.work());
  _emit('untouched.call.after_top_install', untouchedMutable());

  _emit('install.top.v3',
      _install(_c(_top), _c('$_lib::fn:workNew2'), 3, _c(ns)));
  _emit('top.call.2', work());
  _emit('top.version.2', _v(_top));

  // ---- static arm: independent of the top-level arm ----
  _emit('install.static.v2',
      _install(_c(_static), _c('$_lib::fn:staticNew'), 2, _c(ns)));
  _emit('static.call.1', StaticTarget.work());
  _emit('static.call.1.repeat', StaticTarget.work());
  _emit('static.version.1', _v(_static));

  _emit('install.static.v3',
      _install(_c(_static), _c('$_lib::fn:staticNew2'), 3, _c(ns)));
  _emit('static.call.2', StaticTarget.work());
  _emit('static.version.2', _v(_static));

  // ---- scope and identity, at the end ----
  _emit('untouched.call.final', untouchedMutable());
  _emit('plain.call.final', notMutable());
  _emit('top.call.final', work());
  // ---- hot-path observations, after installation ----
  _emit('hot.iterations', 1000000);
  _emit('hot.top.value', hotObserveTop(1000000));
  _emit('hot.static.value', hotObserveStatic(1000000));

  // ---- microbenchmarks, after installation so the mutable arms are
  // running a replacement rather than their release body ----
  const iters = 2000000;
  // One warm pass each, discarded: the first pass pays for lazy stub
  // resolution and a cold instruction cache, which is not what is being
  // compared.
  benchTopMutable(iters ~/ 10);
  benchTopControl(iters ~/ 10);
  benchStaticMutable(iters ~/ 10);
  benchStaticControl(iters ~/ 10);
  _emit('bench.iterations', iters);
  // Three samples per arm, all reported. A single sample at ~1 ns per call is
  // dominated by scheduling noise -- enough that one arm measured FASTER than
  // its own control, which is not a result, it is a coin flip. The gate takes
  // the minimum, which is the least contaminated estimate, and keeps every
  // sample so the spread is visible.
  for (var rep = 0; rep < 3; rep++) {
    _emit('bench.top.mutable.us.$rep', benchTopMutable(iters));
    _emit('bench.top.control.us.$rep', benchTopControl(iters));
    _emit('bench.static.mutable.us.$rep', benchStaticMutable(iters));
    _emit('bench.static.control.us.$rep', benchStaticControl(iters));
  }

  _emit('process.pid.final', pid);
  if (dumpDir.isNotEmpty) _dump(_c('$dumpDir/registry_after.json'));
}

int get pid => Platform.environment.length >= 0 ? _realPid() : 0;

int _realPid() => _pidFn();

final _pidFn = _proc.lookupFunction<Int32 Function(), int Function()>('getpid');
