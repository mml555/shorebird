// Runtime-cost gate: what the cell indirection costs on a hot call.
//
// The measurement is taken INSIDE the process and the discriminating statistic
// is the ratio between two loops in the SAME process:
//
//   hot   a mutable instance method -- cell-indirect once the policy is on
//   cold  an identical method that is not mutable -- an ordinary call
//
// The ratio cancels machine state, thermal drift and scheduling, which is what
// made every wall-clock comparison on this rig unusable before. An absolute
// number from one arm says nothing; hot/cold measured in one process, in both
// arms, says exactly how much the indirection costs.
import 'dart:io' show Platform;

class Hot {
  @pragma('maot:mutable')
  @pragma('vm:never-inline')
  int step(int x) => x ^ (x >> 3);
}

class Cold {
  @pragma('vm:never-inline')
  int step(int x) => x ^ (x >> 3);
}

// Replacement bodies, so the declaration is genuinely replaceable and the
// arm is not accidentally measuring a declaration nothing could install onto.
class HotNew {
  @pragma('maot:mutable')
  @pragma('vm:never-inline')
  int step(int x) => x ^ (x >> 3);
}

final int reps = int.tryParse(Platform.environment['M5_REPS'] ?? '') ?? 9;
final int iters =
    int.tryParse(Platform.environment['M5_ITERS'] ?? '') ?? 20000000;

@pragma('vm:never-inline')
int runHot(Hot h, int n) {
  var acc = 1;
  for (var i = 0; i < n; i++) {
    acc = h.step(acc + i);
  }
  return acc;
}

@pragma('vm:never-inline')
int runCold(Cold c, int n) {
  var acc = 1;
  for (var i = 0; i < n; i++) {
    acc = c.step(acc + i);
  }
  return acc;
}

void main() {
  final h = Hot();
  final c = Cold();
  // Keep the replacement body reachable.
  print('retain=${HotNew().step(3)}');

  // Warm both paths, including the switchable-call states.
  runHot(h, 200000);
  runCold(c, 200000);

  var sink = 0;
  final hotNs = <double>[];
  final coldNs = <double>[];
  for (var r = 0; r < reps; r++) {
    // Interleaved, so drift over the run hits both loops equally.
    final sw1 = Stopwatch()..start();
    sink ^= runHot(h, iters);
    sw1.stop();
    final sw2 = Stopwatch()..start();
    sink ^= runCold(c, iters);
    sw2.stop();
    hotNs.add(sw1.elapsedMicroseconds * 1000.0 / iters);
    coldNs.add(sw2.elapsedMicroseconds * 1000.0 / iters);
  }
  hotNs.sort();
  coldNs.sort();
  final hotMed = hotNs[hotNs.length ~/ 2];
  final coldMed = coldNs[coldNs.length ~/ 2];
  print('sink=$sink');
  print('iters=$iters reps=$reps');
  print('hot.ns=${hotMed.toStringAsFixed(4)}');
  print('cold.ns=${coldMed.toStringAsFixed(4)}');
  print('hot.min=${hotNs.first.toStringAsFixed(4)}');
  print('cold.min=${coldNs.first.toStringAsFixed(4)}');
  print('hot.max=${hotNs.last.toStringAsFixed(4)}');
  print('cold.max=${coldNs.last.toStringAsFixed(4)}');
  print('ratio=${(hotMed / coldMed).toStringAsFixed(4)}');
}
