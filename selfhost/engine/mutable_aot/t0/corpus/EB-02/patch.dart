// EB-02 -- static method body. Subject: `Holder.subject()`.
import '../_support/t0_support.dart';

class Holder {
  static int subject() => 2;
}

Future<void> main(List<String> args) async {
  final tearedBefore = Holder.subject;
  await runFixture({
    'direct': () => Holder.subject().toString(),
    'tearoff_pre': () => tearedBefore().toString(),
    'tearoff_post': () => (Holder.subject)().toString(),
    'dynamic': () {
      dynamic f = Holder.subject;
      return (f() as int).toString();
    },
  }, args);
}
