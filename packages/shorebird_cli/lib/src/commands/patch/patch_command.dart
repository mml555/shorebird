import 'dart:io';
import 'dart:convert';

import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/archive/directory_archive.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/build_trace_session.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/commands/release/releaser.dart';
import 'package:shorebird_cli/src/commands/patch/patch.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/dart_sdk_compatibility.dart';
import 'package:shorebird_cli/src/deployment_track.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/extensions/string.dart';
import 'package:shorebird_cli/src/formatters/formatters.dart';
import 'package:shorebird_cli/src/gen_snapshot_probe.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/metadata/metadata.dart';
import 'package:shorebird_cli/src/patch_diff_checker.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_chooser.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/route_b_provenance.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/version.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// Signature for a function that returns a [Patcher] for a given [ReleaseType].
typedef ResolvePatcher = Patcher Function(ReleaseType releaseType);

/// {@template patch_command}
/// A command that creates a shorebird patch for the provided target platforms.
/// `shorebird patch --platforms=android,ios`
/// {@endtemplate}
class PatchCommand extends ShorebirdCommand {
  /// {@macro patch_command}
  PatchCommand({ResolvePatcher? resolvePatcher}) {
    _resolvePatcher = resolvePatcher ?? getPatcher;
    argParser
      ..addMultiOption(
        CommonArguments.dartDefineArg.name,
        help: CommonArguments.dartDefineArg.description,
      )
      ..addMultiOption(
        CommonArguments.dartDefineFromFileArg.name,
        help: CommonArguments.dartDefineFromFileArg.description,
      )
      ..addMultiOption(
        'platforms',
        abbr: 'p',
        help: 'The platform(s) to build this patch for.',
        allowed: ReleaseType.values.map((e) => e.cliName).toList(),
      )
      ..addOption(
        CommonArguments.buildNameArg.name,
        help: CommonArguments.buildNameArg.description,
        defaultsTo: CommonArguments.buildNameArg.defaultValue,
      )
      ..addOption(
        CommonArguments.buildNumberArg.name,
        help: CommonArguments.buildNumberArg.description,
        defaultsTo: CommonArguments.buildNumberArg.defaultValue,
      )
      ..addOption(
        'target',
        abbr: 't',
        help: 'The main entrypoint file of the application.',
      )
      ..addOption(
        'flavor',
        help: 'The product flavor to use when building the app.',
      )
      ..addOption(
        CommonArguments.releaseVersionArg.name,
        help: '''
The version of the associated release (e.g. "1.0.0").
If you are building an xcframework or aar, this number needs to match the host app's release version.
To target the latest release (e.g. the release that was most recently updated) use --release-version=latest.''',
      )
      ..addFlag(
        'allow-native-diffs',
        help: allowNativeDiffsHelpText,
        negatable: false,
      )
      ..addFlag(
        'allow-asset-diffs',
        help: allowAssetDiffsHelpText,
        negatable: false,
      )
      ..addFlag('assets', help: assetsHelpText, negatable: false)
      ..addFlag('assets-only', help: assetsOnlyHelpText, negatable: false)
      ..addOption(
        'track',
        help: 'The track to publish the patch to.',
        defaultsTo: DeploymentTrack.stable.channel,
      )
      ..addFlag(
        'staging',
        negatable: false,
        help: '''
[DEPRECATED] Whether to publish the patch to the staging environment. Use --track=staging instead.''',
        hide: true,
      )
      // Added for https://github.com/shorebirdtech/shorebird/issues/3223.
      // Can be removed fall 2026 or later.
      ..addFlag(
        'confirm',
        hide: true,
      )
      ..addOption(
        CommonArguments.exportOptionsPlistArg.name,
        help: CommonArguments.exportOptionsPlistArg.description,
      )
      ..addOption(
        CommonArguments.exportMethodArg.name,
        allowed: ExportMethod.values.map((e) => e.argName),
        help: CommonArguments.exportMethodArg.description,
        allowedHelp: {
          for (final method in ExportMethod.values)
            method.argName: method.description,
        },
      )
      ..addFlag(
        'codesign',
        help: 'Codesign the application bundle (iOS only).',
        defaultsTo: true,
      )
      ..addFlag(
        'dry-run',
        abbr: 'n',
        negatable: false,
        help: 'Validate but do not upload the patch.',
      )
      ..addOption(
        CommonArguments.privateKeyArg.name,
        help: CommonArguments.privateKeyArg.description,
      )
      ..addOption(
        CommonArguments.publicKeyArg.name,
        help: CommonArguments.publicKeyArg.description,
      )
      ..addOption(
        CommonArguments.publicKeyCmd.name,
        help: CommonArguments.publicKeyCmd.description,
      )
      ..addOption(
        CommonArguments.signCmd.name,
        help: CommonArguments.signCmd.description,
      )
      ..addOption(
        CommonArguments.splitDebugInfoArg.name,
        help: CommonArguments.splitDebugInfoArg.description,
      )
      ..addFlag(
        CommonArguments.obfuscateArg.name,
        help: CommonArguments.obfuscateArg.description,
        negatable: false,
        hide: true,
      )
      ..addOption(
        CommonArguments.minLinkPercentage.name,
        help: CommonArguments.minLinkPercentage.description,
        defaultsTo: CommonArguments.minLinkPercentage.defaultValue,
      );
  }

  /// Warning message for when native code diffs are detected.
  static final allowNativeDiffsHelpText = '''
Patch even if native code diffs are detected.
NOTE: this is ${styleBold.wrap('not')} recommended. Native code changes cannot be included in a patch and attempting to do so can cause your app to crash or behave unexpectedly.''';

  /// Warning message for when asset diffs are detected.
  static final allowAssetDiffsHelpText = '''
Patch even if asset diffs are detected.
NOTE: this is ${styleBold.wrap('not')} recommended. Asset changes cannot be included in a patch can cause your app to behave unexpectedly.''';

