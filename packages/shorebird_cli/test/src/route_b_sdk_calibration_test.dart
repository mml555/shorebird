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
    kept = RouteBSnapshotKept.fromProfileJson(
      utf8.decode(gzip.decode(bytes)),
    );
  });

  // Keys the reader rejects on a measured class, each with why that is the
  // reader being right and the device probe being weaker than its verdict.
  const explained = {
    // The probes of a tear-off create it and do not call it. The same
    // release's `String.endsWith` call (`str_endsWith__one_byte__s`) ABORTS:
    // its
    // function is `_StringBase.endsWith` with only a `[Stub] LazyCompile`, so
    // a tear-off that is ever called stops the app.
    'dart:core#String#tearoff:endsWith',
    'dynamic#tearoff:endsWith',
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
    expect(
      rejected.difference(explained),
      isEmpty,
      reason: lines.join('\n'),
    );
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
    expect(routeBSdkMeasuredAccepted, hasLength(118));
    expect(refused, hasLength(32), reason: why.toString());
    expect(refused, {
      'dart:core#Iterable#get:first',
      'dart:core#Iterable#tearoff:any',
      'dart:core#Iterable#tearoff:toList',
      'dart:core#Iterable#tearoff:toSet',
      'dart:core#Iterable#toList',
      'dart:core#Iterable#toSet',
      'dart:core#List#get:reversed',
      'dart:core#List#tearoff:sort',
      'dart:core#String#tearoff:endsWith',
      'dart:core#int#&',
      'dart:core#int#<<',
      'dart:core#int#unary-',
      'dart:core#num#~/',
      'dynamic#tearoff:catchError',
      'dynamic#tearoff:close',
      'dynamic#tearoff:containsKey',
      'dynamic#tearoff:endsWith',
      'dynamic#tearoff:forEach',
      'dynamic#tearoff:listen',
      'dynamic#tearoff:remove',
      'dynamic#tearoff:removeLast',
      'dynamic#tearoff:replaceAll',
      'dynamic#tearoff:sort',
      'dynamic#tearoff:split',
      'dynamic#tearoff:startsWith',
      'dynamic#tearoff:then',
      'dynamic#tearoff:timeout',
      'dynamic#tearoff:toDouble',
      'dynamic#tearoff:toLowerCase',
      'dynamic#tearoff:toUpperCase',
      'dynamic#tearoff:trim',
      'dynamic#tearoff:whenComplete',
    }, reason: why.toString());
  });
}
