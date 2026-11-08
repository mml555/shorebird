// Case: four changed members, three of them representable. The product rule is
// that the fourth takes the whole patch down -- shipping 3/4 would leave the
// app running three functions from the patch and one from the release, a state
// nobody designed and nobody could reproduce.
abstract class Shape {
  String describe(String prefix);
}

class Circle implements Shape {
  @pragma('vm:never-inline')
  @override
  String describe(String p) => '$p:circle';
}

@pragma('vm:never-inline')
String alpha() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-a' : 'X';

@pragma('vm:never-inline')
String beta() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-b' : 'X';

@pragma('vm:never-inline')
String gamma() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-c' : 'X';

void main() {
  final Shape s = Circle();
  print('${alpha()}${beta()}${gamma()}${s.describe('p')}');
}
