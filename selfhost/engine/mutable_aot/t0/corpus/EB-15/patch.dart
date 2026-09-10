// EB-15 -- generic function body. Subject: `pick<T>()`.
import '../_support/t0_support.dart';

T pick<T>(T a, T b) => b;

Future<void> main(List<String> args) async {
  final tearedBefore = pick<int>;
  await runFixture({
    'direct': () => pick<int>(1, 2).toString(),
    'tearoff_pre': () => tearedBefore(1, 2).toString(),
    'dynamic': () {
      dynamic f = pick<int>;
      return (f(1, 2) as int).toString();
    },
  }, args);
}
