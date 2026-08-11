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

// NOTE for seam 6: there is deliberately no import of `package:dynamic_modules`
// and no `frame_bench.dart` here. The whole point of the seam-6 arm is that this
// app has no way to attach bytecode to itself, so if `routeBValue` reads NEW,
// the engine did it. Re-adding either import silently weakens the gate.
import 'package:code_push_runtime/code_push_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Bump this in a CODE patch to prove patched Dart is executing. An
/// assets-only patch must leave it alone.
const String kReleaseState = 'AIRGAP-FIXTURE-V1';

// --- Route B step 4a: the device mechanism kill gate -------------------------
//
// TEST-ONLY SCAFFOLDING. This exists to answer one question on real hardware:
// can an AOT function's body be replaced with bytecode, executed through the
// interpreter, and the ORIGINAL AOT Code restored afterwards? It is deliberately
// crude -- a payload bundled as an asset and attached in-process. It is NOT the
// delivery path: no networking, no control plane, no container discovery, no
// persistence. Delete or quarantine it once 4b exists.
//
// vm:never-inline, or the body is spliced into the caller and nothing can
// change it. vm:entry-point, because AOT drops library dictionaries and the
// attach native resolves targets by name -- a real linker works from the
// snapshot's tables and needs neither.
//
// The value routes through DateTime.now() because a literal is constant-folded
// by the type-flow analysis even under vm:never-inline: the call still runs,
// its RESULT is simply replaced at the call site, and the gate then reports a
// working mechanism as OLD. That cost a debugging detour on the host; see
// selfhost/engine/killgate/target.dart.
/// Rung A: a PUBLIC APP symbol a patch may call.
///
/// Nothing in the release calls it. It survives tree-shaking only because the
/// release's dynamic interface retains this library whole, which is exactly the
/// application-retention half rung A is meant to exercise. Its value routes
/// through DateTime.now() for the same reason every other body here does: a
/// literal is constant-folded even under vm:never-inline.
@pragma('vm:never-inline')
String routeBHelper() =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-helper' : 'X';

/// Rung B: an INSTANCE method target whose body ignores the receiver.
///
/// One ABI question and nothing else — can bytecode compiled from a synthetic
/// TOP-LEVEL function execute when attached to an instance method's `Function`,
/// where the real call carries an implicit receiver? No fields, no helper
/// calls, no arguments, no private names. Rung C is the receiver being used.
class RouteBThing {
  /// Rung C: PUBLIC receiver state. Public on purpose — private identity is
  /// library-scoped and belongs to rung D, where it would contaminate this.
  String label = 'NEW-C1';

  /// The first lowering surface: a bare instance getter. `this.label` is the
  /// same Kernel node and needs no separate fixture — but a method nothing
  /// calls is tree-shaken out of the --aot kernel before any tool sees it
  /// (rung D found that the hard way), so a second form has to be CALLED to
  /// be studied.
  ///
  /// PATCH FORM. Nobody writes `self` here — this is an ordinary bare instance
  /// getter, and the producer lowers it to
  /// `String value(RouteBThing self) => self.label;`, which is the one shape
  /// the entry-point contract accepts.
  @pragma('vm:never-inline')
  String value() => label;
}

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String routeBValue() => RouteBThing().value();

/// ONE call site, exercised before, during and after the patch. Reading the
/// same site three times is the actual claim -- that an ordinary compiled call
/// reaches the replacement -- rather than three unrelated calls happening to
/// agree.
@pragma('vm:never-inline')
String routeBProbe() => routeBValue();

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

  // Route B 4a results, accumulated so a SINGLE screenshot carries the whole
  // loop. Three separate screenshots taken over time would each be an
  // unattributable moment; one image showing baseline/attached/detached
  // together cannot be assembled from a partially-working mechanism.
  String _rbBaseline = '—';
  String _rbNote = 'running…';

  String get _assetsPatch => widget.runtime.assetsPatchNumber?.toString() ?? 'none';
  String get _codePatch => widget.runtime.patchNumber?.toString() ?? 'none';

  @override
  void initState() {
    super.initState();
    _load();
    _routeBRead();
  }

  /// SEAM 6: read the value once, as ordinary app code, and show it.
  ///
  /// There is deliberately no attach call here. If this reads NEW, the only
  /// thing that can have replaced the body is the engine's pre-main hook --
  /// the app cannot patch itself, and there is no window in which a user could
  /// observe OLD first.
  void _routeBRead() {
    final v = routeBProbe();
    if (!mounted) return;
    setState(() {
      _rbBaseline = v;
      _rbNote = 'read once in initState; no Dart-side attach';
    });
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
          const SizedBox(height: 8),
          _row('route B value', _rbBaseline),
          _row('route B note', _rbNote),
          _row('code patch', _codePatch),
        ],
      ),
    ),
  );
}
