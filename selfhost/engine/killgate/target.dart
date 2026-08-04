// The program that gets AOT-compiled. `greet` is the function the gate replaces.
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

// vm:never-inline is load-bearing, not hygiene. Without it AOT inlines greet()
// into main() and the output cannot change no matter what we attach -- the gate
// would fail for a reason unrelated to the interpreter. Inlining is precisely
// what limits real patches (it is what a link percentage measures), so the gate
// controls for it rather than accidentally testing it.
@pragma('vm:never-inline')
String greet() => 'OLD';

void main(List<String> args) {
  print('before: ${greet()}');

  if (args.isEmpty) {
    print('usage: target <replacement.bytecode> [libraryUri]');
    exitCode = 2;
    return;
  }

  final bytes = File(args[0]).readAsBytesSync();

  // The library URI as the AOT snapshot records it. Taken as an argument rather
  // than hardcoded: a URI mismatch is the likeliest harness-level failure, and
  // baking it in would cost a full rebuild to correct.
  final libraryUri = args.length > 1 ? args[1] : 'file:///gate/target.dart';

  final ok = attachBytecodeToFunction(
    Uint8List.fromList(bytes),
    libraryUri,
    'greet',
  );
  print('attach: $ok  (libraryUri: $libraryUri)');

  final after = greet();
  print('after:  $after');

  // The verdict, stated by the program itself so the runner cannot misread it.
  if (ok && after == 'NEW') {
    print(
      'GATE: PASS -- interpreted body replaced AOT body in a precompiled runtime',
    );
  } else if (ok) {
    print(
      'GATE: FAIL -- attach succeeded but dispatch did not reroute '
      '(got "$after"; suspect inlining or a direct call)',
    );
  } else {
    print(
      'GATE: INCONCLUSIVE -- attach returned false '
      '(harness lookup, or dart_dynamic_modules missing from the build)',
    );
  }
}
