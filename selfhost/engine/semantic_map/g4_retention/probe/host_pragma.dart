// SM1-G4 CONFOUND DEMONSTRATOR -- host.dart plus vm:entry-point on the subject.
//
// NO RETAINING PRAGMA APPEARS IN THIS FILE, AND THAT IS THE POINT.
//
// `@pragma('vm:entry-point')` retains a symbol INDEPENDENTLY of the dynamic
// interface. SL1-G6A's `missing_retained_import` control passed while measuring
// nothing for exactly that reason. Worse, the two mechanisms are
// indistinguishable downstream: `dynamic_interface_annotator.dart` lowers
// di.yaml's `callable:` list into `@pragma('dyn-module:callable')`, and
// `pkg/vm/lib/transformations/pragma.dart` routes that pragma through the SAME
// `getEntryPointTypeFromOptions` handler as `vm:entry-point` (cases at lines
// 184 and 253). Both produce a `ParsedEntryPointPragma`.
//
// So a subject carrying `vm:entry-point` would be retained whatever the
// contract said, and every withheld-retention arm below would pass while
// measuring the pragma. `lib/assert_no_retaining_pragma.sh` asserts their
// absence before any arm here is trusted.
//
// ignore_for_file: implementation_imports
// NO INSTRUMENT. SL1 measured execution mode with `functionExecutionMode`, but
// that is a BANKED PATCH applied only to the SL1 lane build -- the frozen map
// lineage's `dart:_internal` does not export it, and adding an instrument is
// outside this gate's boundary. Retention is therefore measured BEHAVIOURALLY,
// through the mechanisms the frozen lineage actually ships.
import 'dart:_internal' show loadDynamicModule;
import 'dart:io';
import 'dart:typed_data';

/// THE PATCHABLE DECLARATION under test. Retention of its dispatch point is
/// what the contract is supposed to buy.
class Target {
  // CONFOUND DEMONSTRATOR ONLY. Identical to host.dart except for the single
  // annotation below. It exists to prove that a subject carrying
  // vm:entry-point is retained whatever the dynamic interface says, so a
  // withheld-contract arm measured on it would be vacuous. It is never used to
  // score a retention result.
  @pragma('vm:entry-point')
  Target();

  @pragma('vm:never-inline')
  String work() => 'AOT-TARGET';
}

@pragma('vm:never-inline')
String callWork(Target t) => t.work();

Future<void> main(List<String> args) async {
  final modulePath = args.isNotEmpty ? args[0] : null;

  // THE CONTROL RUNS FIRST AND UNCONDITIONALLY. If the host cannot dispatch to
  // its own implementation, nothing below is attributable to the contract.
  print('CONTROL callWork(Target()) = ${callWork(Target())}');

  if (modulePath == null) {
    print('CONTROL_ONLY');
    return;
  }

  try {
    final bytes = Uint8List.fromList(File(modulePath).readAsBytesSync());
    final patched = await loadDynamicModule(bytes: bytes) as Target;
    final observed = callWork(patched);
    print('SUBJECT callWork(PatchTarget()) = $observed');
    // A host implementation that answers here is a BYPASS, not a pass: the
    // module loaded and the dispatch point still went to the AOT body.
    print(observed == 'PATCH-TARGET' ? 'DISPATCH_OK' : 'DISPATCH_BYPASS');
  } catch (e) {
    // The category is decided by the harness from this text plus the exit
    // path, never by the harness guessing.
    print('LOAD_THREW ${e.runtimeType}: $e');
    exitCode = 5;
  }
  print('DONE');
}
