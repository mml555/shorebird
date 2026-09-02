// Feeds the FROZEN analyzer's own output through the production parser, so the
// measurement-state contract is proven on real documents rather than fixtures.
import 'dart:io';

import 'package:shorebird_cli/src/route_b_coverage.dart';

void main(List<String> args) {
  for (final path in args) {
    final c = RouteBCoverage.fromJson(File(path).readAsStringSync());
    var absent = 0, empty = 0, populated = 0;
    for (final l in c.lowering.values) {
      final t = l.releaseSuperTargets;
      if (t == null) {
        absent++;
      } else if (t.isEmpty) {
        empty++;
      } else {
        populated++;
      }
    }
    stdout.writeln('  ${path.split('/').last}');
    stdout.writeln('    parsed lowering=${c.lowering.length} '
        'absent(null)=$absent empty=$empty populated=$populated');
  }
}
