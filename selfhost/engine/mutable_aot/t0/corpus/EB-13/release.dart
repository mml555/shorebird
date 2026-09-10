// EB-13 -- sync* generator body. Subject: `subject()`. Synchronous, so the
// value is observable in the same turn -- unlike EB-11 and EB-12.
import '../_support/t0_support.dart';

Iterable<int> subject() sync* {
  yield 1;
}

Future<void> main(List<String> args) async {
  await runFixture({
    'direct': () => subject().first.toString(),
    'dynamic': () {
      dynamic f = subject;
      return ((f() as Iterable<int>).first).toString();
    },
  }, args);
}
