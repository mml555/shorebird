// The flavored fixture's app. Its single job is to make the flavor that
// reached the COMPILER observable in the shipped binary and on the screen.
//
// What this file is NOT: a copy of airgap_app/lib/main.dart. That one carries
// the Route B target zoo (receiver calls, private members, a parameterised
// target, a private class) because it is the canonical mechanism fixture. This
// one carries exactly one target, because the claim under test is
// configuration, not mechanism.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Which BUILD of this fixture is running, independent of the flavor.
///
/// A patch flips this to `FLAVORED-FIXTURE-V2`, so "the patch ran" and "the
/// flavor arrived" are two separate readings that cannot be confused for one
/// another — the failure this separation prevents is a matching-flavor arm
/// passing because the release itself already said what the patch would say.
const String kReleaseState = 'FLAVORED-FIXTURE-V1';

/// THE OBSERVABLE. `appFlavor` is `String.fromEnvironment('FLUTTER_APP_FLAVOR')`
/// (`flutter/lib/src/services/flavor.dart:9-11` at the pin), which is the exact
/// define `--flavor` reduces to — so reading it here reads what the compiler
/// was given, not what the command line said.
///
/// Three properties, each of which has already cost this project a run:
///
///   * `DateTime.now()` guard — NOT decoration. A body returning one constant
///     has its RESULT replaced at the call site with the release's own value
///     (`ldr x0, [x0, #0x488]`), so a patch that attached perfectly cannot
///     show. `probes/assert_result_consumed.sh:6-30` records six device runs
///     lost to exactly that, and `vm:never-inline` does not prevent it: it
///     stops the BODY being spliced in, not the RESULT being folded.
///   * called from `initState`, on the path the app actually takes — NOT parked
///     in a dead branch the way `RouteBThing.tagged` is
///     (`airgap_app/lib/main.dart:124`, called only at `:179`). A dead branch
///     keeps a method RETAINED past the kernel prepass, and retention is not
///     reachability: `assert_result_consumed.sh` still reports such a site
///     CONSUMED, correctly, because its result feeds a string interpolation,
///     and a patch to it would still execute never. Consumption is necessary
///     and not sufficient.
///   * `vm:entry-point`, so the dynamic interface can name it.
///
/// Both branches return a flavor-bearing string so the flavor is observable in
/// `strings` whichever branch the compiler keeps.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String flavorState() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'V2/${appFlavor ?? "none"}'
    : 'V2/${appFlavor ?? "none"}!';

void main() => runApp(const FlavoredProbeApp());

class FlavoredProbeApp extends StatelessWidget {
  const FlavoredProbeApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    title: 'flavored probe',
    home: Scaffold(body: _Probe()),
  );
}

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  String _flavorState = '—';
  String _asset = '—';

  @override
  void initState() {
    super.initState();
    // Synchronous FIRST, for the reason airgap_app/lib/main.dart:300-306
    // records: the beacon is built after an await, and a value that depends on
    // when that await resumes makes a harness flaky rather than wrong.
    _readFlavor();
    _load();
  }

  /// Read the observable once, as ordinary app code, and show it.
  ///
  /// There is deliberately no attach call here: if this reads V2 the only thing
  /// that can have replaced the body is the engine's pre-main hook.
  void _readFlavor() {
    final v = flavorState();
    if (!mounted) return;
    setState(() => _flavorState = v);
  }

  Future<void> _load() async {
    String asset;
    try {
      final raw = await rootBundle.loadString('assets/probe.json');
      asset = (jsonDecode(raw) as Map<String, dynamic>)['origin'].toString();
    } on Object catch (e) {
      asset = 'ERROR: $e';
    }
    if (mounted) setState(() => _asset = asset);
    await _beacon(asset);
  }

  /// Report the rendered state so a harness can ASSERT on it rather than parse
  /// pixels.
  ///
  /// ⚠ BEACON-ONLY DOES NOT WORK ON THIS RIG, measured 2026-08-13 and recorded
  /// at `airgap_app/lib/main.dart:278-286`: `cps-ios` logs the beacon as
  /// `GET /selfhost-beacon/state -> 403` with NO QUERY STRING, so a value
  /// carried only in the query is unobservable, and `read_beacon` in
  /// `airgap_acceptance.sh` greps for `state?...`, which that line never
  /// matches. **That is why `flavor state` is also a displayed row** — the
  /// screenshot is the readable evidence until the log carries the query.
  /// The beacon is kept because the query string is the right mechanism the
  /// moment it does.
  ///
  /// Failures are swallowed: a beacon that cannot send must never change what
  /// the app displays.
  Future<void> _beacon(String asset) async {
    try {
      final yaml = await rootBundle.loadString('shorebird.yaml');
      final m = RegExp(r'^base_url:\s*(\S+)', multiLine: true).firstMatch(yaml);
      if (m == null) return;
      final uri = Uri.parse('${m.group(1)}/selfhost-beacon/state').replace(
        queryParameters: {
          'release': kReleaseState,
          'asset': asset,
          'flavor_state': _flavorState,
        },
      );
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final resp = await (await client.getUrl(uri)).close();
      await resp.drain<void>();
      client.close();
    } on Object {
      // Intentionally ignored — see above.
    }
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      children: [
        Text('$label:', style: const TextStyle(fontSize: 14)),
        Text(
          value,
          textAlign: TextAlign.center,
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
          _row('release', kReleaseState),
          // The row the device arms are read off. See _beacon's warning.
          _row('flavor state', _flavorState),
          _row('asset', _asset),
        ],
      ),
    ),
  );
}
