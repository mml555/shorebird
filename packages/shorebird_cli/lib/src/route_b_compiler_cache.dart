// Route B (selfhost): getting a compiler cell onto this machine, so
// [resolveRouteBCompiler] has something to validate.
//
// Deliberately NOT a `CachedArtifact`. Every one of those keys its storage URL
// on `shorebirdEnv.shorebirdEngineRevision` — the engine this machine is
// currently set up to build with — and `Cache.updateAll()` fetches all of them
// eagerly. Both are wrong here: the cell must be keyed on the engine that built
// the RELEASE being patched, and it must be fetched only when a Route B patch
// is actually being produced.
import 'dart:ffi' show Abi;
import 'dart:io' hide Platform;

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/abi.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/http_client/http_client.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';

/// A reference to a [RouteBCompilerResolver] instance.
final routeBCompilerResolverRef = create(RouteBCompilerResolver.new);

/// The [RouteBCompilerResolver] instance available in the current zone.
RouteBCompilerResolver get routeBCompilerResolver =>
    read(routeBCompilerResolverRef);

/// The compiler cell for an engine could not be downloaded.
///
/// Deliberately outside [RouteBCompilerProblem]: that enum says something about
/// the CELL — never published, or published and corrupt — and an unreachable
/// host says neither. Filing a network failure under either one would send
/// someone to republish tooling that is fine, or to cut a release that would
/// not help.
class RouteBCompilerDownloadException implements Exception {
  /// {@macro route_b_compiler_download_exception}
  RouteBCompilerDownloadException(this.message);

  /// A message naming the URL that could not be reached.
  final String message;

  @override
  String toString() => message;
}

/// {@template route_b_compiler_resolver}
/// Downloads and validates the Route B compiler cell for a given engine.
/// {@endtemplate}
class RouteBCompilerResolver {
  /// {@macro route_b_compiler_resolver}
  RouteBCompilerResolver();

  /// The cache directory holding downloaded bundles and validated cells.
  static Directory get cacheRoot =>
      cache.getArtifactDirectory('route-b-compiler');

  /// Resolve the compiler cell that built the release identified by
  /// [engineRevision].
  ///
  /// Throws [RouteBCompilerException] when the cell is unavailable or invalid,
  /// and [RouteBCompilerDownloadException] when it could not be fetched.
  Future<RouteBCompiler> resolve({required String engineRevision}) async {
    final root = cacheRoot;
    return resolveRouteBCompiler(
      engineHash: engineRevision,
      cacheRoot: root,
      fetchBundle: (hash) => _fetchBundle(hash, root),
      extractTo: (archive, destination) => artifactManager.extractZip(
        zipFile: archive,
        outputDirectory: destination,
      ),
    );
  }

  /// The bundle's platform-specific name, e.g. `route-b-compiler-darwin-arm64`.
  ///
  /// Names the HOST that will run the compiler, not the target being patched:
  /// `dartaotruntime` and `dart2bytecode.aot` execute here.
  static String get bundleFileName {
    final String slug;
    if (platform.isMacOS) {
      slug = abi.current == Abi.macosArm64 ? 'darwin-arm64' : 'darwin-x64';
    } else if (platform.isLinux) {
      slug = 'linux-x64';
    } else {
      slug = 'windows-x64';
    }
    return 'route-b-compiler-$slug.zip';
  }

  Future<File?> _fetchBundle(String engineHash, Directory root) async {
    // Kept out of `<root>/<engineHash>`: that path is the validated cell, and
    // resolveRouteBCompiler deletes and re-creates it on every promotion.
    final cached = File(
      p.join(root.path, 'bundles', '$engineHash-$bundleFileName'),
    );
    if (cached.existsSync()) {
      logger.detail('[route-b] using cached compiler bundle ${cached.path}');
      return cached;
    }

    final url =
        '${cache.storageBaseUrl}/${cache.storageBucket}/shorebird/'
        '$engineHash/$bundleFileName';

    final http.StreamedResponse response;
    try {
      response = await httpClient.send(http.Request('GET', Uri.parse(url)));
    } on Exception catch (error) {
      throw RouteBCompilerDownloadException(
        'Could not reach $url to download the Route B compiler for engine '
        '$engineHash: $error',
      );
    }

    // 404 is the one status that means something specific: nothing was ever
    // published for this engine. Returning null lets the resolver report that
    // as "tooling unavailable" rather than as a download failure.
    if (response.statusCode == HttpStatus.notFound) {
      logger.detail('[route-b] no compiler bundle at $url (404)');
      return null;
    }
    if (response.statusCode != HttpStatus.ok) {
      throw RouteBCompilerDownloadException(
        'Failed to download the Route B compiler for engine $engineHash from '
        '$url: ${response.statusCode} ${response.reasonPhrase}',
      );
    }

    // Download to a temporary name and rename into place, so an interrupted
    // download cannot be picked up as a cached bundle by the next run.
    final partial = File('${cached.path}.partial')..createSync(recursive: true);
    final progress = logger.progress(
      'Downloading Route B compiler for engine ${engineHash.substring(0, 8)}',
    );
    try {
      await response.stream.pipe(partial.openWrite());
    } on Exception catch (error) {
      progress.fail();
      if (partial.existsSync()) partial.deleteSync();
      throw RouteBCompilerDownloadException(
        'Failed to download the Route B compiler for engine $engineHash from '
        '$url: $error',
      );
    }
    partial.renameSync(cached.path);
    progress.complete();

    return cached;
  }
}
