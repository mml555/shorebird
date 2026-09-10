// EB-14 -- closure and local-function body, capture shape UNCHANGED.
// A changed capture shape is RS-03 and is deliberately not this row.
import '../_support/t0_support.dart';

int Function() makeClosure(int captured) {
  return () => captured + 1;
}

Future<void> main(List<String> args) async {
  // Created before installation: its context already exists on the heap.
  final madeBefore = makeClosure(1);
  await runFixture({
    'direct': () => makeClosure(1)().toString(),
    'tearoff_pre': () => madeBefore().toString(),
  }, args);
}
