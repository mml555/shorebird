// EB-05 -- setter body. Subject: `Base.subject=`. The observation is what the
// setter STORED, so a stale setter is visible in the stored value.
import '../_support/t0_support.dart';

abstract class Iface {
  set subject(int v);
  int get stored;
}

class Base implements Iface {
  int stored = 0;
  set subject(int v) {
    stored = v * 2;
  }
}

class D1 extends Base {}

class D2 extends Base {}

int _turn = 0;

String _store(Base b, int v) {
  b.subject = v;
  return b.stored.toString();
}

Future<void> main(List<String> args) async {
  final base = Base();
  final receivers = <Base>[D1(), D2()];
  final Iface iface = base;
  await runFixture({
    'direct': () => _store(base, 1),
    'virtual': () => _store(receivers[_turn++ % receivers.length], 1),
    'interface': () {
      iface.subject = 1;
      return iface.stored.toString();
    },
    'dynamic': () {
      dynamic d = base;
      d.subject = 1;
      return (d.stored as int).toString();
    },
  }, args);
}
