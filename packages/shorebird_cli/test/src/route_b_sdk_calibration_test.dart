import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_sdk_kept.dart';
import 'package:shorebird_cli/src/route_b_sdk_measurements.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Calibrates the per-release reader against the device.
///
/// `profile_2fc41d3f.json.gz` is the snapshot profile of the release the device
/// matrix ran on. A member the device resolved on a runtime class must not be
/// rejected by the reader for that class on that release's own profile: if it
/// is, either the reader or the class mapping is wrong.
void main() {
  useTempWorkingDirectory();

  final evidence = p.normalize(
    packagePath(
      p.join(
        '..',
        '..',
        'selfhost',
        'engine',
        'route_b',
        'evidence',
        'sdk_instance_members',
      ),
    ),
  );

  late RouteBSnapshotKept kept;

  setUpAll(() {
    final file = File(p.join(evidence, 'profile_2fc41d3f.json.gz'));
    final bytes = file.readAsBytesSync();
    // Every number below is about this file. A different profile (a re-cut
    // release) means re-deriving them, not editing the pin to pass.
    expect(
      sha256.convert(bytes).toString(),
      'f6d7b5d0d58ae6f535b6ea2d82032e2099c51cb550cef51945ff71eb41ad557d',
    );
    kept = RouteBSnapshotKept.fromProfileJson(utf8.decode(gzip.decode(bytes)));
  });

  // Keys the reader rejects on a measured class, each with why that is the
  // reader being right and the device probe being weaker than its verdict.
  const explained = {
    // `int & int`, `int << int` and `-int` are opcodes only when both operands
    // are statically exactly `int` (a `T extends int` operand is not), and the
    // analysis does not say which a call site is, so the member is looked up
    // by name and `_Smi`/`_Mint` have none in the snapshot. The device probes
    // all used plain `int` operands, hence resolved.
    'dart:core#int#&',
    'dart:core#int#<<',
    'dart:core#int#unary-',
  };

  test('the profile is the one the generated list was measured against', () {
    expect(routeBSdkMeasurementCell, '2fc41d3f');
    expect(routeBSdkMeasuredVmClasses, isNotEmpty);
  });

  test('every accepted key resolves on every class the device resolved it '
      'on, in the profile of the release it ran on', () {
    final rejected = <String>{};
    final lines = <String>[];
    for (final entry in routeBSdkMeasuredVmClasses.entries) {
      final selector = entry.key.split('#').last;
      final member = selector.startsWith('tearoff:')
          ? selector.substring('tearoff:'.length)
          : selector;
      for (final cls in entry.value) {
        if (kept.resolves(cls, member) != true) {
          rejected.add(entry.key);
          lines.add('${entry.key} on $cls');
        }
      }
    }
    expect(rejected.difference(explained), isEmpty, reason: lines.join('\n'));
    // The explanation list stays honest: each entry still needs it.
    expect(explained.difference(rejected), isEmpty);
  });

  test('the per-release check over all accepted keys refuses exactly these '
      '(the closure over declared types, not only the measured classes)', () {
    final refused = <String>{};
    final why = <String, String>{};
    for (final key in routeBSdkMeasuredAccepted) {
      final parts = key.split('#');
      final dynamicKey = parts.length == 2 && parts.first == 'dynamic';
      final last = parts.last;
      final problem = kept.problemFor(
        declaredLibrary: dynamicKey ? null : parts.first,
        declaredClass: dynamicKey ? null : parts[1],
        measured: routeBSdkMeasuredVmClasses[key] ?? const [],
        selector: last.startsWith('tearoff:') ? last.substring(8) : last,
      );
      if (problem != null) {
        refused.add(key);
        why[key] = problem;
      }
    }
    expect(routeBSdkMeasuredAccepted, hasLength(94));
    // A class the release allocates is asked even with no compiled code of
    // its own: `TickerFuture` (allocated by its stub; `then`, `catchError`,
    // `timeout` and `whenComplete` tree-shaken) can be any `Future`, and
    // `ObserverList` (no compiled `iterator`) any `Iterable`.
    expect(refused, hasLength(19), reason: why.toString());
    expect(refused, {
      'dart:async#Future#catchError',
      'dart:async#Future#tearoff:catchError',
      'dart:async#Future#tearoff:then',
      'dart:async#Future#tearoff:timeout',
      'dart:async#Future#tearoff:whenComplete',
      'dart:async#Future#then',
      'dart:async#Future#timeout',
      'dart:async#Future#whenComplete',
      'dart:core#Iterable#get:first',
      'dart:core#Iterable#get:iterator',
      'dart:core#Iterable#tearoff:toList',
      'dart:core#Iterable#tearoff:toSet',
      'dart:core#Iterable#toList',
      'dart:core#Iterable#toSet',
      'dart:core#List#get:reversed',
      'dart:core#int#&',
      'dart:core#int#<<',
      'dart:core#int#unary-',
      'dart:core#num#~/',
    }, reason: why.toString());
  });
}
