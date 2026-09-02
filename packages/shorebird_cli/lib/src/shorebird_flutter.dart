import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/extensions/version.dart';
import 'package:shorebird_cli/src/flutter_version_constraints.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

/// A reference to a [ShorebirdFlutter] instance.
final shorebirdFlutterRef = create(ShorebirdFlutter.new);

/// The [ShorebirdFlutter] instance available in the current zone.
ShorebirdFlutter get shorebirdFlutter => read(shorebirdFlutterRef);

/// {@template shorebird_flutter}
/// Helps manage the Flutter installation used by Shorebird.
/// {@endtemplate}
class ShorebirdFlutter {
  /// {@macro shorebird_flutter}
  const ShorebirdFlutter();

  /// The executable name.
  static const executable = 'flutter';

  /// The Shorebird Flutter fork git URL. Overridable via
  /// `SHOREBIRD_FLUTTER_GIT_URL` so a self-hosted deployment can clone from
  /// its own mirror instead of GitHub.
  static String get flutterGitUrl =>
      platform.environment['SHOREBIRD_FLUTTER_GIT_URL'] ??
      'https://github.com/shorebirdtech/flutter.git';

  /// The `flutter precache` arguments that hydrate the engine artifacts a
  /// release for [releasePlatform] actually needs.
  ///
  /// TARGET-SPECIFIC, and that is a correctness requirement rather than an
  /// optimisation. Precaching unconditionally with `--android` makes an iOS
  /// release depend on Android engine artifacts it will never use, and a cell
  /// that legitimately owns only the iOS toolchain then cannot be installed at
  /// all: `android-arm64-release/` is an overlay-owned path, so a miss is a
  /// loud 404 rather than a silent fall-through. Measured 2026-09-02 against
  /// cell d4c0dbc2 — a macos-ios cell — where it 404'd every fresh install.
  ///
  /// A null [releasePlatform] means "no particular target", which keeps the
  /// historical behaviour for callers that are not installing for a release.
  static List<String> precacheArgsFor(ReleasePlatform? releasePlatform) =>
      switch (releasePlatform) {
        ReleasePlatform.ios => const ['--ios'],
        ReleasePlatform.android => const ['--android'],
        ReleasePlatform.macos => const ['--macos'],
        ReleasePlatform.windows => const ['--windows'],
        ReleasePlatform.linux => const ['--linux'],
        null => ['--android', if (platform.isMacOS) '--ios'],
      };

  /// Arguments to pass to `flutter precache` when no target is specified.
  List<String> get precacheArgs => precacheArgsFor(null);

  String _workingDirectory({String? revision}) {
    revision ??= shorebirdEnv.flutterRevision;
    return p.join(shorebirdEnv.flutterDirectory.parent.path, revision);
  }

  /// Install the provided Flutter [revision], and guarantee that the engine
  /// artifacts a release for [releasePlatform] requires are present.
  ///
  /// THE CONTRACT: selecting a Flutter revision for a target platform
  /// guarantees that platform's engine artifacts exist BEFORE anything tries to
  /// establish engine identity. Directory existence is evidence that a checkout
  /// exists; it is NOT evidence that the target engine exists. Conflating the
  /// two is what this used to do, and it produced a release that refused with
  /// `COHERENCE_UNDETERMINABLE: …/engine/ios-release/gen_snapshot_arm64 is
  /// missing` on a correctly published cell: the bootstrap had created the
  /// checkout and fetched only the Dart SDK, this method saw the directory and
  /// returned, and the coherence gate then correctly reported an absent engine.
  /// Flutter's own lazy download never ran because coherence precedes the build.
  ///
  /// So hydration is UNCONDITIONAL and idempotent — `flutter precache` re-checks
  /// its own stamps cheaply — rather than something that happens only on the
  /// clone path.
  ///
  /// A precache failure is treated as a corrupted install: Flutter's
  /// stamp-based cache will otherwise trust a partial extraction and surface
  /// the missing artifact later as an opaque Gradle error (see
  /// shorebirdtech/shorebird#3783). The user is directed to run
  /// `shorebird cache clean` to start over.
  Future<void> installRevision({
    required String revision,
    ReleasePlatform? releasePlatform,
  }) async {
    final targetDirectory = Directory(_workingDirectory(revision: revision));
    final version = await getVersionForRevision(flutterRevision: revision);
    if (targetDirectory.existsSync()) {
      // Already checked out; still ensure the target engine is present.
      await _precache(
        revision: revision,
        version: version,
        releasePlatform: releasePlatform,
      );
      return;
    }

    final installProgress = logger.progress(
      'Installing Flutter $version (${shortRevisionString(revision)})',
    );

    try {
      // Clone the Shorebird Flutter repo into the target directory.
      await git.clone(
        url: flutterGitUrl,
        outputDirectory: targetDirectory.path,
        args: ['--filter=tree:0', '--no-checkout'],
      );

      // Checkout the correct revision.
      await git.checkout(directory: targetDirectory.path, revision: revision);
      installProgress.complete();
    } catch (error) {
      final short = shortRevisionString(revision);
      installProgress.fail('Failed to install Flutter $version ($short)');
      logger.err('$error');
      rethrow;
    }

    await _precache(
      revision: revision,
      version: version,
      releasePlatform: releasePlatform,
    );
  }

