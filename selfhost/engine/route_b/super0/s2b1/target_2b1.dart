// D-SUPER-2B.1 host specimen. Three shapes in one app:
//
//   lifeGo   State-like lifecycle over a mixin application, BOTH declaring the
//            member -- the Wonderous `super.dispose()` shape, and the one AOT
//            mixin deduplication renames.
//   deepGo   nearest implementation is NOT the immediate superclass.
//   argGo    super call WITH ARGUMENTS. Must be refused, and the AOT kernel
//            reports zero for it (D-SUPER-2B.0), so only the source and the
//            import kernel can catch it.
//
// Every competing implementation is stateful, so a right-value/wrong-object
// result cannot pass.
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

class LifeBase {
  String log = 'UNSET';
  @pragma('vm:never-inline')
  String close() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'BASE:$log' : 'X';
}

mixin TickerLike on LifeBase {
  @pragma('vm:never-inline')
  String close() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'TICKER:$log' : 'X';
}

class LifeState extends LifeBase with TickerLike {
  @pragma('vm:never-inline')
  @override
  String close() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'STATE:$log' : 'X';

  // THE ORIGINAL SITE the compiler backstop rediscovers.
  @pragma('vm:never-inline')
  String original() => super.close();
}

class DeepBase {
  String log = 'UNSET';
  @pragma('vm:never-inline')
  String close() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'DEEP-BASE:$log' : 'X';
}

class DeepMid extends DeepBase {}

class DeepLeaf extends DeepMid {
  @pragma('vm:never-inline')
  @override
  String close() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'DEEP-LEAF:$log' : 'X';

  @pragma('vm:never-inline')
  String original() => super.close();
}

class ArgBase {
  String log = 'UNSET';
  @pragma('vm:never-inline')
  String tag(String a, int b) =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'ARG-BASE:$a:$b:$log' : 'X';
}

class ArgLeaf extends ArgBase {
  @pragma('vm:never-inline')
  @override
  String tag(String a, int b) =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'ARG-LEAF:$log' : 'X';

  @pragma('vm:never-inline')
  String original() => super.tag('a', 7);
}

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String lifeGo(LifeState self) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String deepGo(DeepLeaf self) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String argGo(ArgLeaf self) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

void main(List<String> args) {
  final life = LifeState()..log = 'APP-STATE';
  final deep = DeepLeaf()..log = 'APP-STATE';
  final arg = ArgLeaf()..log = 'APP-STATE';

  print('unpatched life super : ${life.original()}');
  print('unpatched deep super : ${deep.original()}');
  print('unpatched arg  super : ${arg.original()}');
  print('virtual life         : ${life.close()}');
  print('virtual deep         : ${deep.close()}');

  if (args.length < 2) {
    print('usage: target <replacement.bytecode> <lifeGo|deepGo|argGo> [uri]');
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
  switch (which) {
    case 'lifeGo':
      print('patched              : ${lifeGo(life)}');
    case 'deepGo':
      print('patched              : ${deepGo(deep)}');
    default:
      print('patched              : ${argGo(arg)}');
  }
}
