// P6's custom-target arm (Arm B). A SECOND entry point, reached only by
// `--target lib/main_b.dart`.
//
// WHY THIS IS A SEPARATE FILE AND NOT A FLAG IN main.dart. The workflow under
// certification is "release and patch an app whose entry point is not
// lib/main.dart". A flag inside the default entry would exercise none of it:
// the thing that must be shown to work is that the non-default entry is what
// the release and the patch were both compiled from, and that Route B's
// replacement still lands.
//
// WHY IT IS SELF-CONTAINED. If this file imported main.dart and reused its
// widget, then the UI on the device would be main.dart's UI and could not tell
// me which `main()` ran. Rendering its OWN screen makes the entry point
// directly observable: the layout below exists nowhere else in the fixture.
//
// THE THREE OBSERVABLES, fixed here before the release is cut:
//
//   entry          TARGET-B                CONTROL. A const in this library.
//                  Its presence means this program was built from THIS entry;
//                  main.dart does not import this file, so a default-target
//                  build cannot show it at all. Must not change.
//   release        CT-RELEASE-1            CONTROL. Must not change, which is
//                  what separates "the patch executed" from "the device
//                  quietly picked up a different release".
//   custom target  CUSTOM-TARGET-V1        THE TARGET. A patch to
//                  `customTargetState()` must make this read V2.
//
// The armor on `customTargetState` is copied from `flavorState` in main.dart
// for the reasons documented there at length, not by habit:
//   * `DateTime.now()` guard so the RESULT cannot be constant-folded into the
//     call site -- a folded result would read V1 forever and look like a failed
//     patch, or read V2 and prove nothing about the body.
//   * `vm:never-inline`, so the body the patch replaces is the body that runs.
//   * `vm:entry-point`, so the dynamic interface can name it.
//   * called from `initState` on the live path, because retention is not
//     reachability: a member kept alive by a dead branch is patchable and never
//     executes.
// Both branches return a V1 string, so the marker is observable in `strings`
// whichever branch the compiler keeps.

import 'package:flutter/material.dart';

/// CONTROL. Proves the program came from this entry point.
const String kEntryMarker = 'TARGET-B';

/// CONTROL. Proves the device is still running the release under test.
const String kReleaseMarkerB = 'CT-RELEASE-1';

/// THE PATCH TARGET for the custom-target arm.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String customTargetState() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'CUSTOM-TARGET-V2'
    : 'CUSTOM-TARGET-V2!';

void main() => runApp(const CustomTargetProbeApp());

class CustomTargetProbeApp extends StatelessWidget {
  const CustomTargetProbeApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    title: 'custom target probe',
    home: Scaffold(body: _ProbeB()),
  );
}

class _ProbeB extends StatefulWidget {
  const _ProbeB();

  @override
  State<_ProbeB> createState() => _ProbeBState();
}

class _ProbeBState extends State<_ProbeB> {
  String _target = '—';

  @override
  void initState() {
    super.initState();
    _readTarget();
  }

  /// Ordinary app code, with no attach call: if this reads V2, the only thing
  /// that can have replaced the body is the engine's pre-main hook.
  void _readTarget() {
    final v = customTargetState();
    if (!mounted) return;
    setState(() => _target = v);
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      children: [
        Text('$label:', style: const TextStyle(fontSize: 14)),
        Text(
          value,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _row('entry', kEntryMarker),
          _row('release', kReleaseMarkerB),
          _row('custom target', _target),
        ],
      ),
    ),
  );
}
