class Base {
  @pragma('vm:never-inline')
  void go() {}
}

class Child extends Base {
  @pragma('vm:never-inline')
  @override
  void go() {
    super.go();          // super call ONLY -- no `this` anywhere in the source
  }

  @pragma('vm:never-inline')
  void tearoffOnly() {
    final f = go;        // implicit tear-off off `this`
    f();
  }
}

void main() {
  Child()..go()..tearoffOnly();
}