  /// Help text for the opt-in asset bundle upload.
  static final assetsHelpText = '''
Attach this patch's assets to it, so an app built against this control plane can pick them up.
${styleBold.wrap('Experimental')}, and opt-in because it makes the patch larger. The native updater ignores the bundle; reading it requires app-side support.''';

  /// Help text for publishing a patch that carries assets and no code.
  static final assetsOnlyHelpText = '''
Publish a patch containing only this patch's assets, with no Dart code.
${styleBold.wrap('Experimental')}. Implies --assets. Nothing is linked or interpreted, which is what lets an asset change ship where a code change cannot. Requires an updater that advertises support; older updaters are never offered such a patch.''';

  late final ResolvePatcher _resolvePatcher;

  @override
  String get description =>
      'Creates a shorebird patch for the provided target platforms.';

  @override
  String get name => 'patch';

  /// The shorebird app ID for the current project.
  String get appId => shorebirdEnv.getShorebirdYaml()!.getAppId(flavor: flavor);

  /// The build flavor, if provided.
  late String? flavor = results.findOption('flavor', argParser: argParser);

  /// The target script, if provided.
  late String? target = results.findOption('target', argParser: argParser);

  /// Whether to prompt for confirmation before creating the patch.
  bool get confirm => results['confirm'] == true;

  /// Whether to allow changes in assets (--allow-asset-diffs).
  bool get allowAssetDiffs => results['allow-asset-diffs'] == true;

  /// Whether to allow changes in native code (--allow-native-diffs).
  bool get allowNativeDiffs => results['allow-native-diffs'] == true;

  /// Whether to attach this patch's assets to it (--assets).
  ///
  /// Implied by [assetsOnly]: a patch with no code and no assets would carry
  /// nothing at all.
  bool get includeAssets => results['assets'] == true || assetsOnly;

  /// Whether to publish a patch carrying assets and no code (--assets-only).
  bool get assetsOnly => results['assets-only'] == true;

  /// Whether the patch is for the staging environment.
  bool get isStaging => track == DeploymentTrack.staging;

  /// Whether the patch is targeting the latest release version
  /// (--release-version=latest).
  bool get useLatestRelease => results['release-version'] == 'latest';

  /// The deployment track to publish the patch to.
  DeploymentTrack get track => DeploymentTrack(results['track'] as String);

  @override
  Future<int> run() async {
    if (results.releaseTypes.isEmpty) {
      logger.err(
        '''No platforms were provided. Use the --platforms argument to provide one or more platforms''',
      );
      return ExitCode.usage.code;
    }

    if (results.wasParsed('staging')) {
      logger.err(
        '''The --staging flag is deprecated and will be removed in a future release. Use --track=staging instead.''',
      );
      return ExitCode.usage.code;
    }

    await createPatch(results.releaseTypes.map(_resolvePatcher).toList());

    return ExitCode.success.code;
  }

