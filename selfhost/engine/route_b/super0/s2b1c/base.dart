// D-SUPER-2B.1c end-to-end specimen. The SHIPPING producer runs over a real
// changed method, and the observable is the emitted replacement plus what it
// executes -- not "the producer reported success".
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
  @pragma('vm:never-inline')
  String _quiet() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'QUIET:$log' : 'X';
}

mixin TickerLike on LifeBase {
  @pragma('vm:never-inline')
  String close() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'TICKER:$log' : 'X';
}

class LifeState extends LifeBase with TickerLike {
  @pragma('vm:never-inline')
  @override
  String close() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'STATE:$log' : 'X';

  @pragma('vm:never-inline')
  @override
  String _quiet() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'S-QUIET:$log' : 'X';

  // THE TARGET. Its body is what the patch changes.
  //
  // The release's own body already REACHES both super targets, from a branch
  // that never runs. That is not decoration: the first version held them alive
  // from a separate `keepAlive` instead, and TFA then specialised `close` and
  // `_quiet` DIFFERENTLY on the two sides -- reachable only from a dead branch
  // in one, called from `target` in the other -- so the analyzer reported three
  // changed members instead of one and rejected the patch. Reaching them the
  // same way on both sides is what makes `target` the only thing that differs.
  @pragma('vm:never-inline')
  @pragma('vm:entry-point')
  String target() => DateTime.now().millisecondsSinceEpoch >= 0
      ? 'OLD'
      : '${super.close()}|${super._quiet()}';
}

void main(List<String> args) {
  final s = LifeState()..log = 'APP-STATE';
  print('virtual close        : ${s.close()}');
  print('before               : ${s.target()}');
  if (args.isEmpty) {
    print('usage: target <replacement.bytecode> [libraryUri]');
    exitCode = 2;
    return;
  }
  final ok = attachBytecodeToFunction(
    Uint8List.fromList(File(args[0]).readAsBytesSync()),
    args.length > 1 ? args[1] : 'file:///gate/target.dart',
    'LifeState.target',
  );
  print('attach               : $ok');
  print('patched              : ${s.target()}');
}
