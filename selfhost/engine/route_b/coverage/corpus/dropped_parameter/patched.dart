// Case: a getter stops reading a field set by an initializing formal,
// `A(this.x, ...)`. Tree shaking then removes the field, the parameter and
// the argument every caller passes, and the field's initializer has no side
// effects, so no trace of it is left. The constructor's source did not change.
// The getter and the caller whose argument was pruned ship.
class Box {
  Box(this.name, this.extra);
  final String name;
  final String extra;

  @pragma('vm:never-inline')
  String value() => name;
}

@pragma('vm:never-inline')
String routeBMake() => Box('OLD', DateTime.now().toString()).value();

void main() => print(routeBMake());
