// Compiled to bytecode with dart2bytecode; supplies the new body for greet().
//
// Deliberately self-contained -- a string literal and nothing else. If this
// referenced other classes or constants, the gate would also be testing whether
// the patch's bytecode binds to the base snapshot's object pool, and a failure
// would not say which half broke. Binding is the next question, not this one.
//
// Signature must match the target: static, zero arguments, returns String.
String greet() => 'NEW';

void main() {
  // dart2bytecode wants an entry point; the gate attaches greet's bytecode, not
  // this. Kept trivial on purpose.
  print(greet());
}
