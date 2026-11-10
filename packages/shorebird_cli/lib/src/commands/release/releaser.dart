import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/build_flags.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/dd_support.dart';
import 'package:shorebird_cli/src/code_signer.dart';
import 'package:shorebird_cli/src/command_error.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/flutter_version_constraints.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/metadata/metadata.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/split_debug_info.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

export 'package:pub_semver/pub_semver.dart';

/// {@template releaser}
/// Executes platform-specific functionality to create a release.
/// {@endtemplate}
abstract class Releaser {
  /// {@macro releaser}
  Releaser({
    required this.argResults,
    required this.flavor,
    required this.target,
  });

  /// The arguments passed to the command.
  final ArgResults argResults;

  /// The flavor of the release, if any. This is the --flavor argument passed to
  /// the release command.
  final String? flavor;

  /// The target script to run, if any. This is the --target argument passed to
  /// the release command.
  final String? target;

  /// The minimum Flutter version required to create a release of this type.
  Version get minimumFlutterVersion =>
      minimumReleaseFlutterVersion(releaseType);

  /// The type of artifact we are creating a release for.
  ReleaseType get releaseType;

  /// The root directory of the current project.
  Directory get projectRoot => shorebirdEnv.getShorebirdProjectRoot()!;

  /// The human-readable description of the release artifact being built (e.g.,
  /// "Android app", "iOS app").
  String get artifactDisplayName;

  /// Asserts that the command can be run.
  Future<void> assertPreconditions();

  /// Asserts that the combination arguments passed to the command are valid.
  Future<void> assertArgsAreValid();

  /// Requires `--release-version` with a concrete version, for add-to-app
  /// releases (aar, ios-framework), whose version cannot be read from the
  /// built module: it is the version of the app that embeds the module.
  /// Rejects a missing, blank or `latest` value.
  void assertReleaseVersionProvided() {
    final value = (argResults['release-version'] as String?)?.trim();
    if (value != null && value.isNotEmpty && value != 'latest') return;

    final hostPlatform = releaseType.releasePlatform.displayName;
    throw CommandError(
      message:
          'An ${releaseType.cliName} release needs --release-version: the '
          'version of the $hostPlatform app that embeds this module.',
      hint: 'Run: ${releaseType.releaseCommand()}',
    );
  }

  /// Rejects `--release-version`, which is only valid for releases whose
  /// version cannot be inferred from the built artifact (aar, ios-framework).
  /// Call from [assertArgsAreValid] in releasers that read the version from
  /// the built app.
  void assertReleaseVersionFlagNotProvided() {
    if (argResults.wasParsed('release-version')) {
      throw CommandError(
        message:
            '--release-version is only supported for aar and ios-framework '
            'releases.',
        hint:
            'Remove --release-version. This release takes its version from '
            'your pubspec.yaml.',
      );
    }
  }

  /// Builds the release artifacts for the given platform. Returns the "primary"
  /// artifact for the platform (e.g. the AAB for Android, the IPA for iOS).
  ///
  /// Implementations run their Flutter build through [runReleaseBuild].
  Future<FileSystemEntity> buildReleaseArtifacts();

  /// Runs a release's Flutter [build] with the arguments every release build
  /// shares, then checks the build produced what those arguments promised.
  ///
  /// Before building, [clearSupplementDirectory] removes the previous build's
  /// supplement output. [build] receives the user's forwarded arguments plus
  /// the `--split-debug-info` default and obfuscation map options (see
  /// [addSplitDebugInfoDefault] and [addObfuscationMapArgs]), and the encoded
  /// public key (see [resolvePatchSigningKey]). Once it returns,
  /// [verifyObfuscationMap] checks that an obfuscated build saved its
  /// obfuscation map.
  Future<T> runReleaseBuild<T>(
    Future<T> Function(List<String> buildArgs, String? base64PublicKey) build,
  ) async {
    clearSupplementDirectory();
    final base64PublicKey = await resolvePatchSigningKey();
    final buildArgs = [...argResults.forwardedArgs];
    addSplitDebugInfoDefault(buildArgs);
    await addObfuscationMapArgs(buildArgs);
    final result = await build(buildArgs, base64PublicKey);
    verifyObfuscationMap();
    return result;
  }

