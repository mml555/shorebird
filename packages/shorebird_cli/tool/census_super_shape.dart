// D-CENSUS-2. Classifies each census super site by its SOURCE shape, using the
// product's own scanner.
//
// WHY THIS IS A SEPARATE STEP. "Zero source arguments" cannot be read off the
// census kernel. That kernel is built `--aot --tfa`, as a release is, and TFA
// rewrites argument counts -- `super.tag('a', 7)` becomes zero arguments in the
// very kernel the analyzer reads (`super0/s2b0/`). analysisVersion 10 and 11
// therefore refuse to report an argument count at all, on purpose.
//
// The authority for shape is the SOURCE, and the product already has one
// fail-closed reader for it. Restating that rule inside the census analyzer
// would create a second definition free to drift from the one that actually
// admits patches, which is the drift the census design exists to avoid. So this
// calls `routeBSuperCallArgs` itself.
import 'dart:convert';
import 'dart:io';

import 'package:shorebird_cli/src/route_b_super_source.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: census_super_shape.dart <in.jsonl> <out.jsonl>');
    exit(64);
  }
  final input = File(args[0]);
  if (!input.existsSync()) {
    stderr.writeln('no census at ${args[0]}');
    exit(66);
  }

  final sources = <String, String?>{};
  String? sourceOf(String uri) => sources.putIfAbsent(uri, () {
    try {
      final file = File.fromUri(Uri.parse(uri));
      return file.existsSync() ? utf8.decode(file.readAsBytesSync()) : null;
    } on Object {
      return null;
    }
  });

  final out = StringBuffer();
  var siteCount = 0;
  final tally = <String, int>{};
  var first = true;

  for (final line in input.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final row = jsonDecode(line) as Map<String, Object?>;
    if (first) {
      first = false;
      row['superShapeClassifier'] = 'route_b_super_source.routeBSuperCallArgs';
      out.writeln(jsonEncode(row));
      continue;
    }
    final sites = (row['superSites'] as List?) ?? const [];
    if (sites.isNotEmpty) {
      final uri = row['fileUri'] as String?;
      final source = uri == null ? null : sourceOf(uri);
      for (final raw in sites) {
        final site = raw as Map<String, Object?>;
        final String shape;
        if (source == null) {
          // The file could not be read. NOT "probably fine": the scanner's own
          // contract is fail-closed, and so is this.
          shape = 'sourceUnavailable';
        } else {
          shape = routeBSuperCallArgs(
            source: source,
            offset: site['offset']! as int,
            member: site['member']! as String,
          ).name;
        }
        site['sourceArgs'] = shape;
        tally[shape] = (tally[shape] ?? 0) + 1;
        siteCount++;
      }
    }
    out.writeln(jsonEncode(row));
  }

  File(args[1]).writeAsStringSync(out.toString());
  stderr.writeln('  sites classified: $siteCount');
  for (final entry in tally.entries) {
    stderr.writeln('    ${entry.key.padRight(18)} ${entry.value}');
  }
}
