// SL1-G2 host program. One AOT program, one test per process.
//
// EVERY CLAIM IS BACKED BY THE EXECUTION-MODE ORACLE, not by output. G2's rule
// is that output alone is insufficient, so each test asserts what mode the
// relevant function would execute in -- and a test whose oracle evidence is
// missing must FAIL, never pass quietly. That is enforced in `expectMode`.
//
// ignore_for_file: implementation_imports
import 'dart:_internal'
    show loadDynamicModule, functionExecutionMode, attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

// ---------------------------------------------------------------- the oracle
const int kUnsupported = -1, kNotFound = 0, kAot = 1, kInterpreted = 2, kNoCode = 3;
String modeName(int m) => switch (m) {
      kUnsupported => 'UNSUPPORTED',
      kNotFound => 'NOT_FOUND',
      kAot => 'AOT',
      kInterpreted => 'INTERPRETED',
      kNoCode => 'NO_CODE',
      _ => 'UNKNOWN($m)',
    };

int _failures = 0;

/// Assert execution mode, and treat every non-answer as a FAILURE.
///
/// NOT_FOUND is the dangerous one: it is what a typo in a library URI looks
/// like, and if it were allowed to satisfy "not interpreted" then the
/// bytecode->AOT test would pass without measuring anything.
void expectMode(String label, String libraryUri, String target, int want) {
  final got = functionExecutionMode(libraryUri, target);
  final ok = got == want;
  if (!ok) _failures++;
  print('MODE ${ok ? "ok  " : "FAIL"} $label: $target -> ${modeName(got)} '
      '(want ${modeName(want)})');
}

void expect(String label, bool cond, [String? detail]) {
  if (!cond) _failures++;
  print('CHECK ${cond ? "ok  " : "FAIL"} $label${detail == null ? "" : ": $detail"}');
}

// ------------------------------------------------------- host-side surface
abstract class Handler {
  String execute();
}

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String callHandler(Handler h) => h.execute();

/// The opaque callee for the bytecode -> AOT direction. never-inline keeps it a
/// real call; the operands come from [seedA]/[seedB] rather than literals so
/// the result cannot be constant-folded into the module and pass without the
/// call ever happening.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
int multiply(int a, int b) {
  multiplyTrace = StackTrace.current.toString();
  return a * b;
}

String multiplyTrace = '';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
int seedA() => int.parse(Platform.environment['G2_A'] ?? '5');

@pragma('vm:never-inline')
@pragma('vm:entry-point')
int seedB() => int.parse(Platform.environment['G2_B'] ?? '8');

/// The oracle's own falsification subjects. [attachTarget] has a KNOWN mode
/// change across an attach; [knownHost] must NOT change, which is what catches
/// an instrument that returns INTERPRETED for anything resolvable once a module
/// has been loaded.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String attachTarget() => 'OLD';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String knownHost() => 'HOST';

class Box {
  int v;
  Object? held;
  Box(this.v);
}

final Box sharedBox = Box(1);

@pragma('vm:never-inline')
@pragma('vm:entry-point')
Box getSharedBox() => sharedBox;

class HostException implements Exception {
  final String why;
  HostException(this.why);
  @override
  String toString() => 'HostException($why)';
}

/// Throws across the AOT -> bytecode boundary, for the module to catch.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
int hostThrows() => throw HostException('from-host');

/// Host-side `finally` observed while a bytecode frame unwinds through it.
String hostFinallyMark = '';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
int hostThrowsWithFinally() {
  try {
    throw HostException('with-finally');
  } finally {
    hostFinallyMark = 'HOST-FINALLY-RAN';
  }
}

