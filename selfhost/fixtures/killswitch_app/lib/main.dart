// G15 arm 2 fixture — a GOOD patch killed before the success point.
//
// WHY THIS EXISTS. G15's decisive risk is not that a broken patch survives; it
// is that a WORKING one gets tombstoned. `detect_boot_crash_on_init` infers "this
// boot crashed" from "the breadcrumb is still set", which is an inference from
// ABSENCE OF EVIDENCE — equally consistent with a patch that broke Dart and with
// the user swiping the app away during launch, the iOS launch watchdog
// (0x8badf00d), or jetsam. No arm that only exercises good launches and broken
// patches can see that failure, which is why the prior design's table missed it.
//
// NOT `twoengine_app`. That fixture ends `_boot()` in `runApp()` and both
// entrypoints call it, so it is not headless — the earlier design's arm 4
// assumed otherwise and was a false green on precisely that ground.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE RECEIPT, and why it was rebuilt on 2026-08-14.
//
// This fixture has now produced TWO unreadable results, both by the same
// mechanism: a signal whose failure mode mimics the state it exists to
// discriminate.
//
//   1. The `HOME`-derived marker path threw, `main` died before rendering, and
//      the blank screen was indistinguishable from the kill arm working.
//   2. `6d00e95c` put `bootMark = bootProbe();` AHEAD of the marker write. That
//      put the receipt BEHIND the very function arm B exists to make throw — so
//      on the arm where the receipt matters most it can never move. An unmoved
//      marker then reads as "user Dart never ran" when it is equally consistent
//      with "`main` was entered and died on its first statement".
//
// So the receipt is no longer one toggling bit. It is an APPEND-ONLY PHASE LOG,
// and the phases are chosen so that the LAST LINE PRESENT names the exact point
// the launch reached:
//
//   native launch          the process reached `didFinishLaunchingWithOptions`
//   native engine          the implicit FlutterEngine was created
//   dart-main-entered      `main()` ran its first statement
//   boot-probe-returned:X  `bootProbe()` — THE PATCH TARGET — returned X
//   arm:kill / arm:render  the alternation decided
//   first-frame            Flutter actually drew
//
// A gap between any two consecutive phases localises the failure to one step,
// which no screenshot and no single marker file can do. The native half matters
// specifically because it is the only thing that separates "Dart never started"
// from "the app never really launched" — the two states the 2026-08-14 control
// could not tell apart. It is injected by `prepare_killswitch_fixture.sh`,
// because `ios/` is generated and gitignored.
//
// INVARIANTS. Breaking any of these makes every later G15 arm less trustworthy
// than the arms that were already voided:
//
//   * `_receipt('dart-main-entered')` IS THE FIRST STATEMENT OF `main()`. Nothing
//     patchable may precede it, ever.
//   * `bootProbe()` IS NOT WRAPPED IN try/catch. The seam under test must see the
//     unhandled throw; catching it here would make the whole gate vacuous.
//   * an instrument fault NEVER kills the process. It renders red instead.
//   * the receipt is written with `flush`, appended, and never truncated, so it
//     survives `SIGKILL` — which a screen does not.

import 'dart:io';

import 'package:flutter/material.dart';

/// Flipped by the patch. `OLD-kill` is the release value; a patch replaces this
/// body and the screen is the claim.
///
/// REPAIRED 2026-08-17, and the repair is the experiment. This body was
/// `=> 'OLD-kill'` — a foldable constant — for the entire investigation, and
/// `foldability_verdict.txt` measured what that does on a controlled pair:
///
///     foldable constant body -> the RESULT is substituted at every call site
///                            -> no call site survives to reach the Function
///                            -> nothing in the object pool references it (ABSENT)
///                            -> Route B attaches successfully (rc=0)
///                            -> and nobody ever calls it, so OLD renders
///
/// Measured on THIS target at release 96: `TPOOL_ABSENT`, `rc=0`,
/// `uep_post_is_interpret_call=1`, screen `OLD-kill`. Attached perfectly, never
/// executed.
///
/// The guard below is the fixture-standard opaque form `airgap_probe` uses for
/// exactly this reason (`airgap_app/lib/main.dart:52-56`): `DateTime.now()` is
/// not resolvable at compile time, so neither arm can be substituted and the
/// call survives.
///
/// NOTHING ELSE CHANGES. Same name, same signature, same caller in `build()`,
/// same release-visible `OLD-kill`, same patched `NEW-kill`, no pragmas added.
/// `UNREACHABLE-KILL` is never returned; if it appears, the body executed and
/// took the wrong branch — which is visibly different from never executing.
String routeBValue() => DateTime.now().millisecondsSinceEpoch == -1
    ? 'UNREACHABLE-KILL'
    : 'OLD-kill';

