// Copyright (c) 2026, the Shorebird self-host fork.
//
// cli_retention.dart -- asks the CLI's OWN retention check about a coverage
// document the analyzer wrote (analysis version 18), against a release's
// dynamic interface and capability manifest.
//
// Nothing here reimplements the decision: it parses the document with
// `RouteBCoverage`, the interface with `RouteBRetention`, the manifest with
// `RouteBCapabilities`, and prints what the product would say per carried
// member, one line each:
//
//   OK       <key>
//   REFUSED  <key>: <reason>
//
//   dart --packages=<repo>/.dart_tool/package_config.json cli_retention.dart \
//     <coverage.json> <dynamic_interface.yaml> [<manifest.json>]
//
// A missing interface file is passed as the empty string and is refused, the
// way the producer refuses it.
//
// ignore_for_file: avoid_print, depend_on_referenced_packages
import 'dart:io';

import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_retention.dart';

void main(List<String> args) {
  final coverage = RouteBCoverage.fromJson(File(args[0]).readAsStringSync());
  final capabilities = args.length > 2 && args[2].isNotEmpty
      ? RouteBCapabilities.read(File(args[2]))
      : null;
  final retention = args[1].isEmpty
      ? null
      : RouteBRetention.read(File(args[1]), capabilities: capabilities);
  final references = coverage.externalReferences;
  if (references == null) {
    print('NOT-MEASURED analysis version ${coverage.analysisVersion}');
    return;
  }
  for (final key in references.keys.toList()..sort()) {
    final reason = retention == null
        ? routeBNoInterfaceReason
        : retention.refusalForTarget(coverage, key);
    print(reason == null ? 'OK       $key' : 'REFUSED  $key: $reason');
  }
}
