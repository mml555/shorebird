import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/build_trace_session.dart';
import 'package:shorebird_cli/src/archive/directory_archive.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/build_flags.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/command_error.dart';
import 'package:shorebird_cli/src/commands/patch/patch.dart';
import 'package:shorebird_cli/src/commands/release/releaser.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/dart_sdk_compatibility.dart';
import 'package:shorebird_cli/src/deployment_track.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/extensions/directory.dart';
import 'package:shorebird_cli/src/extensions/string.dart';
import 'package:shorebird_cli/src/extensions/version.dart';
import 'package:shorebird_cli/src/flutter_build_options.dart';
import 'package:shorebird_cli/src/formatters/formatters.dart';
import 'package:shorebird_cli/src/gen_snapshot_probe.dart';
import 'package:shorebird_cli/src/interactive_mode.dart';
import 'package:shorebird_cli/src/json_output.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/metadata/metadata.dart';
import 'package:shorebird_cli/src/patch_diff_checker.dart';
import 'package:shorebird_cli/src/patch_verification.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_chooser.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/route_b_provenance.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_documentation.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/split_debug_info.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/toolchain_coherence.dart';
import 'package:shorebird_cli/src/version.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// Signature for a function that returns a [Patcher] for a given [ReleaseType].
typedef ResolvePatcher = Patcher Function(ReleaseType releaseType);

