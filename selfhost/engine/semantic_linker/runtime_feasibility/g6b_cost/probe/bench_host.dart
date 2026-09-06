// SL1-G6B execution benchmark host (cost family D).
//
// OPTIMIZER RESISTANCE IS THE WHOLE DESIGN. Every mode accumulates into a sink
// that is printed, the callees are never-inline, and the operand comes from an
// environment-derived seed the compiler cannot fold. Without that, a mode that
// "runs 10,000,000 calls" can be compiled to a constant and reported as
// infinitely fast -- which is the classic way a boundary benchmark measures
// nothing.
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show loadDynamicModule;
import 'dart:io';
import 'dart:typed_data';

class Base {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  int work(int x) => x ^ 0x5a5a;
}

class HostChild extends Base {
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  @override
  int work(int x) => x ^ 0x3c3c;
}

/// AOT -> AOT direct: a static call, no receiver.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
int directWork(int x) => x ^ 0x5a5a;

/// The AOT callee a module calls, for the bytecode -> AOT mode.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
int hostCallee(int x) => x ^ 0x1234;

@pragma('vm:never-inline')
@pragma('vm:entry-point')
int seed() => int.parse(Platform.environment['G6B_SEED'] ?? '1');

/// Installed by the module so the host can drive bytecode->AOT and
/// bytecode->bytecode loops without re-entering the loader each time.
int Function(int)? patchLoop;
int Function(int)? patchSelfLoop;
int Function(int)? patchWork;

int _sink = 0;

@pragma('vm:never-inline')
void report(String mode, int iters, int micros) {
  final nsPer = iters == 0 ? 0.0 : (micros * 1000.0) / iters;
  print('BENCH $mode iters=$iters micros=$micros ns_per_call=${nsPer.toStringAsFixed(2)}');
}

@pragma('vm:never-inline')
int runDirect(int n, int x) {
  var a = 0;
  for (var i = 0; i < n; i++) { a ^= directWork(x + i); }
  return a;
}

@pragma('vm:never-inline')
int runVirtual(int n, int x, Base b) {
  var a = 0;
  for (var i = 0; i < n; i++) { a ^= b.work(x + i); }
  return a;
}

@pragma('vm:never-inline')
int runViaClosure(int n, int x, int Function(int) f) {
  var a = 0;
  for (var i = 0; i < n; i++) { a ^= f(x + i); }
  return a;
}

Future<void> main(List<String> args) async {
  final n = int.parse(args.isNotEmpty ? args[0] : '10000000');
  final modulePath = args.length > 1 ? args[1] : null;
  final x = seed();

  // Warm up every shape before timing any of it.
  _sink ^= runDirect(n ~/ 100, x);
  _sink ^= runVirtual(n ~/ 100, x, HostChild());

  var sw = Stopwatch()..start();
  _sink ^= runDirect(n, x);
  sw.stop();
  report('aot_to_aot_direct', n, sw.elapsedMicroseconds);

  final b = HostChild();
  sw = Stopwatch()..start();
  _sink ^= runVirtual(n, x, b);
  sw.stop();
  report('aot_to_aot_virtual', n, sw.elapsedMicroseconds);

  if (modulePath == null) {
    print('SINK $_sink');
    return;
  }

  // ---- cost family C: load latency, measured around the loader only.
  final bytes = Uint8List.fromList(File(modulePath).readAsBytesSync());
  print('MODULE bytes=${bytes.length}');
  final rssBefore = ProcessInfo.currentRss;
  sw = Stopwatch()..start();
  final loaded = await loadDynamicModule(bytes: bytes);
  sw.stop();
  final rssAfter = ProcessInfo.currentRss;
  print('LOAD micros=${sw.elapsedMicroseconds} rss_before=$rssBefore rss_after=$rssAfter '
      'rss_delta=${rssAfter - rssBefore}');

  final patch = loaded as Base;

  // AOT -> bytecode: virtual dispatch from AOT into the interpreted override.
  sw = Stopwatch()..start();
  _sink ^= runVirtual(n, x, patch);
  sw.stop();
  report('aot_to_bytecode', n, sw.elapsedMicroseconds);

  // bytecode -> AOT: the module drives the loop and calls an AOT function.
  if (patchLoop != null) {
    sw = Stopwatch()..start();
    _sink ^= patchLoop!(n);
    sw.stop();
    report('bytecode_to_aot', n, sw.elapsedMicroseconds);
  }

  // bytecode -> bytecode: the module drives the loop and calls itself.
  if (patchSelfLoop != null) {
    sw = Stopwatch()..start();
    _sink ^= patchSelfLoop!(n);
    sw.stop();
    report('bytecode_to_bytecode', n, sw.elapsedMicroseconds);
  }

  print('RSS_STEADY ${ProcessInfo.currentRss}');
  print('SINK $_sink');
}
