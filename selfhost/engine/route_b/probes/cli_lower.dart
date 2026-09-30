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
//     <outDir> <projectRoot> <vm_platform.dill> <engineHash> [<manifest.json>]
//
// engineHash must be the hash the cell was published under -- the cell records
// its own and the resolver refuses a mismatch, which is the invariant that
// keeps a patch on the toolchain that built its release.
//
// manifest.json is the RELEASE's capability manifest, the tenth argument. It is
// passed to `produce` exactly as the patcher passes it, so a private reference
// is accepted or refused here on the same evidence the product uses. Omitting
// it is a real case too -- the one every release cut before manifests existed
// is in: absence must refuse private references rather than permit them.
//
// ignore_for_file: avoid_print, depend_on_referenced_packages
import 'dart:io';
import 'dart:typed_data';

import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_capabilities.dart';
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
  // Read through the CLI's own loader, so a malformed manifest behaves here the
  // way it behaves in the product rather than however this harness would.
  final capabilities = args.length > 9 && args[9].isNotEmpty
      ? RouteBCapabilities.read(File(args[9]))
      : null;

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
  print(
    'coverage : ${coverage.verdict.name}, '
    'lowered ${coverage.lowering.length}',
  );
  print(
    capabilities == null
        ? 'grants   : <none; this release published no capability manifest>'
        : 'grants   : policy ${capabilities.policy}, '
              '${capabilities.instanceCallable.length} instance member(s), '
              '${capabilities.classesConstructible.length} class(es), '
              '${capabilities.skipped.length} skipped',
  );
  for (final entry in coverage.lowering.entries) {
    print('  lower  : ${entry.key}');
    print(
      '           receiver ${entry.value.receiverType}, '
      '${entry.value.accesses.length} access(es)',
    );
    // Printed so a run shows WHICH accesses the manifest gate will judge, and
    // under which key. A refusal is otherwise indistinguishable from a lowering
    // that never saw the access at all.
    for (final access in entry.value.accesses) {
      final private = access.privateTarget;
      if (private == null) continue;
      print(
        '           private: ${access.kind} ${access.member} '
        '-> ${private.library}#${private.className}#${private.name}',
      );
    }
    for (final unsupported in entry.value.unsupported) {
      print('           UNSUPPORTED: $unsupported');
    }
  }
  if (coverage.verdict != RouteBVerdict.accept) exit(1);

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
        capabilities: capabilities,
        // The declared substitution, and nothing else: the argument list is the
        // producer's own, with the platform swapped and `--target flutter`
        // dropped. The source path -- the last argument -- is untouched.
        run: (executable, arguments) {
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
          // THE ARGUMENTS, PRINTED. Whether the CFE was asked to resolve
          // private names is otherwise only inferable from the value the app
          // reports, and an inference is not evidence: a mechanism that
          // happened to work for another reason would read identically.
          print('compile  : ${rewritten.join(' ')}');
          return Process.runSync(executable, rewritten);
        },
      ),
      values: {
        loggerRef.overrideWith(ShorebirdLogger.new),
        shorebirdEnvRef.overrideWith(ShorebirdEnv.new),
      },
    );
  } on RouteBUnsupportedTarget catch (error) {
    // A REFUSAL IS A RESULT, printed in a form a probe can assert on. It is not
    // a crash: the negative control of the capability gate is a run that MUST
    // refuse, and a stack trace would make "refused correctly" and "the harness
    // broke" look the same.
    print('REFUSED  : ${error.target}');
    print('           ${error.reason}');
    exit(2);
  }

  final out = File('${work.path}/lowered.sbrbptch')..writeAsBytesSync(bytes);
  final parsed = RouteBContainer.parse(bytes);
  print(
    'container: ${bytes.length} bytes for release ${parsed.releaseBuildId}',
  );
  for (final t in parsed.targets) {
    print('  target : ${t.library}#${t.selector}  ${t.bytecode.length} bytes');
  }
  print('OUT=${out.path}');
}
