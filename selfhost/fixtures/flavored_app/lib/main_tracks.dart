// P6's tracks arm. A third entry point, reached only by
// `--target lib/main_tracks.dart`.
//
// WHY A SEPARATE ENTRY AGAIN. Same reason as `main_b.dart`: the screen must say
// which program is running. This one adds a second job — it must say which
// CLIENT is running, because the whole arm turns on two clients that differ in
// exactly one configured value.
//
// THE FOUR OBSERVABLES, fixed before the release is cut:
//
//   channel        alpha or beta            CONTROL/identity. This IS the client
//                  identity: it is the only value that differs between the two
//                  installs, and it is the value the routing decision is made
//                  on. Read from the
//                  shorebird.yaml BUNDLED IN THIS APP -- the same file the
//                  native updater reads to decide which channel to request. So
//                  the screen shows the client's real track configuration
//                  rather than a copy of it that could disagree.
//   release        TRACKS-REL-1             CONTROL. Must never change; it is
//                  what separates "the patch executed" from "this client picked
//                  up a different release".
//   track state    TRACK-V1                 THE TARGET. A patch to
//                  `trackState()` must make this read V2 -- on the client whose
//                  channel the patch is deployed to, and ONLY that one.
//
// The armor on `trackState` is the same as `flavorState`/`customTargetState`,
// and for the documented reasons rather than by habit: a `DateTime.now()` guard
// so the RESULT cannot be folded into the call site, `vm:never-inline` so the
// replaced body is the body that runs, `vm:entry-point` so the dynamic
// interface can name it, and a call from `initState` on the live path because
// retention is not reachability.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// CONTROL. Proves this client is still running the release under test.
const String kTracksRelease = 'TRACKS-REL-1';

/// THE PATCH TARGET for the tracks arm.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String trackState() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'TRACK-V2'
    : 'TRACK-V2!';

void main() => runApp(const TracksProbeApp());

class TracksProbeApp extends StatelessWidget {
  const TracksProbeApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    title: 'tracks probe',
    home: Scaffold(body: _ProbeT()),
  );
}

class _ProbeT extends StatefulWidget {
  const _ProbeT();

  @override
  State<_ProbeT> createState() => _ProbeTState();
}

class _ProbeTState extends State<_ProbeT> {
  String _track = '—';
  String _channel = '…';

  @override
  void initState() {
    super.initState();
    // Synchronous first, for the reason main.dart records: a value that depends
    // on when an await resumes makes a harness flaky rather than wrong.
    _readTrack();
    _readChannel();
  }

  /// Ordinary app code, no attach call: if this reads V2, the only thing that
  /// can have replaced the body is the engine's pre-main hook.
  void _readTrack() {
    final v = trackState();
    if (!mounted) return;
    setState(() => _track = v);
  }

  /// The channel this client is configured to request, read from the SAME
  /// bundled `shorebird.yaml` the native updater reads.
  ///
  /// Deliberately not a compile-time value: the two clients are one build with
  /// two different bundled yamls, so this is the only place the difference
  /// exists inside the app.
  Future<void> _readChannel() async {
    String v;
    try {
      final raw = await rootBundle.loadString('shorebird.yaml');
      final line = raw
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.startsWith('channel:'), orElse: () => '');
      v = line.isEmpty
          ? 'ABSENT->stable'
          : line.substring('channel:'.length).trim();
    } on Object catch (e) {
      v = 'ERROR: $e';
    }
    if (!mounted) return;
    setState(() => _channel = v);
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      children: [
        Text('$label:', style: const TextStyle(fontSize: 13)),
        Text(
          value,
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _row('channel', _channel),
          _row('release', kTracksRelease),
          _row('track state', _track),
        ],
      ),
    ),
  );
}
