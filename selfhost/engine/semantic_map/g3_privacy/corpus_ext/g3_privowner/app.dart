// SM1-G3 adversarial corpus -- PRIVATE OWNERS.
//
// The base corpus has no private class, so nothing exercised the rule that a
// PUBLIC member of a PRIVATE class is still access-controlled. Its own `Name`
// is public, so a member-only privacy model files it under domain `public` and
// then compares `public` against a library URI -- refusing a legitimate
// same-library access as cross-domain.
library corpus.app;

import 'helper.dart';

/// PRIVATE CLASS, PUBLIC MEMBERS. `ping` and the unnamed constructor both have
/// public `Name`s; only the owner is private.
class _Hidden {
  _Hidden(this.seed);

  final int seed;

  int ping() => seed + 1;

  int _secretPing() => seed + 2;

  int mutable = 3;
}

int useHidden() => _Hidden(1).ping() + _Hidden(2)._secretPing();

int topLevel(int x) => x + 1;

int _privateHelper(int x) => x * 2;

int usesPrivate(int x) => _privateHelper(x);

int usesOtherLibrary(int x) => helperAdd(x) + helperUsesHidden();

void main() {
  print(useHidden());
  print(topLevel(1));
  print(usesPrivate(2));
  print(usesOtherLibrary(3));
}
