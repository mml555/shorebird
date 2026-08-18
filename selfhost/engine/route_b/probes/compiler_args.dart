// Copyright (c) 2026, the Shorebird self-host fork.
//
// compiler_args.dart -- prints the `-D` environment the PRODUCT hands to the
// replacement compiler, so a probe cannot drift from it.
//
// WHY THIS EXISTS. `g41d`'s first draft hand-simulated the product's flags: its
// patch-replacement arm passed "no defines" because that is what
// `compilerArgs` was known to produce, and asserted the value came out wrong.
// That arm would have kept passing forever, including after the defect was
// fixed, because nothing connected it to the code under test. A check that
// cannot fail is worse than no check.
//
// So this prints `RouteBBuildConfig.compilerArgs` itself -- the same getter
// `route_b_producer.dart` splices into the dart2bytecode invocation. If the
// product stops threading a define, this stops printing it, and the arm goes
// red.
//
//   dart --packages=<repo>/packages/shorebird_cli/.dart_tool/package_config.json \
//     compiler_args.dart --injected K=V[,K=V...] -- <buildArg> ...
//
// `--injected` is what a RELEASE recorded; omit it entirely to model a release
// cut before the record existed, which is a DIFFERENT state from recording an
// empty set and is printed as such.
//
// Prints one flag per line, then a RECORDS line. Exit 4 when the configuration
// is unfingerprintable; exit 2 is a usage error, so "cannot fingerprint" is
// never confused with "the harness was called wrong".

import 'dart:io';

import 'package:shorebird_cli/src/route_b_build_config.dart';

void main(List<String> argv) {
  Map<String, String>? injected;
  final buildArgs = <String>[];

  var i = 0;
  var afterSeparator = false;
  while (i < argv.length) {
    final arg = argv[i];
    if (!afterSeparator && arg == '--') {
      afterSeparator = true;
      i++;
      continue;
    }
    if (!afterSeparator && arg == '--injected') {
      if (i + 1 >= argv.length) {
        stderr.writeln('usage: --injected K=V[,K=V...]');
        exit(2);
      }
      injected = <String, String>{};
      for (final pair in argv[i + 1].split(',')) {
        if (pair.isEmpty) continue;
        final eq = pair.indexOf('=');
        if (eq < 0) {
          stderr.writeln('usage: --injected expects K=V, got "$pair"');
          exit(2);
        }
        injected[pair.substring(0, eq)] = pair.substring(eq + 1);
      }
      i += 2;
      continue;
    }
    buildArgs.add(arg);
    i++;
  }

  final config = RouteBBuildConfig.fromBuildArgs(
    buildArgs,
    injectedDefines: injected,
  );
  if (config == null) {
    stdout.writeln('UNFINGERPRINTABLE');
    exit(4);
  }

  for (final flag in config.compilerArgs) {
    stdout.writeln(flag);
  }
  // The distinction the patch side gates on: a release that recorded an EMPTY
  // injected set is stating a fact, while one that recorded nothing predates the
  // field and can never be given one.
  stdout.writeln('RECORDS ${config.recordsInjectedDefines}');
}
