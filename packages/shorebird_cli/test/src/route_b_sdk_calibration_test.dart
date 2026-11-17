import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_sdk_kept.dart';
import 'package:shorebird_cli/src/route_b_sdk_measurements.dart';
import 'package:test/test.dart';

/// Calibrates the per-release reader against the device.
///
/// `profile_2fc41d3f.json.gz` is the snapshot profile of the release the device
/// matrix ran on. A member the device resolved on a runtime class must not be
/// rejected by the reader for that class on that release's own profile: if it
/// is, either the reader or the class mapping is wrong.
void main() {
  final evidence = p.normalize(
    p.join(
      Directory.current.path,
      '..',
      '..',
      'selfhost',
      'engine',
      'route_b',
      'evidence',
      'sdk_instance_members',
    ),
  );

  late RouteBSnapshotKept kept;

  setUpAll(() {
    final file = File(p.join(evidence, 'profile_2fc41d3f.json.gz'));
    kept = RouteBSnapshotKept.fromProfileJson(
      utf8.decode(gzip.decode(file.readAsBytesSync())),
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
    // The bytecode compiler turns `int & int`, `int << int` and `-int` into
    // opcodes that never look the member up (see `_bytecodeIntOperators` in
    // route_b_retention.dart), so the snapshot has no `_Smi`/`_Mint` member
    // for them and the retention check does not ask.
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
}
