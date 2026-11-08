// EB-19 -- callable class `call` body. Subject: `Callable.call()`.
import '../_support/t0_support.dart';

class Callable {
  int call() => 1;
}

class D1 extends Callable {}

class D2 extends Callable {}

int _turn = 0;

Future<void> main(List<String> args) async {
  final c = Callable();
  final receivers = <Callable>[D1(), D2()];
  // A Function-typed reference obtained before installation.
  final int Function() asFunction = c;
  await runFixture({
    'direct': () => c().toString(),
    'virtual': () => receivers[_turn++ % receivers.length]().toString(),
    'dynamic': () {
      dynamic d = c;
      return (d() as int).toString();
    },
    'tearoff_pre': () => asFunction().toString(),
  }, args);
}
