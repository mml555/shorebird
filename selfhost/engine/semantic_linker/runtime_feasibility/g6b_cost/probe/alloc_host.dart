// SL1-G6B addendum: allocation throughput and collection behaviour under mixed
// execution.
//
// THREE MODES, chosen to separate two things that would otherwise be conflated:
//
//   alloc_aot_aot_type        AOT code      allocating an AOT-defined type
//   alloc_bytecode_aot_type   bytecode code allocating an AOT-defined type
//   alloc_bytecode_patch_type bytecode code allocating a PATCH-defined type
//
// Comparing 1 with 2 isolates the cost of running interpreted; comparing 2 with
// 3 isolates the cost of the object being patch-defined. A single
// "interpreted allocation" number would hide which of the two is responsible.
//
// A RING BUFFER, not a growing list. Keeping every object alive would measure
// heap growth and OOM behaviour rather than allocation throughput, and would
// leave nothing for the collector to do. Most objects become garbage promptly,
// which is the shape real allocation has.
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show loadDynamicModule, collectAllGarbageForTesting;
import 'dart:io';
import 'dart:typed_data';

class Cell {
  final int v;
  Object? link;
  Cell(this.v);
}

const int kRing = 1024;
final List<Object?> ring = List<Object?>.filled(kRing, null);

/// Escape hatch: every allocation is stored somewhere the compiler cannot prove
/// dead, so it cannot be scalar-replaced or elided.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
void keep(int i, Object o) {
  ring[i & (kRing - 1)] = o;
}

@pragma('vm:never-inline')
@pragma('vm:entry-point')
Cell makeCell(int v) => Cell(v);

@pragma('vm:never-inline')
@pragma('vm:entry-point')
int allocAot(int n, int seed) {
  var acc = 0;
  for (var i = 0; i < n; i++) {
    final c = makeCell(seed + i);
    keep(i, c);
    acc ^= c.v;
  }
  return acc;
}

/// Installed by the module.
int Function(int, int)? allocBytecodeAotType;
int Function(int, int)? allocBytecodePatchType;

@pragma('vm:never-inline')
@pragma('vm:entry-point')
int seed() => int.parse(Platform.environment['G6B_SEED'] ?? '1');

int _sink = 0;

/// Collection cost, using the G3 instrument and nothing else. Reported with the
/// RSS on both sides so a reader can see what the collection actually did.
@pragma('vm:never-inline')
void collectAndReport(String mode) {
  final before = ProcessInfo.currentRss;
  final sw = Stopwatch()..start();
  collectAllGarbageForTesting();
  sw.stop();
  final after = ProcessInfo.currentRss;
  print('GC $mode micros=${sw.elapsedMicroseconds} rss_before=$before '
      'rss_after=$after rss_delta=${after - before}');
}

@pragma('vm:never-inline')
void runMode(String mode, int n, int Function(int, int) f) {
  // Clear the ring so each mode starts from the same reachable set.
  for (var i = 0; i < kRing; i++) {
    ring[i] = null;
  }
  collectAllGarbageForTesting();
  final rss0 = ProcessInfo.currentRss;
  final sw = Stopwatch()..start();
  _sink ^= f(n, seed());
  sw.stop();
  final rss1 = ProcessInfo.currentRss;
  final ns = (sw.elapsedMicroseconds * 1000.0) / n;
  print('ALLOC $mode n=$n micros=${sw.elapsedMicroseconds} '
      'ns_per_alloc=${ns.toStringAsFixed(2)} '
      'rss_before=$rss0 rss_after=$rss1 rss_delta=${rss1 - rss0}');
  collectAndReport(mode);
}

Future<void> main(List<String> args) async {
  final n = int.parse(args.isNotEmpty ? args[0] : '5000000');
  final modulePath = args.length > 1 ? args[1] : null;

  // Warm every path before timing any of it.
  _sink ^= allocAot(n ~/ 100, 1);

  // ORDER MATTERS FOR RSS, and pretending otherwise would misreport it. The
  // first mode to run absorbs the heap growth; later modes reuse those pages,
  // so their RSS delta is smaller for a reason that has nothing to do with the
  // mode. G6B_SKIP_AOT=1 runs without the AOT mode so the hypothesis can be
  // tested rather than asserted.
  final skipAot = Platform.environment['G6B_SKIP_AOT'] == '1';
  if (!skipAot) runMode('alloc_aot_aot_type', n, allocAot);

  if (modulePath == null) {
    print('SINK $_sink');
    return;
  }
  final bytes = Uint8List.fromList(File(modulePath).readAsBytesSync());
  await loadDynamicModule(bytes: bytes);

  if (allocBytecodeAotType != null) {
    runMode('alloc_bytecode_aot_type', n, allocBytecodeAotType!);
  }
  if (allocBytecodePatchType != null) {
    runMode('alloc_bytecode_patch_type', n, allocBytecodePatchType!);
  }
  print('RSS_STEADY ${ProcessInfo.currentRss}');
  print('SINK $_sink');
}
