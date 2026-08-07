// Canonical air-gap acceptance fixture.
//
// Renders — and BEACONS — the four facts the acceptance run asserts:
//
//   release      a constant compiled into the release. A CODE patch changes
//                it; an assets-only patch must NOT.
//   asset        assets/probe.json read through the runtime's asset bundle.
//                An assets-only patch DOES change it.
//   assets_patch the patch whose assets are being served, or none.
//   code_patch   the running code patch, or none.
//
// Keeping those last two apart is the whole point. An assets-only patch is
// deliberately never offered to the native updater, so anything reading only
// the updater's patch number sees "no patch" and cannot tell a working asset
// overlay from a broken one. code_push_runtime does its own discovery and
// reports the two separately — hence this fixture depends on it rather than on
// shorebird_code_push.
//
// The beacon is a plain GET whose QUERY STRING carries the state. The control
// plane logs every request line, so a 404 there is a success: no server-side
// endpoint is needed, and the harness asserts on the log instead of parsing
// pixels. Screenshots stay as human-readable evidence, never the mechanism.
import 'dart:convert';
import 'dart:io';

import 'package:code_push_runtime/code_push_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Bump this in a CODE patch to prove patched Dart is executing. An
/// assets-only patch must leave it alone.
const String kReleaseState = 'AIRGAP-FIXTURE-V1';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final runtime = await CodePushRuntime.initialize(
    readReleaseVersion: () async => const String.fromEnvironment(
      'FIXTURE_RELEASE_VERSION',
      defaultValue: '1.0.0+1',
    ),
  );
  runApp(ProbeApp(runtime: runtime));
}

class ProbeApp extends StatelessWidget {
  const ProbeApp({required this.runtime, super.key});

  final CodePushRuntime runtime;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(body: SafeArea(child: ProbeBody(runtime: runtime))),
  );
}

class ProbeBody extends StatefulWidget {
  const ProbeBody({required this.runtime, super.key});

  final CodePushRuntime runtime;

  @override
  State<ProbeBody> createState() => _ProbeBodyState();
}

class _ProbeBodyState extends State<ProbeBody> {
  String _asset = 'reading…';

  String get _assetsPatch => widget.runtime.assetsPatchNumber?.toString() ?? 'none';
  String get _codePatch => widget.runtime.patchNumber?.toString() ?? 'none';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String asset;
    try {
      // Through the RUNTIME's bundle, not rootBundle — that is what serves the
      // patch's assets when one is active.
      final raw = await widget.runtime.assetBundle.loadString('assets/probe.json');
      asset = (jsonDecode(raw) as Map<String, dynamic>)['origin'].toString();
    } on Object catch (e) {
      asset = 'ERROR: $e';
    }
    if (mounted) setState(() => _asset = asset);
    await _beacon(asset);
  }

  /// Report the rendered state so the harness can ASSERT on it.
  ///
  /// base_url comes from the bundled shorebird.yaml — the same address the
  /// updater uses — so the beacon cannot drift from the control plane under
  /// test. Failures are swallowed: a beacon that cannot send must never change
  /// what the app displays, because the screenshot is the fallback evidence.
  Future<void> _beacon(String asset) async {
    try {
      final yaml = await rootBundle.loadString('shorebird.yaml');
      final m = RegExp(r'^base_url:\s*(\S+)', multiLine: true).firstMatch(yaml);
      if (m == null) return;
      final uri = Uri.parse('${m.group(1)}/selfhost-beacon/state').replace(
        queryParameters: {
          'release': kReleaseState,
          'asset': asset,
          'assets_patch': _assetsPatch,
          'code_patch': _codePatch,
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
        Text(value,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
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
          _row('asset', _asset),
          _row('assets patch', _assetsPatch),
          _row('code patch', _codePatch),
        ],
      ),
    ),
  );
}
