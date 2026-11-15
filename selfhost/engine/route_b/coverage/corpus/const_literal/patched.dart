// Case: the only edit is a constant literal inside a body, as in
// `const Text('a')` -> `const Text('b')`. The kernel printer writes constants
// as `#C1`, so before analysis version 14 this read as unchanged and the patch
// was refused as inert. The literal is in the replacement's own source, so the
// body edit ships like any other.
class Label {
  const Label(this.text);
  final String text;
}

@pragma('vm:never-inline')
String routeBValue() => const Label('NEW').text;

void main() => print(routeBValue());