/// Called from `main()` BEFORE `runApp`, which is the whole point of it.
///
/// `routeBValue()` cannot serve the crash-backout arm: it is called from
/// `build()`, which runs AFTER launch success has been banked. A patch that
/// throws there is a RUNTIME failure, not a BOOT failure, and G15 deliberately
/// does not back those out.
///
/// This one is invoked from `main()` itself, so a patch that makes it throw is a
/// Dart-phase failure of the boot. NOTE, corrected 2026-08-14: it does NOT run
/// "while `Engine::Run` is still on the stack". `_delayEntrypointInvocation`
/// POSTS `main` to the message queue, so `Engine::Run` has already returned by
/// the time this executes. That correction is the whole reason the seam moved.
/// REPAIRED 2026-08-19, for the same reason `routeBValue` was.
///
/// This body was `=> 'boot-ok'` — a foldable constant — so the release compiler
/// substituted its result at the call site and left an 8-byte stub with NO
/// surviving call sites (`assert_result_consumed.sh`: NOT LOCATED on release
/// 100). A patch to it would have attached, reported success, and never
/// executed: the arm would have shown `boot-ok` and looked like "the patch did
/// not take", which is a precommitted NON-result.
///
/// The opaque guard keeps the call alive so arm B can actually make it throw.
/// `UNREACHABLE-BOOT` is never returned in the release.
String bootProbe() => DateTime.now().millisecondsSinceEpoch == -1
    ? 'UNREACHABLE-BOOT'
    : 'boot-ok';

/// Set from [bootProbe] so the value cannot be tree-shaken away.
String bootMark = '';

/// The app sandbox root.
///
/// `Directory.systemTemp` resolves to `<sandbox>/tmp` on iOS, so its parent is
/// the sandbox. NOT `HOME`: **measured on device 2026-08-14,
/// `Platform.environment['HOME']` is not set there.** The path became
/// `null/Documents/g15_armed`, which is relative, and `createSync` threw against
/// a read-only working directory. The native half uses `NSHomeDirectory()`,
/// which — unlike the Dart environment variable — IS the sandbox root; the two
/// must resolve to the same place and the first device run should confirm it by
/// showing native and Dart lines in one file.
Directory get _sandbox => Directory.systemTemp.parent;

/// The append-only phase log. Shared with the native half.
File get _receiptFile => File('${_sandbox.path}/Documents/g15_receipt');

/// Ties every line of one launch together, and is shown on screen so a
/// screenshot can be matched to its receipt lines rather than assumed to
/// correspond.
final String _launchId =
    DateTime.now().microsecondsSinceEpoch.toRadixString(36);

/// Non-null when the receipt mechanism itself failed.
String? _receiptFault;

/// Appends one phase line. Never throws, and never kills.
void _receipt(String phase) {
  try {
    final File f = _receiptFile;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      'dart $_launchId $phase\n',
      mode: FileMode.append,
      flush: true,
    );
  } on Object catch (e) {
    _receiptFault ??= '$e';
  }
}

