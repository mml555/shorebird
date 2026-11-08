// EB-12 -- async* generator body. Subject: `subject()`.
// A stream created after installation must yield the new value; a stream
// already being consumed is RS-06's subject.
import '../_support/t0_support.dart';

Stream<int> subject() async* {
  yield 2;
}

Future<void> main(List<String> args) async {
  await runFixture({
    'direct': () async => (await subject().first).toString(),
    'dynamic': () async {
      dynamic f = subject;
      return ((await (f() as Stream<int>).first)).toString();
    },
  }, args);
}
