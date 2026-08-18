// Case: the abstract declaration itself changes. Call sites dispatch to
// implementations, so nothing a patch attaches to the abstract member is ever
// entered. The remediation is retention/shape, NOT compiler coverage -- which
// is why this reason must never be reported as "unsupported dispatch-table
// call".
abstract class Shape {
  String describe(String prefix);
}

class Circle implements Shape {
  @pragma('vm:never-inline')
  @override
  String describe(String p) => '$p:circle';
}

void main() {
  final Shape s = Circle();
  print(s.describe(DateTime.now().millisecondsSinceEpoch >= 0 ? 'a' : 'b'));
}