  /// Returns a [Patcher] for the given [ReleaseType].
  @visibleForTesting
  Patcher getPatcher(ReleaseType releaseType) {
    switch (releaseType) {
      case ReleaseType.aar:
        return AarPatcher(
          argResults: results,
          argParser: argParser,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.android:
        return AndroidPatcher(
          argResults: results,
          argParser: argParser,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.ios:
        return IosPatcher(
          argResults: results,
          argParser: argParser,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.iosFramework:
        return IosFrameworkPatcher(
          argResults: results,
          argParser: argParser,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.linux:
        return LinuxPatcher(
          argParser: argParser,
          argResults: results,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.macos:
        return MacosPatcher(
          argParser: argParser,
          argResults: results,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.windows:
        return WindowsPatcher(
          argResults: results,
          argParser: argParser,
          flavor: flavor,
          target: target,
        );
    }
  }

  /// The last built Flutter revision.
  String? lastBuiltFlutterRevision;

  /// Creates a single patch spanning every platform in [patchers].
  ///
  /// One invocation produces one patch, not one per platform: patches are not
  /// platform-scoped server-side, and each uploaded artifact carries its own
  /// platform. That gives `--platforms=android,ios` a single patch number, a
  /// single promotion, and a single rollback.
  ///
  /// The phases matter. Everything that can fail cheaply (preconditions,
  /// argument validation, release resolution) runs for *every* platform before
  /// any platform is built, and the patch is promoted only once every
  /// platform's artifacts have uploaded. An unpromoted patch is served to
  /// nobody, so a failure at any point leaves an inert patch rather than a live
  /// one covering only the platforms that happened to finish first.
  @visibleForTesting
  Future<void> createPatch(List<Patcher> patchers) async {
    // Preflight every platform before doing any work. Preconditions are
    // platform-specific — the Apple patchers require macOS — and used to be
    // asserted at the top of each platform's own turn, by which point earlier
    // platforms had already published. Patching android+ios from a Linux CI
    // runner would ship the Android patch and only then fail.
    for (final patcher in patchers) {
      await patcher.assertPreconditions();
      await patcher.assertArgsAreValid();
    }
    results.assertAbsentOrValidKeyPairOrCommands();

    // Parsed here rather than where it's used, so a bad value fails before any
    // build instead of after every platform has been compiled and linked.
    final minLinkPercentage = parseMinLinkPercentage();

    for (final patcher in patchers) {
      try {
        await shorebirdValidator.validateFlavors(
          flavorArg: flavor,
          releasePlatform: patcher.releaseType.releasePlatform,
        );
      } on ValidationFailedException {
        throw ProcessExit(ExitCode.config.code);
      }
    }

    await cache.updateAll();

    final app = await codePushClientWrapper.getApp(appId: appId);
    final releasePlatforms = patchers
        .map((patcher) => patcher.releaseType.releasePlatform)
        .toSet();

    var inferredReleaseVersion = false;
    // The artifact built speculatively to infer the release version, and the
    // patcher that built it, so that platform isn't compiled twice.
    Patcher? prebuiltPatcher;
    File? prebuiltArtifact;
    final Release release;
    if (useLatestRelease) {
      final releases = await codePushClientWrapper.getReleases(appId: appId);
      // Every platform in one patch shares one release, so "latest" has to mean
      // the newest release that covers *all* of them. Resolving per platform
      // could otherwise straddle versions — patching android against 1.0.2 and
      // ios against 1.0.1 in the same invocation.
      releases
        ..removeWhere(
          (release) => !releasePlatforms.every(
            release.platformStatuses.keys.contains,
          ),
        )
        ..sortByUpdatedAt();
      if (releases.isEmpty) {
        logger.warn(
          '''No releases found for app $appId covering ${_platformList(releasePlatforms)}. You must first create a release before you can create a patch.''',
        );
        throw ProcessExit(ExitCode.usage.code);
      }
      release = releases.last;
    } else if (results.wasParsed('release-version')) {
      final releaseVersion = results['release-version'] as String;
      release = await codePushClientWrapper.getRelease(
        appId: appId,
        releaseVersion: releaseVersion,
      );
    } else if (shorebirdEnv.canAcceptUserInput) {
      release = await promptForRelease(releasePlatforms);
    } else {
      final flutterVersionString = await shorebirdFlutter
          .getVersionAndRevision();
      logger.warn('''
The release version to patch was not specified.
Building with Flutter $flutterVersionString to determine the release version...
+-------------------------------------------------------------------------------+
| Specify a release version (e.g. --release-version=1.0.0+1)                    |
| to avoid a speculative build with the latest Flutter version.                 |
| Tip: Use --release-version=latest to target the most recent release.          |
+-------------------------------------------------------------------------------+
''');
      lastBuiltFlutterRevision = shorebirdEnv.flutterRevision;
      inferredReleaseVersion = true;
      // All platforms share one release version, so one speculative build
      // answers for the whole set.
      prebuiltPatcher = patchers.first;
      prebuiltArtifact = await _tryBuildingArtifact<File>(
        prebuiltPatcher.buildPatchArtifact,
      );
      final releaseVersion = await prebuiltPatcher
          .extractReleaseVersionFromArtifact(prebuiltArtifact);
      release = await codePushClientWrapper.getRelease(
        appId: appId,
        releaseVersion: releaseVersion,
      );
    }

    for (final patcher in patchers) {
      assertReleaseContainsPlatform(release: release, patcher: patcher);
      assertReleaseIsActive(release: release, patcher: patcher);
    }

    try {
      await shorebirdFlutter.installRevision(revision: release.flutterRevision);
    } on Exception {
      throw ProcessExit(ExitCode.software.code);
    }

    final releaseFlutterShorebirdEnv = shorebirdEnv.copyWith(
      flutterRevisionOverride: release.flutterRevision,
    );

    return await runScoped(
      () async {
        await cache.updateAll();

        // After updateAll, so the cache is populated, and before anything
        // invokes Flutter. A frontend/backend mismatch here builds cleanly and
        // fails on the device instead.
        try {
          dartSdkCompatibility.validate();
        } on DartSdkMismatchException catch (error) {
          logger.err('$error');
          throw ProcessExit(ExitCode.config.code);
        }

        final bundles = <ReleasePlatform, Map<Arch, PatchArtifactBundle>>{};
        final sidecars = <ReleasePlatform, PatchSidecars>{};
        final platformMetadata =
            <ReleasePlatform, CreatePatchPlatformMetadata>{};
        // Shared by every platform: one invocation builds them all on one
        // machine. Each patcher may contribute fields it owns (the Apple
        // patchers add the Xcode version).
        var environment = BuildEnvironmentMetadata(
          flutterRevision: shorebirdEnv.flutterRevision,
          operatingSystem: platform.operatingSystem,
          operatingSystemVersion: platform.operatingSystemVersion,
          shorebirdVersion: packageVersion,
          shorebirdYaml: shorebirdEnv.getShorebirdYaml()!,
          usesShorebirdCodePushPackage:
              shorebirdEnv.usesShorebirdCodePushPackage,
        );

        for (final patcher in patchers) {
          final result = await _buildPlatformPatch(
            patcher: patcher,
            release: release,
            prebuiltArtifact: identical(patcher, prebuiltPatcher)
                ? prebuiltArtifact
                : null,
          );
          final releasePlatform = patcher.releaseType.releasePlatform;
          bundles[releasePlatform] = result.bundles;
          sidecars[releasePlatform] = result.sidecars;
          platformMetadata[releasePlatform] = await patcher
              .updatedPlatformMetadata(result.metadata);
          environment = await patcher.updatedEnvironmentMetadata(environment);
        }

        // Recorded AFTER the build, deliberately. The server otherwise cannot
        // say which engine produced a patch — flutterRevision cannot, since two
        // Route B cells can share one Flutter revision and differ in
        // capability.
        //
        // It must not be read BEFORE the build: the engine-identity gate counts
        // reads of `shorebirdEngineRevision` — the first is its pre-build check
        // and later ones detect a stamp the Flutter build rewrote underneath it.
        // An extra early read consumed that first check, so the gate compared
        // the wrong pair and the drift test caught it. Reading here also records
        // the engine that ACTUALLY produced these artifacts rather than the one
        // present before the build.
        environment = environment.copyWith(
          engineRevision: shorebirdEnv.shorebirdEngineRevision,
        );

        final dryRun = results['dry-run'] == true;
        if (dryRun) {
          logger
            ..info('No issues detected.')
            ..info('The server may enforce additional checks.');
          throw ProcessExit(ExitCode.success.code);
        }

        await logPatchSummary(
          app: app,
          releaseVersion: release.version,
          patchers: patchers,
          patchArtifactBundles: bundles,
          minLinkPercentage: minLinkPercentage,
        );

        final metadata = CreatePatchMetadata(
          platforms: platformMetadata,
          usedIgnoreAssetChangesFlag: allowAssetDiffs,
          usedIgnoreNativeChangesFlag: allowNativeDiffs,
          inferredReleaseVersion: inferredReleaseVersion,
          isSigned:
              results.wasParsed(CommonArguments.privateKeyArg.name) ||
              results.wasParsed(CommonArguments.signCmd.name),
          environment: environment,
        );

        // An assets-only patch drops the code artifacts and ships the bundle
        // alone. The build still ran: `flutter_assets` comes out of the built
        // app, so there is no way to package assets without building. What
        // changes is only what gets uploaded.
        if (assetsOnly) {
          final missing = sidecars.entries
              .where((e) => e.value.assets == null)
              .map((e) => e.key.name)
              .toList();
          if (missing.isNotEmpty) {
            // Publishing here would create a patch carrying nothing, which
            // devices would download and apply to no effect — a silent no-op
            // is worse than a failed patch.
            logger.err(
              '''--assets-only was passed but no asset bundle could be packaged for: ${missing.join(', ')}.''',
            );
            throw ProcessExit(ExitCode.software.code);
          }
        }

        // One patch, every platform's artifacts, one promotion at the end.
        await codePushClientWrapper.publishPatch(
          appId: appId,
          releaseId: release.id,
          metadata: metadata.toJson(),
          track: track,
          patchArtifactBundles: assetsOnly
              ? {for (final platform in bundles.keys) platform: const {}}
              : bundles,
          sidecars: sidecars,
        );
      },
      values: {shorebirdEnvRef.overrideWith(() => releaseFlutterShorebirdEnv)},
    );
  }

  /// Builds, validates, and packages one platform's patch artifacts.
  ///
  /// Deliberately uploads nothing: every platform must get this far before any
  /// of them is published, so that a multi-platform patch is all-or-nothing.
  ///
  /// [prebuiltArtifact] is the artifact already built to infer the release
  /// version, if this is the patcher that built it.
  Future<
    ({
      Map<Arch, PatchArtifactBundle> bundles,
      CreatePatchPlatformMetadata metadata,
      PatchSidecars sidecars,
    })
  >
  _buildPlatformPatch({
    required Patcher patcher,
    required Release release,
    required File? prebuiltArtifact,
  }) async {
    final releasePlatform = patcher.releaseType.releasePlatform;

    final releaseArtifact = await codePushClientWrapper.getReleaseArtifact(
      appId: appId,
      releaseId: release.id,
      arch: patcher.primaryReleaseArtifactArch,
      platform: releasePlatform,
    );

    final supplementalArtifact =
        patcher.supplementaryReleaseArtifactArch != null
        ? await codePushClientWrapper.maybeGetReleaseArtifact(
            appId: appId,
            releaseId: release.id,
            arch: patcher.supplementaryReleaseArtifactArch!,
            platform: releasePlatform,
          )
        : null;

    final releaseArchive = await downloadReleaseArtifact(
      releaseArtifact: releaseArtifact,
    );

    final supplementArchive = supplementalArtifact != null
        ? await downloadReleaseArtifact(releaseArtifact: supplementalArtifact)
        : null;

    // Download and extract the supplement archive (if present).
    Directory? supplementDirectory;
    File? obfuscationMapFile;
    if (supplementArchive != null) {
      supplementDirectory = Directory.systemTemp.createTempSync();
      await artifactManager.extractZip(
        zipFile: supplementArchive,
        outputDirectory: supplementDirectory,
      );
      final candidateMapFile = File(
        p.join(supplementDirectory.path, 'obfuscation_map.json'),
      );
      if (candidateMapFile.existsSync()) {
        obfuscationMapFile = candidateMapFile;
        logger.info(
          'Release was built with obfuscation. '
          'Applying obfuscation map to patch build.',
        );
      }
    }

    // Replaying the release's obfuscation map into the patch build requires a
    // gen_snapshot that understands --load-obfuscation-map. A gen_snapshot
    // without it aborts with "Unrecognized flags: load_obfuscation_map" (exit
    // code 255) for every arch, deep inside the Flutter build. Refuse here
    // instead: a rejected patch beats a confusing build failure, and dropping
    // the map to build anyway would produce a patch obfuscated differently
    // than the release, which is silently broken at runtime.
    //
    // The question is asked of the BINARY, not of a Flutter version, and the
    // binary is the release's — `installRevision` above has already put the
    // release's toolchain on disk, while `shorebirdEnv` is not switched over
    // to it until the `copyWith` further down. A version gate here would be
    // inert against the hazard it names; see
    // GenSnapshotProbe.supportsLoadObfuscationMap for the two-cells /
    // one-flutter-revision fact that makes that so.
    if (obfuscationMapFile != null) {
      final support = await genSnapshotProbe.supportsLoadObfuscationMap(
        flutterRevision: release.flutterRevision,
        platform: releasePlatform,
      );
      switch (support) {
        case GenSnapshotFlagSupport.absent:
          logger.err(
            '''
This release was built with obfuscation, but the gen_snapshot that would build the patch does not carry the --load-obfuscation-map flag, so the patch cannot reproduce the release's obfuscation.

  Release Flutter revision: ${release.flutterRevision}
  gen_snapshot: ${genSnapshotProbe.resolveGenSnapshots(flutterRevision: release.flutterRevision, platform: releasePlatform).map((f) => f.path).join('\n                ')}

The flag is an engine capability, not a Flutter version: two engines built from the same Flutter revision can differ on it. Cut a new release with an engine whose gen_snapshot carries the flag, and patch that release instead.''',
          );
          throw ProcessExit(ExitCode.software.code);
        case GenSnapshotFlagSupport.indeterminate:
          // Deliberately fail OPEN, and only here. We could not read a
          // gen_snapshot at all, so we know nothing — and refusing on
          // no-evidence would break working setups whose layout we simply
          // failed to enumerate (a --local-engine tree, an arch directory
          // that is not precached yet). Proceeding costs nothing we were not
          // already paying: gen_snapshot rejects unknown VM flags loudly
          // rather than ignoring them, so the worst case is today's exit-255
          // build failure, never a silently mis-obfuscated patch. The refusal
          // above, by contrast, fires only on measured evidence.
          logger.warn(
            '''
Could not verify that gen_snapshot supports --load-obfuscation-map for Flutter revision ${release.flutterRevision}. If it does not, the patch build will fail with "Unrecognized flags: load_obfuscation_map".''',
          );
        case GenSnapshotFlagSupport.present:
          break;
      }
    }

    // If the user explicitly passed --obfuscate but the release has no
    // obfuscation map, the patch would be obfuscated against a non-obfuscated
    // release, producing a broken patch.
    final userPassedObfuscate = results.flagPresent('obfuscate');
    if (userPassedObfuscate && obfuscationMapFile == null) {
      logger.err(
        '--obfuscate was passed, but the release was not built with '
        'obfuscation. A patch cannot change the obfuscation mode of a '
        'release.',
      );
      throw ProcessExit(ExitCode.software.code);
    }
    if (userPassedObfuscate && obfuscationMapFile != null) {
      logger.info(
        '--obfuscate is not needed for patching. Obfuscation is applied '
        'automatically when the release was built with --obfuscate.',
      );
    }

    patcher
      ..obfuscationMapPath = obfuscationMapFile?.path
      ..assetsOnly = assetsOnly;

    // Build extra args to inject into the Flutter build command. These use
    // --extra-gen-snapshot-options= because they're passed through Flutter's
    // build system, which forwards them to gen_snapshot. This is distinct from
    // patcher.obfuscationGenSnapshotArgs, which produces bare gen_snapshot
    // flags (e.g. --load-obfuscation-map=...) for direct gen_snapshot/linker
    // calls made by Apple patchers outside the Flutter build.
    final extraBuildArgs = <String>[];
    if (obfuscationMapFile != null) {
      extraBuildArgs.addAll([
        '--obfuscate',
        '--extra-gen-snapshot-options='
            '--load-obfuscation-map=${obfuscationMapFile.path}',
      ]);

      // Gate --strip on the release's Flutter revision (not the user's
      // currently-installed pin) so the patch's gen_snapshot behavior
      // matches the release's. On Android with Flutter 3.44+ AGP performs
      // the strip; passing --strip here would pre-strip the snapshot,
      // leaving AGP nothing to strip and tripping flutter_tools'
      // post-build "libapp.so.sym or libapp.so.dbg not present" check.
      final shouldPreStripInGenSnapshot = await shorebirdFlutter
          .shouldPreStripLibappInGenSnapshot(
            platform: patcher.releaseType.releasePlatform,
            flutterRevision: release.flutterRevision,
          );

      if (shouldPreStripInGenSnapshot) {
        // Strip unobfuscated DWARF debug info from the compiled snapshot
        // so it doesn't leak identifiers that obfuscation was meant to
        // hide. On Android 3.44+ this is handled by AGP instead; see the
        // block above.
        extraBuildArgs.add('--extra-gen-snapshot-options=--strip');
      }
    }
    // Flutter requires --split-debug-info with --obfuscate. Auto-add it
    // if --obfuscate will be in the build args (from the user or from
    // the obfuscation map injection above) but --split-debug-info is not.
    final hasObfuscate =
        results.flagPresent('obfuscate') ||
        extraBuildArgs.contains('--obfuscate');
    final hasSplitDebugInfo = results.optionPresent('split-debug-info');
    if (hasObfuscate && !hasSplitDebugInfo) {
      extraBuildArgs.add(
        '--split-debug-info=${p.join('build', 'shorebird', 'symbols')}',
      );
    }
    // Route B (selfhost): the patch must compile against the SAME retention
    // interface the release did. Without it the release kernel is annotated and
    // the patch kernel is not, they disagree about almost every member, and
    // coverage refuses a one-line change — measured at 4,830 changed members
    // for a single edited function.
    //
    // Read from the release's supplement, like the obfuscation map above, and
    // gated on the file existing so no other platform ever sees the flag.
    final retentionInterface = supplementDirectory == null
        ? null
        : File(p.join(supplementDirectory.path, routeBInterfaceFileName));
    if (retentionInterface != null && retentionInterface.existsSync()) {
      extraBuildArgs.add(
        '--extra-front-end-options=--dynamic-interface=${retentionInterface.path}',
      );
    }

    // THE ENGINE-IDENTITY INVARIANT, checked BEFORE the build so a refusal costs
    // nothing: no kernel, no coverage, no bytecode, no artifact, no upload.
    //
    // Only for a Route B release. Every other release's patch is produced the
    // way it always was, and a check that refused those would be inventing a
    // constraint this evidence does not support.
    if (supplementDirectory != null &&
        hasRouteBReleaseProvenance(supplementDirectory)) {
      _assertRouteBEngineIdentity(
        supplementDirectory,
        RouteBEngineCheck.beforeBuild,
      );
    }

    // THE EFFECTIVE-CONFIGURATION INVARIANT, in the same place and for the
    // same reason as the engine-identity check above: refuse BEFORE the build,
    // so a mismatch costs nothing — no kernel, no artifact, no upload.
    //
    // Placed after `extraBuildArgs` is complete because the patch's effective
    // configuration includes what this command injects (e.g. `--obfuscate`
    // mirrored from the release), not merely what the user typed.
    _assertBuildConfigAgrees(
      supplementDirectory,
      [...results.forwardedArgs, ...extraBuildArgs],
    );

    patcher.extraBuildArgs = extraBuildArgs;

    // Set up build tracing before any flutter build / aot_tools /
    // gen_snapshot call runs. Version-gated inside prepareBuildTrace —
    // a no-op on older Flutter pins. Called once per platform; the summary
    // is finalized below, after this platform's link step.
    await artifactBuilder.prepareBuildTrace(platform: releasePlatform.name);

    // Don't build the patch artifact twice with the same Flutter revision:
    // reuse the speculative build only if it used the release's revision.
    final File patchArtifactFile;
    if (prebuiltArtifact != null &&
        lastBuiltFlutterRevision == release.flutterRevision) {
      patchArtifactFile = prebuiltArtifact;
    } else {
      final flutterVersionString = await shorebirdFlutter
          .getVersionAndRevision();
      logger.info('''
Building ${releasePlatform.displayName} patch with Flutter $flutterVersionString
''');
      patchArtifactFile = await _tryBuildingArtifact<File>(
        () => patcher.buildPatchArtifact(releaseVersion: release.version),
      );
    }

    // AND AGAIN, because the build can restamp the cache underneath the first
    // check. `shorebirdEngineRevision` re-reads `bin/internal/engine.version`
    // from disk, so this sees the drift rather than a cached answer — and the
    // drift is real: a build through a CDN that maps an experimental hash onto a
    // stock one records the hash it actually downloaded.
    //
    // Still before coverage, bytecode and publication. The kernel exists by now
    // and is thrown away, which is the correct trade: a wasted build costs
    // minutes, and a patch that installs and does nothing costs a release cycle
    // and the belief that the mechanism works.
    if (supplementDirectory != null &&
        hasRouteBReleaseProvenance(supplementDirectory)) {
      _assertRouteBEngineIdentity(
        supplementDirectory,
        RouteBEngineCheck.afterBuild,
      );
    }

    final diffStatus = await assertUnpatchableDiffs(
      releaseArtifact: releaseArtifact,
      releaseArchive: releaseArchive,
      patchArchive: patchArtifactFile,
      patcher: patcher,
    );
    final patchArtifactBundles = await patcher.createPatchArtifacts(
      appId: appId,
      releaseId: release.id,
      releaseArtifact: releaseArchive,
      supplementDirectory: supplementDirectory,
    );

    // Write the build-trace summary once this platform's compile/link work has
    // finished, before the next platform's prepareBuildTrace overwrites the
    // session. No-op when tracing wasn't set up (older Flutter pin).
    artifactBuilder.writeBuildTraceSummary();

    return (
      bundles: patchArtifactBundles,
      sidecars: await _packageSidecars(patcher),
      metadata: CreatePatchPlatformMetadata(
        hasAssetChanges: diffStatus.hasAssetChanges,
        hasNativeChanges: diffStatus.hasNativeChanges,
        // Attach the build-trace summary if the build produced one.
        // Null for older Flutter pins without the --shorebird-trace
        // flag or when trace parsing failed; uploader sends
        // null-as-omitted.
        buildTraceSummary: buildTraceSession.summary?.toJson(),
      ),
    );
  }

  /// Zips whatever non-code payloads this platform's build produced.
  ///
  /// Both are packaged here rather than at upload time so that a multi-platform
  /// patch stays all-or-nothing: [_buildPlatformPatch] deliberately uploads
  /// nothing, and each platform's `flutter_assets` and symbol directories are
  /// transient build output that the next platform's build may overwrite.
  ///
  /// Neither is fatal. A patch whose assets or symbols could not be packaged is
  /// still a valid patch, so a failure here degrades to "not retained" and says
  /// so, rather than throwing away a build that otherwise succeeded.

  /// Refuses a patch whose EFFECTIVE build configuration differs from the
  /// release's, before any patch artifact is produced.
  ///
  /// THE THREE STATES ARE NOT INTERCHANGEABLE, and each gets its own
  /// diagnostic, because their remediations differ:
  ///
  ///   supplement/record absent  the release predates this contract. Nothing
  ///                             to compare. Cut a new release to get the
  ///                             check. NOT an error.
  ///   `buildConfig: null`       the release's own configuration was
  ///                             UNFINGERPRINTABLE (e.g.
  ///                             `--dart-define-from-file`). Comparable to
  ///                             nothing, permanently, and re-releasing will
  ///                             not help. NOT an error.
  ///   `buildConfig` object      comparable. A difference is refused here.
  ///
  /// Collapsing the first two into one message is how a reader concludes "cut
  /// a new release" for a case where that cannot possibly help.
  void _assertBuildConfigAgrees(
    Directory? supplementDirectory,
    List<String> patchArgs,
  ) {
    if (supplementDirectory == null) return;
    final file = File(
      p.join(supplementDirectory.path, Releaser.buildConfigFileName),
    );
    if (!file.existsSync()) {
      logger.detail(
        '''[build-config] the release records no build configuration; it predates this check. Cut a new release to enable it.''',
      );
      return;
    }

    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } on Object catch (error) {
      logger.detail('[build-config] unreadable record, skipping: $error');
      return;
    }

    if (decoded['buildConfig'] == null) {
      logger.warn(
        '''This release's build configuration cannot be fingerprinted, so this patch's cannot be compared against it. That is permanent for this release: ${decoded['unfingerprintableReason'] ?? 'reason not recorded'}.''',
      );
      return;
    }

    final releaseConfig = RouteBBuildConfig.fromJson(
      decoded['buildConfig'] as Map<String, dynamic>,
    );
    final patchConfig = RouteBBuildConfig.fromBuildArgs(
      patchArgs,
      flavor: RouteBBuildConfig.resolveFlavor(
        cliFlavor: results['flavor'] as String?,
        pubspecFlutterSection: shorebirdEnv.getPubspecYaml()?.flutter,
      ),
    );

    if (patchConfig == null) {
      logger.warn(
        '''This patch was invoked with an option whose effective configuration cannot be determined, so it cannot be shown to match the release's.''',
      );
      return;
    }

    if (releaseConfig.agreesWith(patchConfig)) return;

    logger
      ..err(
        '''The patch's effective build configuration does not match the release's.''',
      )
      ..info(releaseConfig.describeDifference(patchConfig))
      ..info(
        '''
Refusing before building: a patch built with a different configuration compiles a different program than the release it would replace.''',
      );
    throw ProcessExit(ExitCode.software.code);
  }

  Future<PatchSidecars> _packageSidecars(Patcher patcher) async {
    final platformName = patcher.releaseType.releasePlatform.displayName;

    File? assets;
    if (includeAssets) {
      final directory = await patcher.assetsDirectory();
      if (directory == null) {
        logger.warn(
          '--assets was passed but no assets could be resolved for '
          '$platformName. The patch will not carry an asset bundle.',
        );
      } else {
        assets = await _tryZip(directory, name: 'assets', of: platformName);
      }
    }

    // Not gated on a flag: symbols only exist when the build was already asked
    // for them with --split-debug-info, which is the opt-in.
    File? symbols;
    if (await patcher.debugSymbolsDirectory() case final directory?) {
      symbols = await _tryZip(directory, name: 'symbols', of: platformName);
    }

    return (assets: assets, symbols: symbols);
  }

  /// Zips [directory], or returns null and warns if that fails. [name] and [of]
  /// name the payload and platform in that warning.
  Future<File?> _tryZip(
    Directory directory, {
    required String name,
    required String of,
  }) async {
    try {
      return await directory.zipToTempFile(name: name);
    } on Exception catch (error) {
      logger.warn(
        'Failed to package $of $name from ${directory.path} ($error). '
        'They will not be retained with this patch.',
      );
      return null;
    }
  }

  /// Prompts the user for the specific release to patch.
  ///
  /// Only releases covering *every* requested platform are offered: one patch
  /// spans all of them, so a release missing any one of them can't be used.
  Future<Release> promptForRelease(Set<ReleasePlatform> platforms) async {
    final releases = await codePushClientWrapper.getReleases(appId: appId);

    final candidates = releases.where(
      (release) => platforms.every(release.platformStatuses.keys.contains),
    );

    if (candidates.isEmpty) {
      logger.warn(
        '''No releases found for app $appId covering ${_platformList(platforms)}. You must first create a release before you can create a patch.''',
      );
      throw ProcessExit(ExitCode.usage.code);
    }

    return chooseRelease(
      releases: candidates,
      action: 'patch',
    );
  }

  /// Renders [platforms] as a human-readable list, e.g. "android and ios".
  static String _platformList(Set<ReleasePlatform> platforms) {
    final names = platforms.map((p) => p.displayName).toList();
    if (names.length == 1) return names.first;
    return '${names.take(names.length - 1).join(', ')} and ${names.last}';
  }

  /// Parses and validates `--min-link-percentage`.
  @visibleForTesting
  int parseMinLinkPercentage() {
    final raw = results[CommonArguments.minLinkPercentage.name] as String;
    final value = int.tryParse(raw);
    if (value == null ||
        value < CommonArguments.minLinkPercentageMin ||
        value > CommonArguments.minLinkPercentageMax) {
      logger.err(
        '--min-link-percentage must be an integer between '
        '${CommonArguments.minLinkPercentageMin} and '
        '${CommonArguments.minLinkPercentageMax} '
        '(got $raw).',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    return value;
  }

  /// Asserts that the release contains a platform for the given [patcher].
  void assertReleaseContainsPlatform({
    required Release release,
    required Patcher patcher,
  }) {
    final releasePlatform = patcher.releaseType.releasePlatform;
    final contains = release.platformStatuses.containsKey(releasePlatform);
    if (!contains) {
      final platformName = releasePlatform.name;
      logger.err(
        '''No release exists for $platformName in release version ${release.version}. Please run shorebird release $platformName to create one.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }
  }

  /// Asserts that the provided [release] is active.
  void assertReleaseIsActive({
    required Release release,
    required Patcher patcher,
  }) {
    final releaseStatus =
        release.platformStatuses[patcher.releaseType.releasePlatform];
    if (releaseStatus != ReleaseStatus.active) {
      logger.err('''
Release ${release.version} is in an incomplete state. It's possible that the original release was terminated or failed to complete.
Please re-run the release command for this version or create a new release.''');
      throw ProcessExit(ExitCode.software.code);
    }
  }

  /// Refuse a Route B patch whose kernel would come from a different engine
  /// than the release's.
  ///
  /// A provenance/compatibility invariant, not a delivery one. Delivery did its
  /// job in the run that motivated this: it downloaded, installed, promoted and
  /// reported the patch. The defect was letting an incompatible artifact exist.
  ///
  /// A malformed sidecar is NOT a pass. `hasRouteBReleaseProvenance` already
  /// said this is a Route B release, so an unreadable engine revision means the
  /// invariant cannot be checked — and an unverifiable invariant is a refusal.
  void _assertRouteBEngineIdentity(
    Directory supplement,
    RouteBEngineCheck check,
  ) {
    final String releaseEngine;
    try {
      final provenance = readRouteBReleaseProvenance(supplement);
      if (provenance == null) return;
      releaseEngine = provenance.engineRevision;
    } on FormatException catch (error) {
      logger.err('''
This release's Route B provenance could not be read, so the engine it was built by cannot be established: ${error.message}

A patch compiled against the wrong engine installs cleanly and does nothing, so
this is refused rather than attempted. Nothing was uploaded.''');
      throw ProcessExit(ExitCode.software.code);
    }

    final refusal = routeBEngineIdentityRefusal(
      releaseEngineRevision: releaseEngine,
      activeEngineRevision: shorebirdEnv.shorebirdEngineRevision,
      check: check,
    );
    if (refusal == null) return;
    logger.err(refusal);
    throw ProcessExit(ExitCode.software.code);
  }

  /// Ensures the diff between the release and patch archives is safe to patch.
  Future<DiffStatus> assertUnpatchableDiffs({
    required ReleaseArtifact releaseArtifact,
    required File patchArchive,
    required File releaseArchive,
    required Patcher patcher,
  }) async {
    try {
      return patcher.assertUnpatchableDiffs(
        releaseArtifact: releaseArtifact,
        releaseArchive: releaseArchive,
        patchArchive: patchArchive,
      );
    } on UserCancelledException {
      throw ProcessExit(ExitCode.success.code);
    } on UnpatchableChangeException {
      logger.info('Exiting.');
      throw ProcessExit(ExitCode.software.code);
    }
  }

  /// Logs a summary of the patch to be created, including:
  /// - The app name and ID
  /// - The release version
  /// - One line per platform the patch covers, with its arches and sizes
  /// - The track
  /// - The link percentage (if iOS)
  /// - The debug info file (if iOS)
  ///
  /// Also enforces `--min-link-percentage`. The threshold applies to every
  /// platform that reports a link percentage: one patch ships to all of them,
  /// so a single platform linking badly has to fail the whole patch.
  Future<void> logPatchSummary({
    required AppMetadata app,
    required String releaseVersion,
    required List<Patcher> patchers,
    required Map<ReleasePlatform, Map<Arch, PatchArtifactBundle>>
    patchArtifactBundles,
    required int minLinkPercentage,
  }) async {
    final trackSummary = (() {
      return switch (track) {
        DeploymentTrack.staging => '🟠 Track: ${lightCyan.wrap('Staging')}',
        DeploymentTrack.beta => '🔵 Track: ${lightCyan.wrap('Beta')}',
        DeploymentTrack.stable => '🟢 Track: ${lightCyan.wrap('Stable')}',
        final String trackName => '⚪️ Track: ${lightCyan.wrap(trackName)}',
      };
    })();

    for (final patcher in patchers) {
      final linkPercentage = patcher.linkPercentage;
      if (linkPercentage != null && linkPercentage < minLinkPercentage) {
        logger.err(
          '''The ${patcher.releaseType.releasePlatform.displayName} link percentage of this patch ($linkPercentage%) is below the minimum threshold ($minLinkPercentage%). Exiting.''',
        );
        throw ProcessExit(ExitCode.software.code);
      }
    }

    final platformLines = patchers.map((patcher) {
      final releasePlatform = patcher.releaseType.releasePlatform;
      final bundles = patchArtifactBundles[releasePlatform] ?? {};
      final archMetadata = bundles.entries.map(
        (entry) => '${entry.key.name} (${formatBytes(entry.value.size)})',
      );
      return '''🕹️  Platform: ${lightCyan.wrap(releasePlatform.displayName)} ${lightCyan.wrap('[${archMetadata.join(', ')}]')}''';
    });

    final anyLowLinkPercentage = patchers.any(
      (patcher) =>
          patcher.linkPercentage != null &&
          patcher.linkPercentage! < Patcher.linkPercentageWarningThreshold,
    );

    final summary = [
      '''📱 App: ${lightCyan.wrap(app.displayName)} ${lightCyan.wrap('(${app.appId})')}''',
      if (flavor != null) '🍧 Flavor: ${lightCyan.wrap(flavor)}',
      '📦 Release Version: ${lightCyan.wrap(releaseVersion)}',
      ...platformLines,
      trackSummary,
      if (anyLowLinkPercentage)
        '''🔍 Debug Info: ${lightCyan.wrap(Patcher.debugInfoFile.path)}''',
    ];

    logger.info('''

${styleBold.wrap(lightGreen.wrap('🚀 Ready to publish a new patch!'))}

${summary.join('\n')}
''');

    if (confirm && shorebirdEnv.canAcceptUserInput) {
      if (!logger.confirm('Would you like to continue?', defaultValue: true)) {
        logger.info('Aborting.');
        throw ProcessExit(ExitCode.success.code);
      }
    }
  }

  /// Downloads the given [releaseArtifact].
  Future<File> downloadReleaseArtifact({
    required ReleaseArtifact releaseArtifact,
  }) async {
    final File artifactFile;
    try {
      artifactFile = await artifactManager.downloadWithProgressUpdates(
        Uri.parse(releaseArtifact.url),
        message: 'Downloading ${releaseArtifact.arch}',
      );
    } on Exception {
      throw ProcessExit(ExitCode.software.code);
    }

    return artifactFile;
  }
}

/// Executes [build] to build the artifact and includes
/// special handling thrown exceptions such as [ArtifactBuildException].
Future<R> _tryBuildingArtifact<R>(Future<R> Function() build) async {
  try {
    return await build();
  } on ArtifactBuildException catch (e) {
    logger.err(e.message);
    if (!e.fixRecommendation.isNullOrEmpty) {
      logger.info(e.fixRecommendation);
    }
    throw ProcessExit(ExitCode.software.code);
  } on Exception catch (e) {
    logger.err('Failed to build patch artifacts: $e');
    throw ProcessExit(ExitCode.software.code);
  }
}

/// Extension on list of releases for sorting the releases.
extension SortReleases on List<Release> {
  /// Sort the list of releases by when they were last updated ascending.
  void sortByUpdatedAt() => sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
}
