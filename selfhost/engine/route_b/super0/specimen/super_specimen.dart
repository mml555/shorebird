class Parent {
  @pragma('vm:never-inline')
  String value() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'PARENT' : 'X';

  @pragma('vm:never-inline')
  String get tag => DateTime.now().millisecondsSinceEpoch >= 0 ? 'P-TAG' : 'X';
}

class Child extends Parent {
  @pragma('vm:never-inline')
  @override
  String value() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'CHILD' : 'X';

  @pragma('vm:never-inline')
  @override
  String get tag => DateTime.now().millisecondsSinceEpoch >= 0 ? 'C-TAG' : 'X';

  // THE TARGET. Must observably yield PARENT, never CHILD.
  @pragma('vm:never-inline')
  String target() => super.value();

  @pragma('vm:never-inline')
  String targetGetter() => super.tag;
}

// THE RECURSION CONTROL. `recurse()` overrides nothing, but its super call
// lands on a Parent method that itself calls back through virtual dispatch --
// so a mistaken `self.recurse()` cannot return a plausible string; it must
// blow the stack instead.
class Loop extends Parent {
  @pragma('vm:never-inline')
  @override
  String value() => 'LOOP-${super.value()}';
}

void main() {
  print(Child().target());
  print(Child().targetGetter());
  print(Loop().value());
}
