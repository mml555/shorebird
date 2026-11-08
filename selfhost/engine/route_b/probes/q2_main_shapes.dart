// G15 Q2 — what does `main` actually return, at the boundary the seam wraps?
//
// Precommitted in evidence/g15/q2_success_policy_precommit.md. This settles the
// half a host can settle: which of {sync return, Future success, Future error,
// no completion} each of the seven startup shapes produces at
// `userMainFunction(args)` (hooks.dart:410/412).
//
// WHAT THIS IS NOT. It does NOT measure whether `PlatformDispatcher.onError`
// fires before or after the seam would observe. That needs an instrumented
// engine, i.e. the seam itself, and the precommit says so in advance. The source
// argument in evidence/g15/runmain_seam_matrix.txt stands on its own and must not
// be reported as measured until an instrumented engine says so.
//
// WHY `runApp` IS A NO-OP HERE, and why that does not weaken the result. The
// property under test is the RETURN SHAPE of `main`, which is a function of
// `main`'s signature and control flow, not of what it calls. `runApp` returns
// `void` and cannot change whether `main` returns a Future or whether that Future
// completes. Substituting it removes the Flutter binding dependency without
// touching the measured property. S6 is the one shape whose distinguishing
// feature (`PlatformDispatcher.onError`) lives in the half this probe cannot
// reach; its RETURN shape is measured, and its dispatch behaviour is not claimed.
//
// Run: dart selfhost/engine/route_b/probes/q2_main_shapes.dart

import 'dart:async';

/// Stands in for `runApp`. Returns void, exactly as the real one does.
void runApp(Object _) {}

/// How long to watch a Future before recording it as not-completed.
///
/// A BOUNDED OBSERVATION IS NOT A PROOF OF NEVER. S7's signature is "did not
/// complete within the window", and it is reported in exactly those words. The
/// seam must never treat "not yet completed" as "failed" for the same reason.
const Duration kWindow = Duration(milliseconds: 250);

/// The seam's boundary, reproduced. `_runMain` calls `userMainFunction(args)` and
/// discards the result; here we keep it, which is the whole proposal.
Object? invokeAsRunMainWould(Function userMainFunction) => userMainFunction();

Future<String> classify(Function shape) async {
  final Object? returned;
  try {
    returned = invokeAsRunMainWould(shape);
  } on Object catch (e) {
    // A synchronous throw never yields a return value at all. This is the case a
    // lexical try/catch at the boundary catches BEFORE it can be classified
    // unhandled.
    return 'SYNC THROW at the boundary (${e.runtimeType}) — no value returned';
  }

  if (returned is! Future) {
    return 'SYNC RETURN, type ${returned.runtimeType} — completion is immediate';
  }

  var completed = false;
  Object? error;
  unawaited(
    returned.then(
      (Object? v) => completed = true,
      onError: (Object e, StackTrace _) => error = e,
    ),
  );
  await Future<void>.delayed(kWindow);

  if (error != null) {
    return 'FUTURE ERROR (${error.runtimeType}) — positive failure is observable';
  }
  if (completed) {
    return 'FUTURE COMPLETED with a value — success is observable';
  }
  return 'NO COMPLETION within ${kWindow.inMilliseconds}ms — '
      'neither success nor failure is observable yet';
}

// ---- the seven shapes -------------------------------------------------------

void s1() {
  runApp('app');
}

Future<void> s2() async {
  await Future<void>.delayed(Duration.zero);
  runApp('app');
}

Future<void> s3() async {
  await Future<void>.delayed(Duration.zero);
  throw StateError('patched main threw after an await');
}

void s4() {
  throw StateError('patched main threw before runApp');
}

/// `main` installs its own zone guard and handles its own error. The error never
/// reaches the boundary — which is correct: the app genuinely handled it.
void s5() {
  runZonedGuarded(
    () => throw StateError('handled inside the app'),
    (Object e, StackTrace s) {/* the app deals with it */},
  );
  runApp('app');
}

/// Stands for "`main` sets PlatformDispatcher.onError and returns true from it".
/// Only the RETURN SHAPE is measured here; the dispatch half is out of scope by
/// precommitment.
void s6() {
  runApp('app');
}

/// Usable, and deliberately never completes.
Future<void> s7() async {
  runApp('app');
  await Completer<void>().future;
}

Future<void> main() async {
  final shapes = <String, Function>{
    'S1 void main, runApp, returns': s1,
    'S2 async main, await then runApp': s2,
    'S3 async main, throws after await': s3,
    'S4 void main, throws before runApp': s4,
    'S5 main handles its own error in a zone': s5,
    'S6 main sets onError (return shape only)': s6,
    'S7 async main, runApp then awaits forever': s7,
  };

  print('G15 Q2 — main return shapes at the userMainFunction boundary');
  print('observation window: ${kWindow.inMilliseconds}ms\n');
  for (final entry in shapes.entries) {
    print('${entry.key.padRight(42)}  ${await classify(entry.value)}');
  }
}
