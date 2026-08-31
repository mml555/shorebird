// D0.1 hygiene control. Two classes both carry `label`, so a MIS-BINDING
// COMPILES -- a case where the wrong binding failed to resolve would prove
// nothing about the dangerous direction.
//
// Every value is routed through DateTime so nothing constant-folds away before
// the analyzer sees it.
class Other {
  @pragma('vm:never-inline')
  String get label =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'WRONG-OTHER' : 'X';
}

class Shadow {
  static final Other other = Other();

  @pragma('vm:never-inline')
  String get label =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'RIGHT-RECEIVER' : 'X';

  @pragma('vm:never-inline')
  String value() {
    final items = <Other>[Shadow.other];
    return items.map((self) => self.label + '|' + label).join();
  }
}

void main() => print(Shadow().value());
