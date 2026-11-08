// Case: an ordinary top-level function. The canonical representable target --
// AOT emits a static-shaped call, which is exactly the form Route B patches.
@pragma('vm:never-inline')
String routeBValue() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW' : 'X';

void main() => print(routeBValue());