// THE ALTERNATION AND THE SELF-KILL ARM WERE REMOVED 2026-08-19.
//
// `_shouldKillThisLaunch` existed to make every other launch SIGKILL itself, so
// arm 2 could run repeatedly without anyone reaching into the sandbox. That arm
// is disqualified: `Process.killPid(pid, SIGKILL)` did not terminate this
// process, so it produced a Dart-phase exception instead of a process death —
// a different input on a different retirement path
// (`tombstone_instrument_findings.md`).
//
// The stimulus is now the OPERATOR force-quitting inside the widened window, so
// EVERY launch must reach that window. An alternation that killed half of them
// would simply remove half the usable launches.
//
// `_armedMarker` and `_markerFault` went with it; the marker file is no longer
// read or written, and any stale `Documents/g15_armed` on a device is inert.

Future<void> main() async {
  // PHASE 1, AND IT MUST STAY FIRST. Nothing patchable precedes it, so a launch
  // that reaches Dart at all leaves this line behind even if the next statement
  // throws. This is exactly what `1.0.3+1` could not do.
  _receipt('dart-main-entered');

  // PHASE 2. `bootProbe()` is the patch target, and it is DELIBERATELY NOT
  // GUARDED: arm B makes it throw, and the seam under test is what must observe
  // that. If this throws, phase 2 is simply absent from the receipt — which is
  // the positive reading of a Dart-phase boot failure, not an ambiguity.
  bootMark = bootProbe();
  _receipt('boot-probe-returned:$bootMark');

  if (_receiptFault != null) {
    // An instrument fault is NOT an arm result. Render the red banner instead of
    // entering the window, so the operator sees it rather than force-quitting a
    // launch that was never valid.
    _receipt('instrument-fault');
    runApp(const _KillSwitchApp());
    return;
  }

  // THE PRE-SUCCESS WITNESS. Written IMMEDIATELY BEFORE the await, so its
  // presence in the receipt establishes exactly one thing:
  //
  //   this launch reached the intended widened pre-success window.
  //
  // That is what makes a force-quit attributable. Without it the operator is
  // force-quitting on elapsed time and hoping, and a miss is indistinguishable
  // from a launch that never got there.
  _receipt('delayed-main-entered:$_launchId');

  // THE WINDOW. Five seconds: comfortably human-operable, and short enough to
  // stay well clear of the iOS launch watchdog, which would otherwise introduce
  // a second termination cause as a confound.
  //
  // Neither success condition can fire in here: `main` has not completed, and
  // `runApp` has not been called so there is no frame to draw.
  await Future<void>.delayed(const Duration(seconds: 5));

  // Reached ONLY if the operator did not force-quit. Its presence in the receipt
  // is how a MISS is detected and discarded rather than scored.
  _receipt('window-survived:$_launchId');

  runApp(const _KillSwitchApp());

  // PHASE 6. `runApp` returns as soon as the first frame is SCHEDULED, so the
  // callback — not the `runApp` call — is what proves Flutter drew.
  WidgetsBinding.instance.addPostFrameCallback((_) => _receipt('first-frame'));
}

class _KillSwitchApp extends StatelessWidget {
  const _KillSwitchApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF102A43),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'G15 arm 2',
                style: TextStyle(color: Colors.white70, fontSize: 22),
              ),
              const SizedBox(height: 16),
              // THE CLAIM. Reaching this screen at all means the previous
              // launch was killed before recording success and the patch was
              // NOT tombstoned. The value shows whether the patch is still the
              // one running.
              Text(
                'boot: $bootMark',
                style: const TextStyle(color: Colors.white70, fontSize: 18),
              ),
              const SizedBox(height: 8),
              Text(
                'route B value: ${routeBValue()}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              // Ties this screenshot to its receipt lines. Without it, "the
              // screen rendered" and "these receipt lines were written" are two
              // observations an operator has to ASSUME belong to one launch.
              Text(
                'launch $_launchId',
                style: const TextStyle(color: Colors.white38, fontSize: 14),
              ),
              // Loud, and deliberately unmissable: if this is showing, an
              // instrument failed and NOTHING on this screen is an arm-2
              // result. Silence here would let a broken fixture read as a pass.
                if (_receiptFault != null) ...[
                const SizedBox(height: 24),
                Container(
                  color: const Color(0xFFB00020),
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'INSTRUMENT FAULT — NOT AN ARM RESULT\n'
                    'receipt: ${_receiptFault ?? "ok"}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
