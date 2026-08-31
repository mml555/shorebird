// D-SUPER-1B app. The decisive B/C question: can a direct call carry the APP
// OBJECT as receiver and invoke an EXACT instance Procedure?
//
// The receiver is stateful ON PURPOSE. D-SUPER-0 found a source route
// (`class _Shim extends Parent`) that returned the right VALUE off the wrong
// OBJECT, and a parent method returning a constant would have reported it as
// working. So the parent's answer depends on the receiver's own field:
//
//   P:APP-STATE   PASS   exact Parent.read AND the app's Child instance
//   C:APP-STATE   FAIL   virtual dispatch — reached the override
//   P:UNSET       FAIL   right target, wrong receiver
//   load error    FAIL   receiver-taking external DirectCall does not bind
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

class Parent {
  String slot = 'UNSET';

  @pragma('vm:never-inline')
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'P:$slot' : 'X';
}

class Child extends Parent {
  @pragma('vm:never-inline')
  @override
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'C:$slot' : 'X';
}

// The function the patch replaces. It is handed the app's own Child.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String probe(Child c) => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

void main(List<String> args) {
  final child = Child()..slot = 'APP-STATE';
  print('control virtual : ${child.read()}');
  print('before          : ${probe(child)}');

  if (args.isEmpty) {
    print('usage: target <replacement.bytecode> [libraryUri]');
    exitCode = 2;
    return;
  }
  final ok = attachBytecodeToFunction(
    Uint8List.fromList(File(args[0]).readAsBytesSync()),
    args.length > 1 ? args[1] : 'file:///gate/target.dart',
    'probe',
  );
  print('attach          : $ok');

  final String Function(Child) torn = probe;
  print('after  direct   : ${probe(child)}');
  print('after  tear-off : ${torn(child)}');
  print('after  apply    : ${Function.apply(probe, [child])}');
}
