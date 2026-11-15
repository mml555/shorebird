// Case: the only edit is a value inside a constant. The body's kernel names the
// constant by reference, so it read as unchanged until the analyzer printed
// constants by value; a `const Text('A')` -> `const Text('B')` patch then said
// "Nothing in this patch differs".
class Box {
  const Box(this.value);
  final String value;
}

@pragma('vm:never-inline')
String routeBValue() => const Box('NEW').value;

void main() => print(routeBValue());
