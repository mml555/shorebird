// SM1-G5 DEMONSTRATION HOST.
//
// This program never reads the semantic map. It attempts a real patch against a
// named declaration using the VM's own attach primitive and reports what
// actually happened. That independence is the point: #54 requires
// "demonstrated patchable" to mean OBSERVED TO PATCH, not predicted by the same
// model under test, and a demonstrator that consulted the map would make the
// subset check compare the model with itself.
//
// ignore_for_file: implementation_imports, avoid_print
import 'dart:_internal' show attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

import 'package:corpus/app.dart' as app;

/// Calls the subject by name and returns what it produced, so a patch that
/// attaches but does not take effect is distinguishable from one that does.
// NEVER-INLINE INDIRECTION. Without it, the observer's own call to the subject
// is trivially inlinable and a null result would say more about this harness
// than about the subject. The control below distinguishes "the release inlined
// MY call" from "the declaration cannot be patched at all".
@pragma('vm:never-inline')
String _callTopLevel() => '${app.topLevel(1)}';

String observe(String target) {
  switch (target) {
    case 'topLevel':
      return _callTopLevel();
    case 'usesPrivate':
      return '${app.usesPrivate(2)}';
    case 'usesOtherLibrary':
      return '${app.usesOtherLibrary(3)}';
    case 'Shape.area':
      return '${app.Shape(3).area(2, 4)}';
    case 'Shape.perimeter':
      return '${app.Shape(3).perimeter}';
    case 'Shape.scaled':
      return '${app.Shape(3).scaled}';
    case 'Box.unwrap':
      return '${app.Box<app.Shape>(app.Shape(7)).unwrap().sides}';
    default:
      return 'NO_OBSERVER';
  }
}

void main(List<String> args) {
  if (args.length < 3) {
    print('usage: demo_host <libraryUri> <targetName> <bytecode>');
    exitCode = 2;
    return;
  }
  final lib = args[0], target = args[1], path = args[2];

  final before = observe(target);
  print('BEFORE $target = $before');
  if (before == 'NO_OBSERVER') {
    // Refused rather than guessed: a subject with no observer cannot be shown
    // to have changed, so calling it demonstrated would be an over-claim by the
    // harness itself.
    print('DEMO_RESULT NO_OBSERVER');
    return;
  }

  final bytes = Uint8List.fromList(File(path).readAsBytesSync());
  final attached = attachBytecodeToFunction(bytes, lib, target);
  print('ATTACHED $attached');
  if (!attached) {
    print('DEMO_RESULT ATTACH_REFUSED');
    return;
  }

  final after = observe(target);
  print('AFTER  $target = $after');
  // ATTACHING IS NOT PATCHING. The value has to move, or the release answered
  // its own question -- the silent bypass SM1-G4 measured for two retention
  // classes.
  print(after != before ? 'DEMO_RESULT PATCHED' : 'DEMO_RESULT SILENT_NO_EFFECT');
}
