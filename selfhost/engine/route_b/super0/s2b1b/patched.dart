// D-SUPER-2B.1b analyzer v10 controls. Six shapes, each asserting a different
// clause of the new contract. Base and patched differ only in the bodies of the
// six `t*` targets, so every reported lowering belongs to a shape under test.
class Parent {
  String slot = 'UNSET';
  @pragma('vm:never-inline')
  String dispose() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'P-D' : 'X';
  @pragma('vm:never-inline')
  String tag(String a, int b) =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'P-T:$a:$b' : 'X';
  @pragma('vm:never-inline')
  String get acc => DateTime.now().millisecondsSinceEpoch >= 0 ? 'P-A' : 'X';
  set acc(String v) => slot = v;
  @pragma('vm:never-inline')
  String _hidden() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'P-H' : 'X';
}

class Sink {
  // THE ARGUMENT'S VALUE MUST GENUINELY MATTER, and it took two attempts.
  //
  // v1 ignored `o`: TFA specialised `take` to take no parameters and dropped
  // the `this` argument from the call site, so the analyzer saw no escape and
  // the control reported the refusal had vanished. It had not; the specimen
  // had.
  //
  // v2 used `o is Child`: TFA folded that to `true` -- every call site passes a
  // Child -- and dropped the parameter again.
  //
  // Storing it and reading its hashCode is neither foldable nor removable.
  Object? last;

  @pragma('vm:never-inline')
  String take(Object o) {
    last = o;
    return DateTime.now().millisecondsSinceEpoch >= 0 ? 'S:${o.hashCode}' : 'X';
  }
}

class Child extends Parent {
  static final Sink sink = Sink();

  @pragma('vm:never-inline')
  String helper() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'H' : 'X';

  @pragma('vm:never-inline')
  String t1() => super.dispose();
  @pragma('vm:never-inline')
  String t2() => super.tag('a', 7);
  @pragma('vm:never-inline')
  String t3() => this.helper();
  @pragma('vm:never-inline')
  String t4() => Child.sink.take(this);
  @pragma('vm:never-inline')
  String t5() => super.acc;
  @pragma('vm:never-inline')
  String t6() => super._hidden();

  // Retention: hold every member the patched bodies reach, from a dead branch,
  // identically on both sides. Without this the analyzer refuses for "member(s)
  // are new" and says nothing about super.
  @pragma('vm:never-inline')
  String keepAlive() => DateTime.now().millisecondsSinceEpoch < 0
      ? '${dispose()}${tag('a', 7)}$acc${_hidden()}${helper()}'
          '${Child.sink.take(this)}'
      : 'k';
}

void main() {
  final c = Child()..slot = 'APP';
  print(c.keepAlive().isEmpty
      ? 'X'
      : '${c.t1()}${c.t2()}${c.t3()}${c.t4()}${c.t5()}${c.t6()}');
}
