// EB-06 -- operator body. Subject: `Base.operator+`.
import '../_support/t0_support.dart';

class Base {
  int operator +(int o) => o + 1;
}

class D1 extends Base {}

class D2 extends Base {}

int _turn = 0;

Future<void> main(List<String> args) async {
  final base = Base();
  final receivers = <Base>[D1(), D2()];
  await runFixture({
    'direct': () => (base + 1).toString(),
    'virtual': () =>
        (receivers[_turn++ % receivers.length] + 1).toString(),
    'dynamic': () {
      dynamic d = base;
      return ((d + 1) as int).toString();
    },
  }, args);
}
