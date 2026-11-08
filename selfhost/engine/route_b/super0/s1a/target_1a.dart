// D-SUPER-1A app. The question is whether a dynamic module can reference a
// Procedure belonging to the ALREADY-AOT-COMPILED app.
//
// THE OBSERVABLE IS SHARED STATE, NOT THE RETURN STRING. `releaseTopLevel`
// increments a library-private counter that `main` warms TWICE before the patch
// is attached. So:
//
//   APP:PROBE:3   the replacement reached the RELEASE's procedure and its
//                 library state -- it continued the release's count
//   APP:PROBE:1   it reached a COPY carried in the payload, with its own
//                 fresh state. Identical return shape, completely different
//                 answer to the actual question.
//
// A probe that only checked for "APP:PROBE" could not tell those apart, and
// the second is exactly the outcome that would make bucket B false.
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

int _releaseCounter = 0;

// NO `vm:entry-point` HERE, and that is the control working. The first version
// of this specimen carried it, and the negative arm then bound successfully with
// retention withheld -- because `vm:entry-point` pins the function on its own,
// independently of the dynamic interface. The control was measuring my
// annotation, not the mechanism. `greet` still needs the pragma, because
// `attachBytecodeToFunction` looks IT up by name; this one is reached from
// `main` and by kernel identity from the replacement, so it needs nothing.
@pragma('vm:never-inline')
String releaseTopLevel(String x) {
  _releaseCounter++;
  return DateTime.now().millisecondsSinceEpoch >= 0
      ? 'APP:$x:$_releaseCounter'
      : 'X';
}

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String greet() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

void main(List<String> args) {
  // Warm the release's own counter, through the release's own code, before any
  // patch exists.
  print('warm1: ${releaseTopLevel('WARM')}');
  print('warm2: ${releaseTopLevel('WARM')}');
  print('before: ${greet()}');

  if (args.isEmpty) {
    print('usage: target <replacement.bytecode> [libraryUri]');
    exitCode = 2;
    return;
  }
  final bytes = File(args[0]).readAsBytesSync();
  final libraryUri = args.length > 1 ? args[1] : 'file:///gate/target.dart';
  final ok = attachBytecodeToFunction(
    Uint8List.fromList(bytes),
    libraryUri,
    'greet',
  );
  print('attach: $ok  (libraryUri: $libraryUri)');

  // Every shape, because which ones dispatch is a separate settled question and
  // this probe must not silently depend on it.
  final String Function() torn = greet;
  print('after  direct   : ${greet()}');
  print('after  tear-off : ${torn()}');
  print('after  apply    : ${Function.apply(greet, const [])}');
}
