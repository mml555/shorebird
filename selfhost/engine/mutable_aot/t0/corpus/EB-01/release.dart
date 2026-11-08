// EB-01 -- top-level function body. Subject: `subject()`.
import '../_support/t0_support.dart';

int subject() => 1;

Future<void> main(List<String> args) async {
  // Captured before any installation could occur: a tear-off is a reference
  // to a declaration, not a snapshot of its implementation.
  final tearedBefore = subject;
  await runFixture({
    'direct': () => subject().toString(),
    'tearoff_pre': () => tearedBefore().toString(),
    'tearoff_post': () => (subject)().toString(),
    'dynamic': () {
      dynamic f = subject;
      return (f() as int).toString();
    },
  }, args);
}
