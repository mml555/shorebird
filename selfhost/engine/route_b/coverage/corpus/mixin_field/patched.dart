// Case: a mixin field's literal initializer edited, the class applying the
// mixin directly (no base class). AOT copies the field and its initializer into
// a `dart:mixin_deduplication` class, outside the app libraries. The copy is
// what runs, and a patch cannot replace it, so the patch is refused.
mixin Counter {
  int start = 2;
}

class Tally with Counter {
  @pragma('vm:never-inline')
  String value() => start == 1 ? 'OLD' : 'X';
}

void main() => print(Tally().value());