  /// Hydrate [revision]'s engine artifacts for [releasePlatform].
  ///
  /// Runs the TARGET revision's own `flutter` binary, not the pinned one. The
  /// pinned binary resolves its own `engine.version`, so using it while
  /// installing a different revision asked the CDN for the wrong engine's
  /// artifacts — measured while installing F3 (`ab29aee0`), which requested
  /// paths under the previous cell.
  Future<void> _precache({
    required String revision,
    required String? version,
    required ReleasePlatform? releasePlatform,
  }) async {
    final targetDirectory = Directory(_workingDirectory(revision: revision));
    final precacheProgress = logger.progress(
      'Running ${lightCyan.wrap('flutter precache')}',
    );

    // The revision's own binary, via the env's existing accessor rather than
    // re-deriving the platform-specific name here.
    final targetFlutter = shorebirdEnv
        .copyWith(flutterRevisionOverride: revision)
        .flutterBinaryFile
        .path;
    final precacheArguments = [
      'precache',
      ...precacheArgsFor(releasePlatform),
    ];
    final ShorebirdProcessResult result;
    try {
      result = await process.run(
        targetFlutter,
        precacheArguments,
        workingDirectory: targetDirectory.path,
        useVendedFlutter: false,
      );
    } on Exception catch (error) {
      precacheProgress.fail('Failed to precache Flutter $version');
      throw CacheCorruptedException(
        'Failed to precache Flutter $version: $error.',
      );
    }
    if (result.exitCode != ExitCode.success.code) {
      precacheProgress.fail('Failed to precache Flutter $version');
      final stderr = '${result.stderr}'.trim();
      throw CacheCorruptedException(
        'flutter precache exited with code ${result.exitCode}: $stderr.',
      );
    }
    precacheProgress.complete();
  }

  /// Whether the current revision is unmodified.
  Future<bool> isUnmodified({String? revision}) async {
    final status = await git.status(
      directory: _workingDirectory(revision: revision),
      args: ['--untracked-files=no', '--porcelain'],
    );
    return status.isEmpty;
  }

