// SM1-G5 adversarial corpus: PRIVATE REFERENCES THAT ARE NOT PLAIN CALLS.
//
// Each body below reaches a private declaration through a node kind that is NOT
// an InstanceGet/StaticGet/InstanceInvocation. Before the walker modelled them,
// these node kinds were ALLOWLISTED with no fact-bearing visitor, so every body
// here read as "no private references found" -- a false negative, which is the
// one thing this gate must never produce.
library corpus.app;

import 'helper.dart';

int _secret() => 3;

class Base {
  int _hidden() => 7;
  int baseValue() => 1;
}

class Sub extends Base {
  /// SUPER METHOD INVOCATION of a private member.
  int viaSuper() => super._hidden();

  /// INSTANCE TEAR-OFF of a private member.
  int Function() viaInstanceTearOff() => _hidden;
}

/// STATIC TEAR-OFF of a private top-level function.
int viaStaticTearOff() {
  final f = _secret;
  return f();
}

/// DYNAMIC access to a private member: the target is not statically resolved,
/// so no exact identity exists and the walker must REFUSE rather than report
/// nothing found.
int viaDynamic(dynamic d) => d._hidden() as int;

void main() {
  print(viaStaticTearOff() + Sub().viaSuper() +
      Sub().viaInstanceTearOff()() + viaDynamic(Sub()) + helperAdd(1));
}
