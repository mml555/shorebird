// Copyright (c) 2026, the Shorebird self-host fork.
//
// cli_lower.dart -- drives the CLI's OWN analyzer and producer over a
// release/patch pair, for the implicit-`this` lowering.
//
// The point of this harness is that nothing here reimplements the lowering.
// `RouteBProducer.produce` decides the replacement source, and the source it
// writes to `replacement_0.dart` is the source that gets compiled -- so the
// text this prints is the text the product would ship.
//
// ONE declared deviation from the product path: the compile is redirected to
// the VM platform instead of the Flutter one, because the release this runs
// against is a plain `dartaotruntime` program. That substitution is done in the
// `run` hook, which is the same seam the unit tests use; the sources, the
// container, the packing and the installation are untouched.
//
//   dart --packages=<repo>/.dart_tool/package_config.json cli_lower.dart \
//     <cell.zip> <base.dill> <patched.dill> <import.dill> <buildId> \
//     <outDir> <projectRoot> <vm_platform.dill> <engineHash>
//
// engineHash must be the hash the cell was published under -- the cell records
// its own and the resolver refuses a mismatch, which is the invariant that
// keeps a patch on the toolchain that built its release.
//
// ignore_for_file: avoid_print, depend_on_referenced_packages
import 'dart:io';

import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_container.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

Future<void> main(List<String> args) async {
  final cellZip = File(args[0]);
  final baseDill = File(args[1]);
  final patchedDill = File(args[2]);
  final importDill = File(args[3]);
  final buildId = args[4];
  final work = Directory(args[5])..createSync(recursive: true);
  final projectRoot = Directory(args[6]);
  final vmPlatform = args[7];
  final engineHash = args[8];

  final compiler = await resolveRouteBCompiler(
    engineHash: engineHash,
    cacheRoot: Directory.systemTemp.createTempSync('cell'),
    fetchBundle: (h) async => cellZip,
    extractTo: (a, d) async {
      final r = Process.runSync('unzip', ['-q', '-o', a.path, '-d', d.path]);
      if (r.exitCode != 0) throw Exception(r.stderr);
    },
  );

  final coverage = const RouteBCoverageAnalyzer().analyze(
    compiler: compiler,
    baseDill: baseDill,
    patchedDill: patchedDill,
  );
  print('coverage : ${coverage.verdict.name}, '
      'lowered ${coverage.lowering.length}');
  for (final entry in coverage.lowering.entries) {
    print('  lower  : ${entry.key}');
    print('           receiver ${entry.value.receiverType}, '
        '${entry.value.accesses.length} access(es)');
    for (final unsupported in entry.value.unsupported) {
      print('           UNSUPPORTED: $unsupported');
    }
  }
  if (coverage.verdict != RouteBVerdict.accept) exit(1);

  final bytes = runScoped(
    () => const RouteBProducer().produce(
      compiler: compiler,
      coverage: coverage,
      importKernel: importDill,
      releaseBuildId: buildId,
      workingDirectory: work,
      projectRoot: projectRoot,
      // The declared substitution, and nothing else: the argument list is the
      // producer's own, with the platform swapped and `--target flutter`
      // dropped. The source path -- the last argument -- is untouched.
      run: (executable, arguments) {
        final rewritten = <String>[];
        for (var i = 0; i < arguments.length; i++) {
          if (arguments[i] == '--platform') {
            rewritten..add('--platform')..add(vmPlatform);
            i++;
            continue;
          }
          if (arguments[i] == '--target') {
            i++;
            continue;
          }
          rewritten.add(arguments[i]);
        }
        return Process.runSync(executable, rewritten);
      },
    ),
    values: {
      loggerRef.overrideWith(ShorebirdLogger.new),
      shorebirdEnvRef.overrideWith(ShorebirdEnv.new),
    },
  );

  final out = File('${work.path}/lowered.sbrbptch')..writeAsBytesSync(bytes);
  final parsed = RouteBContainer.parse(bytes);
  print('container: ${bytes.length} bytes for release ${parsed.releaseBuildId}');
  for (final t in parsed.targets) {
    print('  target : ${t.library}#${t.selector}  ${t.bytecode.length} bytes');
  }
  print('OUT=${out.path}');
}
