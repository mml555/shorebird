// Case: the other compound spellings -- an explicit `this.` with `+=`, `++`
// before and after, `??=`, and `+=` inside a closure (the setState shape). The
// front end puts the read and the write at the member name in every one, so
// each is one receiver edit and carried like any instance member.
class Counter {
  int _a = 0;
  int b = 0;
  int? _c;
  int _d = 0;
  void tick(void Function() f) => f();

  @pragma('vm:never-inline')
  int ta() => this._a += 2;
  @pragma('vm:never-inline')
  int tb() => this.b++ + 0;
  @pragma('vm:never-inline')
  int tc() => this._c ??= 4;
  @pragma('vm:never-inline')
  void td() => tick(() {
    _d += 2;
  });
  @pragma('vm:never-inline')
  int te() => ++this.b + 0;
}

void main() {
  final c = Counter();
  print([c.ta(), c.tb(), c.tc(), c.te()]);
  c.td();
}
