// G4.1c's DISCRIMINATING fixture: a reachable program whose behaviour depends
// on a define FLUTTER injects and no user ever types.
//
// WHY THIS EXISTS. `airgap_app` release 40 was an integration regression arm and
// nothing more: it reads none of the six injected defines, so its prepass and
// import kernels are byte-identical with and without them and a green release
// there cannot observe G4.1c at all. This fixture is the specimen that can.
//
// THE THREE THINGS THAT MUST ALL HOLD, or an arm on this file proves nothing:
//
//   1. REACHABLE, not merely present. Retention is not reachability
//      (PARITY.md, "Consumption is not reachability"), so a
//      `String.fromEnvironment` read sitting in dead code would satisfy a
//      careless reading of "the program depends on an injected define" and
//      demonstrate nothing. `injectedDefineProbe()` is called from `main` and
//      its result is DISPLAYED and BEACONED.
//
//   2. NOT CONSTANT-FOLDABLE AT THE CALL SITE. This has cost this project two
//      investigations already (`selfhost/engine/killgate/target.dart`
//      2026-08-09; releases 25-30 in 2026-08-11). A body returning one
//      compile-time constant has its RESULT substituted at the call site by the
//      type-flow analysis even under `vm:never-inline` — the patched Function is
//      still called, its answer is simply overwritten with the release's own
//      constant, and a WORKING mechanism reports as OLD. Every value-bearing
//      body here therefore routes through `DateTime.now()`, which is opaque to
//      the analysis.
//
//   3. THE TWO BRANCHES MUST RETAIN DIFFERENT SYMBOLS. A probe whose arms call
//      the same thing reports agreement no matter what the defines were.
//
// WHAT THE GATE IS, and why it is `!= ''` rather than a version literal.
// The defect is PRESENCE vs ABSENCE of the injected define, not any particular
// Flutter version — Route B's kernels received NONE of the six. Gating on
// emptiness therefore tests exactly the defect and does not rot when the pinned
// Flutter moves. `FLUTTER_VERSION` cannot legally be empty in a real build:
// Flutter exits if a user tries to set it (`flutter_command.dart:1563-1571`),
// and it always injects a value. So "" means one thing only — this program was
// compiled by something that did not receive Flutter's injected defines.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// The injected define under test. Flutter appends this to EVERY build
/// (`_addFlutterVersionToDartDefines`); no user can supply it.
const String flutterVersion = String.fromEnvironment('FLUTTER_VERSION');

/// Bump in a CODE patch to prove patched Dart is executing at all. Independent
/// of the define arms, so a totally dead patch and a define-blind patch are
/// distinguishable.
const String kReleaseState = 'INJDEF-FIXTURE-V1';

/// REACHABLE ONLY when Flutter's injected defines reached the compiler.
///
/// Route B's prepass decides retention and its import kernel is what a patch
/// BINDS against. Before G4.1c both were compiled without the injected defines,
/// so both described the program in which this function is the DEAD arm while
/// the shipped release had it live.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String versionGatedValue() =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-gated' : 'X';

/// REACHABLE ONLY when they did not. The presence of this in a release's live
/// path is itself the defect.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String unversionedValue() =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-unversioned' : 'X';

/// THE SINGLE CALL SITE whose live callee depends on a Flutter-injected define.
///
/// THE READ IS INLINE, AND THAT IS LOAD-BEARING — measured, not stylistic. An
/// earlier draft of this fixture branched on the top-level [flutterVersion]
/// instead, and `route_b_analyze` reported the with-define and without-define
/// kernels as IDENTICAL (`changed: []`) even though the two `.dill` files
/// genuinely differed by 24 bytes. The reason is that the difference lived in a
/// top-level const FIELD's initializer, and the analyzer diffs CALLABLES — so
/// the whole discriminator sat in the one place the instrument does not look.
/// Spelling `const String.fromEnvironment` here embeds the value in this
/// function's own body, which is what the analyzer compares.
///
/// A fixture whose discriminator is invisible to the instrument that reads it is
/// worse than no fixture: it reports agreement and looks like a passing arm.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String injectedDefineProbe() {
  if (const String.fromEnvironment('FLUTTER_VERSION') != '') {
    return versionGatedValue();
  }
  return unversionedValue();
}

/// THE PATCH-REPLACEMENT ARM, and it tests a different link than the one above.
///
/// The arms above are about which program Route B ANALYSED. This one is about
/// what a REPLACEMENT BODY is compiled against: `route_b_producer.dart` threads
/// the release's recorded defines into `dart2bytecode` as `-D` flags so that a
/// replacement reading `const String.fromEnvironment` resolves it the way the
/// release around it did. Its own source comment states the failure mode — "a
/// replacement reading a define would silently bake in the DEFAULT while the
/// release around it holds the real value — a divergence no runtime check can
/// see, because both are literals by then."
///
/// A patch form of this body reads `flutterVersion` directly, so it renders the
/// injected value if the patch compiler received it and the empty string if it
/// did not.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String replacementReadsDefine() =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-replacement' : 'X';

/// The USER-DEFINE CONTROL, and it is what keeps the arm above honest.
///
/// A user `--dart-define` has always been threaded into the replacement
/// compile. If a patch form of THIS renders its value while the one above
/// renders empty, the propagation MECHANISM works and only the injected family
/// is missing — which is a specific, narrow gap. If both render empty, the
/// mechanism itself is broken and the injected-define reading would be a
/// misattribution.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String replacementReadsUserDefine() =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-user' : 'X';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProbeApp());
}

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(body: SafeArea(child: ProbeBody())),
  );
}

class ProbeBody extends StatefulWidget {
  const ProbeBody({super.key});

  @override
  State<ProbeBody> createState() => _ProbeBodyState();
}

class _ProbeBodyState extends State<ProbeBody> {
  String _probe = '—';
  String _replacement = '—';
  String _userDefine = '—';

  @override
  void initState() {
    super.initState();
    // Synchronous and FIRST, so the values are set before the beacon can be
    // built. Depending on await timing would make a sealed harness flaky rather
    // than wrong, which is worse.
    final p = injectedDefineProbe();
    final r = replacementReadsDefine();
    final u = replacementReadsUserDefine();
    setState(() {
      _probe = p;
      _replacement = r;
      _userDefine = u;
    });
    _beacon();
  }

  /// Report the rendered state so a harness can ASSERT on it rather than read a
  /// screenshot. Failures are swallowed: a beacon that cannot send must never
  /// change what the app displays, because the screenshot is the fallback.
  Future<void> _beacon() async {
    try {
      final yaml = await rootBundle.loadString('shorebird.yaml');
      final m = RegExp(r'^base_url:\s*(\S+)', multiLine: true).firstMatch(yaml);
      if (m == null) return;
      final uri = Uri.parse('${m.group(1)}/selfhost-beacon/state').replace(
        queryParameters: {
          'release': kReleaseState,
          'probe': _probe,
          'replacement': _replacement,
          'user_define': _userDefine,
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
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      children: [
        Text('$label:', style: const TextStyle(fontSize: 14)),
        Text(
          value,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
          _row('injected-define probe', _probe),
          _row('replacement reads define', _replacement),
          _row('replacement reads user define', _userDefine),
        ],
      ),
    ),
  );
}
