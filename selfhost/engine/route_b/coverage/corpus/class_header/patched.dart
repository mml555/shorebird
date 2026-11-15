// Case: the only edit is a class's `implements` clause. A patch cannot change
// the hierarchy, so `o is Tagged` on the device is answered by the release's
// `Item`. Tree shaking folds that test into `main`, so before class headers
// were compared this read as a changed `main` and shipped, printing the old
// answer.
abstract class Named {
  String get tag;
}

abstract class Tagged {
  String get tag;
}

class Item implements Named, Tagged {
  @pragma('vm:never-inline')
  @override
  String get tag => 'I';
}

void main() {
  final Object o = Item();
  print(o is Tagged ? 'NEW' : 'OLD');
}
