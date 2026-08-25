// Copyright (c) 2026, the Shorebird self-host fork.
//
// cli_survival.dart -- drives the CLI's OWN analyzer, survival oracle and
// producer over a release/patch pair, with P4.1's gate live.
//
// Nothing here reimplements the gate. `cellSurvivalOracle` runs the cell's real
// `route_b_release_probe.aot` against the release's real snapshot profile, and
// `RouteBProducer.produce` makes the publication decision -- so a refusal
// printed here is the refusal the product would print, for the same reason.
//
// ONE declared deviation from the product path, identical to cli_lower.dart's:
// the compile is redirected to the VM platform instead of the Flutter one,
// because the release this runs against is a plain `dartaotruntime` program.
// That substitution happens in the `run` hook, which is the same seam the unit
// tests use. The oracle, the probe, the profile, the binding and the decision
// are untouched.
//
//   dart --packages=<repo>/.dart_tool/package_config.json cli_survival.dart \
//     <cell.zip> <base.dill> <patched.dill> <import.dill> <buildId> \
//     <outDir> <projectRoot> <vm_platform.dill> <engineHash> \
//     <profile.json> <binding.json> <artifactSha256>
//     [--no-gate|--no-profile] [--bound]
//
// --no-gate omits the oracle entirely. That is the MUTATION arm: it shows what
// the product does with the gate removed, which is the only way to know the
// gate is what refused rather than something else along the way.
//
// --no-profile is the LEGACY RELEASE arm: a release cut before the profile
// sidecar existed. It uploaded no evidence, so the question cannot be answered,
// and an unanswered prerequisite is not a satisfied one.
//
// ignore_for_file: avoid_print, depend_on_referenced_packages
import 'dart:io';
import 'dart:typed_data';

import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_binding.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:shorebird_cli/src/route_b_survival.dart';
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
  final profile = File(args[9]);
  final binding = File(args[10]);
  final artifactSha = args[11];
  final gated = !args.contains('--no-gate');
  // The LEGACY RELEASE shape: one cut before the profile sidecar existed. The
  // patcher builds exactly this oracle rather than omitting the gate, because
  // an absent gate is indistinguishable from a gate that passed.
  final legacy = args.contains('--no-profile');
  // P4.4. With evidence the producer records a binding and refuses a target
  // whose SHAPE changed; without it, it records nothing and asks nothing --
  // which is the mutation arm.
  final bound = args.contains('--bound');

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
  print('coverage : ${coverage.verdict.name}');
  for (final t in [...coverage.representable, ...coverage.conditional]) {
    print('  target : $t');
  }
  if (coverage.verdict != RouteBVerdict.accept) {
    print('VERDICT  : COVERAGE_REJECTED');
    exit(1);
  }

  final oracle = legacy
      ? ((List<String> targets) => <String, RouteBSurvivalVerdict>{
          for (final t in targets)
            t: const RouteBSurvivalVerdict(
              survival: RouteBSurvival.unknown,
              instrumentResult: 'RELEASE_EVIDENCE_ABSENT',
              detail: 'this release uploaded no route_b_snapshot_profile.json',
            ),
        })
      : gated
      ? cellSurvivalOracle(
          compiler: compiler,
          profile: profile,
          binding: binding,
          releaseArtifactSha256: artifactSha,
        )
      : null;

  // Printed BEFORE the decision, so the evidence a refusal rests on is visible
  // even when the refusal happens. The producer asks the same oracle again;
  // that is one extra probe run in this harness only.
  if (oracle != null) {
    final targets = [...coverage.representable, ...coverage.conditional]
      ..sort();
    oracle(targets).forEach((target, verdict) {
      print(
        'probe    : $target -> ${verdict.instrumentResult} '
        '(${verdict.survival.name})',
      );
      if (verdict.evidence.isNotEmpty) {
        print('           ${verdict.evidence}');
      }
    });
  } else {
    print('probe    : <GATE REMOVED -- mutation arm>');
  }

  final Uint8List bytes;
  try {
    bytes = runScoped(
      () => const RouteBProducer().produce(
        compiler: compiler,
        coverage: coverage,
        importKernel: importDill,
        releaseBuildId: buildId,
        workingDirectory: work,
        projectRoot: projectRoot,
        survival: oracle,
        releaseEvidence: bound
            ? RouteBReleaseEvidence(
                releaseBuildId: buildId,
                engineRevision: engineHash,
                compatibilityRevision: routeBCompatibilityRevision,
                releaseArtifactSha256: artifactSha,
              )
            : null,
        run: (executable, arguments) {
          // THE DECLARED DEVIATION, identical to cli_lower.dart's. Swapping the
          // platform path alone is not enough: `--target flutter` makes the CFE
          // look for Flutter's extra required libraries, which a VM platform
          // dill does not carry, and it dies in loadExtraRequiredLibraries with
          // a null-check crash that names neither flag.
          final rewritten = <String>[];
          for (var i = 0; i < arguments.length; i++) {
            if (arguments[i] == '--platform') {
              rewritten
                ..add('--platform')
                ..add(vmPlatform);
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
        // The logger writes a run log through shorebirdEnv, so scoping the
        // logger alone crashes on the SUCCESS path only -- which reads as the
        // gate refusing when it did not.
        shorebirdEnvRef.overrideWith(ShorebirdEnv.new),
      },
    );
  } on RouteBUnsupportedTarget catch (error) {
    print('VERDICT  : REFUSED');
    print('  target : ${error.target}');
    print('  reason : ${error.reason.split('\n').first}');
    // The whole reason, so a wording assertion can see it.
    print('--- reason (full) ---');
    print(error.reason);
    print('--- end ---');
    exit(3);
  }

  print('VERDICT  : PUBLISHED ${bytes.length} container bytes');
}
