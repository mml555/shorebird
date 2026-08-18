// The step 1 + step 2 replacement body: it must both BIND and be REACHED.
//
// The killgate's replacement.dart is deliberately self-contained -- it
// references nothing outside itself, so that a binding failure could not
// masquerade as an execution failure while the execution question was open.
// That question is closed, so this body does the opposite on purpose:
//
//   print()  is an SDK symbol. It resolves only if the release retained it,
//            which is Route B step 2. Without retention this dies at load in
//            bytecode_reader.cc:1172 with "Unable to find function print in
//            Library:'dart:core'" -- Spike B's canonical failure.
//
// and the value it returns has to arrive back through a plain Dart call site,
// which is Route B step 1. So one run exercises both halves, and each half has
// a distinct failure signature: no BOUND line means retention, BOUND without
// NEW-PRINTED at the call sites means dispatch.
@pragma('dyn-module:entry-point')
String greet() {
  print('BOUND');
  return 'NEW-PRINTED';
}