Future<void> main(List<String> args) async {
  final test = args.isEmpty ? 'none' : args[0];
  final modulePath = args.length > 1 ? args[1] : null;
  final moduleUri = args.length > 2 ? args[2] : null;

  // The oracle must be alive before anything leans on it. On an OFF build it
  // reports UNSUPPORTED and every test below is meaningless, so say so loudly
  // rather than reporting a wall of NOT_FOUND.
  final selfMode = functionExecutionMode(
      'package:dynamic_modules/g2_host.dart', 'callHandler');
  print('ORACLE: callHandler -> ${modeName(selfMode)}');
  if (selfMode == kUnsupported) {
    print('G2: ORACLE UNSUPPORTED — this build has no dynamic modules');
    exitCode = 3;
    return;
  }
  if (selfMode != kAot) {
    print('G2: ORACLE SELF-CHECK FAILED — the oracle cannot see a plain AOT '
        'function, so nothing it says about anything else can be trusted');
    exitCode = 4;
    return;
  }

  // THE INSTRUMENT IS FALSIFIED BEFORE IT SCORES ANYTHING. Required control:
  // one function whose mode is known to change, one that must not, and a name
  // that does not exist. Without the second and third, an instrument that
  // answered INTERPRETED for anything resolvable after a module load would pass
  // every real test below while measuring nothing.
  if (test == 'sanity') {
    const host = 'package:dynamic_modules/g2_host.dart';
    expectMode('before attach: target', host, 'attachTarget', kAot);
    expectMode('before attach: knownHost', host, 'knownHost', kAot);
    expectMode('nonexistent symbol', host, 'noSuchFunctionAnywhere', kNotFound);
    expectMode('nonexistent library', 'package:dynamic_modules/nope.dart',
        'knownHost', kNotFound);

    final bytes = Uint8List.fromList(File(modulePath!).readAsBytesSync());
    final attached = attachBytecodeToFunction(bytes, host, 'attachTarget');
    expect('attach succeeded', attached, '$attached');

    expectMode('after attach: target', host, 'attachTarget', kInterpreted);
    expectMode('after attach: knownHost UNCHANGED', host, 'knownHost', kAot);
    expectMode('after attach: nonexistent still NOT_FOUND', host,
        'noSuchFunctionAnywhere', kNotFound);

    print(_failures == 0 ? 'G2-TEST PASS' : 'G2-TEST FAIL ($_failures)');
    exitCode = _failures == 0 ? 0 : 1;
    return;
  }

  // The load itself is the boundary for the `throw` test, so its error is
  // captured rather than allowed to abort the process.
  Object? loaded;
  Object? loadError;
  StackTrace? loadStack;
  if (modulePath != null) {
    final bytes = Uint8List.fromList(File(modulePath).readAsBytesSync());
    try {
      loaded = await loadDynamicModule(bytes: bytes);
    } on Object catch (e, st) {
      loadError = e;
      loadStack = st;
    }
  }

  switch (test) {
    // A. AOT -> bytecode -> AOT, through virtual dispatch.
    case 'dispatch':
      expect('module returned a Handler', loaded is Handler, '${loaded.runtimeType}');
      final h = loaded as Handler;
      expectMode('module implementation is interpreted', moduleUri!,
          'PatchHandler.execute', kInterpreted);
      expectMode('the AOT caller is still AOT',
          'package:dynamic_modules/g2_host.dart', 'callHandler', kAot);
      final r = callHandler(h);
      expect('AOT caller received the bytecode result', r == 'FROM-BYTECODE', r);
      // Control came back: we are executing AOT again after the call.
      expectMode('caller still AOT after the round trip',
          'package:dynamic_modules/g2_host.dart', 'callHandler', kAot);

    // B. bytecode -> AOT.
    case 'callback':
      expectMode('module entry is interpreted', moduleUri!, 'entry', kInterpreted);
      expectMode('multiply is RETAINED AOT, not interpreted',
          'package:dynamic_modules/g2_host.dart', 'multiply', kAot);
      expect('bytecode call reached AOT multiply', loaded == 40, '$loaded');
      expect('multiply captured a stack trace', multiplyTrace.isNotEmpty);
      print('TRACE-BEGIN multiply');
      print(multiplyTrace.trimRight());
      print('TRACE-END');

    // C. shared heap and exact identity.
    case 'identity':
      final parts = loaded as List<Object?>;
      final returnedBox = parts[0];
      expect('module returned the very same Box (identity, not equality)',
          identical(returnedBox, sharedBox), '${identical(returnedBox, sharedBox)}');
      expect('module mutation B->A is visible to AOT', sharedBox.v == 99, '${sharedBox.v}');
      expect('AOT retains a patch-defined object', sharedBox.held != null,
          '${sharedBox.held.runtimeType}');
      expect('patch retains the AOT object, by identity',
          parts[1] == true, '${parts[1]}');
      sharedBox.v = 7;
      expect('AOT mutation A->B is visible through the same reference',
          (returnedBox as Box).v == 7, '${returnedBox.v}');

    // D1. bytecode throws, AOT catches.
    case 'throw':
      expect('AOT caught a throw that originated in bytecode', loadError != null,
          '${loadError.runtimeType}');
      expect('it is the patch-DEFINED type, carrying its own payload',
          '$loadError' == 'ModuleException(from-module)', '$loadError');
      expect('the throw produced a stack trace', loadStack != null);
      print('TRACE-BEGIN module-throw');
      print('$loadStack'.trimRight());
      print('TRACE-END');
      // The boundary must still be usable after an exception unwound through it.
      expectMode('multiply still AOT after a bytecode throw unwound into AOT',
          'package:dynamic_modules/g2_host.dart', 'multiply', kAot);
      expect('AOT still executes correctly after the unwind',
          multiply(6, 7) == 42, '${multiply(6, 7)}');

    // D2. AOT throws, bytecode catches -- including through a host finally.
    case 'catch':
      expect('module caught the host exception', '$loaded' == 'MODULE-CAUGHT:HostException(from-host)|FINALLY:HOST-FINALLY-RAN|AGAIN:80',
          '$loaded');
      expect('the host finally ran during unwinding',
          hostFinallyMark == 'HOST-FINALLY-RAN', hostFinallyMark);
      expectMode('multiply still AOT after exceptions crossed the boundary',
          'package:dynamic_modules/g2_host.dart', 'multiply', kAot);
    default:
      print('G2: unknown test $test');
      exitCode = 2;
      return;
  }

  print(_failures == 0 ? 'G2-TEST PASS' : 'G2-TEST FAIL ($_failures)');
  exitCode = _failures == 0 ? 0 : 1;
}
