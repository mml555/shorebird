// EB-08 -- generative constructor body. Subject: `Built()`.
import '../_support/t0_support.dart';

class Built {
  int n = 0;
  Built() {
    n = 2;
  }
}

Future<void> main(List<String> args) async {
  await runFixture({
    'direct': () => Built().n.toString(),
  }, args);
}
