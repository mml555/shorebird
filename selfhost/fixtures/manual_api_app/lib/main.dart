// manual_api_app — the manual updater API's fixture.
//
// Drives updates from DART rather than letting the runtime apply them:
// `checkForUpdate(track:)` and `update(track:)` from
// `package:shorebird_code_push`, with `auto_update: false` in shorebird.yaml.
//
// WHY A PATCH NUMBER ON SCREEN IS NOT THE EVIDENCE. `readCurrentPatch` is
// exercised by every airgap release, so a number appearing proves nothing about
// these two calls. What this fixture is built to show instead:
//
//   * nothing downloads until a button is pressed (that is `auto_update: false`
//     working, and it is an ENGINE property with no Dart introspection -- so it
//     is proven behaviourally, by the absence of a download, not by asking);
//   * `checkForUpdate` reports availability WITHOUT downloading -- `next patch`
//     must stay `none` across a check that says `outdated`;
//   * `update(track:)` honours ITS OWN track argument. The load-bearing case:
//     check `beta` (which says outdated), then call `update(stable)`. If that
//     downloads beta's patch, the call is consuming cached eligibility from the
//     preceding check rather than respecting its argument.
//
// Hence four buttons, each naming its track explicitly, and no shared "last
// checked track" state anywhere in this file -- if the fixture remembered the
// track, it could supply the very leak the arm is trying to detect.
//
// `initState` is deliberately READ-ONLY: `readCurrentPatch`/`readNextPatch`
// only inspect updater state. No check, no update, no orchestration -- Phase 0
// asks whether anything downloads when the user does nothing.

import 'package:flutter/material.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

/// Bumped by the patch, so "the patch's CODE ran" is a separate reading from
/// "a patch number appeared".
///
/// A FUNCTION, not a `const`. The first attempt at this arm used
/// `const marker = 'MANUAL-V1'` and the producer correctly refused the patch —
/// *"Nothing in this patch differs from the release, so it would install and
/// change nothing"* — because a changed const DECLARATION is invisible to the
/// coverage analyzer, which compares procedure bodies. That is the same
/// constant blindness the defines arm hit, and this is its second recorded
/// instance.
///
/// The armor is the pattern the flavor, custom-target and obfuscation arms all
/// used, and each piece earns its place: a `DateTime.now()` guard so the RESULT
/// cannot be folded into the call site, `vm:never-inline` so the body the patch
/// replaces is the body that runs, `vm:entry-point` so the dynamic interface can
/// name it, and a call from `initState` on the live path because retention is not
/// reachability. Both branches carry the marker so it is observable in `strings`
/// whichever one the compiler keeps.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String markerText() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'MANUAL-V2'
    : 'MANUAL-V2!';

/// The non-default track under test. A custom value is used rather than
/// `UpdateTrack.beta` only where the API needs it; here beta is a real track on
/// the control plane, so the enum's own value is correct.
const betaTrack = UpdateTrack.beta;
const stableTrack = UpdateTrack.stable;

void main() => runApp(const ManualApiApp());

class ManualApiApp extends StatefulWidget {
  const ManualApiApp({super.key});

  @override
  State<ManualApiApp> createState() => _ManualApiAppState();
}

class _ManualApiAppState extends State<ManualApiApp> {
  final _updater = ShorebirdUpdater();

  String _marker = '…';
  String _current = '?';
  String _next = '?';
  String _status = 'idle — nothing pressed';

  @override
  void initState() {
    super.initState();
    // Synchronous first, and read as ordinary app code with no attach call: if
    // this reads V2, the only thing that can have replaced the body is the
    // engine's pre-main hook.
    _marker = markerText();
    _refresh();
  }

  /// Reads updater state only. Called at startup and after every action so the
  /// two patch rows always reflect what the updater actually holds.
  Future<void> _refresh() async {
    try {
      final cur = await _updater.readCurrentPatch();
      final nxt = await _updater.readNextPatch();
      if (!mounted) return;
      setState(() {
        _current = cur?.number.toString() ?? 'none';
        _next = nxt?.number.toString() ?? 'none';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _current = 'read error';
        _next = 'read error';
        _status = 'readCurrentPatch/readNextPatch threw: $e';
      });
    }
  }

  /// `checkForUpdate` on exactly the track named by the button.
  Future<void> _check(UpdateTrack track, String label) async {
    setState(() => _status = 'checking $label…');
    try {
      final s = await _updater.checkForUpdate(track: track);
      if (!mounted) return;
      setState(() => _status = 'check($label) -> $s');
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _status = 'check($label) threw: $e');
    }
    await _refresh();
  }

  /// `update` on exactly the track named by the button.
  ///
  /// The track is taken from the argument and never from remembered state, so
  /// `update(stable)` after `check(beta)` genuinely tests whether the call
  /// respects its own argument.
  Future<void> _update(UpdateTrack track, String label) async {
    setState(() => _status = 'updating $label…');
    try {
      await _updater.update(track: track);
      if (!mounted) return;
      setState(() => _status = 'update($label) returned normally');
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() => _status = 'update($label) UpdateException: ${e.reason} — ${e.message}');
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _status = 'update($label) threw: $e');
    }
    await _refresh();
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('$label:', style: const TextStyle(fontSize: 14)),
        Text(value, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'manual api probe',
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_marker, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 18),
              _row('current patch', _current),
              _row('next patch', _next),
              const SizedBox(height: 10),
              const Text('last check status', style: TextStyle(fontSize: 13)),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(border: Border.all(color: Colors.black26)),
                child: Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () => _check(stableTrack, 'stable'),
                    child: const Text('Check stable'),
                  ),
                  ElevatedButton(
                    onPressed: () => _check(betaTrack, 'beta'),
                    child: const Text('Check beta'),
                  ),
                  ElevatedButton(
                    onPressed: () => _update(stableTrack, 'stable'),
                    child: const Text('Update stable'),
                  ),
                  ElevatedButton(
                    onPressed: () => _update(betaTrack, 'beta'),
                    child: const Text('Update beta'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
