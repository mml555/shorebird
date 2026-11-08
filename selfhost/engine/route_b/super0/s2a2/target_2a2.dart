// D-SUPER-2A.2 execution leg. Does LOCAL re-derivation in the import kernel
// select the implementation the unpatched program actually runs?
//
// Two targets, each a different reason the answer could be wrong:
//
//   mixGo   MixLoud extends MixB with LoudMixin, and BOTH declare `read`.
//           `super.read()` must reach the MIXIN's copy, not MixB's. This is the
//           shape whose canonical identity is renamed by AOT mixin
//           deduplication (D-SUPER-2A), so it is the one a transported name
//           would break.
//
//   deepGo  DeepC extends DeepB extends DeepA, and DeepB declares NOTHING.
//           `super.read()` must reach DeepA. The rule has to be "the
//           implementation the hierarchy selects", not "a method on the
//           immediate syntactic superclass" -- the two differ here, and they
//           also differed on the real `_AnimatedCloudsState` site, whose
//           retained target lived in a SHORTER mixin application than its own
//           superclass.
//
// EVERY COMPETING IMPLEMENTATION IS STATEFUL. A constant-returning parent would
// let a right-value/wrong-object result pass, which is precisely how
// D-SUPER-0's shim route nearly passed.
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

class MixB {
  String slot = 'UNSET';
  @pragma('vm:never-inline')
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'MIX-B:$slot' : 'X';
}

mixin LoudMixin on MixB {
  @pragma('vm:never-inline')
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'MIXIN:$slot' : 'X';
}

class MixLoud extends MixB with LoudMixin {
  @pragma('vm:never-inline')
  @override
  String read() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'MIX-LOUD:$slot' : 'X';

  @pragma('vm:never-inline')
  String mixGoOriginal() => super.read();
}

class DeepA {
  String slot = 'UNSET';
  @pragma('vm:never-inline')
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'DEEP-A:$slot' : 'X';
}

class DeepB extends DeepA {}

class DeepC extends DeepB {
  @pragma('vm:never-inline')
  @override
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'DEEP-C:$slot' : 'X';

  @pragma('vm:never-inline')
  String deepGoOriginal() => super.read();
}

// The replaced functions are TOP-LEVEL and take the receiver as parameter 0 --
// the shape a Route B replacement actually has, and the shape
// `attachBytecodeToFunction` can locate by name. The first version of this
// specimen made them instance methods and the harness reported
// "function mixGo not found", which is a harness limitation, not a result.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String mixGo(MixLoud self) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String deepGo(DeepC self) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

void main(List<String> args) {
  final mix = MixLoud()..slot = 'APP-STATE';
  final deep = DeepC()..slot = 'APP-STATE';

  // THE BASELINE IS THE UNPATCHED PROGRAM'S OWN SUPER CALL, not a guess about
  // what it should be.
  print('unpatched mix super  : ${mix.mixGoOriginal()}');
  print('unpatched deep super : ${deep.deepGoOriginal()}');
  print('virtual mix          : ${mix.read()}');
  print('virtual deep         : ${deep.read()}');

  if (args.length < 2) {
    print('usage: target <replacement.bytecode> <mixGo|deepGo> [libraryUri]');
    exitCode = 2;
    return;
  }
  final which = args[1];
  final ok = attachBytecodeToFunction(
    Uint8List.fromList(File(args[0]).readAsBytesSync()),
    args.length > 2 ? args[2] : 'file:///gate/target.dart',
    which,
  );
  print('attach               : $ok  ($which)');

  if (which == 'mixGo') {
    print('patched              : ${mixGo(mix)}');
  } else {
    print('patched              : ${deepGo(deep)}');
  }
}