  /// Uploads the release artifacts to the CodePush server.
  ///
  /// The supplement artifact is uploaded separately, by
  /// [uploadSupplementArtifact].
  Future<void> uploadReleaseArtifacts({
    required Release release,
    required String appId,
  });

  /// Creates a copy of [metadata] with releaser-specific fields updated.
  Future<UpdateReleaseMetadata> updatedReleaseMetadata(
    UpdateReleaseMetadata metadata,
  ) async {
    return metadata;
  }

  /// Instructions explaining next steps after running `shorebird release`. This
  /// could include how to upload the generated artifact to a store and how to
  /// patch the release.
  String get postReleaseInstructions;

  /// Extracts the release version from the compiled artifact.
  ///
  /// We extract the release version from the compiled artifact because we can
  /// be 100% certain that the artifact will report that same number when making
  /// patch check requests.
  Future<String> getReleaseVersion({
    required FileSystemEntity releaseArtifactRoot,
  });

  /// Gets the base64-encoded public key from either file or command.
  ///
  /// Returns null if no public key is configured.
  Future<String?> getEncodedPublicKey() => argResults.getEncodedPublicKey();

  /// How this platform's build is signed for patch signing. Set by
  /// [resolvePatchSigningKey]; null until the build runs.
  ArtifactSigningRequest? signing;

  /// Decides which public key this platform's build embeds, sets [signing]
  /// to match, and returns the key base64-encoded, or null if the build
  /// embeds none.
  ///
  /// A key passed with --public-key-path or --public-key-cmd is the
  /// customer's, who signs every patch. Otherwise the build embeds the
  /// managed key the server returns for the app, and Shorebird signs every
  /// patch; a failed fetch fails the release, so it never silently goes
  /// unsigned. With --no-patch-signing the build embeds no key.
  Future<String?> resolvePatchSigningKey() async {
    final customerKey = await getEncodedPublicKey();
    if (customerKey != null) {
      signing = const ArtifactSigningRequest(
        mode: ReleaseSigningMode.customer,
      );
      return customerKey;
    }
    // A server Shorebird does not host (a self-hosted control plane) has no
    // Shorebird-managed signing key to hand out, so only a key of the
    // customer's own can sign there. Without one the release is built
    // unsigned, as with --no-patch-signing, rather than failing on the fetch.
    if (!argResults.patchSigningEnabled ||
        shorebirdEnv.hostedEnvironment == null) {
      signing = const ArtifactSigningRequest(
        mode: ReleaseSigningMode.unsigned,
      );
      return null;
    }
    final SigningKey signingKey;
    try {
      signingKey = await codePushClientWrapper.getSigningKey(
        appId: shorebirdEnv.getShorebirdYaml()!.getAppId(flavor: flavor),
      );
    } on ProcessExit {
      // The fetch already said why it failed; say what the user can do.
      logger.info(
        'Releases embed a Shorebird-managed patch signing key by default. '
        'To release without one (patches will be unsigned), pass '
        '--no-${CommonArguments.patchSigningArg.name}.',
      );
      rethrow;
    }
    signing = ArtifactSigningRequest(
      mode: ReleaseSigningMode.managed,
      keyId: signingKey.id,
    );
    return codeSigner.base64PublicKeyFromPem(signingKey.publicKeyPem);
  }

  /// Whether the user is building with obfuscation. Checks for `--obfuscate`
  /// both as a parsed flag and after the `--` separator, since it can be
  /// passed either to Shorebird directly or forwarded to Flutter.
  bool get useObfuscation => argResults.flagPresent('obfuscate');

  /// DD table cascade byte threshold for the release build.
  ///
  /// Passed to Flutter tools via the SHOREBIRD_DD_MAX_BYTES environment
  /// variable for backwards compatibility: older Flutter builds that don't
  /// recognize the variable will silently ignore it, whereas an unknown
  /// command-line flag would cause a build failure.
  ///
  /// The CLI option (`--dd-max-bytes`) carries `defaultsTo: '10000'`, so the
  /// default-enabled case arrives here as the string `'10000'`. We rely on
  /// the option-parsing default rather than re-defaulting null here, so
  /// callers that explicitly stub `argResults['dd-max-bytes']` to null
  /// (e.g. tests, programmatic invocations) get DD-disabled rather than
  /// silently re-enabled.
  ///
  /// Returns null when DD should be disabled: the option is absent, or the
  /// value is `0` (the user's "disable DD" knob), or the value is malformed,
  /// or the engine in use cannot run the DD pass at all.
  int? get ddMaxBytes {
    final value = argResults[CommonArguments.ddMaxBytesArg.name] as String?;
    if (value == null) return null;
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) return null;

