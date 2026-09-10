// EB-04 -- getter body. Subject: `Base.subject`.
import '../_support/t0_support.dart';

abstract class Iface {
  int get subject;
}

class Base implements Iface {
  int get subject => 1;
}

class D1 extends Base {}

class D2 extends Base {}

int _turn = 0;

Future<void> main(List<String> args) async {
  final base = Base();
  final receivers = <Base>[D1(), D2()];
  final Iface iface = base;
  await runFixture({
    'direct': () => base.subject.toString(),
    'virtual': () => receivers[_turn++ % receivers.length].subject.toString(),
    'interface': () => iface.subject.toString(),
    'dynamic': () {
      dynamic d = base;
      return (d.subject as int).toString();
    },
  }, args);
}
