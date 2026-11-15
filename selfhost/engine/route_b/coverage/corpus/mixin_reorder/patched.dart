// Case: class declarations reordered, nothing else. AOT numbers its mixin
// copies (`_MixinApplication0&Base&N`) in declaration order, and two
// instantiations of a generic mixin share a name, so a reorder once read as
// every copy, header and body naming one having changed. Keys and printed text
// drop the counter and carry the type arguments, so the patch is inert.
mixin Box<T> {
  List<T> items = <T>[];
  int count() => items.length;
}

mixin Named {
  @pragma('vm:never-inline')
  String label() => 'OLD';
}

class Base {}

class Item extends Base with Named {}

class Strings with Box<String> {}

class Ints with Box<int> {}

void main() => print('${Ints().count()}${Strings().count()}${Item().label()}');
