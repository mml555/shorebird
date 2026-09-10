// EB-03 -- instance method body. Subject: `Base.subject()`.
//
// Every dispatch form to ONE declaration lives here on purpose. An
// implementation that updates `direct` and leaves `virtual` stale is a bypass
// (#62 I2), and modelling the forms as modes of one row makes that read as a
// failure rather than as a percentage.
import '../_support/t0_support.dart';

abstract class Iface {
  int subject();
}

class Base implements Iface {
  int subject() => 2;
}

// Two subclasses, neither overriding, so class-hierarchy analysis cannot
// devirtualize the receiver to a single target.
class D1 extends Base {}

class D2 extends Base {}

class Sub extends Base {
  int viaSuper() => super.subject();
}

int _turn = 0;

Future<void> main(List<String> args) async {
  final base = Base();
  final receivers = <Base>[D1(), D2()];
  final Iface iface = base;
  final sub = Sub();
  final tearedBefore = base.subject;
  await runFixture({
    'direct': () => base.subject().toString(),
    'virtual': () => receivers[_turn++ % receivers.length].subject().toString(),
    'interface': () => iface.subject().toString(),
    'super': () => sub.viaSuper().toString(),
    'dynamic': () {
      dynamic d = base;
      return (d.subject() as int).toString();
    },
    'tearoff_pre': () => tearedBefore().toString(),
    'tearoff_post': () => (base.subject)().toString(),
  }, args);
}
