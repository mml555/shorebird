// EB-11 -- async function body. Subject: `subject()`.
// A call STARTED after installation must complete with the new value. A call
// already suspended inside the old body is RS-05's subject, not this row's.
import '../_support/t0_support.dart';

Future<int> subject() async => 1;

Future<void> main(List<String> args) async {
  final tearedBefore = subject;
  await runFixture({
    'direct': () async => (await subject()).toString(),
    'tearoff_pre': () async => (await tearedBefore()).toString(),
    'dynamic': () async {
      dynamic f = subject;
      return ((await f()) as int).toString();
    },
  }, args);
}
