// Case: a getter stops reading a field, and the field's declaration and
// initializer are untouched. Tree shaking then drops the field from the
// patched kernel and keeps its initializer, which can have side effects, as a
// nameless local in the constructor. The constructor's printed kernel differs
// while its source did not. Version 14's first cut refused this valid patch as
// a changed constructor. The getter is the only edit, and it ships.
int routeBCompute() => DateTime.now().millisecondsSinceEpoch >= 0 ? 1 : 2;

class Box {
  Box(this.name);
  int extra = routeBCompute();
  final String name;

  @pragma('vm:never-inline')
  String value() => '$name $extra';
}

void main() => print(Box('OLD').value());
