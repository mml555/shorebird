// Arm C's fixture: boot-time patch signature verification under Strict.
//
// Dedicated on purpose. The Tracks/Flavored Probe fixture carries four certified
// rows and its own updater state; this arm needs an independent bundle id, an
// independent control-plane app, and `patch_verification: strict`, so it gets a
// fixture of its own rather than an edit to evidence that is already banked.
//
// THE THREE OBSERVABLES, fixed before the release is cut:
//
//   release      SIGN-REL-1   CONTROL. Must never change. Separates "a patch
//                executed" from "the device picked up a different release".
//   sign state   SIGN-V1      THE TARGET. Patch 1 (signed by K1) must make this
//                read SIGN-V2. Patch 2 (signed by K2) must NEVER make it read
//                SIGN-V3.
//
// The armor on `signState` is the pattern the flavor, custom-target, obfuscation
// and tracks arms all used, for the documented reasons: a `DateTime.now()` guard
// so the RESULT cannot be folded into the call site, `vm:never-inline` so the
// body the patch replaces is the body that runs, `vm:entry-point` so the dynamic
// interface can name it, and a call from `initState` on the live path because
// retention is not reachability.

import 'package:flutter/material.dart';

/// CONTROL. Proves the device is still running the release under test.
const String kSignRelease = 'SIGN-REL-1';

/// THE PATCH TARGET.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String signState() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'SIGN-V3'
    : 'SIGN-V3!';

void main() => runApp(const SignProbeApp());

class SignProbeApp extends StatelessWidget {
  const SignProbeApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    title: 'sign probe',
    home: Scaffold(body: _Probe()),
  );
}

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  String _state = '—';

  @override
  void initState() {
    super.initState();
    // Ordinary app code, no attach call: if this reads V2, the only thing that
    // can have replaced the body is the engine's pre-main hook.
    _state = signState();
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
          _row('release', kSignRelease),
          _row('sign state', _state),
        ],
      ),
    ),
  );
}
