// Copyright (c) 2026, the Shorebird self-host fork.
//
// cli_produce.dart -- drives the CLI's OWN producer, for the host-equivalence
// gate.
//
// Runs exactly the code `shorebird patch` runs -- RouteBCoverageAnalyzer, then
// RouteBProducer -- so `host_equivalence.sh` compares the shipping
// implementation against the manually proven tooling rather than a
// reimplementation of it.
//
// Run with the repo's package config:
//
//   dart --packages=.dart_tool/package_config.json \
//     selfhost/engine/route_b/producer/cli_produce.dart \
//     <cell.zip> <base.dill> <patched.dill> <import.dill> <buildId> <outDir> \
//     [projectRoot]
//
// projectRoot is where the replacement's `--packages` comes from; it defaults
// to the directory holding base.dill, which is the corpus root in the harness.
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_container.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';

Future<void> main(List<String> args) async {
  final cellZip = File(args[0]);
  final baseDill = File(args[1]);
  final patchedDill = File(args[2]);
  final importDill = File(args[3]);
  final buildId = args[4];

  final compiler = await resolveRouteBCompiler(
    engineHash: '591a9f8d8e21f8c08cd379ac4c63a0300ac98959',
    cacheRoot: Directory.systemTemp.createTempSync('cell'),
    fetchBundle: (h) async => cellZip,
    extractTo: (a, d) async {
      final r = Process.runSync('unzip', ['-q', '-o', a.path, '-d', d.path]);
      if (r.exitCode != 0) throw Exception(r.stderr);
    },
  );

  final coverage = const RouteBCoverageAnalyzer()
      .analyze(compiler: compiler, baseDill: baseDill, patchedDill: patchedDill);
  print('coverage: ${coverage.verdict.name}, '
      'representable ${coverage.representable.length}, '
      'spans ${coverage.sources.length}');
  if (coverage.verdict != RouteBVerdict.accept) exit(1);

  final work = Directory(
    args.length > 5 ? args[5] : Directory.systemTemp.createTempSync().path,
  )
    ..createSync(recursive: true);
  final bytes = runScoped(
    () => const RouteBProducer().produce(
      compiler: compiler,
      coverage: coverage,
      importKernel: importDill,
      releaseBuildId: buildId,
      workingDirectory: work,
      projectRoot: Directory(
        args.length > 6 ? args[6] : baseDill.parent.path,
      ),
    ),
    values: {
      loggerRef.overrideWith(ShorebirdLogger.new),
      shorebirdEnvRef.overrideWith(ShorebirdEnv.new),
    },
  );

  final out = File('${work.path}/cli.sbrbptch')..writeAsBytesSync(bytes);
  print('container: ${bytes.length} bytes  sha256=${sha256.convert(bytes)}');
  final parsed = RouteBContainer.parse(bytes);
  print('  release  : ${parsed.releaseBuildId}');
  for (final t in parsed.targets) {
    print('  target   : ${t.library}#${t.selector}  '
        '${t.bytecode.length} bytes');
  }
  // Hand the payload paths to the reference packer for comparison.
  print('WORK=${work.path}');
  print('SELECTORS=${jsonEncode([
        for (final t in parsed.targets) '${t.library}#${t.selector}',
      ])}');
  print('OUT=${out.path}');
}
