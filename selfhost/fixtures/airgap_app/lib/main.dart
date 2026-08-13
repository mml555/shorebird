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

  /// The WRITE target, separate from `label` so a write arm cannot be confused
  /// with a read arm. Its release value is what the app shows if the assignment
  /// silently does nothing, so a broken write reads as `UNSET` rather than
  /// passing by accident.
  String slot = 'UNSET';

  /// RUNG D ON DEVICE: private receiver state, and the release NEVER READS IT.
  ///
  /// That absence is the test. Its retention cannot come from use, because
  /// nothing uses it — the release keeps it only because retention enumerated
  /// private members from the NON-AOT kernel (`--private-dill`) under policy
  /// P2 and named it in the interface. The `--aot` prepass has already
  /// tree-shaken it away, so a release that enumerated from the prepass alone
  /// would ship with nothing here for a patch to reach.
  ///
  /// So a patch reading this proves the whole G3.6b path on hardware: P2
  /// enumeration retained it, the manifest recorded the grant, the producer
  /// accepted the reference against that manifest, and the CFE resolved the
  /// private name in this library. If any link failed, the CLI would refuse
  /// the patch before publication rather than ship something that binds to
  /// nothing.
  ///
  /// ignore: unused_field — see above; being unused IS the condition under
  /// test, and referencing it to satisfy the lint would destroy the test.
  // ignore: unused_field
  String _secret = 'NEW-PRIV';

  /// The call form's target. Routed through DateTime.now() so it is not
  /// constant-folded into whoever calls it.
  ///
  /// The RELEASE form of `value()` names it in a branch that never runs, which
  /// is how it is retained: retention is declared from a kernel prepass, and a
  /// method nothing calls is tree-shaken out of that kernel before the
  /// interface is generated (rung D found this the hard way) — so the release
  /// would ship with nothing for `self.helper()` to reach.
  @pragma('vm:never-inline')
  String helper() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-C2' : 'X';

  /// The argument-bearing target. Its parameter survives compilation because
  /// the release declares a dynamic interface retaining this library; without
  /// one, `--aot` would eliminate a parameter only ever passed a constant, and
  /// an interpreted `self.tagged('ARG')` would then meet a compiled method
  /// taking none.
  @pragma('vm:never-inline')
  String tagged(String x) =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-$x' : 'X';

  /// The lowering surface. Two forms have been through the whole path:
  ///
  ///   String value() => label;      ->  value(RouteBThing self) => self.label
  ///   String value() => helper();   ->  value(RouteBThing self) => self.helper()
  ///
  /// `this.label` and `this.helper()` are the same Kernel nodes as the bare
  /// spellings and differ only in the lexical edit; the host probe covers them.
  ///
  /// THE COMMITTED BODY IS THE **RELEASE** FORM, AND IT MUST NOT BE FOLDABLE.
  ///
  /// A patch body is a TRANSIENT edit to this line: you change it, cut the
  /// patch, and the release form belongs back here. Whatever is here when a
  /// RELEASE is cut decides whether any patch can ever be observed — because if
  /// this body's result is a compile-time constant, the type-flow analysis
  /// substitutes that constant AT THE CALL SITE in `routeBValue()`. The call is
  /// still emitted and still runs, Route B's dispatch still works, and the
  /// returned value is dead before anything can read it:
  ///
  ///     blr  x30                       ; the patched Function really is called
  ///     add  x0, x27, #0xd, lsl #12    ; and its answer is overwritten here
  ///     ldr  x0, [x0, #0x488]          ; with the release's own constant
  ///
  /// `vm:never-inline` does NOT prevent this. It stops the body being spliced
  /// into the caller; it does not stop the RESULT being replaced.
  ///
  /// THIS HAS NOW COST TWO INVESTIGATIONS. `selfhost/engine/killgate/target.dart`
  /// recorded it on 2026-08-09. It recurred here on 2026-08-11 when the release
  /// form became `=> slot = 'NEW-SET'` — one constant — and releases 25 through
  /// 30 then spent six device runs and five overturned causal attributions on a
  /// patch that attached perfectly and could not possibly show. The comments
  /// above were already warning about it; comments were not enough, so the
  /// invariant now has a detector:
  ///
  ///     probes/assert_result_consumed.sh <App> --fixture-signature
  ///
  /// Run it on the release binary BEFORE interpreting any device result.
  ///
  /// The dead branch is not decoration either: it NAMES `helper` and `tagged` so
  /// they survive the kernel prepass the dynamic interface is generated from. A
  /// method nothing calls is tree-shaken before the interface can name it, and a
  /// patch body calling `self.helper()` would then bind to nothing (rung D found
  /// that the hard way). The `DateTime.now()` guard is what keeps both branches
  /// alive: it is opaque to the analysis, so neither the fold nor the shaking
  /// happens.
  ///
  /// PATCH FORM, for reference — a receiver-bound WRITE. The producer lowers only
  /// the receiver — `slot` becomes `self.slot` — and `= 'NEW-SET'` crosses over
  /// as the source's own text. The value shown is the assignment's own result, so
  /// an assignment that silently did nothing would read `UNSET`, not `NEW-SET`.
  @pragma('vm:never-inline')
  String value() => DateTime.now().millisecondsSinceEpoch >= 0
      ? 'OLD-rel'
      : '${helper()}${tagged('ARG')}$label';
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

  /// G3.6c + G3.6d DEVICE GATE: a method on a PRIVATE CLASS.
  ///
  /// This class is private and extends Flutter's `State`, which is the shape that
  /// makes privacy the measured blocker rather than an academic one — `State`
  /// subclasses are private by convention, so a patch that cannot reach a private
  /// class cannot reach most real Flutter code.
  ///
  /// Two walls have to be down at once for a patch here to run: the producer must
  /// lower the receiver as `dynamic self` because the class name is not resolvable
  /// (`G3.6c`), and the release's dynamic interface must carry a `class:` item so
  /// the private class and its members survive `PruneDictionaries` (`G3.6d`). The
  /// host probe fails when the `class:` items are stripped, so this is a real
  /// conjunction and not one feature counted twice.
  ///
  /// Non-foldable for the same reason as every other target in this file: a body
  /// returning one constant has its RESULT replaced at the call site and the gate
  /// then reports a working mechanism as OLD. See `RouteBThing.value`.
  @pragma('vm:never-inline')
  String privateClassValue() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-pc' : 'X';

  // Route B 4a results, accumulated so a SINGLE screenshot carries the whole
  // loop. Three separate screenshots taken over time would each be an
  // unattributable moment; one image showing baseline/attached/detached
  // together cannot be assembled from a partially-working mechanism.
  String _rbBaseline = '—';
  String _rbNote = 'running…';

  /// The private-class target's value, stored so the call's RESULT is consumed by
  /// something observable. A displayed field is the cheapest consumer there is.
  String _rbPrivateClass = '—';

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
    // The private-class read, at the same moment and through the same kind of
    // ordinary call. `privateClassValue()` is an instance method on THIS private
    // class, so the call site is a patchable instance call and the value below is
    // whatever the Function's entry point produced.
    final pc = privateClassValue();
    if (!mounted) return;
    setState(() {
      _rbBaseline = v;
      _rbPrivateClass = pc;
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

  // vertical: 5 rather than 8 — the seventh row (the private-class target) has to
  // fit on an iPhone 7's 1334 px without a RenderFlex overflow stripe, and an
  // overflowing screenshot is an unreadable result rather than a failed one.
  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
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
          _row('private class', _rbPrivateClass),
          _row('route B note', _rbNote),
          _row('code patch', _codePatch),
        ],
      ),
    ),
  );
}
