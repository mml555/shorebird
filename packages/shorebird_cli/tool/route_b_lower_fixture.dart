// Runs the REAL producer (`RouteBProducer.produce`) over every member of an
// analyzer coverage document, one target at a time, with the real
// dart2bytecode behind it, and keeps each target's bytecode.
//
// It exists for `selfhost/engine/route_b/coverage/inlined_ops_qualify.sh`: the
// analyzer's `inlined` flag is a claim about the bytecode of the producer's
// LOWERED slice (`super.` becomes `$routeBSuper(...) as dynamic`, a receiver
// becomes a typed `self` parameter, ...), so that is what must be compiled and
// compared, not the raw source.
//
//   dart run tool/route_b_lower_fixture.dart \
//     --coverage coverage.json --release-dill release.dill \
//     --verification-dill patched_noaot.dill --flutter-platform platform.dill \
//     --work out/ --only-containing __ \
//     (--compiler-aot dart2bytecode.aot --runtime dartaotruntime
//      | --compiler-jit dart2bytecode.dart --dart dart --packages cfg.json)
//
// Writes out/<n>.bytecode and out/index.tsv (`n<TAB>key<TAB>ok|refused:why`).
// cspell:words aotruntime
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/shorebird_logger.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:shorebird_cli/src/route_b_retention.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

void main(List<String> args) => runScoped(
  () => _run(args),
  values: {
    loggerRef.overrideWith(ShorebirdLogger.new),
    shorebirdEnvRef.overrideWith(ShorebirdEnv.new),
  },
);

void _run(List<String> args) {
  final o = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    o[args[i].substring(2)] = args[i + 1];
  }
  String need(String k) => o[k] ?? (throw ArgumentError('missing --$k'));
  final doc =
      jsonDecode(File(need('coverage')).readAsStringSync())
          as Map<String, dynamic>;
  final work = Directory(need('work'))..createSync(recursive: true);
  final project = Directory(p.join(work.path, 'project'))
    ..createSync(recursive: true);
  Directory(p.join(project.path, '.dart_tool')).createSync();
  File(
    p.join(project.path, '.dart_tool', 'package_config.json'),
  ).writeAsStringSync('{"configVersion":2,"packages":[]}');

  final aot = o['compiler-aot'];
  final jit = o['compiler-jit'];
  final compiler = RouteBCompiler(
    supportsDirectSuperDualKernel: true,
    runtime: File(aot != null ? need('runtime') : need('dart')),
    compilerSnapshot: File(aot ?? jit!),
    platformDill: File(need('flutter-platform')),
    analyzer: File('unused'),
    frontend: File('unused'),
    interfaceGenerator: File('unused'),
    releaseProbe: File('unused'),
    flutterPlatformDill: File(need('flutter-platform')),
    provenance: '',
  );
  // The producer passes `<snapshot> <args>`; a JIT run needs the package
  // config before the script.
  ProcessResult run(String exe, List<String> a) {
    final r = Process.runSync(
      exe,
      jit != null ? ['--packages=${need('packages')}', ...a] : a,
    );
    if (r.exitCode != 0) {
      stderr.writeln('compiler exit ${r.exitCode}: ${r.stderr}\n${r.stdout}');
    }
    return r;
  }

  final only = o['only-containing'] ?? '';
  final keys = <String>{
    ...(doc['patchable'] as List).cast<String>(),
    ...(doc['carried'] as List).cast<String>(),
  }.where((k) => k.contains(only)).toList()..sort();
  final index = StringBuffer();
  for (var n = 0; n < keys.length; n++) {
    final key = keys[n];
    final one = Map<String, dynamic>.from(doc)
      ..['changed'] = [key]
      ..['patchable'] = [key]
      ..['conditional'] = <String>[]
      ..['carried'] = <String>[]
      ..['verdict'] = 'accept';
    final dir = Directory(p.join(work.path, '$n'))..createSync();
    try {
      const RouteBProducer().produce(
        compiler: compiler,
        coverage: RouteBCoverage.fromJson(jsonEncode(one)),
        releaseImportKernel: File(need('release-dill')),
        releaseBuildId: 'qualify',
        workingDirectory: dir,
        projectRoot: project,
        patchedVerificationKernel: File(need('verification-dill')),
        retention: const _KeepsEverything(),
        run: run,
      );
      File(
        p.join(dir.path, 'replacement_0.bytecode'),
      ).copySync(p.join(work.path, '$n.bytecode'));
      File(
        p.join(dir.path, 'replacement_0.dart'),
      ).copySync(p.join(work.path, '$n.dart'));
      index.writeln('$n\t$key\tok');
    } on Object catch (e) {
      index.writeln('$n\t$key\trefused: ${'$e'.split('\n').first}');
    }
  }
  File(p.join(work.path, 'index.tsv')).writeAsStringSync('$index');
  stdout.writeln('${keys.length} targets');
}

/// Retention is the CLI's per-release check, not what is qualified here: the
/// fixture has no release interface, so every target is let through to the
/// lowering and the compiler.
class _KeepsEverything implements RouteBRetention {
  const _KeepsEverything();

  @override
  String? refusalForTarget(RouteBCoverage coverage, String key) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
