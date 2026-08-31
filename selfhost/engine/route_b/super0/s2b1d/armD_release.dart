// 2B.1d arm A -- ordinary hierarchy. Baseline for the new import relationship.
// ignore_for_file: implementation_imports
import 'dart:_internal' show attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

class AParent {
  String state = 'UNSET';
  @pragma('vm:never-inline')
  String read() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'PARENT:$state' : 'X';
}

class AChild extends AParent {
  @pragma('vm:never-inline')
  @override
  String read() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'CHILD:$state' : 'X';

  // Release keeps the target reachable and the super target retained.
  // NO super site in the release. `read()` is a VIRTUAL call, which retains the
  // member without creating a super invocation.
  @pragma('vm:never-inline')
  String target() => DateTime.now().millisecondsSinceEpoch >= 0
      ? 'OLD'
      : read();
}

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String go(AChild self) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

void main(List<String> args) {
  final c = AChild()..state = 'APP-STATE';
  print('unpatched super     : ${c.target()}');
  print('virtual             : ${c.read()}');
  if (args.isEmpty) {
    print('usage: target <replacement.bytecode> [uri]');
    exitCode = 2;
    return;
  }
  final ok = attachBytecodeToFunction(
    Uint8List.fromList(File(args[0]).readAsBytesSync()),
    args.length > 1 ? args[1] : 'file:///gate/target.dart',
    'go',
  );
  print('attach              : $ok');
  print('patched             : ${go(c)}');
}
