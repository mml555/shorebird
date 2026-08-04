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
//
// vm:entry-point is also required, and for a different reason: the Precompiler
// drops library dictionaries, so at runtime an AOT snapshot cannot look a
// top-level function up by name. Without this the native reports
// "function greet not found" even though the library resolves fine.
//
// That is a GATE limitation, not a design constraint on the real system: a real
// linker identifies patch targets from the snapshot's own tables at build time,
// not by runtime name lookup, so it does not need every patchable function
// pinned as an entry point.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
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

  // Three call shapes, because they exercise DIFFERENT dispatch paths and the
  // difference between them IS the finding:
  //
  //   direct   -- AOT emits a branch whose target was resolved at compile time,
  //               so it never consults Function.code_.
  //   tear-off -- a closure call goes THROUGH the function's entry point, which
  //               is exactly what AttachBytecode repoints at InterpretCall.
  //   dynamic  -- likewise resolved at runtime.
  //
  // If direct stays OLD while the indirect shapes return NEW, the interpreter is
  // executing the attached bytecode correctly and the only gap is call-site
  // rewriting -- a linker problem, not a VM one.
  final direct = greet();
  final String Function() torn = greet;
  final viaTearOff = torn();
  // ignore: avoid_dynamic_calls
  final viaDynamic = (greet as dynamic)() as String;
  // Function.apply routes through DartEntry::InvokeFunction (dart_entry.cc:141),
  // which is the one path we KNOW contains `if (function.IsInterpreted())`. If
  // this returns NEW while the others do not, the interpreter works and every
  // other shape is simply a statically-bound call site.
  final viaApply = Function.apply(greet, const []) as String;

  print('after  direct   : $direct');
  print('after  tear-off : $viaTearOff');
  print('after  dynamic  : $viaDynamic');
  print('after  apply    : $viaApply');

  final anyNew =
      direct == 'NEW' ||
      viaTearOff == 'NEW' ||
      viaDynamic == 'NEW' ||
      viaApply == 'NEW';
  if (ok && direct == 'NEW') {
    print('GATE: PASS -- interpreted body replaced AOT body, direct calls included');
  } else if (ok && anyNew) {
    print(
      'GATE: PASS (partial) -- the interpreter DOES execute the attached '
      'bytecode; direct calls still reach the old code, so call-site rewriting '
      'is the remaining work',
    );
  } else if (ok) {
    print(
      'GATE: FAIL -- attach succeeded but no call shape reached the new body; '
      'the interpreter is not executing it',
    );
  } else {
    print(
      'GATE: INCONCLUSIVE -- attach returned false '
      '(harness lookup, or dart_dynamic_modules missing from the build)',
    );
  }
}
