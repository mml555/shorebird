// Case: the shapes the earlier widening work had to survive -- a torn-off
// function passed as a value, and a body containing a closure. Both are
// static-shaped at the top level, so both stay representable.
@pragma('vm:never-inline')
String tornOff() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

@pragma('vm:never-inline')
String withClosure() {
  String inner() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-in' : 'X';
  return inner();
}

void main() {
  final String Function() f = tornOff;
  print('${f()}${withClosure()}');
}
