// Drives the PRODUCTION selection path — ShorebirdFlutter.resolveFlutterRevision
// and installRevision, the exact calls `shorebird release` makes — and then
// reads the installed checkout's engine.version and resolves the Route B
// compiler for it. Proves the whole selector chain without cutting a release.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/http_client/http_client.dart';
import 'package:shorebird_cli/src/json_output.dart';
import 'package:shorebird_cli/src/logging/shorebird_logger.dart';
import 'package:shorebird_cli/src/route_b_compiler_cache.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';

class _Recording extends http.BaseClient {
  _Recording(this._inner);
  final http.Client _inner;
  final urls = <String>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    urls.add(request.url.toString());
    return _inner.send(request);
  }
}

Future<void> main(List<String> args) async {
  final requested = args[0];
  final recorder = _Recording(http.Client());

  await runScoped(
    () async {
      // 1. the same two calls release_command makes for a non-'latest' arg
      await shorebirdFlutter.fetchRemoteRefs();
      final resolved = await shorebirdFlutter.resolveFlutterRevision(requested);
      stdout.writeln('  requested        : $requested');
      stdout.writeln('  revParse resolved: $resolved');
      if (resolved == null) {
        stdout.writeln('  RESULT: UNRESOLVED');
        return;
      }
      await shorebirdFlutter.installRevision(revision: resolved);

      // 2. the installed checkout, read from disk
      final env = shorebirdEnv.copyWith(flutterRevisionOverride: resolved);
      final dir = env.flutterDirectory;
      stdout.writeln('  installed dir    : ${p.basename(dir.path)}');
      final head = Process.runSync('git', [
        '-C',
        dir.path,
        'rev-parse',
        'HEAD',
      ]).stdout.toString().trim();
      stdout.writeln('  checkout HEAD    : $head');
      final engine = env.shorebirdEngineRevision;
      stdout.writeln('  engine.version   : $engine');

      // 3. and the compiler that engine selects
      try {
        final c = await RouteBCompilerResolver().resolve(
          engineRevision: engine,
        );
        final bundle = File(
          p.join(
            RouteBCompilerResolver.cacheRoot.path,
            'bundles',
            '$engine-route-b-compiler-darwin-arm64.zip',
          ),
        );
        stdout.writeln('  compiler archive : '
            '${sha256.convert(bundle.readAsBytesSync())}');
        stdout.writeln('  dual-kernel      : '
            '${c.supportsDirectSuperDualKernel}');
        stdout.writeln('  RESULT: ACCEPTED');
      } on Object catch (e) {
        stdout.writeln('  RESULT: REFUSED');
        stdout.writeln('    ${'$e'.split('\n').first}');
      }
      stdout.writeln('  REQUESTS:');
      for (final u in recorder.urls) {
        stdout.writeln('    ${u.replaceFirst('http://localhost:8085', '')}');
      }
    },
    values: {
      httpClientRef.overrideWith(() => recorder),
      cacheRef.overrideWith(Cache.new),
      loggerRef.overrideWith(ShorebirdLogger.new),
      shorebirdEnvRef.overrideWith(ShorebirdEnv.new),
      isJsonModeRef.overrideWith(() => false),
      artifactManagerRef.overrideWith(ArtifactManager.new),
      shorebirdFlutterRef.overrideWith(ShorebirdFlutter.new),
      gitRef.overrideWith(Git.new),
    },
  );
}
