// Drives the PRODUCTION RouteBCompilerResolver against the real CDN, from an
// empty compiler cache. Not a re-implementation: it constructs the same scoped
// dependencies the CLI does and calls resolve().
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/http_client/http_client.dart';
import 'package:shorebird_cli/src/json_output.dart';
import 'package:shorebird_cli/src/logging/shorebird_logger.dart';
import 'package:shorebird_cli/src/route_b_compiler_cache.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

/// Counts every request the resolver makes, so ORDERING is observed rather
/// than assumed.
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
  final engine = args[0];
  final root = Directory(args[1]);
  final recorder = _Recording(http.Client());

  await runScoped(() async {
    stdout.writeln('  cacheRoot path         : '
        '${RouteBCompilerResolver.cacheRoot.path}');
    final resolver = RouteBCompilerResolver();
    try {
      final compiler = await resolver.resolve(engineRevision: engine);
      stdout.writeln('RESULT: ACCEPTED');
      stdout.writeln('  dual-kernel capability : '
          '${compiler.supportsDirectSuperDualKernel}');
      final bundle = File(p.join(root.path, 'bundles',
          '$engine-route-b-compiler-darwin-arm64.zip'));
      if (bundle.existsSync()) {
        stdout.writeln('  bundle archive sha256  : '
            '${sha256.convert(bundle.readAsBytesSync())}');
      }
      final prov = File(p.join(root.path, engine, 'PROVENANCE.txt'));
      if (prov.existsSync()) {
        final line = prov
            .readAsLinesSync()
            .firstWhere((l) => l.startsWith('engine revision'), orElse: () => '');
        stdout.writeln('  producer lineage       : ${line.split(':').last.trim()}');
      }
    } on Object catch (e) {
      stdout.writeln('RESULT: REFUSED');
      stdout.writeln('  $e'.split('\n').take(3).join('\n  '));
    }
    stdout.writeln('REQUESTS (in order):');
    for (final u in recorder.urls) {
      stdout.writeln('  ${u.replaceFirst('http://localhost:8085', '')}');
    }
  }, values: {
    httpClientRef.overrideWith(() => recorder),
    cacheRef.overrideWith(Cache.new),
    loggerRef.overrideWith(ShorebirdLogger.new),
    shorebirdEnvRef.overrideWith(ShorebirdEnv.new),
    isJsonModeRef.overrideWith(() => false),
    artifactManagerRef.overrideWith(ArtifactManager.new),
  });
}
