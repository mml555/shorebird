// MAOT-T0 (#64) -- shared fixture scaffolding.
//
// A fixture program declares the subject under test and hands the harness a
// map of DISPATCH MODES, each a closure that reaches that subject by a
// different route. The harness compares every mode's observation, because
// #62's I2 is that *every* supported invocation path must reach the current
// implementation -- direct working while virtual stays stale is a bypass, not
// a partial pass.
//
// Two things here are load-bearing rather than convenience:
//
//   processNonce  a value minted once per process. Every observation carries
//                 it, so the harness can tell a genuine in-process transition
//                 from a restart. Restarting and re-running is the easiest way
//                 to fake a patch, and it is control 9 in #64's list.
//
//   the heat loop the same call is made `heat` times before the value is
//                 reported, so an AOT build has actually specialised the call
//                 site by the time it is observed. A cold-only harness cannot
//                 see a stale inline cache.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

/// Minted once per process. Two observations carrying different nonces did
/// not happen in the same program run, whatever else they show.
final String processNonce = _mintNonce();

String _mintNonce() {
  final r = Random.secure();
  return List<int>.generate(16, (_) => r.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

void _emit(Map<String, Object?> record) {
  print('T0OBS ${jsonEncode(record)}');
}

/// Runs every dispatch mode and reports one observation each.
///
/// `args` carries `--phase=<pre|post>` and `--heat=<n>`. The phase is recorded
/// rather than interpreted: what a phase MEANS is the harness's decision, and
/// a fixture that could label its own output "post" would be able to claim a
/// transition that never happened.
Future<void> runFixture(
    Map<String, FutureOr<String> Function()> dispatchers,
    List<String> args) async {
  var phase = 'pre';
  var heat = 1;
  for (final a in args) {
    if (a.startsWith('--phase=')) phase = a.substring(8);
    if (a.startsWith('--heat=')) heat = int.parse(a.substring(7));
  }

  for (final entry in dispatchers.entries) {
    String value;
    try {
      // The loop is the point: the last call is the observed one, and by then
      // the call site has been executed `heat` times. Dispatchers may be
      // asynchronous -- an async body's value is not observable in the turn
      // that started it, and a fixture that reported the un-awaited sentinel
      // would read identically before and after a patch.
      value = await entry.value();
      for (var i = 1; i < heat; i++) {
        value = await entry.value();
      }
    } catch (e) {
      value = 'THREW:${e.runtimeType}';
    }
    _emit({
      'phase': phase,
      'dispatch': entry.key,
      'value': value,
      'nonce': processNonce,
      'heat': heat,
    });
  }
}