/// Added to the hint for a patch blocked by native changes.
const _nativeCrashWarning =
    "\nOnly do this if your Dart code doesn't depend on the native changes: "
    "a mismatch between your Dart code and the release's native code can "
    'crash your app.';

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
        abbr: 'D',
        splitCommas: false,
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
      ..addFlag(
        'allow-build-flag-diffs',
        help: allowBuildFlagDiffsHelpText,
        negatable: false,
      )
      ..addFlag(
        'show-dex-diff',
        help: showDexDiffHelpText,
        negatable: false,
      )
      ..addFlag('assets', help: assetsHelpText, negatable: false)
      ..addFlag('assets-only', help: assetsOnlyHelpText, negatable: false)
      ..addOption(
        'track',
        aliases: const ['channel'],
        help:
            'The track to publish the patch to (staging, beta, stable, or a '
            'custom track). Asked for when not given.',
      )
      ..addFlag(
        'staging',
        negatable: false,
        help: '''
[DEPRECATED] Whether to publish the patch to the staging environment. Use --track=staging instead.''',
        hide: true,
      )
      ..addFlag(
        CommonArguments.confirmArg.name,
        help: CommonArguments.confirmArg.description,
        negatable: false,
        hide: true,
      )
      ..addFlag(
        CommonArguments.noConfirmArg.name,
        help: CommonArguments.noConfirmArg.description,
        negatable: false,
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
        help: 'Codesign the app bundle or XCFrameworks (iOS and macOS only).',
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
      )
      ..addOption(
        CommonArguments.ddMaxBytesArg.name,
        hide: true,
        help: CommonArguments.ddMaxBytesArg.description,
      )
      ..addFlutterBuildOptions();
  }

  /// Warning message for when native code diffs are detected.
  static final allowNativeDiffsHelpText = '''
Patch even if native code diffs are detected.
NOTE: this is ${styleBold.wrap('not')} recommended. Native code changes cannot be included in a patch and attempting to do so can cause your app to crash or behave unexpectedly.''';

  /// Help text for the full DEX diff flag.
  static const showDexDiffHelpText = '''
Print every differing instruction when native changes are detected in an Android patch.
Without this, the first few differing instructions of the first ten changed methods are shown, string constants are replaced by their length, and a payload such as a switch table or an array initializer is cut after its first few units. Output contains your app's bytecode, including class and method names, and is written to the shorebird.log file support asks you to attach.''';

  /// Warning message for when asset diffs are detected.
  static final allowAssetDiffsHelpText = '''
Patch even if asset diffs are detected.
NOTE: this is ${styleBold.wrap('not')} recommended. Asset changes cannot be included in a patch can cause your app to behave unexpectedly.''';

  /// Help text for the flag to patch despite build flag diffs.
  static final allowBuildFlagDiffsHelpText = '''
Patch even if the --dart-define values or --target differ from the release's.
NOTE: this is ${styleBold.wrap('not')} recommended. A patch built with different values may fail to link or change code the release runs.''';

  /// Help text for attaching a patch's assets to it.
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

  @override
  String get usageFooter => flutterBuildOptionsUsage('patch');

  /// The shorebird app ID for the current project.
  String get appId => shorebirdEnv.getShorebirdYaml()!.getAppId(flavor: flavor);

  /// The build flavor, if provided.
  late String? flavor = results.findOption('flavor', argParser: argParser);

  /// The target script, if provided.
  late final String? target = resolveTarget();

  /// Whether to allow changes in assets (--allow-asset-diffs).
  bool get allowAssetDiffs => results['allow-asset-diffs'] == true;

  /// Whether to patch despite build flags that differ from the release's
  /// (--allow-build-flag-diffs).
  bool get allowBuildFlagDiffs => results['allow-build-flag-diffs'] == true;

  /// Whether to allow changes in native code (--allow-native-diffs).
  bool get allowNativeDiffs => results['allow-native-diffs'] == true;

  /// Whether to attach this patch's assets to it (--assets).
  ///
  /// Implied by [assetsOnly]: a patch with no code and no assets would carry
  /// nothing at all.
  bool get includeAssets => results['assets'] == true || assetsOnly;

  /// Whether to publish a patch carrying assets and no code (--assets-only).
  bool get assetsOnly => results['assets-only'] == true;

  /// Whether the patch is targeting the latest release version
  /// (--release-version=latest).
  bool get useLatestRelease => results['release-version'] == 'latest';

  /// The deployment track to publish the patch to.
  DeploymentTrack get track => _track ??= _resolveTrack();
  DeploymentTrack? _track;

  /// Whether [track] is stable only because --track wasn't given and the CLI
  /// couldn't ask.
  bool _usedDefaultTrack = false;

  /// The track from --track, or asked for when it wasn't given.
  ///
  /// Without a terminal to ask in, a missing --track still means stable so CI
  /// scripts written against that default keep working, with a warning that
  /// a future release will require --track.
  DeploymentTrack _resolveTrack() {
    if (results['track'] case final String trackName) {
      // A new track is created on first publish, so reject a name that
      // `channels create` and `patches set-track` would also reject.
      final trackNameError = CommonArguments.nameError(
        label: 'Track name',
        value: trackName,
        maxLength: CommonArguments.trackNameMaxLength,
      );
      if (trackNameError != null) usageException(trackNameError);
      return DeploymentTrack(trackName);
    }

    if (shorebirdEnv.canAcceptUserInput) {
      return logger.chooseOne<DeploymentTrack>(
        'Which track should this patch be published to?',
        choices: const [
          DeploymentTrack.staging,
          DeploymentTrack.beta,
          DeploymentTrack.stable,
        ],
        defaultValue: DeploymentTrack.staging,
        display: (track) => track.channel,
      );
    }

    logger.warn(
      'No --track given, so this patch is published to the stable track, '
      'which reaches all users. A future release will require --track when '
      'it cannot ask. Pass --track=stable to keep publishing to stable, or '
      '--track=staging to test the patch before promoting it.',
    );
    _usedDefaultTrack = true;
    return DeploymentTrack.stable;
  }

  @override
  Future<int> run() async {
    final releaseTypes = releaseTypesOrUsageError(siblingCommand: 'patches');

    final ddMaxBytes = results[CommonArguments.ddMaxBytesArg.name] as String?;
    if (ddMaxBytes != null && (int.tryParse(ddMaxBytes) ?? -1) < 0) {
      usageException(
        '--${CommonArguments.ddMaxBytesArg.name} must be a non-negative '
        'integer (got $ddMaxBytes).',
      );
    }

    if (results.wasParsed('staging')) {
      return reportError(
        message: '--staging is no longer supported.',
        hint: 'Pass --track=staging instead.',
      );
    }

    final patchers = [
      for (final releaseType in releaseTypes) _resolvePatcher(releaseType),
    ];
    // One invocation publishes one patch spanning every platform.
    final published = await createPatch(patchers);

    if (isJsonMode) {
      emitJsonSuccess({
        'app_id': appId,
        'track': track.channel,
        'patches': [for (final p in published) p.toJson()],
      });
    }

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

  /// Creates a single patch spanning every platform in [patchers].
  ///
  /// One invocation produces one patch, not one per platform: patches are not
  /// platform-scoped server-side, and each uploaded artifact carries its own
  /// platform. That gives `--platforms=android,ios` a single patch number, a
  /// single promotion, and a single rollback.
  ///
  /// The phases matter. Everything that can fail cheaply (preconditions,
  /// argument validation, release resolution, downloads, signing and
  /// obfuscation setup) runs for *every* platform before any platform is
  /// built, and the patch is promoted only once every platform's artifacts
  /// have uploaded. An unpromoted patch is served to nobody, so a failure at
  /// any point leaves an inert patch rather than a live one covering only the
  /// platforms that happened to finish first.
  ///
  /// Returns what was published, one entry per platform, all naming the same
  /// patch. A dry run does not return: it exits the process with success once
  /// the patch has been checked.
  @visibleForTesting
  Future<List<PublishedPatch>> createPatch(List<Patcher> patchers) async {
    // Preflight every platform before doing any work. Preconditions are
    // platform-specific (the Apple patchers require macOS), so patching
    // android+ios from a Linux CI runner must fail now, not after the Android
    // patch has been built.
    for (final patcher in patchers) {
      await _assertCanPatch(patcher);
    }

    // Parsed here rather than where it's used, so a bad value fails before any
    // build instead of after every platform has been compiled and linked.
    parseMinLinkPercentage();

    await cache.updateAll();

    final app = await codePushClientWrapper.getApp(appId: appId);

    final resolved = await _resolveRelease(patchers);
    final release = resolved.release;

    for (final patcher in patchers) {
      assertReleaseContainsPlatform(release: release, patcher: patcher);
      assertReleaseIsActive(release: release, patcher: patcher);
      _assertCanSignForRelease(release: release, patcher: patcher);
      _assertReleaseSignedForPolicy(
        app: app,
        release: release,
        patcher: patcher,
      );
      _warnIfFlutterRevisionHasKnownIssue(release: release, patcher: patcher);
    }

    try {
      // Once per DISTINCT target platform: a patch may span several, and
      // hydration is per-platform. installRevision is idempotent, so repeat
      // calls only re-check stamps.
      for (final releasePlatform in {
        for (final patcher in patchers) patcher.releaseType.releasePlatform,
      }) {
        await shorebirdFlutter.installRevision(
          revision: release.flutterRevision,
          releasePlatform: releasePlatform,
        );
      }
    } on Exception {
      throw ProcessExit(ExitCode.software.code);
    }

    final releaseFlutterShorebirdEnv = shorebirdEnv.copyWith(
      flutterRevisionOverride: release.flutterRevision,
    );

    // AFTER selection and hydration, exactly as the release path does, and
    // against the RELEASE's revision rather than the ambient one. Asserting
    // first judged a checkout whose engine artifacts had not been fetched yet,
    // and reported an absent engine as an incoherent toolchain.
    //
    // Same gate as the release path: a patch built by an incoherent toolchain
    // is as unpublishable as a release cut by one. The patch path passes its
    // own platform too, so a release-only fix would recreate the asymmetry the
    // platform scoping just removed.
    //
    // Also fails before downloading anything if the release's Flutter is too
    // old.
    await runScoped(
      () async {
        for (final patcher in patchers) {
          await toolchainCoherence.assertCoherent(
            releasePlatform: patcher.releaseType.releasePlatform,
          );
          await _assertReleaseFlutterVersionSupported(
            patcher: patcher,
            release: release,
          );
          await patcher.assertEngineCanPatch();
        }
        await _warnIfInstallOnlySkipsSignatureCheck(release: release);
      },
      values: {shorebirdEnvRef.overrideWith(() => releaseFlutterShorebirdEnv)},
    );

    // The extracted supplements (including any obfuscation map a build loads)
    // are needed until the patch is built and published.
    final downloads = <Patcher, _ReleaseDownloads>{};
    try {
      for (final patcher in patchers) {
        await patcher.prepareForRelease(appId: appId, release: release);
        final downloaded = await _downloadReleaseArtifacts(
          patcher: patcher,
          release: release,
        );
        downloads[patcher] = downloaded;
        patcher.assetsOnly = assetsOnly;
        _configureSigning(
          patcher: patcher,
          release: release,
          releaseArtifact: downloaded.releaseArtifact,
        );
        await _configureObfuscation(
          patcher: patcher,
          release: release,
          obfuscationMapFile: downloaded.obfuscationMapFile,
        );
        _assertBuildFlagsMatchRelease(
          patcher: patcher,
          release: release,
          supplementDirectory: downloaded.supplementDirectory,
        );
      }

      return await runScoped(
        () => _buildAndPublishPatch(
          patchers: patchers,
          app: app,
          release: release,
          inferredReleaseVersion: resolved.inferredReleaseVersion,
          downloads: downloads,
        ),
        values: {
          shorebirdEnvRef.overrideWith(() => releaseFlutterShorebirdEnv),
        },
      );
    } finally {
      for (final downloaded in downloads.values) {
        if (downloaded.supplementDirectory case final directory?) {
          directory.deleteTemporarySync();
        }
      }
    }
  }

  /// The patchers [_assertCanPatch] has already passed.
  final _checkedPatchers = Set<Patcher>.identity();

  /// Checks that [patcher] can build a patch with the given arguments and
  /// flavors, exiting otherwise. A patcher already checked is not checked
  /// again.
  Future<void> _assertCanPatch(Patcher patcher) async {
    if (_checkedPatchers.contains(patcher)) return;
    await patcher.assertPreconditions();
    await patcher.assertArgsAreValid();
    assertSigningArgsValid();

    // Resolve the track now so a bad --track, or the prompt for a missing
    // one, comes before the build rather than after it. A dry run publishes
    // nothing, so it only checks a --track that was given.
    if (results['dry-run'] != true || results['track'] != null) {
      _track ??= _resolveTrack();
    }

    try {
      await shorebirdValidator.validateFlavors(
        flavorArg: flavor,
        releasePlatform: patcher.releaseType.releasePlatform,
      );
    } on ValidationFailedException catch (e) {
      throw PreconditionFailedExit(e);
    }
    _checkedPatchers.add(patcher);
  }

  /// Determines which release to patch.
  ///
  /// Every platform in one patch shares one release, so the release has to
  /// cover *all* of [patchers]' platforms. Resolving per platform could
  /// otherwise straddle versions, such as patching android against 1.0.2 and
  /// ios against 1.0.1 in the same invocation.
  ///
  /// Without `--release-version`, the release is chosen from the app's
  /// releases. Without a terminal to prompt in, that works only when exactly
  /// one release covers every platform.
  Future<({Release release, bool inferredReleaseVersion})> _resolveRelease(
    List<Patcher> patchers,
  ) async {
    // Always false in this fork, which never guesses (see below); kept so the
    // plumbing matches upstream.
    const inferredReleaseVersion = false;
    final Release release;
    final releaseTypes = [for (final patcher in patchers) patcher.releaseType];
    if (useLatestRelease) {
      final releases = await codePushClientWrapper.getReleases(appId: appId);
      releases
        ..removeWhere(
          (release) => !releaseTypes.every(
            (type) => release.hasPlatform(type.releasePlatform),
          ),
        )
        ..sortByUpdatedAt();
      if (releases.isEmpty) {
        throw _noReleasesToPatch(releaseTypes);
      }
      // Use the most recently updated release covering every platform.
      release = releases.last;
    } else if (results.wasParsed('release-version')) {
      final releaseVersion = results['release-version'] as String;
      release = await codePushClientWrapper.getRelease(
        appId: appId,
        releaseVersion: releaseVersion,
      );
    } else {
      // Upstream guesses the release version here when it can't prompt, by
      // building the app and reading the version out of the artifact
      // (deprecated, to be removed after 2027-01-01:
      // shorebirdtech/shorebird#4354). This fork never guesses: it goes to
      // the chooser, which takes the only release without prompting and, when
      // there are several and nothing can prompt, refuses with
      // InteractivePromptRequiredException (exit 64) before any build.
      release = await promptForRelease(releaseTypes);
    }

    return (
      release: release,
      inferredReleaseVersion: inferredReleaseVersion,
    );
  }

  /// Downloads [release]'s primary artifact and, if the platform has one, its
  /// supplement, which is extracted. Detects whether the release was built
  /// with obfuscation from the supplement's obfuscation map.
  Future<_ReleaseDownloads> _downloadReleaseArtifacts({
    required Patcher patcher,
    required Release release,
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

    return (
      releaseArtifact: releaseArtifact,
      releaseArchive: releaseArchive,
      supplementDirectory: supplementDirectory,
      obfuscationMapFile: obfuscationMapFile,
    );
  }

  /// Configures [patcher] to build the patch against the key [release]'s
  /// [releaseArtifact] embeds.
  ///
  /// Shorebird signs the patches of a release that embeds a managed key, so
  /// passing a key of your own for one is a usage error.
  void _configureSigning({
    required Patcher patcher,
    required Release release,
    required ReleaseArtifact releaseArtifact,
  }) {
    final signing = releaseArtifact.signing;
    if (signing?.mode != ReleaseSigningMode.managed.value) return;

    final keyArgs = [
      CommonArguments.publicKeyArg.name,
      CommonArguments.publicKeyCmd.name,
      CommonArguments.privateKeyArg.name,
      CommonArguments.signCmd.name,
    ].where(results.wasParsed);
    if (keyArgs.isNotEmpty) {
      usageException(
        'Release ${release.version} is signed with a Shorebird-managed key, '
        'and Shorebird signs its patches. Remove '
        '${keyArgs.map((arg) => '--$arg').join(', ')}.',
      );
    }
    final publicKeyPem = signing!.publicKeyPem;
    if (publicKeyPem == null) {
      throw CommandError(
        message:
            'Release ${release.version} is signed with a Shorebird-managed '
            'key, but the server did not return it.',
        hint: 'Try again, and contact Shorebird support if this persists.',
        exitCode: ExitCode.software,
      );
    }
    patcher.releaseManagedPublicKeyPem = publicKeyPem;
  }

  /// Stops before the patch build when its dart-defines or target differ
  /// from those [release] recorded in its supplement, which would fail to
  /// link or change code the release runs. With --allow-build-flag-diffs,
  /// or when the user confirms in a terminal, it goes on: a define the code
  /// never reads changes nothing. Releases from a
  /// CLI that recorded no flags aren't checked.
  void _assertBuildFlagsMatchRelease({
    required Patcher patcher,
    required Release release,
    required Directory? supplementDirectory,
  }) {
    if (supplementDirectory == null) return;
    final file = File(p.join(supplementDirectory.path, BuildFlags.fileName));
    if (!file.existsSync()) return;
    final releaseFlags = BuildFlags.tryParse(file.readAsStringSync());
    if (releaseFlags == null) {
      logger.detail(
        'Not checking build flags: ${BuildFlags.fileName} is '
        'from a newer CLI or unreadable.',
      );
      return;
    }
    final BuildFlags patchFlags;
    try {
      patchFlags = BuildFlags.fromArgs(results, target: patcher.target);
    } on FormatException catch (error) {
      usageException(error.message);
    }
    final differences = patchFlags.differencesFrom(releaseFlags);
    if (differences.isEmpty) return;

    final platform = patcher.releaseType.releasePlatform.displayName;
    logger.warn(
      '''
This patch isn't built with the same flags as release ${release.version} ($platform):
${differences.map((line) => '  $line').join('\n')}
A patch must be built with the --dart-define values and --target of its release, or it may fail to link or change code the release runs.''',
    );
    if (allowBuildFlagDiffs) return;
    if (!shorebirdEnv.canAcceptUserInput) {
      throw CommandError(
        message: "This patch's flags don't match release ${release.version}.",
        hint:
            'Pass the same --dart-define, --dart-define-from-file and '
            '--target values as the release, or create a new release. To '
            'patch anyway, pass --allow-build-flag-diffs.',
        code: JsonErrorCode.interactivePromptRequired,
      );
    }
    if (logger.confirm('Continue anyway?')) return;
    logger.err('Aborting.');
    throw PromptDeclinedExit();
  }

  /// Configures [patcher] to build the patch with the same obfuscation as
  /// [release], which has [obfuscationMapFile] if it was obfuscated, and sets
  /// the extra Flutter build args that requires.
  Future<void> _configureObfuscation({
    required Patcher patcher,
    required Release release,
    required File? obfuscationMapFile,
  }) async {
    final releasePlatform = patcher.releaseType.releasePlatform;

    // If the user explicitly passed --obfuscate but the release has no
    // obfuscation map, the patch would be obfuscated against a non-obfuscated
    // release, producing a broken patch.
    final userPassedObfuscate = results.flagPresent('obfuscate');
    if (userPassedObfuscate && obfuscationMapFile == null) {
      usageException(
        '--obfuscate was passed, but release ${release.version} was not '
        'built with obfuscation. A patch cannot change the obfuscation mode '
        'of a release: re-run without --obfuscate to patch this release, or '
        'create a new release with --obfuscate.',
      );
    }
    if (userPassedObfuscate && obfuscationMapFile != null) {
      logger.info(
        '--obfuscate is not needed for patching. Obfuscation is applied '
        'automatically when the release was built with --obfuscate.',
      );
    }

    // Building a patch with the release's obfuscated names needs
    // gen_snapshot's --load-obfuscation-map, which older Flutter versions
    // lack. Only patches that are linked against the release need matching
    // names; elsewhere the patch is obfuscated independently instead.
    var loadObfuscationMap = obfuscationMapFile != null;
    final releaseFlutterVersion = tryParseVersion(release.flutterVersion ?? '');
    if (loadObfuscationMap &&
        releaseFlutterVersion != null &&
        !releaseFlutterVersion.satisfiesFloor(
          minimumObfuscationFlutterVersion,
        )) {
      if (patchesLinkAgainstRelease(releasePlatform)) {
        throw CommandError(
          message:
              'Release ${release.version} was built with obfuscation on '
              'Flutter $releaseFlutterVersion, but patching an obfuscated '
              '${releasePlatform.displayName} release requires Flutter '
              '$minimumObfuscationFlutterVersion or later.',
          hint:
              'Create a new release to patch. Run: '
              '${patcher.releaseType.releaseCommand()} --obfuscate '
              '--flutter-version=$minimumObfuscationFlutterVersion',
          exitCode: ExitCode.unavailable,
        );
      }
      loadObfuscationMap = false;
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
    // binary is the release's: `installRevision` has already put the release's
    // toolchain on disk, while `shorebirdEnv` is not switched over to it until
    // the build. A version gate alone would be inert against the hazard it
    // names; see GenSnapshotProbe.supportsLoadObfuscationMap for the
    // two-cells / one-flutter-revision fact that makes that so.
    if (loadObfuscationMap) {
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
          // gen_snapshot at all, so we know nothing, and refusing on
          // no-evidence would break working setups whose layout we simply
          // failed to enumerate (a --local-engine tree, an arch directory
          // that is not precached yet). gen_snapshot rejects unknown VM flags
          // loudly rather than ignoring them, so the worst case is a build
          // failure, never a silently mis-obfuscated patch. The refusal above,
          // by contrast, fires only on measured evidence.
          logger.warn(
            '''
Could not verify that gen_snapshot supports --load-obfuscation-map for Flutter revision ${release.flutterRevision}. If it does not, the patch build will fail with "Unrecognized flags: load_obfuscation_map".''',
          );
        case GenSnapshotFlagSupport.present:
          break;
      }
    }

    patcher
      ..obfuscate = obfuscationMapFile != null
      ..obfuscationMapPath = loadObfuscationMap
          ? obfuscationMapFile!.path
          : null;

    // Build extra args to inject into the Flutter build command. These use
    // --extra-gen-snapshot-options= because they're passed through Flutter's
    // build system, which forwards them to gen_snapshot. This is distinct from
    // patcher.obfuscationGenSnapshotArgs, which produces bare gen_snapshot
    // flags (e.g. --load-obfuscation-map=...) for direct gen_snapshot/linker
    // calls made by Apple patchers outside the Flutter build.
    final extraBuildArgs = <String>[];
    if (obfuscationMapFile != null) {
      extraBuildArgs.add('--obfuscate');
      if (loadObfuscationMap) {
        final loadMapOption =
            '--load-obfuscation-map=${obfuscationMapFile.path}';
        extraBuildArgs.add('--extra-gen-snapshot-options=$loadMapOption');
      }

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
    // --obfuscate may come from the user or from the obfuscation map
    // injection above; either way it needs --split-debug-info, as on release.
    final splitDebugInfo = splitDebugInfoDefault(
      obfuscate:
          results.flagPresent('obfuscate') ||
          extraBuildArgs.contains('--obfuscate'),
      hasSplitDebugInfo: results.optionPresent('split-debug-info'),
    );
    if (splitDebugInfo != null) extraBuildArgs.add(splitDebugInfo);
    patcher.extraBuildArgs = extraBuildArgs;
  }

  /// Builds every platform's patch with [release]'s Flutter revision and
  /// settings, checks each against the release, and publishes them as one
  /// patch. Must run with the release's Flutter revision in scope.
  ///
  /// A dry run exits the process with success once the patches are checked.
  Future<List<PublishedPatch>> _buildAndPublishPatch({
    required List<Patcher> patchers,
    required AppMetadata app,
    required Release release,
    required bool inferredReleaseVersion,
    required Map<Patcher, _ReleaseDownloads> downloads,
  }) async {
    await cache.updateAll();

    // After updateAll, so the cache is populated, and before anything
    // invokes Flutter. A frontend/backend mismatch here builds cleanly and
    // fails on the device instead.
    try {
      dartSdkCompatibility.validate();
    } on DartSdkMismatchException catch (error) {
      throw CommandError(
        message: '$error',
        exitCode: ExitCode.config,
      );
    }

    final bundles = <ReleasePlatform, Map<Arch, PatchArtifactBundle>>{};
    final sidecars = <ReleasePlatform, PatchSidecars>{};
    final platformMetadata = <ReleasePlatform, CreatePatchPlatformMetadata>{};
    // Shared by every platform: one invocation builds them all on one
    // machine. Each patcher may contribute fields it owns (the Apple
    // patchers add the Xcode version).
    var environment = BuildEnvironmentMetadata(
      flutterRevision: shorebirdEnv.flutterRevision,
      operatingSystem: platform.operatingSystem,
      operatingSystemVersion: platform.operatingSystemVersion,
      shorebirdVersion: packageVersion,
      shorebirdYaml: shorebirdEnv.getShorebirdYaml()!,
      usesShorebirdCodePushPackage: shorebirdEnv.usesShorebirdCodePushPackage,
    );

    for (final patcher in patchers) {
      final result = await _buildPlatformPatch(
        patcher: patcher,
        release: release,
        downloaded: downloads[patcher]!,
      );
      final releasePlatform = patcher.releaseType.releasePlatform;
      bundles[releasePlatform] = result.bundles;
      sidecars[releasePlatform] = result.sidecars;
      platformMetadata[releasePlatform] = await patcher.updatedPlatformMetadata(
        result.metadata,
      );
      environment = await patcher.updatedEnvironmentMetadata(environment);
    }

    // Recorded AFTER the build, deliberately. The server otherwise cannot
    // say which engine produced a patch: flutterRevision cannot, since two
    // Route B cells can share one Flutter revision and differ in
    // capability.
    //
    // It must not be read BEFORE the build: the engine-identity gate counts
    // reads of `shorebirdEngineRevision`; the first is its pre-build check
    // and later ones detect a stamp the Flutter build rewrote underneath it.
    // An extra early read consumed that first check, so the gate compared
    // the wrong pair and the drift test caught it. Reading here also records
    // the engine that ACTUALLY produced these artifacts rather than the one
    // present before the build.
    environment = environment.copyWith(
      engineRevision: shorebirdEnv.shorebirdEngineRevision,
    );

    for (final patcher in patchers) {
      await assertMinLinkPercentage(
        patcher,
        namePlatform: patchers.length > 1,
      );
    }

    _exitIfDryRun(patchers: patchers, release: release);

    await logPatchSummary(
      app: app,
      releaseVersion: release.version,
      patchers: patchers,
      patchArtifactBundles: bundles,
    );

    final metadata = CreatePatchMetadata(
      platforms: platformMetadata,
      usedIgnoreAssetChangesFlag: allowAssetDiffs,
      usedIgnoreNativeChangesFlag: allowNativeDiffs,
      inferredReleaseVersion: inferredReleaseVersion,
      usedDefaultTrack: _usedDefaultTrack,
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
        // devices would download and apply to no effect: a silent no-op
        // is worse than a failed patch.
        throw CommandError(
          message:
              '--assets-only was passed but no asset bundle could be '
              'packaged for: ${missing.join(', ')}.',
          exitCode: ExitCode.software,
        );
      }
    }

    // One patch, every platform's artifacts, one promotion at the end.
    final patch = await codePushClientWrapper.publishPatch(
      appId: appId,
      releaseId: release.id,
      metadata: metadata.toJson(),
      track: track,
      patchArtifactBundles: assetsOnly
          ? {for (final platform in bundles.keys) platform: const {}}
          : bundles,
      sidecars: sidecars,
    );

    return [
      for (final patcher in patchers)
        PublishedPatch(
          platform: patcher.releaseType.releasePlatform,
          release: release,
          patch: patch,
          linkPercentage: patcher.linkPercentage,
        ),
    ];
  }

  /// Builds, validates, and packages one platform's patch artifacts.
  ///
  /// Deliberately uploads nothing: every platform must get this far before any
  /// of them is published, so that a multi-platform patch is all-or-nothing.
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
    required _ReleaseDownloads downloaded,
  }) async {
    final releasePlatform = patcher.releaseType.releasePlatform;
    final supplementDirectory = downloaded.supplementDirectory;
    final configuredBuildArgs = patcher.extraBuildArgs;
    final extraBuildArgs = [...configuredBuildArgs];

    // Route B (selfhost): the patch must compile against the SAME retention
    // interface the release did. Without it the release kernel is annotated and
    // the patch kernel is not, they disagree about almost every member, and
    // coverage refuses a one-line change — measured at 4,830 changed members
    // for a single edited function.
    //
    // Read from the release's supplement, like the obfuscation map, and gated
    // on the file existing so no other platform ever sees the flag.
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

    // Only when this step added something: the arguments were already set when
    // the obfuscation settings were configured.
    if (extraBuildArgs.length != configuredBuildArgs.length) {
      patcher.extraBuildArgs = extraBuildArgs;
    }

    // Set up build tracing before any flutter build / aot_tools /
    // gen_snapshot call runs. Version-gated inside prepareBuildTrace —
    // a no-op on older Flutter pins. Called once per platform; the summary
    // is finalized below, after this platform's link step.
    await artifactBuilder.prepareBuildTrace(platform: releasePlatform.name);

    // Always build here, even if the app was built to guess the release
    // version: that build used the current Flutter and none of the release's
    // settings (obfuscation, a managed signing key).
    final flutterVersionString = await shorebirdFlutter.getVersionAndRevision();
    logger.info('''
Building ${releasePlatform.displayName} patch with Flutter $flutterVersionString
''');
    final patchArtifactFile = await _tryBuildingArtifact<File>(
      () => patcher.buildPatchArtifact(releaseVersion: release.version),
    );

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
      releaseArtifact: downloaded.releaseArtifact,
      releaseArchive: downloaded.releaseArchive,
      patchArchive: patchArtifactFile,
      patcher: patcher,
    );
    final patchArtifactBundles = await patcher.createPatchArtifacts(
      appId: appId,
      releaseId: release.id,
      releaseArtifact: downloaded.releaseArchive,
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

  /// Exits if [release] was built with a Flutter version older than
  /// [Patcher.minimumFlutterVersion]. Must run with the release's Flutter
  /// revision in scope. A version that can't be determined is let through.
  Future<void> _assertReleaseFlutterVersionSupported({
    required Patcher patcher,
    required Release release,
  }) async {
    final minimumFlutterVersion = patcher.minimumFlutterVersion;
    if (minimumFlutterVersion == null) return;

    final flutterVersion = await shorebirdFlutter.getVersion();
    if (flutterVersion == null ||
        flutterVersion.satisfiesFloor(minimumFlutterVersion)) {
      return;
    }

    final flutterVersionAndRevision = await shorebirdFlutter
        .getVersionAndRevision();
    final cliName = patcher.releaseType.cliName;
    throw CommandError(
      message:
          'Release ${release.version} was built with Flutter '
          '$flutterVersionAndRevision, but patching with `$cliName` needs at '
          'least Flutter $minimumFlutterVersion (see '
          '$supportedFlutterVersionsUrl).',
      hint:
          'A release cannot change Flutter versions, so create a new release '
          'with the latest Flutter to patch. Run: '
          '${patcher.releaseType.releaseCommand()}',
      exitCode: ExitCode.software,
    );
  }

  /// Warns if shorebird.yaml asks for `patch_verification: install_only` and
  /// [release] was built with a Flutter whose updater never checks patch
  /// signatures in that mode (since updater#352), so devices on [release]
  /// install this patch without checking its signature. Only a new release
  /// can change that, so the patch goes ahead. Must run with the release's
  /// Flutter revision in scope.
  ///
  /// Reads today's shorebird.yaml, which is the release's unless it has
  /// changed since.
  Future<void> _warnIfInstallOnlySkipsSignatureCheck({
    required Release release,
  }) async {
    final patchVerification = shorebirdEnv
        .getShorebirdYaml()
        ?.patchVerification;
    if (patchVerification != PatchVerification.installOnly) return;
    if (!installOnlySkipsSignatureCheck(shorebirdEnv.shorebirdEngineRevision)) {
      return;
    }
    final flutterVersion = await shorebirdFlutter.getVersionAndRevision();
    logger.warn(
      '''
shorebird.yaml sets `patch_verification: install_only`, which does not check patch signatures with Flutter $flutterVersion, the Flutter release ${release.version} was built with. If the release was built with this setting, devices on it will install this patch without checking its signature.
To have signatures checked, remove `patch_verification` from shorebird.yaml (or set it to `strict`) and create a new release, or release with a Flutter version that checks signatures in install_only mode, such as --flutter-version=3.41.8.''',
    );
  }

  /// Warns if Shorebird marked the Flutter revision [release] was built with
  /// as having a known problem on [patcher]'s platform. A patch can't change
  /// the Flutter a release was built with, so the patch goes ahead; the fix
  /// is a new release.
  void _warnIfFlutterRevisionHasKnownIssue({
    required Release release,
    required Patcher patcher,
  }) {
    final issue = release.flutterRevisionIssue;
    if (issue == null) return;
    final platform = patcher.releaseType.releasePlatform;
    final platforms = issue.platforms;
    if (platforms != null && !platforms.contains(platform)) return;

    String flutterBuild(String? version, String revision) {
      final shortRevision = revision.length > 10
          ? revision.substring(0, 10)
          : revision;
      return version == null
          ? 'Flutter revision $shortRevision'
          : 'Flutter $version ($shortRevision)';
    }

    final details = issue.details;
    final fixedInRevision = issue.fixedInRevision;
    final releaseWith = fixedInRevision == null
        ? 'a Flutter version without this problem'
        : '${flutterBuild(issue.fixedInVersion, fixedInRevision)} or newer';
    final builtWith = flutterBuild(
      release.flutterVersion,
      release.flutterRevision,
    );
    final problem =
        'Release ${release.version} was built with $builtWith, which has a '
        'known problem on ${platform.displayName}: ${issue.summary}';
    final fix =
        'A patch cannot change the Flutter version a release was built with. '
        'To fix this, create a new release with $releaseWith.';
    logger.warn([problem, ?details, fix].join('\n'));
  }

  /// Parses and validates `--min-link-percentage`.
  @visibleForTesting
  int parseMinLinkPercentage() {
    final raw = results[CommonArguments.minLinkPercentage.name] as String;
    final value = int.tryParse(raw);
    if (value == null ||
        value < CommonArguments.minLinkPercentageMin ||
        value > CommonArguments.minLinkPercentageMax) {
      usageException(
        '--min-link-percentage must be an integer between '
        '${CommonArguments.minLinkPercentageMin} and '
        '${CommonArguments.minLinkPercentageMax} '
        '(got $raw).',
      );
    }
    return value;
  }

  /// Exits with an error when [patcher]'s link percentage is below
  /// `--min-link-percentage`. Runs before `--dry-run` exits, so a dry run
  /// fails the same way the real run would.
  @visibleForTesting
  Future<void> assertMinLinkPercentage(
    Patcher patcher, {
    bool namePlatform = false,
  }) async {
    final linkPercentage = patcher.linkPercentage;
    final minLinkPercentage = parseMinLinkPercentage();
    if (linkPercentage != null && linkPercentage < minLinkPercentage) {
      // The platform is only named when more than one is being patched, where
      // it says which one fell short.
      final platformName = namePlatform
          ? '${patcher.releaseType.releasePlatform.displayName} '
          : '';
      throw CommandError(
        message:
            'The ${platformName}link percentage of this patch '
            '($linkPercentage%) is below the minimum threshold '
            '($minLinkPercentage%).',
        hint:
            'Not publishing. Lower --min-link-percentage to accept this '
            'patch, or see ${Patcher.debugInfoFile.path} for what could not '
            'be linked.',
        exitCode: ExitCode.software,
      );
    }
  }

  /// Reports a successful check and exits with success if this is a dry run.
  void _exitIfDryRun({
    required List<Patcher> patchers,
    required Release release,
  }) {
    final dryRun = results['dry-run'] == true;
    if (!dryRun) return;

    if (isJsonMode) {
      // One platform keeps the single-platform shape; several are reported
      // together because they are one patch.
      final single = patchers.length == 1 ? patchers.single : null;
      emitJsonSuccess({
        'dry_run': true,
        'app_id': appId,
        if (single != null)
          'platform': single.releaseType.releasePlatform.name
        else
          'platforms': [
            for (final patcher in patchers)
              patcher.releaseType.releasePlatform.name,
          ],
        'release_id': release.id,
        'release_version': release.version,
        if (single != null)
          'link_percentage': single.linkPercentage
        else
          'link_percentages': {
            for (final patcher in patchers)
              patcher.releaseType.releasePlatform.name: patcher.linkPercentage,
          },
      });
    } else {
      logger
        ..info('No issues detected.')
        ..info('The server may enforce additional checks.');
    }
    throw ProcessExit(ExitCode.success.code);
  }

  /// Prompts the user for the specific release to patch.
  ///
  /// Only releases covering *every* requested platform are offered: one patch
  /// spans all of them, so a release missing any one of them can't be used.
  Future<Release> promptForRelease(Iterable<ReleaseType> releaseTypes) async {
    final releases = await codePushClientWrapper.getReleases(appId: appId);

    final candidates = releases.where(
      (release) => releaseTypes.every(
        (type) => release.hasPlatform(type.releasePlatform),
      ),
    );

    if (candidates.isEmpty) {
      throw _noReleasesToPatch(releaseTypes);
    }

    return chooseRelease(
      releases: candidates,
      action: 'patch',
    );
  }

  /// The error to throw when there is nothing to patch for [releaseTypes].
  ///
  /// The app id comes from the flavor's entry under `flavors` in
  /// shorebird.yaml when --flavor is passed, otherwise from `app_id`.
  CommandError _noReleasesToPatch(Iterable<ReleaseType> releaseTypes) {
    final flavor = this.flavor;
    final checkAppId = flavor == null
        ? 'check app_id in shorebird.yaml or pass --flavor'
        : 'check flavors.$flavor in shorebird.yaml';
    final releaseCommand = [
      releaseTypes.map((type) => type.releaseCommand()).join(' and '),
      if (flavor != null) '--flavor=$flavor',
    ].join(' ');
    final platforms = {for (final t in releaseTypes) t.releasePlatform};
    return CommandError(
      message: platforms.length == 1
          ? 'No ${platforms.single.displayName} releases found for app $appId.'
          : 'No releases found for app $appId covering '
                '${_platformList(platforms)}.',
      hint:
          'A patch needs a release to apply to (if this is the wrong app, '
          '$checkAppId). Run: $releaseCommand',
    );
  }

  /// Renders [platforms] as a human-readable list, e.g. "Android and iOS".
  static String _platformList(Iterable<ReleasePlatform> platforms) {
    final names = {for (final p in platforms) p.displayName}.toList();
    if (names.length == 1) return names.first;
    return '${names.take(names.length - 1).join(', ')} and ${names.last}';
  }

  /// Asserts that the release contains a platform for the given [patcher].
  void assertReleaseContainsPlatform({
    required Release release,
    required Patcher patcher,
  }) {
    final releasePlatform = patcher.releaseType.releasePlatform;
    if (!release.hasPlatform(releasePlatform)) {
      final releaseCommand = patcher.releaseType.releaseCommand(
        releaseVersion: release.version,
      );
      throw CommandError(
        message:
            'Release ${release.version} has no '
            '${releasePlatform.displayName} build.',
        hint: 'Run: $releaseCommand',
        exitCode: ExitCode.software,
      );
    }
  }

  /// Asserts that the provided [release] is active.
  void assertReleaseIsActive({
    required Release release,
    required Patcher patcher,
  }) {
    if (!release.isActiveOn(patcher.releaseType.releasePlatform)) {
      final releaseCommand = patcher.releaseType.releaseCommand(
        releaseVersion: release.version,
      );
      throw CommandError(
        message:
            'Release ${release.version} is incomplete: the release command '
            'that created it was stopped or failed.',
        hint:
            'Re-run the release for this version, or create a new one. '
            'Run: $releaseCommand',
        exitCode: ExitCode.software,
      );
    }
  }

  /// Exits if [release] embeds the customer's own key on [patcher]'s
  /// platform but no key was passed to sign the patch with: devices running
  /// the release reject an unsigned patch.
  void _assertCanSignForRelease({
    required Release release,
    required Patcher patcher,
  }) {
    final signingMode =
        release.platforms[patcher.releaseType.releasePlatform]?.signingMode;
    if (signingMode != ReleaseSigningMode.customer.value) return;

    final publicKeyPath = CommonArguments.publicKeyArg.name;
    final privateKeyPath = CommonArguments.privateKeyArg.name;
    final publicKeyCmd = CommonArguments.publicKeyCmd.name;
    final signCmd = CommonArguments.signCmd.name;
    final hasPublicKey =
        results.wasParsed(publicKeyPath) || results.wasParsed(publicKeyCmd);
    final hasSigner =
        results.wasParsed(privateKeyPath) || results.wasParsed(signCmd);
    if (hasPublicKey && hasSigner) return;

    usageException(
      'Release ${release.version} was signed with your own key, so its '
      'patches must be too. Pass the same public key as the release, with '
      '--$publicKeyPath and --$privateKeyPath, or --$publicKeyCmd and '
      '--$signCmd.',
    );
  }

  /// Exits before building if [app]'s enterprise requires patch signing and
  /// [release]'s build for [patcher]'s platform checks no signature: built
  /// with `--no-patch-signing`, or by a CLI that predates release signing.
  /// The server refuses every patch to such a release.
  void _assertReleaseSignedForPolicy({
    required AppMetadata app,
    required Release release,
    required Patcher patcher,
  }) {
    if (app.patchSigningRequired != true) return;
    final platform = patcher.releaseType.releasePlatform;
    final signingMode = release.platforms[platform]?.signingMode;
    if (signingMode == ReleaseSigningMode.managed.value ||
        signingMode == ReleaseSigningMode.customer.value) {
      return;
    }
    throw CommandError(
      message:
          '${app.enterpriseName ?? 'Your enterprise'} requires patch '
          "signing, and release ${release.version} (${platform.displayName}) "
          "wasn't built with signing, so its devices can't verify a patch.",
      hint: 'Ship a new release and patch that.',
      exitCode: ExitCode.noPerm,
    );
  }

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

    // THE ASYMMETRY THAT MATTERS. Reaching here means the RELEASE's
    // configuration is known -- it is `releaseConfig`, sitting right there --
    // and only the PATCH declines to state its own. That is not the same
    // predicament as the release-side null above, and it must not share its
    // behaviour:
    //
    //   * the release-side null is nobody's choice and has no remedy. Refusing
    //     it would strand that release forever, so it warns and proceeds.
    //   * this one is a per-invocation choice, and it is reversible by the
    //     person making it -- pass the defines the way the release did.
    //
    // Treating them alike made the whole check opt-out by one flag, and it
    // opted out in precisely the case where a mismatch is MOST likely: a patch
    // pulling defines from a file the release never had is a patch with
    // different defines. "Cannot be determined" is not evidence of agreement.
    if (patchConfig == null) {
      logger
        ..err(
          '''This patch cannot be shown to match the release's build configuration.''',
        )
        ..info(
          '''
The release's configuration IS known (fingerprint ${releaseConfig.fingerprint}), but this patch was invoked with ${routeBUnfingerprintableOptions.join(', ')}, whose effective configuration cannot be determined from the command line.

This is not the same as a release that cannot be fingerprinted -- that case is permanent and is allowed through. This one is yours to resolve: pass the same defines the release used, in a form that can be compared.''',
        )
        ..info(
          '''
Refusing before building: a patch built with a different configuration compiles a different program than the release it would replace.''',
        );
      throw ProcessExit(ExitCode.software.code);
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
  Future<PatchSidecars> _packageSidecars(Patcher patcher) async {
    final platformName = patcher.releaseType.releasePlatform.displayName;

    File? assets;
    String? assetsHashSignature;
    if (includeAssets) {
      final directory = await patcher.assetsDirectory();
      if (directory == null) {
        logger.warn(
          '--assets was passed but no assets could be resolved for '
          '$platformName. The patch will not carry an asset bundle.',
        );
      } else {
        assets = await _tryZip(directory, name: 'assets', of: platformName);
        if (assets != null) {
          // Devices install the bundle as `dlc.assets` and, in Strict mode,
          // verify this signature over the sha256 of exactly these bytes, as
          // they do for code. Null when no signing key is configured.
          assetsHashSignature = await patcher.signHash(
            sha256.convert(await assets.readAsBytes()).toString(),
          );
        }
      }
    }

    // Not gated on a flag: symbols only exist when the build was already asked
    // for them with --split-debug-info, which is the opt-in.
    File? symbols;
    if (await patcher.debugSymbolsDirectory() case final directory?) {
      symbols = await _tryZip(directory, name: 'symbols', of: platformName);
    }

    return (
      assets: assets,
      assetsHashSignature: assetsHashSignature,
      symbols: symbols,
    );
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
      // Must be awaited inside the try, otherwise the catch clauses below never
      // see the failure and the patch exits with an unhandled exception.
      return await patcher.assertUnpatchableDiffs(
        releaseArtifact: releaseArtifact,
        releaseArchive: releaseArchive,
        patchArchive: patchArchive,
      );
    } on UserCancelledException {
      logger.err('Aborting.');
      throw PromptDeclinedExit();
    } on UnpatchableChangeException catch (e) {
      // The diff checker has already listed the changes.
      final changes = e.changes;
      final native = changes.contains(UnpatchableChange.native);
      final releaseCommand = patcher.releaseType.releaseCommand(
        releaseVersion: '<new version>',
      );
      throw CommandError(
        message:
            'Not publishing: '
            '${changes.map((c) => c.description).join(' and ')} changed '
            "since the release, and a patch can't include those changes.",
        hint:
            'To ship these changes, create a new release. '
            'Run: $releaseCommand\n'
            'To publish the patch without them, pass '
            '${changes.map((c) => c.flag).join(' ')}.'
            '${native ? _nativeCrashWarning : ''}',
        exitCode: ExitCode.software,
      );
    }
  }

  /// Logs a summary of the patch to be created, including:
  /// - The app name and ID
  /// - The release version
  /// - One line per platform the patch covers, with its arches and sizes
  /// - The track
  /// - The debug info file (if a platform linked poorly)
  Future<void> logPatchSummary({
    required AppMetadata app,
    required String releaseVersion,
    required List<Patcher> patchers,
    required Map<ReleasePlatform, Map<Arch, PatchArtifactBundle>>
    patchArtifactBundles,
  }) async {
    final trackSummary = (() {
      return switch (track) {
        DeploymentTrack.staging => '🟠 Track: ${lightCyan.wrap('Staging')}',
        DeploymentTrack.beta => '🔵 Track: ${lightCyan.wrap('Beta')}',
        DeploymentTrack.stable => '🟢 Track: ${lightCyan.wrap('Stable')}',
        final String trackName => '⚪️ Track: ${lightCyan.wrap(trackName)}',
      };
    })();

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

    // A requested confirmation must not approve itself: `logger.confirm`
    // throws InteractivePromptRequiredException (exit 64) when nothing can
    // answer, so this refuses rather than publishing unattended.
    if (results[CommonArguments.confirmArg.name] == true &&
        !logger.confirm(
          'Would you like to continue?',
          defaultValue: true,
          hint:
              'Re-run with a TTY, or drop --confirm to proceed without '
              'confirmation.',
        )) {
      // Declining a confirmation the user asked for is not a failure: the
      // fork's CLI exited 0 with an info line, and scripts that run with
      // --confirm rely on that. Only the non-TTY refusal above is an error
      // (exit 64).
      logger.info('Aborting.');
      throw ProcessExit(ExitCode.success.code);
    }
  }

  /// Downloads the given [releaseArtifact].
  Future<File> downloadReleaseArtifact({
    required ReleaseArtifact releaseArtifact,
  }) async {
    final File artifactFile;
    try {
      artifactFile = await artifactManager.downloadReleaseArtifact(
        releaseArtifact,
        message: 'Downloading ${releaseArtifact.arch}',
      );
    } on Exception catch (error) {
      throw CommandError(
        message: 'Could not download the release artifact: $error',
        hint: 'Run the command again once that is fixed.',
        exitCode: ExitCode.software,
      );
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
    throw CommandError(
      message: e.message,
      hint: e.fixRecommendation.isNullOrEmpty ? null : e.fixRecommendation,
      exitCode: ExitCode.software,
    );
  } on ProcessExit {
    // The build already reported why it stopped.
    rethrow;
  } on Exception catch (e) {
    throw CommandError(
      message: 'Failed to build patch artifacts: $e',
      exitCode: ExitCode.software,
    );
  }
}

/// What [PatchCommand] downloads for one platform of the release it patches:
/// the primary artifact and, if the platform has one, the extracted
/// supplement (with the obfuscation map it holds, if any).
typedef _ReleaseDownloads = ({
  ReleaseArtifact releaseArtifact,
  File releaseArchive,
  Directory? supplementDirectory,
  File? obfuscationMapFile,
});

/// Extension on list of releases for sorting the releases.
extension SortReleases on List<Release> {
  /// Sort the list of releases by when they were last updated ascending.
  void sortByUpdatedAt() => sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
}

/// {@template published_patch}
/// One platform's outcome of `shorebird patch`: which release it patched,
/// the patch that resulted, and how much of the release's Dart code the
/// patch could share with it.
/// {@endtemplate}
class PublishedPatch {
  /// {@macro published_patch}
  const PublishedPatch({
    required this.platform,
    required this.release,
    required this.patch,
    required this.linkPercentage,
  });

  /// The platform the patch was built for.
  final ReleasePlatform platform;

  /// The release the patch applies to.
  final Release release;

  /// The patch as the server created it.
  final CreatePatchResponse patch;

  /// The share of Dart code linked against the release, as a percentage,
  /// where the platform reports one.
  final double? linkPercentage;

  /// The shape written into the `--json` envelope.
  Map<String, dynamic> toJson() => {
    'platform': platform.name,
    'release_id': release.id,
    'release_version': release.version,
    'patch_id': patch.id,
    'patch_number': patch.number,
    'link_percentage': linkPercentage,
  };
}
