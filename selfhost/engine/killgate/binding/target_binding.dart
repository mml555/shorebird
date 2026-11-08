// Spike B target: does patch bytecode BIND to this program at load time?
//
// The execution gate (../target.dart) proved the interpreter runs an attached
// body. This target asks the next question: can the attached body call BACK
// into the host — an app function (hostSuffix) and an SDK function (print) —
// or does resolution die in bytecode_reader.cc the way the killgate's first
// print() attempt did?
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String greet() => 'OLD';

// The app symbol the replacement bytecode calls. Retention is the experiment:
//   arm1 keeps the vm:entry-point pragma below (the killgate's known crutch);
//   arm2 strips it (the driver deletes the ARM1 marker line) and relies on
//        gen_kernel --dynamic-interface listing it as callable — upstream's
//        designed release-time contract (dyn-module:callable ≡ vm:entry-point,
//        runtime/vm/object.cc FindEntryPointPragma).
@pragma('vm:never-inline')
@pragma('vm:entry-point') // ARM1-PRAGMA
String hostSuffix() => 'HOST';

void main(List<String> args) {
  if (args.length < 2) {
    print('usage: target_binding <replacement.bytecode> <libraryUri>');
    exitCode = 2;
    return;
  }
  // Call it once so TFA cannot drop it regardless of arm; what each arm
  // controls is whether the NAME survives for load-time resolution.
  print('host check: ${hostSuffix()}');

  final bytes = File(args[0]).readAsBytesSync();
  final ok = attachBytecodeToFunction(
    Uint8List.fromList(bytes),
    args[1],
    'greet',
  );
  if (!ok) {
    print('BINDING: ATTACH-FAILED');
    exitCode = 3;
    return;
  }
  // NOTE: this Dart-level call is EXPECTED to return OLD. Every Dart-side
  // call shape — including Function.apply — is statically bound in AOT (the
  // 2026-08-04 execution gate's finding); the path that provably enters the
  // interpreter is DartEntry::InvokeFunction from C++, which the attach
  // native itself exercises and reports as "ATTACH: C++ invoke of target
  // returned: ...". THAT line is Spike B's execution evidence; this one just
  // documents the known call-emission gap that Route B's new emission mode
  // exists to close.
  final result = Function.apply(greet, const []) as String;
  print('BINDING: RESULT=$result');
}
