// Case: a genuinely polymorphic instance call. Two implementations reached
// through the base type, so the site is specialized into a dispatch-table call
// that loads a raw entry point and never consults the Function. No patch can
// reach it -- and the kernel cannot tell you that.
abstract class Shape {
  String describe(String prefix);
}

class Circle implements Shape {
  @pragma('vm:never-inline')
  @override
  String describe(String prefix) => '$prefix:NEW-circle';
}

class Square implements Shape {
  @pragma('vm:never-inline')
  @override
  String describe(String prefix) => '$prefix:OLD-square';
}

void main() {
  final shapes = <Shape>[Circle(), Square()];
  for (final s in shapes) {
    print(s.describe(DateTime.now().millisecondsSinceEpoch >= 0 ? 'a' : 'b'));
  }
}
