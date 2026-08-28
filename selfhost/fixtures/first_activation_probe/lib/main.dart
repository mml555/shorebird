// First-activation disappearance probe.
//
// Answers ONE question: what terminates the process after the first activation
// of a newly installed patch? It is an instrument, not a fix, and not a
// certification fixture.
//
//   activation state   ACT-V1     patched to ACT-V2, ACT-V3, ... one per
//                                 new-patch generation, so a first activation
//                                 is visually distinguishable from a repeat.
//
// The patch target is armored the same way every other fixture here is: a
// `DateTime.now()` guard so the release compiler cannot fold the body into a
// constant, `vm:never-inline` so a call site survives, `vm:entry-point` so
// tree-shaking keeps it. A foldable constant is unpatchable, and that has cost
// this project a device run before.
//
// NOTHING IN HERE TOUCHES THE LIFECYCLE. See lib/timeline.dart for why that
// boundary is load-bearing while Epoch B is collecting.

import 'dart:async';
import 'dart:io' show pid;

import 'package:flutter/material.dart';

import 'package:first_activation_probe/timeline.dart';

/// THE PATCH TARGET.
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String activationState() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'ACT-V5'
    : 'ACT-V5!';

void main() {
  // As early as Dart can observe. Anything before this belongs to the engine
  // and is only visible in syslog and the Route B trace.
  Timeline.begin('main');
  Timeline.mark('DART_MAIN_ENTERED', 'state=${activationState()}');

  // Uncaught async and framework errors are recorded, then rethrown to the
  // default handler. An instrument must not change whether the process dies.
  FlutterError.onError = (details) {
    Timeline.mark('FLUTTER_ERROR', details.exceptionAsString().split('\n').first);
    FlutterError.presentError(details);
  };

  runZonedGuarded(
    () => runApp(const FirstActivationProbe()),
    (error, stack) {
      Timeline.mark('ZONE_ERROR', error.toString().split('\n').first);
      throw error;
    },
  );
}

class FirstActivationProbe extends StatefulWidget {
  const FirstActivationProbe({super.key});

  @override
  State<FirstActivationProbe> createState() => _FirstActivationProbeState();
}

class _FirstActivationProbeState extends State<FirstActivationProbe>
    with WidgetsBindingObserver {
  String _state = 'pending';
  bool _firstFrameSeen = false;

  @override
  void initState() {
    super.initState();
    Timeline.mark('INIT_STATE');
    WidgetsBinding.instance.addObserver(this);
    _state = activationState();

    // FIRST FRAME is the same trigger the updater uses to bank launch success,
    // so it is the anchor everything after is measured from. The updater's own
    // `success_diag.log` records the pid; the harness correlates by pid rather
    // than this fixture asserting anything about success itself.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_firstFrameSeen) return;
      _firstFrameSeen = true;
      Timeline.mark('FIRST_FRAME', 'state=$_state');
      _startHeartbeats();
    });
  }

  /// Heartbeats AFTER the success boundary, never moving it.
  ///
  /// Separate timers rather than a periodic one: a periodic timer that misses a
  /// tick is indistinguishable from a process that died, and the difference is
  /// the entire finding.
  void _startHeartbeats() {
    for (final ms in Timeline.heartbeatOffsets) {
      Timer(Duration(milliseconds: ms), () {
        Timeline.mark('POST_FRAME_HEARTBEAT', '+${ms}ms');
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The sequence that matters: does a disappearance arrive as a lifecycle
    // transition (paused/detached, i.e. the system asked) or with no transition
    // at all (i.e. the process was killed)?
    Timeline.mark('APP_LIFECYCLE', state.name);
    super.didChangeAppLifecycleState(state);
  }

  @override
  void didHaveMemoryPressure() {
    // A jetsam kill leaves no crash report of the usual kind. If this fires
    // before a disappearance, that is a strong classification signal.
    Timeline.mark('MEMORY_PRESSURE');
    super.didHaveMemoryPressure();
  }

  @override
  void dispose() {
    Timeline.mark('DISPOSE');
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF1B3A2F),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'first activation probe',
                style: TextStyle(color: Colors.white70, fontSize: 20),
              ),
              const SizedBox(height: 16),
              Text(
                'activation state:',
                style: const TextStyle(color: Colors.white70, fontSize: 18),
              ),
              Text(
                _state,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),
              // Loud and deliberately unmissable, following the killswitch
              // fixture's convention: if the instrument could not write, NOTHING
              // on this screen or in the timeline is a result.
              if (Timeline.lastError != null)
                Container(
                  color: const Color(0xFFB00020),
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'INSTRUMENT FAULT — NOT A RESULT\n${Timeline.lastError}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              // Ties a screenshot to the timeline entries of the same process.
              // Without it, "the screen showed this" and "these lines were
              // written" are two observations an operator has to assume belong
              // together.
              Text(
                'pid $_pidText',
                style: const TextStyle(color: Colors.white38, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _pidText => pidForDisplay.toString();
}

/// Read once so the rendered pid and the timeline pid cannot disagree.
final int pidForDisplay = _readPid();

int _readPid() {
  Timeline.mark('PID_READ');
  return pid;
}
