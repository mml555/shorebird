// Copyright (c) 2026, the Shorebird self-host fork.
//
// cli_verdict.dart -- the CLI's half of the parity harness.
//
// Runs the REAL parser from shorebird_cli over an analysis document and prints
// what it made of it, in the same normalized shape the harness reads from the
// reference tools. Nothing is reimplemented here; if this file had its own idea
// of what `conditional` means, the harness would be comparing the harness
// against itself.
//
// Run with shorebird_cli's package config:
//
//   dart --packages=packages/shorebird_cli/.dart_tool/package_config.json \
//     cli_verdict.dart coverage.json
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:shorebird_cli/src/route_b_coverage.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: cli_verdict.dart <coverage.json>');
    exit(2);
  }

  final RouteBCoverage coverage;
  try {
    coverage = RouteBCoverage.fromJson(File(args.single).readAsStringSync());
  } on FormatException catch (error) {
    stderr.writeln('PARSE FAILED: ${error.message}');
    exit(3);
  }

  print(
    const JsonEncoder.withIndent('  ').convert({
      'verdict': coverage.verdict.name,
      'changed': coverage.changed,
      'added': coverage.added,
      'removed': coverage.removed,
      'representable': coverage.representable,
      'conditional': coverage.conditional,
      'rejections': [
        for (final r in coverage.rejections)
          {
            'target': r.target,
            'category': r.category.name,
            'reason': r.reason,
          },
      ],
      // The message is compared too. A verdict that is right and a message that
      // names the wrong function is still a patch someone cannot debug.
      'refusalMessage': coverage.verdict == RouteBVerdict.reject
          ? coverage.refusalMessage
          : null,
    }),
  );
}
