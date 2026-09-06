// SL1-G1 substrate probe. Asks ONLY whether the two builds behave as a matched
// control/experiment pair, and reports each native's outcome separately because
// the frozen source gives them DIFFERENT off-path behaviour: attach refuses by
// returning false, while load and detach throw UnsupportedError.
//
// Every line it prints is a fact about one native. Nothing here is evidence
// about patching applications; that is G2 onward.
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show attachBytecodeToFunction, loadDynamicModule;
import 'dart:io';
import 'dart:typed_data';

// WHY loadDynamicModule IS IMPORTED, NOT BOUND BY NAME. The first cut of this
// probe copied dynmod/host.dart and bound the native directly with
// @pragma("vm:external-name", "Internal_loadDynamicModule"). It aborted the OFF
// arm at native_entry.cc:253, "Failed to resolve native function" -- because
// VM-internal natives resolve by name only for `dart:` libraries, which is the
// dynmod lane's own documented finding.
//
// That measured the user-library binding restriction, not the substrate, and it
// would have failed IDENTICALLY on the ON arm -- so the comparison would have
// been worthless in both directions. dynmod needed that workaround because it
// ran on a stock SDK; this frozen lineage exposes loadDynamicModule on
// dart:_internal (sdk/lib/internal/internal.dart), and the `dynamic_modules`
// package name is upstream's own allowance for importing it.

/// The function whose body a module replaces. never-inline is not decoration:
/// without it AOT inlines the callee into main and the probe would report a
/// failure that has nothing to do with the substrate.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String target() => 'OLD';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String hostSuffix() => 'HOST';

Future<void> main(List<String> args) async {
  // 1. NORMAL AOT. Both arms must pass this; a build that cannot run its own
  //    AOT output is broken independently of the question being asked.
  print('AOT: target()=${target()} hostSuffix()=${hostSuffix()}');

  if (args.isEmpty) {
    print('PROBE: no module supplied; normal-AOT check only');
    return;
  }
  final bytes = Uint8List.fromList(File(args[0]).readAsBytesSync());
  final libraryUri = args[1];

  // 2. ATTACH. Refuses by RETURN VALUE when built without dynamic modules.
  try {
    final ok = attachBytecodeToFunction(bytes, libraryUri, 'target');
    print('ATTACH: returned=$ok');
  } on Object catch (e) {
    print('ATTACH: threw=${e.runtimeType}: $e');
  }

  // 3. The Dart-side call. EXPECTED to stay OLD on both arms -- AOT binds these
  //    sites statically (the 2026-08-04 call-emission gap). Printed so a future
  //    change in that answer is visible rather than assumed.
  print('DART-CALL: target()=${target()}');

  // 4. LOAD. Throws UnsupportedError when built without dynamic modules --
  //    a DIFFERENT off-path from attach, which refuses by return value. Both
  //    are recorded separately because conflating them would hide one.
  try {
    final r = await loadDynamicModule(bytes: bytes);
    print('LOAD: returned=$r');
  } on Object catch (e) {
    print('LOAD: threw=${e.runtimeType}: $e');
  }
}
