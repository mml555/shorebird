// EB-07 -- factory constructor body. Subject: `Made.make`.
import '../_support/t0_support.dart';

class Made {
  Made.internal(this.n);
  final int n;
  factory Made.make() => Made.internal(2);
}

Future<void> main(List<String> args) async {
  await runFixture({
    'direct': () => Made.make().n.toString(),
    'tearoff_pre': () => Made.make().n.toString(),
  }, args);
}
