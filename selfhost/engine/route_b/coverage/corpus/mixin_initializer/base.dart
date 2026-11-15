// Case: a mixin's field initializer edited. AOT copies the mixin's fields and
// their initializers into each class that applies it, and moves those copies
// into `dart:mixin_deduplication`. The edit shows only there, which is outside
// the app libraries, so it once read as unchanged. The copy is what runs, and a
// patch cannot replace it, so the patch is refused.
mixin Counter {
  final int start = int.parse('1');
}

class Base {}

class Tally extends Base with Counter {
  @pragma('vm:never-inline')
  String value() => start == 1 ? 'OLD' : 'X';
}

void main() => print(Tally().value());
