// SL1-G1 substrate probe. Asks ONLY whether the two builds behave as a matched
// control/experiment pair, and reports each native's outcome separately because
// the frozen source gives them DIFFERENT off-path behaviour: attach refuses by
// returning false, while load and detach throw UnsupportedError.
//
// Every line it prints is a fact about one native. Nothing here is evidence
// about patching applications; that is G2 onward.
//
// ignore_for_file: implementation_imports
import 'dart:_internal' show attachBytecodeToFunction;
import 'dart:io';
import 'dart:typed_data';

/// The dynamic-module loader, bound the way dynmod/host.dart binds it, so the
/// probe can measure its off-path behaviour without importing a private library
/// member that does not exist in an OFF build.
@pragma("vm:external-name", "Internal_loadDynamicModule")
external Object? _loadDynamicModule(Uint8List bytes);

/// The function whose body a module replaces. never-inline is not decoration:
/// without it AOT inlines the callee into main and the probe would report a
/// failure that has nothing to do with the substrate.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String target() => 'OLD';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String hostSuffix() => 'HOST';

void main(List<String> args) {
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

  // 4. LOAD. Throws UnsupportedError when built without dynamic modules.
  try {
    final r = _loadDynamicModule(bytes);
    print('LOAD: returned=$r');
  } on Object catch (e) {
    print('LOAD: threw=${e.runtimeType}: $e');
  }
}
