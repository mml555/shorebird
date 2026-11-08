// SM1-G5 adversarial corpus: a PRIVATE GETTER AND SETTER SHARING A NAME.
//
// `_x` is declared twice -- once as a getter, once as a setter -- so a
// reference resolved only to (library, owner, name) cannot say which
// declaration it meant. `readIt` must consult the GETTER's G3 row and `writeIt`
// the SETTER's. A predictor that searches G3 across kinds and takes the first
// match would let one authorise the other, which is the loose-identity fault
// this corpus exists to catch.
library corpus.app;

import 'helper.dart';

class Holder {
  int _v = 0;

  int get _x => _v;

  set _x(int n) {
    _v = n;
  }

  int readIt() => _x;

  void writeIt(int n) {
    _x = n;
  }
}

int usesHolder() {
  final h = Holder();
  h.writeIt(3);
  return h.readIt() + helperAdd(1);
}

void main() {
  print(usesHolder());
}
