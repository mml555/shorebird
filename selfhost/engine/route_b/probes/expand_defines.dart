// Copyright (c) 2026, the Shorebird self-host fork.
//
// expand_defines.dart -- prints the CLI's OWN view of a build's defines, so a
// probe can compare it against Flutter's.
//
// Nothing here reimplements anything. `DartDefineFromFileExpansion.expand` and
// `RouteBBuildConfig.fromBuildArgs` are the product code paths, and what this
// prints is what the fingerprint and the Route B kernels are built from -- so a
// disagreement printed here is a disagreement in the product, not in the
// harness.
//
//   dart --packages=<repo>/packages/shorebird_cli/.dart_tool/package_config.json \
//     expand_defines.dart <workingDirectory> [<buildArg> ...]
//
// Prints two sections, because they answer different questions:
//
//   FILE <K>=<V>        what --dart-define-from-file alone contributes
//   EFFECTIVE <K>=<V>   the whole set the fingerprint is taken over, files and
//                       --dart-define together, with Flutter's precedence
//
// Exit 3 with `FAILED: <reason>` when the option's meaning could not be
// determined; exit 4 when the whole configuration is unfingerprintable. Exit 2
// is a usage error, so "could not expand" is never confused with "the harness
// was called wrong".

import 'dart:io';

import 'package:shorebird_cli/src/dart_define_from_file.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: expand_defines.dart <workingDirectory> [<buildArg> ...]',
    );
    exit(2);
  }
  final workingDirectory = args.first;
  final buildArgs = args.skip(1).toList();

  final expansion = DartDefineFromFileExpansion.expand(
    buildArgs,
    workingDirectory: workingDirectory,
  );
  if (!expansion.ok) {
    stdout.writeln('FAILED: ${expansion.failureReason}');
    exit(3);
  }
  for (final key in expansion.defines.keys.toList()..sort()) {
    stdout.writeln('FILE $key=${expansion.defines[key]}');
  }

  final config = RouteBBuildConfig.fromBuildArgs(
    buildArgs,
    workingDirectory: workingDirectory,
  );
  if (config == null) {
    stdout.writeln('FAILED: configuration is unfingerprintable');
    exit(4);
  }
  for (final key in config.effectiveDefines.keys.toList()..sort()) {
    stdout.writeln('EFFECTIVE $key=${config.effectiveDefines[key]}');
  }
}
