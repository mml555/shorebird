// Case: the edit is a top-level `const` the body reads. The read is folded into
// the body as a constant, and the field itself is not a patch target, so the
// body is what changed.
const routeBText = 'NEW';

@pragma('vm:never-inline')
String routeBValue() => routeBText;

void main() => print(routeBValue());