    // An engine built from vanilla Dart has no DD support, and every failure
    // inside Flutter's DD pass is fatal — the build dies with
    // "Unrecognized flags: print_dd_function_identity_to", which sends you
    // looking in the wrong layer. Turn it off ourselves instead of making
    // every user of such an engine know to pass --dd-max-bytes=0.
    final genSnapshot = ddGenSnapshotArtifact;
    if (genSnapshot != null && !ddSupport.isSupportedBy(genSnapshot)) {
      logger.detail(
        '''This engine's gen_snapshot does not support the DD pass; building without it (equivalent to --dd-max-bytes=0). Patches against this release compute DD on the fly when applied.''',
      );
      return null;
    }
    return parsed;
  }

  /// The `gen_snapshot` whose DD support decides whether [ddMaxBytes] applies,
  /// or null for platforms where Flutter never runs the DD pass.
  ///
  /// Flutter gates the pass on `usesLinker`, which is Apple-only, so only the
  /// Apple releasers override this.
  ShorebirdArtifact? get ddGenSnapshotArtifact => null;

  /// Path where the obfuscation map is saved during obfuscated builds: the
  /// user's own `--save-obfuscation-map` path if they passed one (relative
  /// paths are resolved against the project root, where Flutter builds), or
  /// `build/shorebird/obfuscation_map.json` otherwise.
  String get obfuscationMapPath {
    final userPath = userObfuscationMapPath;
    if (userPath != null) {
      return p.normalize(p.join(projectRoot.path, userPath));
    }
    return p.join(
      projectRoot.path,
      'build',
      'shorebird',
      'obfuscation_map.json',
    );
  }

  /// The path the user passed to gen_snapshot's `--save-obfuscation-map`
  /// through `--extra-gen-snapshot-options`, or null if they didn't.
  ///
  /// Flutter splits `--extra-gen-snapshot-options` values on commas, and
  /// gen_snapshot honors the last `--save-obfuscation-map`, so this returns
  /// the last one.
  String? get userObfuscationMapPath {
    const extraOptionsPrefix = '--extra-gen-snapshot-options=';
    const saveMapPrefix = '--save-obfuscation-map=';
    String? path;
    for (final arg in argResults.forwardedArgs) {
      final value = arg.startsWith(extraOptionsPrefix)
          ? arg.substring(extraOptionsPrefix.length)
          : arg;
      for (final option in value.split(',')) {
        if (option.startsWith(saveMapPrefix)) {
          path = option.substring(saveMapPrefix.length);
        }
      }
    }
    return path;
  }

  /// Auto-adds --split-debug-info when --obfuscate is used without it.
  void addSplitDebugInfoDefault(List<String> buildArgs) {
    final splitDebugInfo = splitDebugInfoDefault(
      obfuscate: useObfuscation,
      hasSplitDebugInfo: buildArgs.any(
        (a) => a.startsWith('--split-debug-info'),
      ),
    );
    if (splitDebugInfo != null) buildArgs.add(splitDebugInfo);
  }

  /// Adds obfuscation-related gen_snapshot options to [buildArgs].
  ///
  /// When obfuscation is enabled, passes --save-obfuscation-map to capture
  /// the mapping, unless the user passed their own (see
  /// [userObfuscationMapPath]), which is kept and read from instead, since
  /// gen_snapshot writes only one map. Conditionally passes --strip to
  /// remove unobfuscated DWARF debugging information from the compiled
  /// snapshot, since the DWARF sections would otherwise leak identifiers
  /// that obfuscation was meant to hide.
  ///
  /// On Android, --strip is only passed for Flutter versions older than
  /// 3.44. From 3.44 onward, upstream Flutter PR
  /// https://github.com/flutter/flutter/pull/181275 (merged 2026-01-26)
  /// made AGP responsible for stripping `libapp.so` and emitting the
  /// matching `.sym` companion into the AAB's BUNDLE-METADATA. Passing
  /// --strip to gen_snapshot on 3.44+ pre-strips the snapshot, leaving AGP
  /// with nothing to strip. flutter_tools then fails the build with
  /// "libapp.so.sym or libapp.so.dbg not present when checking final
  /// appbundle for debug symbols." Letting AGP do the stripping preserves
  /// the obfuscation protection in the user-shipped APK (AGP uses
  /// `llvm-strip --strip-unneeded`, which removes the same DWARF sections
  /// that gen_snapshot --strip would have), while restoring the `.sym`
  /// companion that 3.44 requires. The `.sym` file containing the
  /// pre-strip DWARF is only retained in BUNDLE-METADATA, which Play
  /// strips before delivery to end-user devices, so the only readers are
  /// the developer's own Play Console crash dashboard.
  ///
  /// On non-Android platforms (iOS, macOS, Linux, Windows, iOS framework,
  /// AAR), AGP is not in the pipeline, so --strip is always passed
  /// regardless of Flutter version.
  Future<void> addObfuscationMapArgs(List<String> buildArgs) async {
    if (!useObfuscation) return;
    final mapDir = Directory(p.dirname(obfuscationMapPath));
    if (!mapDir.existsSync()) mapDir.createSync(recursive: true);
    if (userObfuscationMapPath == null) {
      buildArgs.add(
        '--extra-gen-snapshot-options='
        '--save-obfuscation-map=$obfuscationMapPath',
      );
    }

    final shouldPreStripInGenSnapshot = await shorebirdFlutter
        .shouldPreStripLibappInGenSnapshot(
          platform: releaseType.releasePlatform,
          flutterRevision: shorebirdEnv.flutterRevision,
        );

    if (shouldPreStripInGenSnapshot) {
      buildArgs.add('--extra-gen-snapshot-options=--strip');
    }
  }

  /// Platform subdirectory for the supplement directory (e.g. 'android',
  /// 'ios'). Used to construct `build/<platformSubdir>/shorebird/`.
  String get supplementPlatformSubdir;

  /// Arch string for the supplement artifact on the server (e.g.
  /// 'android_supplement').
  String get supplementArtifactArch;

  /// The filename a release's effective build configuration is recorded under
  /// inside the supplement.
  static const buildConfigFileName = 'build_config.json';

  /// Records this release's EFFECTIVE build configuration into the supplement,
  /// so a later patch can be compared against it.
  ///
  /// THE CONTRACT, stated explicitly because the alternative is an accident:
  /// **every modern release records a build config**, and the three states are
  /// kept distinguishable on purpose —
  ///
  ///   file absent          the release predates this contract. A patch cannot
  ///                        compare, and must say so rather than assume it
  ///                        matches.
  ///   `buildConfig` object the effective configuration. Comparable.
  ///   `buildConfig: null`  the configuration is UNFINGERPRINTABLE — a file
  ///                        passed to `--dart-define-from-file` could not be
  ///                        read or parsed, so the effective define set is
  ///                        unknown. Comparable to nothing, and that is itself
  ///                        information.
  ///
  /// **The third state used to mean "`--dart-define-from-file` was used at
  /// all"**, and now means only that its files could not be resolved: the
  /// option is expanded by `dart_define_from_file.dart`.
  ///
  /// ONE LIMIT, NAMED RATHER THAN IMPLIED. On iOS the expansion is checked
  /// against Flutter's own resolved `DART_DEFINES` for the same build
  /// (`ios_releaser._defineExpansionDisagreement`). **On Android there is no
  /// equivalent artifact to check against** — Flutter hands the resolved set to
  /// Gradle as a `-Pdart-defines` argument and writes it nowhere — so the
  /// Android fingerprint uses the expansion unverified. Release and patch run
  /// the same expansion, so a mismatch between them is still detected; what is
  /// not detected is a port error that maps two genuinely different files to the
  /// same defines on both sides.
  ///
  /// Recording the third state explicitly is the point: "absent" and "unknown"
  /// have different remediations, and collapsing them is how a patch silently
  /// skips the check it was supposed to run.
  ///
  /// The shape mirrors `route_b_provenance.json`'s `buildConfig` key so that
  /// promoting this into a platform-neutral contract later is a MOVE rather
  /// than a translation.
  void recordEffectiveBuildConfig(List<String> buildArgs) {
    final supplementDir = artifactManager.getReleaseSupplementDirectory(
      platformSubdir: supplementPlatformSubdir,
      create: true,
    );
    // No project root: nothing downstream could upload a supplement anyway.
    if (supplementDir == null) return;

    final config = RouteBBuildConfig.fromBuildArgs(buildArgs, flavor: flavor);
    File(p.join(supplementDir.path, buildConfigFileName)).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'buildConfig': config?.toJson(),
        if (config == null)
          'unfingerprintableReason':
              'the effective define set could not be determined — a file '
              'passed to --dart-define-from-file could not be read or parsed '
              '(see dart_define_from_file.dart)',
      }),
    );
    logger.detail(
      config == null
          ? '[build-config] recorded UNFINGERPRINTABLE configuration'
          : '[build-config] recorded fingerprint ${config.fingerprint}',
    );
  }

  /// Deletes `build/<supplementPlatformSubdir>/shorebird/` if it exists, so
  /// that files a previous build left there (e.g. link supplements written by
  /// an older Flutter that did not clear the directory itself) cannot be
  /// uploaded as part of this release.
  void clearSupplementDirectory() {
    final supplementDir = Directory(
      p.join(projectRoot.path, 'build', supplementPlatformSubdir, 'shorebird'),
    );
    if (!supplementDir.existsSync()) return;
    logger.detail('Deleting stale supplement directory ${supplementDir.path}');
    supplementDir.deleteSync(recursive: true);
  }

  /// Assembles the supplement directory: copies the obfuscation map (if
  /// present) into the platform supplement dir and writes the release's
  /// [BuildFlags]. Returns the directory, or null if there's no project.
  Directory? assembleSupplementDirectory() {
    final obfuscationMapFile = File(obfuscationMapPath);
    final hasObfuscationMap = useObfuscation && obfuscationMapFile.existsSync();
    final supplementDir = artifactManager.getReleaseSupplementDirectory(
      platformSubdir: supplementPlatformSubdir,
      create: true,
    );
    if (supplementDir == null) return null;

    final targetMapFile = File(
      p.join(supplementDir.path, 'obfuscation_map.json'),
    );
    if (hasObfuscationMap) {
      obfuscationMapFile.copySync(targetMapFile.path);
    } else if (targetMapFile.existsSync()) {
      // Remove stale obfuscation map from a previous obfuscated build so that
      // the supplement doesn't incorrectly signal that this release was
      // obfuscated.
      logger.detail(
        'Removing stale obfuscation map from supplement directory. '
        'If this release should be obfuscated, re-run with --obfuscate.',
      );
      targetMapFile.deleteSync();
    }

    // The build already read every --dart-define-from-file, so this reads
    // them again only to hash them.
    File(
      p.join(supplementDir.path, BuildFlags.fileName),
    ).writeAsStringSync(
      json.encode(BuildFlags.fromArgs(argResults, target: target).toJson()),
    );

    return supplementDir;
  }

  /// Uploads the supplement artifact (e.g. obfuscation map) if one was
  /// assembled. `shorebird release` calls this right after
  /// [uploadReleaseArtifacts].
  ///
  /// Both uploads run while the release is a draft on this platform, and
  /// `shorebird patch` refuses a release that is not active on its platform.
  /// A run stopped between them leaves a release nothing can patch until it
  /// is released again.
  Future<void> uploadSupplementArtifact({
    required String appId,
    required int releaseId,
  }) async {
    final supplementDir = assembleSupplementDirectory();
    if (supplementDir != null) {
      await codePushClientWrapper.createSupplementReleaseArtifact(
        appId: appId,
        releaseId: releaseId,
        platform: releaseType.releasePlatform,
        supplementDirectoryPath: supplementDir.path,
        arch: supplementArtifactArch,
        signing: signing,
      );
    }
  }

  /// Verifies the obfuscation map was generated after build.
  void verifyObfuscationMap() {
    if (!useObfuscation) return;
    final mapFile = File(obfuscationMapPath);
    if (!mapFile.existsSync()) {
      throw CommandError(
        message:
            'Obfuscation was enabled but the obfuscation map was not '
            'generated at $obfuscationMapPath.',
        hint: 'Re-run with --verbose to see the build output.',
        exitCode: ExitCode.software,
      );
    }
    logger.detail('Obfuscation map saved to $obfuscationMapPath');
  }
}
