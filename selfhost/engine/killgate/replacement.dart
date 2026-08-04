// Supplies the new body for greet(). Compiled to bytecode with dart2bytecode.
//
// This file must reference NOTHING outside itself -- not even print(). The first
// version had `void main() { print(greet()); }` and the gate died in
// bytecode_reader.cc with:
//
//   error: Unable to find function print in Library:'dart:core' Class: ::
//
// That is the BINDING problem, not the execution question: a patch's bytecode
// references have to resolve against the base snapshot's identifiers, and they do
// not do so for free. Binding is the next question. Keeping this body
// self-contained is what stops a binding failure from masquerading as an
// execution failure.
//
// The module's entry point IS the replacement body, because the gate attaches the
// entry function's bytecode onto the target. Its signature must therefore match
// greet(): static, zero arguments, returns String.
@pragma('dyn-module:entry-point')
String greet() => 'NEW';
