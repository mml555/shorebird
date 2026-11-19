// Prints the `dart:` base classes of a release's snapshot profile that the
// per-release SDK-member check decides by route_b_sdk_base_classes.dart, in the
// format of test/fixtures/route_b_sdk_kept/stubless_sdk_bases.tsv.
//
//   dart run tool/route_b_stubless_sdk_bases.dart route_b_snapshot_profile.json
import 'dart:io';

import 'package:shorebird_cli/src/route_b_sdk_kept.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: route_b_stubless_sdk_bases.dart <profile.json>');
    exitCode = 2;
    return;
  }
  final kept = RouteBSnapshotKept.fromProfileJson(
    File(args.single).readAsStringSync(),
  );
  stdout.writeln(kept.stublessSdkBases.join('\n'));
  stderr.writeln(
    'allocated base classes asked: ${kept.allocatedBaseClassCount}',
  );
}
