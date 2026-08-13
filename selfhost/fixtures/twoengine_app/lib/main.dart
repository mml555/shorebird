// The two-engine harness's Dart side.
//
// Two entrypoints, one per engine, because ATTRIBUTABILITY is the whole point.
// "Some engine printed X" cannot become a verdict: each engine runs a distinct
// entrypoint, prints a distinct prefix, and writes a distinct marker file. If the
// two outputs were identical there would be no way to tell two engines from one
// engine reporting twice — which is one of the precommitted failure rows.
//
// WHAT THIS FIXTURE DOES NOT CLAIM. Booting two engines says NOTHING about Route B
// arming. Arming needs our engine, a release and a patch; this runs on stock
// Flutter against a simulator on purpose, so that a green run here can never be
// reported against `G15`. It establishes the missing PRECONDITION — that a host
// exists which puts two independently initialized engines in one process — and
// nothing more.
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Engine one's entrypoint. `main` needs no pragma: it is the default entrypoint
/// and is always retained.
void main() => _boot('one');

/// Engine two's entrypoint, named in `runWithEntrypoint:`.
///
/// `vm:entry-point` IS LOAD-BEARING AND ITS ABSENCE FAILS LATE. Without it this
/// survives `flutter run` — debug builds are JIT and keep everything — and is
/// tree-shaken in AOT, so the harness would work all through development and the
/// second engine would come up with a missing entrypoint in exactly the
/// release-mode device gate this fixture exists to unblock.
@pragma('vm:entry-point')
void engineTwoMain() => _boot('two');

/// The per-engine identity written to the marker and printed to the log.
///
/// Includes the isolate's own debug name as well as the label the entrypoint
/// supplies, so the two are cross-checkable: two markers whose `isolate=` agree
/// would mean one isolate ran both entrypoints, which is not two engines.
String _identity(String label) {
  final iso = Isolate.current.debugName ?? 'unknown';
  return 'engine=$label isolate=$iso '
      'entrypoint=${label == 'one' ? 'main' : 'engineTwoMain'} '
      'flutter_view=${ui.PlatformDispatcher.instance.views.length}';
}

void _boot(String label) {
  final id = _identity(label);
  // NSLog-visible on the simulator via `flutter run`, and prefixed so the two
  // engines' lines can be counted separately.
  // ignore: avoid_print
  print('G15-ENGINE $id');
  _writeMarker(label, id);
  runApp(_HarnessApp(label: label, identity: id));
}

/// Write a per-engine marker into the app's own tmp directory.
///
/// `Directory.systemTemp` is NSTemporaryDirectory inside the app container, so no
/// plugin is needed to get a writable path — which is what keeps this fixture
/// free of a Podfile. A marker per engine, named by engine, so "two markers with
/// different content" is a file-system fact rather than a reading of the log.
void _writeMarker(String label, String identity) {
  try {
    final f = File('${Directory.systemTemp.path}/g15-engine-$label.marker');
    f.writeAsStringSync('$identity\nwritten=${DateTime.now().toIso8601String()}\n');
    // ignore: avoid_print
    print('G15-MARKER engine=$label path=${f.path}');
  } on Object catch (e) {
    // ignore: avoid_print
    print('G15-MARKER-FAILED engine=$label error=$e');
  }
}

class _HarnessApp extends StatelessWidget {
  const _HarnessApp({required this.label, required this.identity});

  final String label;
  final String identity;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      backgroundColor: label == 'one' ? Colors.indigo : Colors.teal,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'ENGINE $label',
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  identity,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
