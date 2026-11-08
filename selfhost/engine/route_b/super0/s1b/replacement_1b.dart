// D-SUPER-1B replacement. `shorebirdDirectCall` is a THROWAWAY compiler
// intrinsic, not a product surface: the patched dart2bytecode recognises the
// call by name and lowers it to exactly the operation an ordinary `super` call
// already compiles to --
//
//     _genDirectCallWithArgs(exactTarget, hasReceiver: true, isUnchecked: true)
//
// -- with the receiver taken from argument 0 instead of from `this`. The target
// is named the way the release kernel names it (library, class, member), which
// is the identity D-SUPER-0 step 1 proved survives AOT.
//
// The body below is never executed as Dart; if the compiler did NOT intercept
// it, the throw is what would run, so a missed interception cannot masquerade
// as a pass.
import 'package:dynamic_modules/target_1b.dart';

String shorebirdDirectCall(
  Object receiver,
  String library,
  String className,
  String member,
) => throw StateError('not intercepted by the compiler');

@pragma('dyn-module:entry-point')
String probe(Child c) => shorebirdDirectCall(
  c,
  'package:dynamic_modules/target_1b.dart',
  'Parent',
  'read',
);
