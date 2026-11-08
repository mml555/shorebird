// Part 2B specimen, PATCHABLE HALF.
//
// Deliberately free of `dart:_internal`: the attach machinery lives in
// `harness.dart` instead. The producer emits a replacement that inherits the
// target library's imports, and a synthetic replacement library cannot import a
// platform-private library — "Can't access platform private library", which is
// what the first version of this specimen hit. A real app would never import it
// either.
class Base {
  String state = 'UNSET';
  @pragma('vm:never-inline')
  String close() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'BASE:$state' : 'X';
}

mixin Ticker on Base {
  @pragma('vm:never-inline')
  String close() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'TICKER:$state' : 'X';
}

class Leaf extends Base with Ticker {
  @pragma('vm:never-inline')
  @override
  String close() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'LEAF:$state' : 'X';

  // THE TARGET. The release already direct-calls the mixin's `close`, which is
  // what the narrow-v1 evidence rule requires and what forced AOT to compile it.
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  String target() => super.close();
}