  /// Returns the current system Flutter version.
  /// Throws a [ProcessException] if the version check fails.
  /// Returns `null` if the version check succeeds but the version cannot be
  /// parsed.
  Future<String?> getSystemVersion() async {
    const args = ['--version'];
    final result = await process.run(executable, args, useVendedFlutter: false);

    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        args,
        '${result.stderr}',
        result.exitCode,
      );
    }

    final output = result.stdout.toString();
    final flutterVersionRegex = RegExp(r'Flutter (\d+.\d+.\d+)');
    final match = flutterVersionRegex.firstMatch(output);

    return match?.group(1);
  }

  /// Executes `flutter config --list` and returns the output as a map.
  Map<String, dynamic> getConfig() {
    final args = ['config', '--list'];
    final result = process.runSync(executable, args);
    // Gracefully handle errors (e.g. older Flutter versions that don't support
    // `flutter config --list`).
    if (result.exitCode != ExitCode.success.code) return <String, dynamic>{};
    final output = '${result.stdout}';
    final config = <String, dynamic>{};
    final lines = LineSplitter.split(output).toList();
    for (final line in lines.skip(1)) {
      final index = line.indexOf(':');
      if (index == -1) continue;
      final key = line.substring(0, index).trim();
      final value = line.substring(index + 1).trim();
      config[key] = value;
    }
    return config;
  }

  /// Converts a full git revision to a short revision string.
  String shortRevisionString(String revision) => revision.substring(0, 10);

  /// Given a revision and a version, formats them into a single string.
  ///
  /// e.g. 3.16.3 and b9b2390296b9b2390296 -> 3.16.3 (b9b2390296)
  String formatVersion({required String revision, required String? version}) {
    version ??= 'unknown';
    return '$version (${shortRevisionString(revision)})';
  }

  /// Returns the current Shorebird Flutter version and revision.
  /// Returns unknown if the version check fails.
  Future<String> getVersionAndRevision() async {
    late final String? version;

    try {
      version = await getVersionString();
    } on Exception {
      version = 'unknown';
    }

    return formatVersion(
      version: version,
      revision: shorebirdEnv.flutterRevision,
    );
  }

  /// Returns the current Shorebird Flutter version.
  /// Throws a [ProcessException] if the version check fails.
  /// Returns `null` if the version check succeeds but the version cannot be
  /// parsed.
  Future<String?> getVersionString() async {
    final flutterRevision = shorebirdEnv.flutterRevision;
    return getVersionForRevision(flutterRevision: flutterRevision);
  }

  /// The current Shorebird Flutter version as a [Version]. Returns null if the
  /// version cannot be parsed.
  Future<Version?> getVersion() async {
    final versionString = await getVersionString();
    if (versionString == null) {
      return null;
    }

    final Version version;
    try {
      version = Version.parse(versionString);
    } on FormatException {
      return null;
    }

    return version;
  }

  /// Returns the human readable version for a given git revision
  /// e.g. b9b2390296b9b2390296 -> 3.16.3
  Future<String?> getVersionForRevision({
    required String flutterRevision,
  }) async {
    final result = await git.forEachRef(
      contains: flutterRevision,
      format: '%(refname:short)',
      pattern: 'refs/remotes/origin/flutter_release/*',
      directory: _workingDirectory(),
    );

    return LineSplitter.split(result)
        .map((e) => e.replaceFirst('origin/flutter_release/', ''))
        .toList()
        .firstOrNull;
  }

  /// Pattern for a valid git hash (4-40 hex characters).
  /// Git allows short hashes as long as they're unambiguous.
  static final _gitHashPattern = RegExp(r'^[0-9a-fA-F]{4,40}$');

  /// Translates [versionOrHash] into a Flutter revision. If this is a semver
  /// version, it will look up the git revision for that version. If not, it
  /// will check if it's a valid git hash that exists in the local Flutter repo.
  ///
  /// Returns the full hash if valid, or null if it's neither a valid semver
  /// version nor a valid git hash that exists locally.
  Future<String?> resolveFlutterRevision(String versionOrHash) async {
    final parsedVersion = tryParseVersion(versionOrHash);
    if (parsedVersion != null) {
      return getRevisionForVersion(versionOrHash);
    }

    // If we were unable to parse the version, check if it's a valid git hash.
    if (!_gitHashPattern.hasMatch(versionOrHash)) {
      return null;
    }

    // Verify the hash exists locally by resolving it to its full hash.
    try {
      final fullHash = await git.revParse(
        revision: versionOrHash,
        directory: _workingDirectory(),
      );
      return fullHash;
    } on ProcessException {
      return null;
    }
  }

  /// Translates [versionOrHash] into a Flutter [Version]. If [versionOrHash]
  /// is semver version string, it will simply parse that into a [Version]. If
  /// not, it will assume that the input is a git commit hash and attempt to
  /// map it to a Flutter version.
  Future<Version?> resolveFlutterVersion(String versionOrHash) async {
    final parsedVersion = tryParseVersion(versionOrHash);
    if (parsedVersion != null) {
      return parsedVersion;
    }

    try {
      // If we were unable to parse the version, assume it's a revision hash.
      final versionString = await getVersionForRevision(
        flutterRevision: versionOrHash,
      );
      return versionString != null ? tryParseVersion(versionString) : null;
    } on Exception {
      return null;
    }
  }

  /// Whether `gen_snapshot` should be invoked with `--strip` for a build
  /// targeting [platform] on the Flutter pin identified by [flutterRevision].
  ///
  /// On non-Android platforms (iOS, macOS, Linux, Windows, iOS framework,
  /// AAR), AGP is not in the pipeline, so we always pre-strip in gen_snapshot.
  ///
  /// On Android, the answer depends on the Flutter version: from 3.44 onward
  /// AGP performs the strip and emits the matching `.sym` companion;
  /// pre-stripping in gen_snapshot on those versions leaves AGP with nothing
  /// to strip and trips flutter_tools' post-build verification. See
  /// [libappStrippedByAgpConstraint].
  ///
  /// An unresolvable [flutterRevision] (e.g. a development branch) is treated
  /// as satisfying the constraint, since the alternative — pre-stripping —
  /// would fail the post-build check on any 3.44+ pin.
  Future<bool> shouldPreStripLibappInGenSnapshot({
    required ReleasePlatform platform,
    required String flutterRevision,
  }) async {
    if (platform != ReleasePlatform.android) return true;
    final version = await resolveFlutterVersion(flutterRevision);
    return !libappStrippedByAgpConstraint.isSatisfiedBy(
      version: version ?? libappStrippedByAgpConstraint.minVersion,
      revision: flutterRevision,
    );
  }

  /// Fetches the latest remote refs for the Flutter clone so that
  /// release branch pointers (e.g. `flutter_release/3.38.5`) are up to date.
  Future<void> fetchRemoteRefs() async {
    try {
      await git.fetch(directory: _workingDirectory());
    } on Exception {
      logger.warn(
        'Failed to fetch latest Flutter versions. '
        'Resolving with potentially stale data.',
      );
    }
  }

  /// Returns the git revision for the provided [version].
  /// e.g. 3.16.3 -> b9b23902966504a9778f4c07e3a3487fa84dcb2a
  Future<String?> getRevisionForVersion(String version) async {
    try {
      final result = await git.revParse(
        revision: 'refs/remotes/origin/flutter_release/$version',
        directory: _workingDirectory(),
      );
      return LineSplitter.split(result).toList().firstOrNull;
    } on ProcessException {
      return null;
    }
  }

  /// Get the list of Flutter versions for the given [revision].
  Future<List<String>> getVersions({String? revision}) async {
    final result = await git.forEachRef(
      format: '%(refname:short)',
      pattern: 'refs/remotes/origin/flutter_release/*',
      directory: _workingDirectory(revision: revision),
    );
    return LineSplitter.split(
      result,
    ).map((e) => e.replaceFirst('origin/flutter_release/', '')).toList();
  }
}
