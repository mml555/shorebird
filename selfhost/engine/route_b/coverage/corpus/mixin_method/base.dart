// Case: a mixin method's body edited. AOT copies the mixin's members into each
// class that applies it, in `dart:mixin_deduplication`, and calls reach the
// copy. A patch replaces the app's procedures, not that copy, so the edit would
// never run; the patch is refused.
mixin Labelled {
  @pragma('vm:never-inline')
  String get label => 'OLD';
}

class Base {}

class Item extends Base with Labelled {}

void main() => print(Item().label);
