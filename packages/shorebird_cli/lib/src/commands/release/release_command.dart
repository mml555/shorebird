import 'dart:async';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/build_trace_session.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/release/release.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/dart_sdk_compatibility.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/extensions/string.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/metadata/metadata.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_documentation.dart';
import 'package:shorebird_cli/src/runtime_endpoint.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/toolchain_coherence.dart';
import 'package:shorebird_cli/src/version.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

/// A function that resolves a [Releaser] for a given [ReleaseType].
typedef ResolveReleaser = Releaser Function(ReleaseType releaseType);

/// {@template release_command}
/// Creates a new app release for the specified platform(s).
/// {@endtemplate}
class ReleaseCommand extends ShorebirdCommand {
  /// {@macro release_command}
  ReleaseCommand({ResolveReleaser? resolveReleaser}) {
    _resolveReleaser = resolveReleaser ?? getReleaser;
    argParser
      ..addMultiOption(
        CommonArguments.dartDefineArg.name,
        help: CommonArguments.dartDefineArg.description,
      )
      ..addMultiOption(
        CommonArguments.dartDefineFromFileArg.name,
        help: CommonArguments.dartDefineFromFileArg.description,
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
        CommonArguments.buildNameArg.name,
        help: CommonArguments.buildNameArg.description,
        defaultsTo: CommonArguments.buildNameArg.defaultValue,
      )
      ..addOption(
        CommonArguments.buildNumberArg.name,
        help: CommonArguments.buildNumberArg.description,
        defaultsTo: CommonArguments.buildNumberArg.defaultValue,
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
        help: 'Validate but do not upload the release.',
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
      ..addOption(
        'flutter-version',
        defaultsTo: 'latest',
        help: '''
The Flutter version to use when building the app (e.g: 3.16.3).
This option also accepts Flutter commit hashes (e.g. 611a4066f1).
Defaults to "latest" which builds using the latest stable Flutter version.''',
      )
      ..addOption(
        'artifact',
        help:
            '''The type of artifact to generate. Only relevant for Android releases.''',
        allowed: ['aab', 'apk'],
        defaultsTo: 'aab',
        allowedHelp: {
          'aab': 'Android App Bundle',
          'apk': 'Android Package Kit',
        },
      )
      ..addMultiOption(
        'platforms',
        abbr: 'p',
        help: 'The platform(s) to build this release for.',
        allowed: ReleaseType.values.map((e) => e.cliName).toList(),
        // TODO(bryanoltman): uncomment this once https://github.com/dart-lang/args/pull/273 lands
        // mandatory: true.
      )
      ..addFlag(
        'split-per-abi',
        help:
            'Whether to split the APKs per ABIs (Android only). '
            'To learn more, see: https://developer.android.com/studio/build/configure-apk-splits#configure-abi-split',
        hide: true,
        negatable: false,
      )
      // Added for https://github.com/shorebirdtech/shorebird/issues/3223.
      // Can be removed fall 2026 or later.
      ..addFlag(
        'confirm',
        hide: true,
      )
      ..addOption(
        'release-version',
        help: '''
The version of the associated release (e.g. "1.0.0"). This should be the version
of the iOS app that is using this module. (aar and ios-framework only)''',
      )
      ..addMultiOption(
        'target-platform',
        help: 'The target platform(s) for which the app is compiled.',
        defaultsTo: Arch.values.map((arch) => arch.targetPlatformCliArg),
        allowed: Arch.values.map((arch) => arch.targetPlatformCliArg),
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
        CommonArguments.splitDebugInfoArg.name,
        help: CommonArguments.splitDebugInfoArg.description,
      )
      ..addFlag(
        CommonArguments.obfuscateArg.name,
        help: CommonArguments.obfuscateArg.description,
        negatable: false,
      )
      ..addOption(
        'dd-max-bytes',
        defaultsTo: '10000',
        // Hidden from --help: changing this off the default is almost never
        // the right call for end users. The flag is here for internal
        // testing of the cascade limiter against patch flows.
        hide: true,
        help:
            'Dynamic Dispatch table cascade byte threshold. '
            'Functions whose transitive caller tree exceeds this many bytes '
            'are routed through the indirect dispatch table. '
            'Set to 0 to disable.',
      );
  }

  late final ResolveReleaser _resolveReleaser;

  @override
  String get description =>
      'Creates a shorebird release for the provided target platforms.';

  @override
  String get name => 'release';

  @override
  Future<int> run() async {
    if (results.releaseTypes.isEmpty) {
      logger.err(
        '''No platforms were provided. Use the --platforms argument to provide one or more platforms''',
      );
      return ExitCode.usage.code;
    }

    final releaserFutures = results.releaseTypes
        .map(_resolveReleaser)
        .map(createRelease);

    for (final future in releaserFutures) {
      await future;
    }

    return ExitCode.success.code;
  }

  /// Returns a [Releaser] for the given [ReleaseType].
  @visibleForTesting
  Releaser getReleaser(ReleaseType releaseType) {
    switch (releaseType) {
      case ReleaseType.aar:
        return AarReleaser(argResults: results, flavor: flavor, target: target);
      case ReleaseType.android:
        return AndroidReleaser(
          argResults: results,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.ios:
        return IosReleaser(argResults: results, flavor: flavor, target: target);
      case ReleaseType.iosFramework:
        return IosFrameworkReleaser(
          argResults: results,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.linux:
        return LinuxReleaser(
          argResults: results,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.macos:
        return MacosReleaser(
          argResults: results,
          flavor: flavor,
          target: target,
        );
      case ReleaseType.windows:
        return WindowsReleaser(
          argResults: results,
          flavor: flavor,
          target: target,
        );
    }
  }

  /// Whether to prompt for confirmation before creating the release.
  bool get confirm => results['confirm'] == true;

  /// The shorebird app ID for the current project.
  String get appId => shorebirdEnv.getShorebirdYaml()!.getAppId(flavor: flavor);

  /// The build flavor, if provided.
  String? get flavor => results.findOption('flavor', argParser: argParser);

  /// The target script, if provided.
  String? get target => results.findOption('target', argParser: argParser);

  /// The flutter version specified.
  String get flutterVersionArg => results['flutter-version'] as String;

  /// The build name specified via `--build-name`.
  String? get buildName =>
      results[CommonArguments.buildNameArg.name] as String?;

  /// The build number specified via `--build-number.
  String? get buildNumber =>
      results[CommonArguments.buildNumberArg.name] as String?;

  /// The workflow to create a new release for a Shorebird app.
  ///
  /// Expectations for methods invoked by this command:
  ///  - They perform their own logging. If an error occurs, they are
  ///    responsible for properly logging the error, cleaning up running
  ///    [Progress]es, etc.
  ///  - They handle their own exceptions and exit with a non-zero exit code if
  ///    an error occurs *instead of* throwing an exception.
  @visibleForTesting
  Future<void> createRelease(Releaser releaser) async {
    await releaser.assertPreconditions();
    await assertArgsAreValid(releaser);

    try {
      await shorebirdValidator.validateFlavors(
        flavorArg: flavor,
        releasePlatform: releaser.releaseType.releasePlatform,
      );
    } on ValidationFailedException {
      throw ProcessExit(ExitCode.config.code);
    }

    // BEFORE anything is built or fetched. A self-hosted workflow must not be
    // able to publish a release whose runtime points at upstream Shorebird:
    // the app would ask api.shorebird.dev for patches to an app that exists
    // only here, be offered nothing, and report no error. Absence of a
    // base_url still means "use Shorebird's service" for an upstream workflow,
    // which this does not touch.
    runtimeEndpoint.assertShippable();

    await cache.updateAll();

    // This command handles logging, we don't need to provide our own
    // progress, error logs, etc.
    final app = await codePushClientWrapper.getApp(appId: appId);
    final targetFlutterRevision = await resolveTargetFlutterRevision();
    try {
      await shorebirdFlutter.installRevision(
        revision: targetFlutterRevision,
        releasePlatform: releaser.releaseType.releasePlatform,
      );
    } on Exception {
      throw ProcessExit(ExitCode.software.code);
    }

    // COHERENCE COMES AFTER SELECTION AND HYDRATION, and the order is the whole
    // point. It used to run first, against whatever revision happened to be
    // pinned, and before the target revision's engine artifacts existed — so a
    // correctly published cell was refused with
    // `COHERENCE_UNDETERMINABLE: …/engine/ios-release/gen_snapshot_arm64 is
    // missing` on a fresh checkout the bootstrap had just created. An absent
    // engine is not an incoherent one; it is an engine nobody had fetched yet.
    //
    // Still BEFORE any artifact is produced, which is what the check is for: a
    // mixed toolchain ships releases that cannot be patched and kernels that
    // abort the mandatory profile step, and both were previously discovered
    // only after publication.
    //
    // Asserted against the TARGET revision, not the ambient one, because
    // --flutter-version may select a different Flutter than the pin.
    // Captured BEFORE entering the scope. Building it inside the override
    // closure resolves `shorebirdEnv` from the scope being defined, so
    // copyWith recurses into itself — that overflowed the stack.
    final targetEnv = shorebirdEnv.copyWith(
      flutterRevisionOverride: targetFlutterRevision,
    );
    await runScoped(
      () async => toolchainCoherence.assertCoherent(
        releasePlatform: releaser.releaseType.releasePlatform,
      ),
      values: {shorebirdEnvRef.overrideWith(() => targetEnv)},
    );

    // If a user explicitly specified --build-name (and optionally
    // --build-number), we ensure that the version is releasable to avoid
    // unnecessarily waiting for a build.
    if (buildName != null) {
      final version = buildName!;
      await ensureVersionIsReleasable(
        version: buildNumber != null ? '$version+$buildNumber' : version,
        flutterRevision: targetFlutterRevision,
        releasePlatform: releaser.releaseType.releasePlatform,
      );
    }

    final releaseFlutterShorebirdEnv = shorebirdEnv.copyWith(
      flutterRevisionOverride: targetFlutterRevision,
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

        // Set up build tracing for this platform before any flutter build /
        // aot_tools / gen_snapshot call runs. Version-gated inside
        // prepareBuildTrace — a no-op on older Flutter pins. Finalized at
        // the end of finalizeRelease, after upload, so uploaded metadata
        // reflects the whole command.
        await artifactBuilder.prepareBuildTrace(
          platform: releaser.releaseType.releasePlatform.name,
        );

        final flutterVersionString = await shorebirdFlutter
            .getVersionAndRevision();
        logger.info(
          '''Building ${releaser.artifactDisplayName} with Flutter $flutterVersionString''',
        );
        final FileSystemEntity releaseArtifact;
        try {
          releaseArtifact = await releaser.buildReleaseArtifacts();
        } on ArtifactBuildException catch (e) {
          logger.err(e.message);
          if (!e.fixRecommendation.isNullOrEmpty) {
            logger.info(e.fixRecommendation);
          }
          throw ProcessExit(ExitCode.software.code);
        } on Exception catch (e) {
          logger.err('Failed to build release artifacts: $e');
          throw ProcessExit(ExitCode.software.code);
        }

        final releaseVersion = await releaser.getReleaseVersion(
          releaseArtifactRoot: releaseArtifact,
        );

        // Ensure we can create a release from what we've built.
        await ensureVersionIsReleasable(
          version: releaseVersion,
          flutterRevision: targetFlutterRevision,
          releasePlatform: releaser.releaseType.releasePlatform,
        );

        final dryRun = results['dry-run'] == true;
        if (dryRun) {
          logger
            ..info('No issues detected.')
            ..info('The server may enforce additional checks.');
          throw ProcessExit(ExitCode.success.code);
        }

        await printReleaseSummary(
          app: app,
          releaseVersion: releaseVersion,
          flutterVersion: targetFlutterRevision,
          releasePlatform: releaser.releaseType.releasePlatform,
        );

        final release = await getOrCreateRelease(
          version: releaseVersion,
          releasePlatform: releaser.releaseType.releasePlatform,
        );
        await prepareRelease(release: release, releaser: releaser);
        await releaser.uploadReleaseArtifacts(release: release, appId: appId);
        await finalizeRelease(release: release, releaser: releaser);

        logger
          ..success('''

✅ Published Release ${release.version}!''')
          ..info(releaser.postReleaseInstructions);

        printPatchInstructions(
          releaser: releaser,
          releaseVersion: releaseVersion,
          releaseType: releaser.releaseType,
          flavor: flavor,
          target: target,
        );
      },
      values: {shorebirdEnvRef.overrideWith(() => releaseFlutterShorebirdEnv)},
    );
  }

  /// Validates arguments that are common to all release types.
  Future<void> assertArgsAreValid(Releaser releaser) async {
    results.assertAbsentOrValidPublicKeyOrCmd();

    final shorebirdYaml = shorebirdEnv.getShorebirdYaml();
    final hasPublicKey =
        results.wasParsed(CommonArguments.publicKeyArg.name) ||
        results.wasParsed(CommonArguments.publicKeyCmd.name);

    // REFUSED, not warned, and refused HERE rather than at patch time.
    //
    // The self-hosted updater has no production install-time signature
    // verification: the only code that verifies an InstallOnly patch lives
    // behind #[cfg(test)]. So a release cut with this mode produces clients
    // that never verify a patch, whatever a later patch command does — and a
    // refusal at patch time cannot repair a client already in the field.
    //
    // Checked before the unsigned warning so a command that is going to fail
    // for an unsupported verification mode does not also emit signing noise.
    if (shorebirdYaml?.patchVerification == PatchVerification.installOnly) {
      logger.err(
        '''
patch_verification: install_only is unsupported by the self-hosted updater
because production install-time signature verification is not implemented.
Use patch_verification: strict.''',
      );
      throw ProcessExit(ExitCode.config.code);
    }

    // Unconditional on the ABSENCE OF A KEY, not on the presence of a
    // patch_verification entry.
    //
    // It previously warned only when patch_verification was set, which left the
    // most common configuration — no entry, no key — silent, even though that
    // release verifies nothing: Strict without a public key skips verification
    // outright. The message states the security consequence rather than the
    // config interaction, because "patch_verification will have no effect" is
    // not what a reader needs to know when there is no patch_verification entry
    // to begin with.
    if (!hasPublicKey) {
      logger.warn(
        'No patch public key was provided. Patches for this release will not '
        'be cryptographically verified on the device.\n'
        'To enable verification, provide '
        '--${CommonArguments.publicKeyArg.name} or '
        '--${CommonArguments.publicKeyCmd.name}.',
      );
    }

    final version = await shorebirdFlutter.resolveFlutterVersion(
      flutterVersionArg,
    );
    final minimumFlutterVersion = releaser.minimumFlutterVersion;
    if (minimumFlutterVersion != null &&
        version != null &&
        version < minimumFlutterVersion) {
      logger.err('''
At least Flutter $minimumFlutterVersion is required to release with `${releaser.releaseType.name}`.
For more information see: ${supportedFlutterVersionsUrl.toLink()}''');
      throw ProcessExit(ExitCode.usage.code);
    }

    // Ask the releaser to assert its own args are valid.
    await releaser.assertArgsAreValid();
  }

  /// Determines which Flutter version to use for the release. This will be
  /// either the version specified by the user or the version provided by
  /// [shorebirdEnv]. Will exit with [ExitCode.software] if the version
  /// specified by the user is not found/supported.
  Future<String> resolveTargetFlutterRevision() async {
    if (flutterVersionArg == 'latest') return shorebirdEnv.flutterRevision;

    // Fetch the latest remote refs so that release branch pointers
    // (e.g. flutter_release/3.38.5) are up to date.
    await shorebirdFlutter.fetchRemoteRefs();

    final String? revision;
    try {
      revision = await shorebirdFlutter.resolveFlutterRevision(
        flutterVersionArg,
      );
    } on Exception catch (error) {
      logger.err('''
Unable to determine revision for Flutter version: $flutterVersionArg.
$error''');
      throw ProcessExit(ExitCode.software.code);
    }

    if (revision == null) {
      final openIssueLink = link(
        uri: Uri.parse(
          'https://github.com/shorebirdtech/shorebird/issues/new?assignees=&labels=feature&projects=&template=feature_request.md&title=feat%3A+',
        ),
        message: 'open an issue',
      );
      logger.err('''
Version $flutterVersionArg not found. Please $openIssueLink to request a new version.
Use `shorebird flutter versions list` to list available versions.
''');
      throw ProcessExit(ExitCode.software.code);
    }

    return revision;
  }

  /// Asserts that a release with version [version] can be released using
  /// flutter revision [flutterRevision]. If a release has already been
  /// published with the given [version] for the platform [releasePlatform], or
  /// if a release already exists with [version] but was compiled with a
  /// different Flutter revision, an error will be thrown.
  Future<void> ensureVersionIsReleasable({
    required String version,
    required String flutterRevision,
    required ReleasePlatform releasePlatform,
  }) async {
    final existingRelease = await codePushClientWrapper.maybeGetRelease(
      appId: appId,
      releaseVersion: version,
    );

    if (existingRelease != null) {
      codePushClientWrapper.ensureReleaseIsNotActive(
        release: existingRelease,
        platform: releasePlatform,
      );

      // All artifacts associated with a given release must be built
      // with the same Flutter revision.
      if (existingRelease.flutterRevision != flutterRevision) {
        final flutterVersion = await shorebirdFlutter.getVersionForRevision(
          flutterRevision: flutterRevision,
        );

        final formattedCurrentReleaseVersion = shorebirdFlutter.formatVersion(
          revision: flutterRevision,
          version: flutterVersion,
        );

        final formattedExistingReleaseVersion = shorebirdFlutter.formatVersion(
          revision: existingRelease.flutterRevision,
          version: existingRelease.flutterVersion,
        );

        logger
          ..err('''
${styleBold.wrap(lightRed.wrap('A release with version $version already exists but was built using a different Flutter revision.'))}
''')
          ..info(
            '''

  Existing release built with: ${lightCyan.wrap(formattedExistingReleaseVersion)}
  Current release built with: ${lightCyan.wrap(formattedCurrentReleaseVersion)}

${styleBold.wrap(lightRed.wrap('All platforms for a given release must be built using the same Flutter revision.'))}

To resolve this issue, you can:
  * Re-run the release command with "${lightCyan.wrap('--flutter-version=${existingRelease.flutterRevision}')}".
  * Delete the existing release and re-run the release command with the desired Flutter version.
  * Bump the release version and re-run the release command with the desired Flutter version.''',
          );
        throw ProcessExit(ExitCode.software.code);
      }
    }
  }

  /// Prints a summary of the release to be created.
  Future<void> printReleaseSummary({
    required AppMetadata app,
    required String releaseVersion,
    required String flutterVersion,
    required ReleasePlatform releasePlatform,
  }) async {
    final flutterVersionString = await shorebirdFlutter.getVersionAndRevision();
    // TODO(bryanoltman): include archs in the summary for android
    // (and other platforms?)
    final summary = [
      '''📱 App: ${lightCyan.wrap(app.displayName)} ${lightCyan.wrap('(${app.appId})')}''',
      if (flavor != null) '🍧 Flavor: ${lightCyan.wrap(flavor)}',
      '📦 Release Version: ${lightCyan.wrap(releaseVersion)}',
      '🕹️  Platform: ${lightCyan.wrap(releasePlatform.name)}',
      '🐦 Flutter Version: ${lightCyan.wrap(flutterVersionString)}',
    ];

    logger.info('''

${styleBold.wrap(lightGreen.wrap('🚀 Ready to create a new release!'))}

${summary.join('\n')}
''');

    // A REQUESTED CONFIRMATION MUST NOT BE SILENTLY DROPPED.
    //
    // This read `confirm && shorebirdEnv.canAcceptUserInput`, so when nothing
    // could answer the confirmation was SKIPPED and the mutation went ahead.
    // Measured by CI-NONINTERACTIVE-1: `shorebird release --confirm` with
    // fd 0
    // closed and CI=true published successfully, with no prompt in the output.
    // An operator who explicitly asked to be asked was silently approved.
    //
    // `logger.confirm` already fails closed on its own -- it calls
    // _failIfNonInteractive and throws InteractivePromptRequiredException,
    // which the runner turns into a named error and a non-zero exit. The guard
    // was preventing that mechanism from ever running. Removing it makes the
    // non-interactive case REFUSE instead of approve.
    //
    // The default path is untouched: `confirm` comes from a hidden --confirm
    // flag that defaults to FALSE (upstream #3223), so an ordinary
    // `shorebird release` neither prompts before nor refuses after this change.
    // Only an explicit --confirm is affected, which is exactly the case that
    // asked to be asked.
    if (confirm) {
      if (!logger.confirm(
        'Would you like to continue?',
        defaultValue: true,
        hint:
            'Re-run with a TTY, or drop --confirm to proceed without '
            'confirmation.',
      )) {
        logger.info('Aborting.');
        throw ProcessExit(ExitCode.success.code);
      }
    }
  }

  /// Fetches the release with version [version] from the server or creates a
  /// new release if none exists.
  Future<Release> getOrCreateRelease({
    required String version,
    required ReleasePlatform releasePlatform,
  }) async {
    return await codePushClientWrapper.maybeGetRelease(
          appId: appId,
          releaseVersion: version,
        ) ??
        await codePushClientWrapper.createRelease(
          appId: appId,
          version: version,
          flutterRevision: shorebirdEnv.flutterRevision,
          platform: releasePlatform,
        );
  }

  /// Prepares the release by updating the release status to draft.
  Future<void> prepareRelease({
    required Release release,
    required Releaser releaser,
  }) async {
    await codePushClientWrapper.updateReleaseStatus(
      appId: appId,
      releaseId: release.id,
      platform: releaser.releaseType.releasePlatform,
      status: ReleaseStatus.draft,
    );
  }

  /// Finalizes the release by updating the status to active.
  Future<void> finalizeRelease({
    required Release release,
    required Releaser releaser,
  }) async {
    // Write the build-trace summary now, after the release artifact has been
    // uploaded, so aggregate timings reflect the full command. No-op when
    // tracing wasn't set up (older Flutter pin).
    artifactBuilder.writeBuildTraceSummary();

    final hasPublicKey =
        results.wasParsed(CommonArguments.publicKeyArg.name) ||
        results.wasParsed(CommonArguments.publicKeyCmd.name);
    final baseMetadata = UpdateReleaseMetadata(
      releasePlatform: releaser.releaseType.releasePlatform,
      flutterVersionOverride: flutterVersionArg,
      includesPublicKey: hasPublicKey,
      environment: BuildEnvironmentMetadata(
        flutterRevision: shorebirdEnv.flutterRevision,
        operatingSystem: platform.operatingSystem,
        operatingSystemVersion: platform.operatingSystemVersion,
        shorebirdVersion: packageVersion,
        shorebirdYaml: shorebirdEnv.getShorebirdYaml()!,
        usesShorebirdCodePushPackage: shorebirdEnv.usesShorebirdCodePushPackage,
        // The ENGINE that produced this, so the control plane can say WHICH
        // engine did — flutterRevision cannot, since two cells can share one
        // Flutter revision and differ in capability.
        engineRevision: shorebirdEnv.shorebirdEngineRevision,
      ),
      // Attach the build-trace summary if the build produced one.
      // Null for older Flutter pins without the --shorebird-trace flag
      // or when trace parsing failed; uploader sends null-as-omitted.
      buildTraceSummary: buildTraceSession.summary?.toJson(),
    );
    final updatedMetadata = await releaser.updatedReleaseMetadata(baseMetadata);
    await codePushClientWrapper.updateReleaseStatus(
      appId: appId,
      releaseId: release.id,
      platform: releaser.releaseType.releasePlatform,
      status: ReleaseStatus.active,
      metadata: updatedMetadata.toJson(),
    );
  }

  /// Instructions explaining how to patch the release that was just created.
  void printPatchInstructions({
    required Releaser releaser,
    required String releaseVersion,
    required ReleaseType releaseType,
    String? flavor,
    String? target,
  }) {
    final baseCommand = [
      'shorebird patch',
      '--platforms=${releaseType.cliName}',
      if (flavor != null) '--flavor=$flavor',
      if (target != null) '--target=$target',
    ].join(' ');
    logger.info(
      '''To create a patch for this release, run ${lightCyan.wrap('$baseCommand --release-version=$releaseVersion')}''',
    );
  }
}
