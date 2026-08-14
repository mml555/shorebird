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
// HOW THE KILL LANDS IN THE RIGHT WINDOW, and why it is deterministic rather
// than a race. After patch `0009`, launch success is banked when `Engine::Run`
// RETURNS. `Engine::Run` is what invokes this entrypoint. So a process that dies
// inside `main()` dies *before* `Run` returns: the boot records neither success
// nor failure, which is exactly the state a swipe-away leaves behind. No timing
// window to hit and no external tooling required.
//
// NOT `twoengine_app`. That fixture ends `_boot()` in `runApp()` and both
// entrypoints call it, so it is not headless — the earlier design's arm 4
// assumed otherwise and was a false green on precisely that ground.

import 'dart:io';

import 'package:flutter/material.dart';

/// Flipped by the patch. `OLD-kill` is the release value; a patch replaces this
/// body and the screen is the claim.
String routeBValue() => 'OLD-kill';

/// Arming marker, in the app sandbox so it survives a SIGKILL and the next
/// launch can read it. `HOME` is the sandbox root on iOS, so this needs no
/// plugin — deliberately, since a plugin would add native code to a fixture
/// whose whole point is a specific native launch sequence.
File get _armedMarker =>
    File('${Platform.environment['HOME']}/Documents/g15_armed');

/// Alternates: absent → kill this launch and arm nothing further; present →
/// consume it and run normally.
///
/// The alternation is the point. G15's design requires arm 2 to be run MORE
/// THAN ONCE — a single survival is consistent with the kill having landed
/// outside the window by luck — and self-alternating gives that without anyone
/// reaching into the sandbox between launches. Deleting the marker to re-arm is
/// also why this does not need an uninstall, which would reset iOS Local
/// Network consent and block the app on a modal before any code runs.
bool _shouldKillThisLaunch() {
  final marker = _armedMarker;
  if (marker.existsSync()) {
    marker.deleteSync();
    return false;
  }
  marker.createSync(recursive: true);
  return true;
}

void main() {
  if (_shouldKillThisLaunch()) {
    // SIGKILL, not `exit()`. Jetsam and the launch watchdog do not let the
    // process wind down, and a clean exit could run teardown that the cases
    // being simulated never run — which might report an outcome and defeat the
    // entire arm.
    Process.killPid(pid, ProcessSignal.sigkill);
    // Unreachable. If SIGKILL were ever not delivered, falling through to
    // runApp would render a screen that looks like a normal launch, so the
    // arm would silently become vacuous. Fail loudly instead.
    throw StateError('G15: SIGKILL did not terminate the process');
  }

  runApp(const _KillSwitchApp());
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
                'route B value: ${routeBValue()}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
