import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:equatable/equatable.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/archive_analysis/archive_analysis.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/build_trace_session.dart';
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
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/flutter_build_options.dart';
import 'package:shorebird_cli/src/gen_snapshot_probe.dart';
import 'package:shorebird_cli/src/json_output.dart';
import 'package:shorebird_cli/src/interactive_mode.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/metadata/metadata.dart';
import 'package:shorebird_cli/src/patch_diff_checker.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/route_b_provenance.dart';
import 'package:shorebird_cli/src/shorebird_documentation.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/toolchain_coherence.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import '../../fakes.dart';
import '../../helpers.dart';
import '../../matchers.dart';
import '../../mocks.dart';

class _FakeRelease extends Fake with Equatable implements Release {
  _FakeRelease({required this.updatedAt});

  @override
  final DateTime updatedAt;

  @override
  List<Object?> get props => [updatedAt];
}

void main() {
  useTempWorkingDirectory();
  group(PatchCommand, () {
    const appId = 'test-app-id';
    const appDisplayName = 'Test App';
    const arch = 'aarch64';
    const flutterRevision = '83305b5088e6fe327fb3334a73ff190828d85713';
    const flutterVersion = '3.22.0';
    const releasePlatform = ReleasePlatform.android;
    const releaseVersion = '1.2.3+1';
    const patchArtifactBundles = {
      Arch.arm32: PatchArtifactBundle(
        arch: 'arm32',
        hash: '#',
        size: 42,
        path: '',
      ),
    };
    const shorebirdYaml = ShorebirdYaml(appId: appId);
    const diffStatus = DiffStatus(
      hasAssetChanges: false,
      hasNativeChanges: false,
    );

    final appMetadata = AppMetadata(
      appId: appId,
      displayName: appDisplayName,
      createdAt: DateTime(2023),
      updatedAt: DateTime(2023),
    );
    final release = Release(
      id: 0,
      appId: appId,
      version: releaseVersion,
      flutterRevision: flutterRevision,
      flutterVersion: flutterVersion,
      displayName: '1.2.3+1',
      platforms: const {
        releasePlatform: ReleasePlatformDetails(status: ReleaseStatus.active),
      },
      createdAt: DateTime(2023),
      updatedAt: DateTime(2023),
    );
    const releaseArtifact = ReleaseArtifact(
      id: 0,
      releaseId: 0,
      arch: arch,
      platform: releasePlatform,
      hash: '#',
      size: 42,
      url: 'https://example.com',
      canSideload: true,
    );
    const aabArtifact = ReleaseArtifact(
      id: 0,
      releaseId: 0,
      arch: arch,
      platform: releasePlatform,
      hash: '#',
      size: 42,
      url: 'https://example.com/release.aab',
      canSideload: true,
    );
    const supplementArtifact = ReleaseArtifact(
      id: 0,
      releaseId: 0,
      arch: arch,
      platform: releasePlatform,
      hash: '#',
      size: 422,
      url: 'https://example.com/supplement.zip',
      canSideload: false,
    );

    late AotTools aotTools;
    late ArgResults argResults;
    late ArtifactBuilder artifactBuilder;
    late ArtifactManager artifactManager;
    late Cache cache;
    late DartSdkCompatibility dartSdkCompatibility;
    late GenSnapshotProbe genSnapshotProbe;
    late ToolchainCoherence toolchainCoherence;
    late CodePushClientWrapper codePushClientWrapper;
    late ShorebirdLogger logger;
    late Patcher patcher;
    late Progress progress;
    late ShorebirdEnv shorebirdEnv;
    late ShorebirdFlutter shorebirdFlutter;
    late ShorebirdValidator shorebirdValidator;

    late PatchCommand command;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          aotToolsRef.overrideWith(() => aotTools),
          artifactBuilderRef.overrideWith(() => artifactBuilder),
          artifactManagerRef.overrideWith(() => artifactManager),
          buildTraceSessionRef.overrideWith(
            () => BuildTraceSession(commandStartedAt: DateTime(2023)),
          ),
          cacheRef.overrideWith(() => cache),
          dartSdkCompatibilityRef.overrideWith(() => dartSdkCompatibility),
          genSnapshotProbeRef.overrideWith(() => genSnapshotProbe),
          toolchainCoherenceRef.overrideWith(() => toolchainCoherence),
          codePushClientWrapperRef.overrideWith(() => codePushClientWrapper),
          loggerRef.overrideWith(() => logger),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          shorebirdFlutterRef.overrideWith(() => shorebirdFlutter),
          shorebirdValidatorRef.overrideWith(() => shorebirdValidator),
        },
      );
    }

    setUpAll(() {
      registerFallbackValue(CreatePatchMetadata.forTest());
      registerFallbackValue(CreatePatchPlatformMetadata.forTest());
      registerFallbackValue(BuildEnvironmentMetadata.forTest());
      registerFallbackValue(DeploymentTrack.stable);
      registerFallbackValue(FakeDiffStatus());
      registerFallbackValue(Directory(''));
      registerFallbackValue(File(''));
      registerFallbackValue(FileSetDiff.empty());
      registerFallbackValue(release);
      registerFallbackValue(FakeReleaseArtifact());
      registerFallbackValue(ReleasePlatform.android);
      registerFallbackValue(Uri.parse('https://example.com'));
    });

    void stubReleaseFlutterVersion(String version) {
      final versionedRelease = Release(
        id: release.id,
        appId: appId,
        version: releaseVersion,
        flutterRevision: flutterRevision,
        flutterVersion: version,
        displayName: release.displayName,
        platforms: const {
          ReleasePlatform.android: ReleasePlatformDetails(
            status: ReleaseStatus.active,
          ),
          ReleasePlatform.ios: ReleasePlatformDetails(
            status: ReleaseStatus.active,
          ),
        },
        createdAt: release.createdAt,
        updatedAt: release.updatedAt,
      );
      when(
        () => codePushClientWrapper.getRelease(
          appId: any(named: 'appId'),
          releaseVersion: any(named: 'releaseVersion'),
        ),
      ).thenAnswer((_) async => versionedRelease);
      when(
        () => codePushClientWrapper.getReleases(appId: any(named: 'appId')),
      ).thenAnswer((_) async => [versionedRelease]);
    }

    setUp(() {
      aotTools = MockAotTools();
      argResults = MockArgResults();
      artifactBuilder = MockArtifactBuilder();
      when(
        () => artifactBuilder.prepareBuildTrace(
          platform: any(named: 'platform'),
        ),
      ).thenAnswer((_) async {});
      when(artifactBuilder.writeBuildTraceSummary).thenReturn(null);
      artifactManager = MockArtifactManager();
      cache = MockCache();
      dartSdkCompatibility = MockDartSdkCompatibility();
      genSnapshotProbe = MockGenSnapshotProbe();
      // The producer's coherence gate is exercised by
      // toolchain_coherence_test.dart, including its refusal path; here it is
      // stubbed coherent so these tests keep testing the command.
      toolchainCoherence = MockToolchainCoherence();
      when(
        () => toolchainCoherence.assertCoherent(
          releasePlatform: any(named: 'releasePlatform'),
        ),
      ).thenAnswer((_) async {});
      codePushClientWrapper = MockCodePushClientWrapper();
      logger = MockShorebirdLogger();
      progress = MockProgress();
      patcher = MockPatcher();
      shorebirdEnv = MockShorebirdEnv();
      shorebirdFlutter = MockShorebirdFlutter();
      shorebirdValidator = MockShorebirdValidator();

      when(() => argResults['dry-run']).thenReturn(false);
      when(() => argResults['platforms']).thenReturn(['android']);
      when(() => argResults['release-version']).thenReturn(releaseVersion);
      when(
        () => argResults[CommonArguments.minLinkPercentage.name],
      ).thenReturn(CommonArguments.minLinkPercentage.defaultValue);
      when(
        () => argResults['track'],
      ).thenReturn(DeploymentTrack.stable.channel);
      when(() => argResults.wasParsed(any())).thenReturn(true);
      // wasParsed(any()) is stubbed true above, so ForwardedArgs._flagNamed goes
      // on to cast `this['obfuscate'] as bool`. The command reads forwardedArgs
      // to compute the patch's effective configuration, so this flag needs a
      // value.
      when(
        () => argResults[CommonArguments.obfuscateArg.name],
      ).thenReturn(false);
      // Likewise for the forwarded `flutter build` options: with wasParsed true
      // they are read as lists, and none were passed.
      for (final option in flutterBuildOptions) {
        when(() => argResults[option.name]).thenReturn(<String>[]);
      }
      when(() => argResults.wasParsed('staging')).thenReturn(false);
      when(
        () => argResults.wasParsed(CommonArguments.privateKeyArg.name),
      ).thenReturn(false);
      when(
        () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
      ).thenReturn(false);
      when(
        () => argResults.wasParsed(CommonArguments.publicKeyCmd.name),
      ).thenReturn(false);
      when(
        () => argResults.wasParsed(CommonArguments.signCmd.name),
      ).thenReturn(false);
      when(() => argResults.rest).thenReturn([]);

      when(aotTools.isLinkDebugInfoSupported).thenAnswer((_) async => true);
      when(aotTools.isLinkMetadataSupported).thenAnswer((_) async => true);

      when(
        () => artifactManager.downloadReleaseArtifact(
          any(),
          message: any(named: 'message'),
        ),
      ).thenAnswer((_) async => File(''));
      when(
        () => artifactManager.extractZip(
          zipFile: any(named: 'zipFile'),
          outputDirectory: any(named: 'outputDirectory'),
        ),
      ).thenAnswer((_) async {});

      when(() => cache.updateAll()).thenAnswer((_) async => {});

      when(
        () => codePushClientWrapper.getApp(appId: any(named: 'appId')),
      ).thenAnswer((_) async => appMetadata);
      when(
        () => codePushClientWrapper.getRelease(
          appId: any(named: 'appId'),
          releaseVersion: any(named: 'releaseVersion'),
        ),
      ).thenAnswer((_) async => release);
      when(
        () => codePushClientWrapper.getReleases(appId: any(named: 'appId')),
      ).thenAnswer((_) async => [release]);
      when(
        () => codePushClientWrapper.publishPatch(
          appId: any(named: 'appId'),
          releaseId: any(named: 'releaseId'),
          track: any(named: 'track'),
          patchArtifactBundles: any(named: 'patchArtifactBundles'),
          sidecars: any(named: 'sidecars'),
          metadata: any(named: 'metadata'),
        ),
      ).thenAnswer((_) async => const CreatePatchResponse(id: 3, number: 2));

      when(
        () => codePushClientWrapper.getReleaseArtifacts(
          appId: any(named: 'appId'),
          releaseId: any(named: 'releaseId'),
          architectures: any(named: 'architectures'),
          platform: any(named: 'platform'),
        ),
      ).thenAnswer(
        (_) async => {
          Arch.arm32: releaseArtifact,
          Arch.arm64: releaseArtifact,
          Arch.x86_64: releaseArtifact,
        },
      );
      when(
        () => codePushClientWrapper.getReleaseArtifact(
          appId: any(named: 'appId'),
          releaseId: any(named: 'releaseId'),
          arch: 'aab',
          platform: ReleasePlatform.android,
        ),
      ).thenAnswer((_) async => aabArtifact);
      when(
        () => codePushClientWrapper.maybeGetReleaseArtifact(
          appId: any(named: 'appId'),
          releaseId: any(named: 'releaseId'),
          arch: 'supplement',
          platform: ReleasePlatform.android,
        ),
      ).thenAnswer((_) async => supplementArtifact);

      when(
        () => logger.chooseOne<Release>(
          any(),
          choices: any(named: 'choices'),
          display: any(named: 'display'),
          hint: any(named: 'hint'),
        ),
      ).thenReturn(release);
      when(() => logger.progress(any())).thenReturn(progress);

      when(() => patcher.assertEngineCanPatch()).thenAnswer((_) async {});
      when(() => patcher.assertArgsAreValid()).thenAnswer((_) async {});
      when(() => patcher.assertPreconditions()).thenAnswer((_) async {});
      when(
        () => patcher.prepareForRelease(
          appId: any(named: 'appId'),
          release: any(named: 'release'),
        ),
      ).thenAnswer((_) async {});
      when(() => patcher.requiresReleaseVersionArg).thenReturn(false);
      when(
        () => patcher.extractReleaseVersionFromArtifact(any()),
      ).thenAnswer((_) async => releaseVersion);
      when(
        () => patcher.buildPatchArtifact(
          releaseVersion: any(named: 'releaseVersion'),
        ),
      ).thenAnswer((_) async => File(''));
      when(() => patcher.releaseType).thenReturn(ReleaseType.android);
      when(() => patcher.primaryReleaseArtifactArch).thenReturn('aab');
      when(
        () => patcher.createPatchArtifacts(
          appId: any(named: 'appId'),
          releaseId: any(named: 'releaseId'),
          releaseArtifact: any(named: 'releaseArtifact'),
          supplementDirectory: any(named: 'supplementDirectory'),
        ),
      ).thenAnswer((_) async => patchArtifactBundles);
      // The release's gen_snapshot accepts --load-obfuscation-map unless a test
      // says otherwise.
      when(
        () => genSnapshotProbe.supportsLoadObfuscationMap(
          flutterRevision: any(named: 'flutterRevision'),
          platform: any(named: 'platform'),
        ),
      ).thenAnswer((_) async => GenSnapshotFlagSupport.present);
      when(
        () => genSnapshotProbe.resolveGenSnapshots(
          flutterRevision: any(named: 'flutterRevision'),
          platform: any(named: 'platform'),
        ),
      ).thenReturn([File('/path/to/gen_snapshot')]);
      when(() => patcher.extraBuildArgs).thenReturn(const []);
      when(patcher.assetsDirectory).thenAnswer((_) async => null);
      when(() => patcher.signHash(any())).thenAnswer((_) async => null);
      when(patcher.debugSymbolsDirectory).thenAnswer((_) async => null);
      when(() => patcher.updatedPlatformMetadata(any())).thenAnswer(
        (invocation) async =>
            invocation.positionalArguments.first as CreatePatchPlatformMetadata,
      );
      when(() => patcher.updatedEnvironmentMetadata(any())).thenAnswer(
        (invocation) async =>
            invocation.positionalArguments.first as BuildEnvironmentMetadata,
      );
      when(
        () => patcher.assertUnpatchableDiffs(
          releaseArtifact: any(named: 'releaseArtifact'),
          releaseArchive: any(named: 'releaseArchive'),
          patchArchive: any(named: 'patchArchive'),
        ),
      ).thenAnswer((_) async => diffStatus);

      when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(shorebirdYaml);
      when(() => shorebirdEnv.flutterRevision).thenReturn(flutterRevision);
      when(
        () => shorebirdEnv.shorebirdEngineRevision,
      ).thenReturn('test-engine-revision');
      when(
        () => shorebirdEnv.copyWith(
          flutterRevisionOverride: any(named: 'flutterRevisionOverride'),
        ),
      ).thenAnswer((invocation) {
        when(() => shorebirdEnv.flutterRevision).thenReturn(
          invocation.namedArguments[#flutterRevisionOverride] as String,
        );
        return shorebirdEnv;
      });
      when(() => shorebirdEnv.canAcceptUserInput).thenReturn(true);
      when(() => shorebirdEnv.usesShorebirdCodePushPackage).thenReturn(false);

      when(
        () => shorebirdFlutter.getVersionAndRevision(),
      ).thenAnswer((_) async => flutterRevision);
      when(
        () => shorebirdFlutter.installRevision(
          revision: any(named: 'revision'),
          releasePlatform: any(named: 'releasePlatform'),
        ),
      ).thenAnswer((_) async => {});

      when(
        () => shorebirdValidator.validateFlavors(
          flavorArg: any(named: 'flavorArg'),
          releasePlatform: any(named: 'releasePlatform'),
        ),
      ).thenAnswer((_) async => {});

      command = PatchCommand(resolvePatcher: (_) => patcher)
        ..testArgResults = argResults
        ..testRunner = usageRunner();
    });

    test('has non-empty description', () {
      expect(command.description, isNotEmpty);
    });

    test('accepts hidden --no-confirm and --confirm', () {
      final parser = PatchCommand().argParser;
      expect(parser.options['no-confirm']!.hide, isTrue);
      expect(parser.options['confirm']!.hide, isTrue);
      expect(() => parser.parse(['--no-confirm']), returnsNormally);
      expect(parser.parse(['--confirm'])['confirm'], isTrue);
      expect(parser.parse([])['confirm'], isFalse);
    });

    test('accepts --channel as an alias of --track', () {
      final results = PatchCommand().argParser.parse(['--channel', 'beta']);
      expect(results['track'], equals('beta'));
    });

    test('accepts a hidden --dd-max-bytes option with no default', () {
      final option =
          PatchCommand().argParser.options[CommonArguments.ddMaxBytesArg.name]!;
      expect(option.hide, isTrue);
      expect(option.defaultsTo, isNull);
      expect(option.help, equals(CommonArguments.ddMaxBytesArg.description));
    });

    group('run', () {
      group('--dd-max-bytes', () {
        setUp(() {
          when(() => argResults['release-version']).thenReturn(releaseVersion);
        });

        void setDdMaxBytes(String value) {
          when(
            () => argResults[CommonArguments.ddMaxBytesArg.name],
          ).thenReturn(value);
        }

        for (final value in ['-1', 'lots', '1.5', '']) {
          test('rejects "$value" before building', () async {
            setDdMaxBytes(value);

            await expectLater(
              runWithOverrides(command.run),
              throwsA(
                isA<UsageException>().having(
                  (e) => e.message,
                  'message',
                  '--dd-max-bytes must be a non-negative integer '
                      '(got $value).',
                ),
              ),
            );
            verifyNever(
              () => patcher.buildPatchArtifact(
                releaseVersion: any(named: 'releaseVersion'),
              ),
            );
          });
        }

        for (final value in ['0', '10000']) {
          test('accepts "$value"', () async {
            setDdMaxBytes(value);

            final exitCode = await runWithOverrides(command.run);

            expect(exitCode, equals(ExitCode.success.code));
          });
        }
      });

      group('when --staging is passed', () {
        setUp(() {
          when(() => argResults.wasParsed('staging')).thenReturn(true);
        });

        test(
          'errors that --staging is unsupported and exits with usage code',
          () async {
            await expectLater(
              runWithOverrides(command.run),
              completion(equals(ExitCode.usage.code)),
            );
            verify(
              () => logger.err('--staging is no longer supported.'),
            ).called(1);
            verify(
              () => logger.info('Pass --track=staging instead.'),
            ).called(1);
          },
        );
      });

      group('when patching more than one platform', () {
        late Patcher iosPatcher;

        setUp(() {
          iosPatcher = MockPatcher();
          when(() => iosPatcher.releaseType).thenReturn(ReleaseType.ios);
          when(
            () => argResults['platforms'],
          ).thenReturn(['android', 'ios']);
          command =
              PatchCommand(
                  resolvePatcher: (type) =>
                      type == ReleaseType.ios ? iosPatcher : patcher,
                )
                ..testArgResults = argResults
                ..testRunner = usageRunner();
        });

        test(
          'checks every platform before building any of them',
          () async {
            when(
              () => iosPatcher.assertPreconditions(),
            ).thenThrow(ProcessExit(ExitCode.config.code));

            await expectLater(
              () => runWithOverrides(command.run),
              exitsWithCode(ExitCode.config),
            );

            verify(() => patcher.assertPreconditions()).called(1);
            verifyNever(
              () => patcher.buildPatchArtifact(
                releaseVersion: any(named: 'releaseVersion'),
              ),
            );
            verifyNever(
              () => codePushClientWrapper.publishPatch(
                appId: any(named: 'appId'),
                releaseId: any(named: 'releaseId'),
                metadata: any(named: 'metadata'),
                track: any(named: 'track'),
                patchArtifactBundles: any(named: 'patchArtifactBundles'),
                sidecars: any(named: 'sidecars'),
              ),
            );
          },
        );
      });
    });

    group('--assets and --assets-only', () {
      test('--assets is an opt-in flag', () {
        final parser = PatchCommand().argParser;

        expect(parser.options['assets']!.isFlag, isTrue);
        expect(parser.parse([])['assets'], isFalse);
        expect(parser.parse(['--assets'])['assets'], isTrue);
      });

      test('--assets-only is an opt-in flag', () {
        final parser = PatchCommand().argParser;

        expect(parser.options['assets-only']!.isFlag, isTrue);
        expect(parser.options['assets-only']!.negatable, isFalse);
        expect(parser.parse([])['assets-only'], isFalse);
        expect(parser.parse(['--assets-only'])['assets-only'], isTrue);
      });

      test('--assets-only implies --assets', () {
        // A patch with neither code nor assets would carry nothing at all, so
        // requiring both flags together would only trip people up.
        final args = MockArgResults();
        when(() => args['assets']).thenReturn(false);
        when(() => args['assets-only']).thenReturn(true);
        final assetsOnlyCommand = PatchCommand()..testArgResults = args;

        expect(assetsOnlyCommand.assetsOnly, isTrue);
        expect(assetsOnlyCommand.includeAssets, isTrue);
      });

      test('--assets does not imply --assets-only', () {
        final args = MockArgResults();
        when(() => args['assets']).thenReturn(true);
        when(() => args['assets-only']).thenReturn(false);
        final assetsCommand = PatchCommand()..testArgResults = args;

        expect(assetsCommand.includeAssets, isTrue);
        expect(assetsCommand.assetsOnly, isFalse);
      });

      group('when --assets-only is passed', () {
        late Directory assetsDirectory;

        Map<ReleasePlatform, PatchSidecars> publishedSidecars() =>
            verify(
                  () => codePushClientWrapper.publishPatch(
                    appId: any(named: 'appId'),
                    releaseId: any(named: 'releaseId'),
                    metadata: any(named: 'metadata'),
                    track: any(named: 'track'),
                    patchArtifactBundles: any(named: 'patchArtifactBundles'),
                    sidecars: captureAny(named: 'sidecars'),
                  ),
                ).captured.single
                as Map<ReleasePlatform, PatchSidecars>;

        setUp(() {
          when(() => argResults['assets-only']).thenReturn(true);
          assetsDirectory = Directory.systemTemp.createTempSync('assets');
          File(
            p.join(assetsDirectory.path, 'asset.txt'),
          ).writeAsStringSync('hello');
          when(
            patcher.assetsDirectory,
          ).thenAnswer((_) async => assetsDirectory);
        });

        test('tells the patcher, so it can skip code-only work', () async {
          await runWithOverrides(command.run);

          verify(() => patcher.assetsOnly = true).called(1);
        });

        test('publishes the asset bundle and no code', () async {
          await runWithOverrides(command.run);

          verify(
            () => codePushClientWrapper.publishPatch(
              appId: appId,
              releaseId: any(named: 'releaseId'),
              metadata: any(named: 'metadata'),
              track: any(named: 'track'),
              patchArtifactBundles: {ReleasePlatform.android: const {}},
              sidecars: any(named: 'sidecars'),
            ),
          ).called(1);
        });

        test('uploads an asset bundle for the platform', () async {
          await runWithOverrides(command.run);

          expect(
            publishedSidecars()[ReleasePlatform.android]?.assets,
            isNotNull,
          );
        });

        test('signs the asset bundle hash when a key is configured', () async {
          when(
            () => patcher.signHash(any()),
          ).thenAnswer((_) async => 'assets-signature');

          await runWithOverrides(command.run);

          final sidecar = publishedSidecars()[ReleasePlatform.android]!;
          // The signature is over the sha256 of the zip as uploaded, which is
          // the file the updater hashes for dlc.assets.
          final hash = sha256.convert(sidecar.assets!.readAsBytesSync());
          verify(() => patcher.signHash(hash.toString())).called(1);
          expect(sidecar.assetsHashSignature, 'assets-signature');
        });

        test('sends no signature without a key', () async {
          when(() => patcher.signHash(any())).thenAnswer((_) async => null);

          await runWithOverrides(command.run);

          final sidecar = publishedSidecars()[ReleasePlatform.android]!;
          expect(sidecar.assets, isNotNull);
          expect(sidecar.assetsHashSignature, isNull);
        });

        test('refuses to publish a patch that would carry nothing', () async {
          when(patcher.assetsDirectory).thenAnswer((_) async => null);

          await expectLater(
            runWithOverrides(command.run),
            exitsWithError(
              message: contains(
                '--assets-only was passed but no asset bundle could be '
                'packaged for: android',
              ),
              exitCode: ExitCode.software,
            ),
          );
          verifyNever(
            () => codePushClientWrapper.publishPatch(
              appId: any(named: 'appId'),
              releaseId: any(named: 'releaseId'),
              metadata: any(named: 'metadata'),
              track: any(named: 'track'),
              patchArtifactBundles: any(named: 'patchArtifactBundles'),
              sidecars: any(named: 'sidecars'),
            ),
          );
        });
      });

      test('without --assets-only, code artifacts are published', () async {
        await runWithOverrides(command.run);

        verify(() => patcher.assetsOnly = false).called(1);
        verify(
          () => codePushClientWrapper.publishPatch(
            appId: appId,
            releaseId: any(named: 'releaseId'),
            metadata: any(named: 'metadata'),
            track: any(named: 'track'),
            patchArtifactBundles: {
              ReleasePlatform.android: patchArtifactBundles,
            },
            sidecars: any(named: 'sidecars'),
          ),
        ).called(1);
      });
    });

    group('when patching several platforms in one invocation', () {
      late Patcher iosPatcher;
      late Release multiPlatformRelease;

      /// Matches any call to publishPatch, for verify and verifyNever.
      Future<CreatePatchResponse> anyPublishPatch() =>
          codePushClientWrapper.publishPatch(
            appId: any(named: 'appId'),
            releaseId: any(named: 'releaseId'),
            metadata: any(named: 'metadata'),
            track: any(named: 'track'),
            patchArtifactBundles: any(named: 'patchArtifactBundles'),
            sidecars: any(named: 'sidecars'),
          );

      Release releaseCovering(
        Set<ReleasePlatform> platforms, {
        int id = 7,
        String version = releaseVersion,
        DateTime? updatedAt,
      }) => Release(
        id: id,
        appId: appId,
        version: version,
        flutterRevision: flutterRevision,
        flutterVersion: flutterVersion,
        displayName: version,
        platforms: {
          for (final platform in platforms)
            platform: const ReleasePlatformDetails(
              status: ReleaseStatus.active,
            ),
        },
        createdAt: DateTime(2023),
        updatedAt: updatedAt ?? DateTime(2023),
      );

      setUp(() {
        iosPatcher = MockPatcher();
        when(() => iosPatcher.releaseType).thenReturn(ReleaseType.ios);
        when(
          () => iosPatcher.primaryReleaseArtifactArch,
        ).thenReturn('xcarchive');
        when(
          () => iosPatcher.supplementaryReleaseArtifactArch,
        ).thenReturn(null);
        when(() => iosPatcher.linkPercentage).thenReturn(null);
        when(() => iosPatcher.requiresReleaseVersionArg).thenReturn(false);
        when(() => iosPatcher.extraBuildArgs).thenReturn(const []);
        when(() => iosPatcher.assertArgsAreValid()).thenAnswer((_) async {});
        when(() => iosPatcher.assertPreconditions()).thenAnswer((_) async {});
        when(() => iosPatcher.assertEngineCanPatch()).thenAnswer((_) async {});
        when(
          () => iosPatcher.prepareForRelease(
            appId: any(named: 'appId'),
            release: any(named: 'release'),
          ),
        ).thenAnswer((_) async {});
        when(iosPatcher.assetsDirectory).thenAnswer((_) async => null);
        when(iosPatcher.debugSymbolsDirectory).thenAnswer((_) async => null);
        when(
          () => iosPatcher.buildPatchArtifact(
            releaseVersion: any(named: 'releaseVersion'),
          ),
        ).thenAnswer((_) async => File(''));
        when(
          () => iosPatcher.createPatchArtifacts(
            appId: any(named: 'appId'),
            releaseId: any(named: 'releaseId'),
            releaseArtifact: any(named: 'releaseArtifact'),
            supplementDirectory: any(named: 'supplementDirectory'),
          ),
        ).thenAnswer((_) async => patchArtifactBundles);
        when(
          () => iosPatcher.assertUnpatchableDiffs(
            releaseArtifact: any(named: 'releaseArtifact'),
            releaseArchive: any(named: 'releaseArchive'),
            patchArchive: any(named: 'patchArchive'),
          ),
        ).thenAnswer((_) async => diffStatus);
        when(() => iosPatcher.updatedPlatformMetadata(any())).thenAnswer(
          (invocation) async =>
              invocation.positionalArguments.first
                  as CreatePatchPlatformMetadata,
        );
        when(() => iosPatcher.updatedEnvironmentMetadata(any())).thenAnswer(
          (invocation) async =>
              invocation.positionalArguments.first as BuildEnvironmentMetadata,
        );

        multiPlatformRelease = releaseCovering({
          ReleasePlatform.android,
          ReleasePlatform.ios,
        });
        when(
          () => codePushClientWrapper.getRelease(
            appId: any(named: 'appId'),
            releaseVersion: any(named: 'releaseVersion'),
          ),
        ).thenAnswer((_) async => multiPlatformRelease);
        when(
          () => codePushClientWrapper.getReleases(appId: any(named: 'appId')),
        ).thenAnswer((_) async => [multiPlatformRelease]);
        when(
          () => codePushClientWrapper.getReleaseArtifact(
            appId: any(named: 'appId'),
            releaseId: any(named: 'releaseId'),
            arch: 'xcarchive',
            platform: ReleasePlatform.ios,
          ),
        ).thenAnswer((_) async => releaseArtifact);

        when(() => argResults['platforms']).thenReturn(['android', 'ios']);
        command =
            PatchCommand(
                resolvePatcher: (type) =>
                    type == ReleaseType.ios ? iosPatcher : patcher,
              )
              ..testArgResults = argResults
              ..testRunner = usageRunner();
      });

      test('publishes exactly one patch, with one patch number, '
          'carrying every platform', () async {
        final published = await runWithOverrides(
          () => command.createPatch([patcher, iosPatcher]),
        );

        // One publishPatch is one patch number and one promotion; the server
        // promotes the patch it just created once every artifact is uploaded.
        verify(
          () => codePushClientWrapper.publishPatch(
            appId: appId,
            releaseId: multiPlatformRelease.id,
            metadata: any(named: 'metadata'),
            track: DeploymentTrack.stable,
            patchArtifactBundles: {
              ReleasePlatform.android: patchArtifactBundles,
              ReleasePlatform.ios: patchArtifactBundles,
            },
            sidecars: any(named: 'sidecars'),
          ),
        ).called(1);
        expect(published, hasLength(2));
        expect(
          published.map((p) => p.platform),
          unorderedEquals([ReleasePlatform.android, ReleasePlatform.ios]),
        );
        expect(published.map((p) => p.patch.number).toSet(), equals({2}));
      });

      test('run publishes once and reports the one patch number', () async {
        final exitCode = await runWithOverrides(command.run);

        expect(exitCode, equals(ExitCode.success.code));
        verify(anyPublishPatch).called(1);
      });

      test('records metadata for every platform', () async {
        await runWithOverrides(command.run);

        final metadata =
            verify(
                  () => codePushClientWrapper.publishPatch(
                    appId: any(named: 'appId'),
                    releaseId: any(named: 'releaseId'),
                    metadata: captureAny(named: 'metadata'),
                    track: any(named: 'track'),
                    patchArtifactBundles: any(named: 'patchArtifactBundles'),
                    sidecars: any(named: 'sidecars'),
                  ),
                ).captured.single
                as Map<String, dynamic>;

        expect(
          (metadata['platforms']! as Map).keys,
          containsAll(<String>['android', 'ios']),
        );
      });

      test('asserts every platform before building any of them', () async {
        await runWithOverrides(command.run);

        verifyInOrder([
          patcher.assertPreconditions,
          iosPatcher.assertPreconditions,
          () => patcher.buildPatchArtifact(
            releaseVersion: any(named: 'releaseVersion'),
          ),
        ]);
      });

      test('runs every patcher\'s engine check, in the release revision, '
          'before building any of them', () async {
        final revisions = <String>[];
        when(() => patcher.assertEngineCanPatch()).thenAnswer((_) async {
          revisions.add(shorebirdEnv.flutterRevision);
        });
        when(() => iosPatcher.assertEngineCanPatch()).thenAnswer((_) async {
          revisions.add(shorebirdEnv.flutterRevision);
        });

        await runWithOverrides(command.run);

        expect(revisions, [release.flutterRevision, release.flutterRevision]);
        verifyInOrder([
          patcher.assertEngineCanPatch,
          iosPatcher.assertEngineCanPatch,
          () => patcher.buildPatchArtifact(
            releaseVersion: any(named: 'releaseVersion'),
          ),
        ]);
      });

      test('a platform whose engine cannot patch stops the whole patch '
          'before anything is built', () async {
        when(() => iosPatcher.assertEngineCanPatch()).thenThrow(
          CommandError(
            message: 'ios engine cannot patch',
            exitCode: ExitCode.unavailable,
          ),
        );

        await expectLater(
          runWithOverrides(command.run),
          exitsWithCode(ExitCode.unavailable),
        );

        verify(() => patcher.assertEngineCanPatch()).called(1);
        verifyNever(
          () => patcher.buildPatchArtifact(
            releaseVersion: any(named: 'releaseVersion'),
          ),
        );
      });

      group('when a later platform fails to build', () {
        setUp(() {
          when(
            () => iosPatcher.buildPatchArtifact(
              releaseVersion: any(named: 'releaseVersion'),
            ),
          ).thenThrow(Exception('oh no'));
        });

        test('publishes nothing, so no platform goes live alone', () async {
          await expectLater(
            runWithOverrides(command.run),
            exitsWithCode(ExitCode.software),
          );

          verify(
            () => patcher.buildPatchArtifact(
              releaseVersion: any(named: 'releaseVersion'),
            ),
          ).called(1);
          verifyNever(anyPublishPatch);
        });
      });

      group('when the release does not cover every platform', () {
        setUp(() {
          final androidOnly = releaseCovering({ReleasePlatform.android});
          when(
            () => codePushClientWrapper.getRelease(
              appId: any(named: 'appId'),
              releaseVersion: any(named: 'releaseVersion'),
            ),
          ).thenAnswer((_) async => androidOnly);
        });

        test('errors and publishes nothing', () async {
          await expectLater(
            runWithOverrides(command.run),
            exitsWithCode(ExitCode.software),
          );

          verifyNever(anyPublishPatch);
        });
      });

      group('when --release-version=latest', () {
        setUp(() {
          when(() => argResults['release-version']).thenReturn('latest');
        });

        test('skips releases that do not cover every platform', () async {
          // Newer, but android-only: resolving "latest" per platform would
          // pick it for android and straddle two release versions.
          final androidOnly = releaseCovering(
            {ReleasePlatform.android},
            id: 9,
            version: '1.2.4+1',
            updatedAt: DateTime(2024),
          );
          when(
            () => codePushClientWrapper.getReleases(appId: any(named: 'appId')),
          ).thenAnswer((_) async => [multiPlatformRelease, androidOnly]);

          await runWithOverrides(command.run);

          verify(
            () => codePushClientWrapper.publishPatch(
              appId: appId,
              releaseId: multiPlatformRelease.id,
              metadata: any(named: 'metadata'),
              track: any(named: 'track'),
              patchArtifactBundles: any(named: 'patchArtifactBundles'),
              sidecars: any(named: 'sidecars'),
            ),
          ).called(1);
        });

        test('errors when no release covers every platform', () async {
          when(
            () => codePushClientWrapper.getReleases(appId: any(named: 'appId')),
          ).thenAnswer(
            (_) async => [
              releaseCovering({ReleasePlatform.android}),
            ],
          );

          await expectLater(
            runWithOverrides(command.run),
            exitsWithError(
              message: contains('covering Android and iOS'),
              exitCode: ExitCode.usage,
            ),
          );
          verifyNever(anyPublishPatch);
        });
      });

      group('with --dry-run', () {
        setUp(() {
          when(() => argResults['dry-run']).thenReturn(true);
          when(
            () => shorebirdEnv.buildDirectory,
          ).thenReturn(Directory.systemTemp.createTempSync());
        });

        test(
          'builds and checks every platform, and publishes nothing',
          () async {
            await expectLater(
              runWithOverrides(command.run),
              exitsWithCode(ExitCode.success),
            );

            verify(
              () => patcher.buildPatchArtifact(
                releaseVersion: any(named: 'releaseVersion'),
              ),
            ).called(1);
            verify(
              () => iosPatcher.buildPatchArtifact(
                releaseVersion: any(named: 'releaseVersion'),
              ),
            ).called(1);
            verify(() => logger.info('No issues detected.')).called(1);
            verifyNever(anyPublishPatch);
          },
        );

        test('fails when any one platform is below the minimum '
            'link percentage, naming it', () async {
          when(() => iosPatcher.linkPercentage).thenReturn(12.3);

          await expectLater(
            runWithOverrides(command.run),
            exitsWithError(
              message: allOf(
                contains('iOS'),
                contains('below the minimum threshold (20%)'),
              ),
              exitCode: ExitCode.software,
            ),
          );
          verifyNever(() => logger.info('No issues detected.'));
          verifyNever(anyPublishPatch);
        });
      });
    });

    group('createPatch', () {
      group('sidecars', () {
        /// Runs a patch and returns the sidecars it published for Android.
        Future<PatchSidecars> publishedSidecars() async {
          await runWithOverrides(() => command.createPatch([patcher]));
          final captured =
              verify(
                    () => codePushClientWrapper.publishPatch(
                      appId: any(named: 'appId'),
                      releaseId: any(named: 'releaseId'),
                      metadata: any(named: 'metadata'),
                      track: any(named: 'track'),
                      patchArtifactBundles: any(named: 'patchArtifactBundles'),
                      sidecars: captureAny(named: 'sidecars'),
                    ),
                  ).captured.single
                  as Map<ReleasePlatform, PatchSidecars>;
          return captured[ReleasePlatform.android]!;
        }

        /// A directory holding one file, so zipping it produces something.
        Directory populatedDir() {
          final dir = Directory.systemTemp.createTempSync();
          File(p.join(dir.path, 'contents'))
            ..createSync(recursive: true)
            ..writeAsStringSync('contents');
          return dir;
        }

        group('assets', () {
          test('are not packaged without --assets', () async {
            expect((await publishedSidecars()).assets, isNull);
            // Opt-in means the AAB is never even decoded for assets.
            verifyNever(patcher.assetsDirectory);
          });

          group('with --assets', () {
            setUp(() {
              when(() => argResults['assets']).thenReturn(true);
            });

            test('are packaged when the platform resolves them', () async {
              when(
                patcher.assetsDirectory,
              ).thenAnswer((_) async => populatedDir());

              final assets = (await publishedSidecars()).assets;

              expect(assets, isNotNull);
              expect(assets!.existsSync(), isTrue);
              expect(p.basename(assets.path), equals('assets.zip'));
            });

            test('warn and are skipped when the platform resolves '
                'nothing', () async {
              when(patcher.assetsDirectory).thenAnswer((_) async => null);

              expect((await publishedSidecars()).assets, isNull);
              verify(
                () => logger.warn(
                  any(that: contains('no assets could be resolved')),
                ),
              ).called(1);
            });

            test('do not fail the patch when packaging fails', () async {
              // An empty directory that gets removed before it can be zipped.
              final vanished = Directory.systemTemp.createTempSync()
                ..deleteSync();
              when(patcher.assetsDirectory).thenAnswer((_) async => vanished);

              // publishedSidecars() only returns if the patch published, so
              // this asserts both that the bundle is missing and that its
              // absence did not take the patch down with it.
              expect((await publishedSidecars()).assets, isNull);
              verify(
                () => logger.warn(any(that: contains('Failed to package'))),
              ).called(1);
            });
          });
        });

        group('symbols', () {
          test('are not packaged when the build emitted none', () async {
            expect((await publishedSidecars()).symbols, isNull);
          });

          test('are retained with no flag of their own', () async {
            // --split-debug-info is the opt-in: if the build produced symbols,
            // the user already asked for them.
            when(
              patcher.debugSymbolsDirectory,
            ).thenAnswer((_) async => populatedDir());

            final symbols = (await publishedSidecars()).symbols;

            expect(symbols, isNotNull);
            expect(p.basename(symbols!.path), equals('symbols.zip'));
          });
        });
      });

      test('checks the patcher once when run already checked it', () async {
        await runWithOverrides(command.run);

        verify(() => patcher.assertPreconditions()).called(1);
        verify(() => patcher.assertArgsAreValid()).called(1);
      });

      test('publishes the patch', () async {
        await runWithOverrides(() => command.createPatch([patcher]));

        verify(
          () => codePushClientWrapper.publishPatch(
            appId: appId,
            releaseId: any(named: 'releaseId'),
            metadata: any(named: 'metadata'),
            track: any(named: 'track'),
            patchArtifactBundles: {
              ReleasePlatform.android: patchArtifactBundles,
            },
            sidecars: any(named: 'sidecars'),
          ),
        ).called(1);
      });

      group('when the engine cannot run the patcher\'s patches', () {
        setUp(() {
          when(() => patcher.assertEngineCanPatch()).thenThrow(
            CommandError(
              message: 'engine built without patch support',
              exitCode: ExitCode.unavailable,
            ),
          );
        });

        test('runs with the release\'s Flutter revision selected', () async {
          String? seen;
          when(() => patcher.assertEngineCanPatch()).thenAnswer((_) async {
            seen = shorebirdEnv.flutterRevision;
            throw CommandError(message: 'x', exitCode: ExitCode.unavailable);
          });

          await expectLater(
            () => runWithOverrides(() => command.createPatch([patcher])),
            exitsWithError(message: 'x', exitCode: ExitCode.unavailable),
          );

          expect(seen, release.flutterRevision);
        });

        test('exits before downloading or building anything', () async {
          await expectLater(
            () => runWithOverrides(() => command.createPatch([patcher])),
            exitsWithError(
              message: 'engine built without patch support',
              exitCode: ExitCode.unavailable,
            ),
          );

          verifyNever(
            () => codePushClientWrapper.getReleaseArtifact(
              appId: any(named: 'appId'),
              releaseId: any(named: 'releaseId'),
              arch: any(named: 'arch'),
              platform: any(named: 'platform'),
            ),
          );
          verifyNever(
            () => patcher.buildPatchArtifact(
              releaseVersion: any(named: 'releaseVersion'),
            ),
          );
        });
      });

      group('when the patcher has a minimum Flutter version', () {
        final minimumFlutterVersion = Version(3, 27, 4);

        setUp(() {
          when(
            () => patcher.minimumFlutterVersion,
          ).thenReturn(minimumFlutterVersion);
        });

        group('when the release Flutter version is older', () {
          setUp(() {
            when(() => patcher.releaseType).thenReturn(ReleaseType.ios);
            when(
              () => codePushClientWrapper.getRelease(
                appId: any(named: 'appId'),
                releaseVersion: any(named: 'releaseVersion'),
              ),
            ).thenAnswer(
              (_) async => Release(
                id: release.id,
                appId: release.appId,
                version: release.version,
                flutterRevision: release.flutterRevision,
                flutterVersion: release.flutterVersion,
                displayName: release.displayName,
                platforms: const {
                  ReleasePlatform.ios: ReleasePlatformDetails(
                    status: ReleaseStatus.active,
                  ),
                },
                createdAt: release.createdAt,
                updatedAt: release.updatedAt,
              ),
            );
            when(
              () => shorebirdFlutter.getVersion(),
            ).thenAnswer((_) async => Version(3, 0, 0));
          });

          test(
            'exits with an error saying a newer Flutter is needed',
            () async {
              await expectLater(
                () => runWithOverrides(() => command.createPatch([patcher])),
                exitsWithError(
                  message:
                      'Release ${release.version} was built with Flutter '
                      '$flutterRevision, but patching with `ios` needs at '
                      'least Flutter $minimumFlutterVersion (see '
                      '$supportedFlutterVersionsUrl).',
                  hint:
                      'A release cannot change Flutter versions, so create a '
                      'new release with the latest Flutter to patch. Run: '
                      'shorebird release ios',
                  exitCode: ExitCode.software,
                ),
              );

              verifyNever(
                () => codePushClientWrapper.getReleaseArtifact(
                  appId: any(named: 'appId'),
                  releaseId: any(named: 'releaseId'),
                  arch: any(named: 'arch'),
                  platform: any(named: 'platform'),
                ),
              );
              verifyNever(
                () => patcher.buildPatchArtifact(
                  releaseVersion: any(named: 'releaseVersion'),
                ),
              );
            },
          );
        });

        group('when the release Flutter version is a side version', () {
          setUp(() {
            when(() => shorebirdFlutter.getVersion()).thenAnswer(
              (_) async => Version.parse('$minimumFlutterVersion-sb.1'),
            );
          });

          test('builds the patch', () async {
            await runWithOverrides(() => command.createPatch([patcher]));

            verify(
              () => patcher.buildPatchArtifact(
                releaseVersion: any(named: 'releaseVersion'),
              ),
            ).called(1);
          });
        });

        group('when the release Flutter version is supported', () {
          setUp(() {
            when(
              () => shorebirdFlutter.getVersion(),
            ).thenAnswer((_) async => minimumFlutterVersion);
          });

          test(
            "reads the release's Flutter version after installing it",
            () async {
              String? revisionWhenRead;
              when(() => shorebirdFlutter.getVersion()).thenAnswer((_) async {
                revisionWhenRead = shorebirdEnv.flutterRevision;
                return minimumFlutterVersion;
              });

              await runWithOverrides(() => command.createPatch([patcher]));

              verifyInOrder([
                () => shorebirdFlutter.installRevision(
                  revision: release.flutterRevision,
                  releasePlatform: any(named: 'releasePlatform'),
                ),
                () => shorebirdFlutter.getVersion(),
                () => codePushClientWrapper.getReleaseArtifact(
                  appId: appId,
                  releaseId: release.id,
                  arch: any(named: 'arch'),
                  platform: releasePlatform,
                ),
              ]);
              expect(revisionWhenRead, equals(release.flutterRevision));
            },
          );

          test('builds the patch', () async {
            await runWithOverrides(() => command.createPatch([patcher]));

            verify(
              () => patcher.buildPatchArtifact(
                releaseVersion: any(named: 'releaseVersion'),
              ),
            ).called(1);
          });
        });

        group('when the release Flutter version is unknown', () {
          setUp(() {
            when(
              () => shorebirdFlutter.getVersion(),
            ).thenAnswer((_) async => null);
          });

          test('builds the patch', () async {
            await runWithOverrides(() => command.createPatch([patcher]));

            verify(
              () => patcher.buildPatchArtifact(
                releaseVersion: any(named: 'releaseVersion'),
              ),
            ).called(1);
          });
        });
      });

      group('when shorebird.yaml sets patch_verification: install_only', () {
        const brokenEngine = '6eae37c3bd60906cfaa3b026b3271b896a76e46f';
        const releaseFlutterRevision = 'release-flutter-revision';
        const warning =
            '''
shorebird.yaml sets `patch_verification: install_only`, which does not check patch signatures with Flutter $flutterRevision, the Flutter release $releaseVersion was built with. If the release was built with this setting, devices on it will install this patch without checking its signature.
To have signatures checked, remove `patch_verification` from shorebird.yaml (or set it to `strict`) and create a new release, or release with a Flutter version that checks signatures in install_only mode, such as --flutter-version=3.41.8.''';

        late ShorebirdEnv releaseShorebirdEnv;

        void setUpYaml(PatchVerification patchVerification) {
          when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
            ShorebirdYaml(appId: appId, patchVerification: patchVerification),
          );
        }

        void setUpReleaseEngine(String engineRevision) {
          when(
            () => releaseShorebirdEnv.shorebirdEngineRevision,
          ).thenReturn(engineRevision);
        }

        Matcher isSignatureWarning() =>
            contains('does not check patch signatures');

        setUp(() {
          releaseShorebirdEnv = MockShorebirdEnv();
          // The current Flutter's engine checks signatures; only the
          // release's, in scope once its Flutter is installed, may not.
          when(
            () => shorebirdEnv.shorebirdEngineRevision,
          ).thenReturn('fixed-engine-revision');
          when(
            () => shorebirdEnv.copyWith(
              flutterRevisionOverride: releaseFlutterRevision,
            ),
          ).thenReturn(releaseShorebirdEnv);
          when(
            () => releaseShorebirdEnv.getShorebirdYaml(),
          ).thenAnswer((_) => shorebirdEnv.getShorebirdYaml());
          when(
            () => releaseShorebirdEnv.flutterRevision,
          ).thenReturn(releaseFlutterRevision);
          when(
            () => releaseShorebirdEnv.canAcceptUserInput,
          ).thenReturn(true);
          when(
            () => releaseShorebirdEnv.usesShorebirdCodePushPackage,
          ).thenReturn(false);
          when(
            () => codePushClientWrapper.getRelease(
              appId: any(named: 'appId'),
              releaseVersion: any(named: 'releaseVersion'),
            ),
          ).thenAnswer(
            (_) async => Release(
              id: release.id,
              appId: release.appId,
              version: release.version,
              flutterRevision: releaseFlutterRevision,
              flutterVersion: release.flutterVersion,
              displayName: release.displayName,
              platforms: release.platforms,
              createdAt: release.createdAt,
              updatedAt: release.updatedAt,
            ),
          );
          setUpYaml(PatchVerification.installOnly);
        });

        group("when the release's engine skips the signature check", () {
          setUp(() => setUpReleaseEngine(brokenEngine));

          test('warns, then builds and publishes the patch', () async {
            await runWithOverrides(() => command.createPatch([patcher]));

            verify(() => logger.warn(warning)).called(1);
            verify(
              () => codePushClientWrapper.publishPatch(
                appId: appId,
                releaseId: any(named: 'releaseId'),
                metadata: any(named: 'metadata'),
                track: any(named: 'track'),
                patchArtifactBundles: {
                  ReleasePlatform.android: patchArtifactBundles,
                },
                sidecars: any(named: 'sidecars'),
              ),
            ).called(1);
          });

          test('does not warn when patch_verification is strict', () async {
            setUpYaml(PatchVerification.strict);

            await runWithOverrides(() => command.createPatch([patcher]));

            verifyNever(() => logger.warn(any(that: isSignatureWarning())));
          });
        });

        group("when the release's engine checks signatures", () {
          setUp(() => setUpReleaseEngine('fixed-engine-revision'));

          test('does not warn', () async {
            await runWithOverrides(() => command.createPatch([patcher]));

            verifyNever(() => logger.warn(any(that: isSignatureWarning())));
          });
        });
      });

      group("when the release's Flutter revision has a known issue", () {
        const issue = FlutterRevisionIssue(
          summary: "Android patches don't install.",
          details: 'Patches download but never install.',
          platforms: [ReleasePlatform.android],
          fixedInRevision: '0cae2fc0a4b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5',
          fixedInVersion: '3.22.1',
        );

        void setUpIssue(
          FlutterRevisionIssue? issue, {
          String? releaseFlutterVersion = flutterVersion,
        }) {
          when(
            () => codePushClientWrapper.getRelease(
              appId: any(named: 'appId'),
              releaseVersion: any(named: 'releaseVersion'),
            ),
          ).thenAnswer(
            (_) async => Release(
              id: release.id,
              appId: release.appId,
              version: release.version,
              flutterRevision: release.flutterRevision,
              flutterVersion: releaseFlutterVersion,
              displayName: release.displayName,
              platforms: release.platforms,
              createdAt: release.createdAt,
              updatedAt: release.updatedAt,
              flutterRevisionIssue: issue,
            ),
          );
        }

        const warning =
            '''
Release $releaseVersion was built with Flutter $flutterVersion (83305b5088), which has a known problem on Android: Android patches don't install.
Patches download but never install.
A patch cannot change the Flutter version a release was built with. To fix this, create a new release with Flutter 3.22.1 (0cae2fc0a4) or newer.''';

        Matcher isIssueWarning() => contains('has a known problem');

        test('warns, then builds and publishes the patch', () async {
          setUpIssue(issue);

          await runWithOverrides(() => command.createPatch([patcher]));

          verify(() => logger.warn(warning)).called(1);
          verify(
            () => codePushClientWrapper.publishPatch(
              appId: appId,
              releaseId: any(named: 'releaseId'),
              metadata: any(named: 'metadata'),
              track: any(named: 'track'),
              patchArtifactBundles: {
                ReleasePlatform.android: patchArtifactBundles,
              },
              sidecars: any(named: 'sidecars'),
            ),
          ).called(1);
        });

        test('warns on every platform when the mark names none', () async {
          setUpIssue(
            const FlutterRevisionIssue(summary: 'Known problem.'),
          );

          await runWithOverrides(() => command.createPatch([patcher]));

          verify(
            () => logger.warn(
              any(
                that: allOf(
                  isIssueWarning(),
                  contains('a Flutter version without this problem'),
                ),
              ),
            ),
          ).called(1);
        });

        test('names the revision when the release has no version', () async {
          setUpIssue(
            const FlutterRevisionIssue(summary: 'Known problem.'),
            releaseFlutterVersion: null,
          );

          await runWithOverrides(() => command.createPatch([patcher]));

          verify(
            () => logger.warn(
              any(
                that: contains(
                  'built with Flutter revision 83305b5088, which has a known',
                ),
              ),
            ),
          ).called(1);
        });

        test("does not warn for a platform the mark doesn't name", () async {
          setUpIssue(
            const FlutterRevisionIssue(
              summary: 'Known crashes on iOS.',
              platforms: [ReleasePlatform.ios],
            ),
          );

          await runWithOverrides(() => command.createPatch([patcher]));

          verifyNever(() => logger.warn(any(that: isIssueWarning())));
        });
      });

      group('flavor validation', () {
        group('when no flavors are present', () {
          test('validates successfully', () async {
            await runWithOverrides(() => command.createPatch([patcher]));

            verify(
              () => shorebirdValidator.validateFlavors(
                flavorArg: null,
                releasePlatform: ReleasePlatform.android,
              ),
            ).called(1);
          });
        });

        group('when flavors are present', () {
          const flavor = 'development';
          setUp(() {
            when(() => argResults['flavor']).thenReturn(flavor);
          });

          test('validates successfully', () async {
            await runWithOverrides(() => command.createPatch([patcher]));

            verify(
              () => shorebirdValidator.validateFlavors(
                flavorArg: flavor,
                releasePlatform: ReleasePlatform.android,
              ),
            ).called(1);
          });
        });

        group('when flavor validation fails', () {
          setUp(() {
            when(
              () => shorebirdValidator.validateFlavors(
                flavorArg: any(named: 'flavorArg'),
                releasePlatform: any(named: 'releasePlatform'),
              ),
            ).thenThrow(
              ValidationFailedException(
                message: 'Flavors are not supported on this platform.',
              ),
            );
          });

          test('exits with code 78 (config)', () async {
            await expectLater(
              runWithOverrides(() => command.createPatch([patcher])),
              exitsWithCode(ExitCode.config),
            );
          });

          test('carries the flavor failure for the runner to report as '
              'precondition_failed', () async {
            await expectLater(
              runWithOverrides(() => command.createPatch([patcher])),
              throwsA(
                isA<PreconditionFailedExit>().having(
                  (e) => e.failure.message,
                  'failure.message',
                  'Flavors are not supported on this platform.',
                ),
              ),
            );
          });
        });
      });

      group("when the app's enterprise requires patch signing", () {
        Release releaseSignedWith(ReleaseSigningMode? mode) => Release(
          id: release.id,
          appId: release.appId,
          version: release.version,
          flutterRevision: release.flutterRevision,
          flutterVersion: release.flutterVersion,
          displayName: release.displayName,
          platforms: {
            releasePlatform: ReleasePlatformDetails(
              status: ReleaseStatus.active,
              signingMode: mode?.value,
            ),
          },
          createdAt: release.createdAt,
          updatedAt: release.updatedAt,
        );

        void releaseIs(Release release) {
          when(
            () => codePushClientWrapper.getRelease(
              appId: any(named: 'appId'),
              releaseVersion: any(named: 'releaseVersion'),
            ),
          ).thenAnswer((_) async => release);
        }

        setUp(() {
          when(
            () => codePushClientWrapper.getApp(appId: any(named: 'appId')),
          ).thenAnswer(
            (_) async => AppMetadata(
              appId: appId,
              displayName: appDisplayName,
              createdAt: DateTime(2023),
              updatedAt: DateTime(2023),
              patchSigningRequired: true,
              enterpriseName: 'Acme Corp',
            ),
          );
        });

        for (final mode in [ReleaseSigningMode.unsigned, null]) {
          test('refuses a release with signing mode ${mode?.value} before '
              'building', () async {
            releaseIs(releaseSignedWith(mode));
            await expectLater(
              () => runWithOverrides(() => command.createPatch([patcher])),
              exitsWithError(
                message:
                    'Acme Corp requires patch signing, and release '
                    '${release.version} (${releasePlatform.displayName}) '
                    "wasn't built with signing, so its devices can't verify "
                    'a patch.',
                hint: 'Ship a new release and patch that.',
                exitCode: ExitCode.noPerm,
              ),
            );
            verifyNever(
              () => shorebirdFlutter.installRevision(
                revision: any(named: 'revision'),
                releasePlatform: any(named: 'releasePlatform'),
              ),
            );
            verifyNever(
              () => patcher.buildPatchArtifact(
                releaseVersion: any(named: 'releaseVersion'),
              ),
            );
          });
        }

        test('patches a release signed with a managed key', () async {
          releaseIs(releaseSignedWith(ReleaseSigningMode.managed));
          await runWithOverrides(() => command.createPatch([patcher]));
          verify(
            () => patcher.buildPatchArtifact(
              releaseVersion: any(named: 'releaseVersion'),
            ),
          ).called(1);
        });
      });

      group("when the release embeds the customer's key", () {
        final signedRelease = Release(
          id: release.id,
          appId: release.appId,
          version: release.version,
          flutterRevision: release.flutterRevision,
          flutterVersion: release.flutterVersion,
          displayName: release.displayName,
          platforms: {
            releasePlatform: ReleasePlatformDetails(
              status: ReleaseStatus.active,
              signingMode: ReleaseSigningMode.customer.value,
            ),
          },
          createdAt: release.createdAt,
          updatedAt: release.updatedAt,
        );

        setUp(() {
          when(
            () => codePushClientWrapper.getRelease(
              appId: any(named: 'appId'),
              releaseVersion: any(named: 'releaseVersion'),
            ),
          ).thenAnswer((_) async => signedRelease);
        });

        test('exits before building when no key is passed', () async {
          await expectLater(
            runWithOverrides(() => command.createPatch([patcher])),
            throwsA(
              isA<UsageException>().having(
                (e) => e.message,
                'message',
                'Release ${release.version} was signed with your own key, so '
                    'its patches must be too. Pass the same public key as the '
                    'release, with --public-key-path and --private-key-path, '
                    'or --public-key-cmd and --sign-cmd.',
              ),
            ),
          );
          verifyNever(
            () => shorebirdFlutter.installRevision(
              revision: any(named: 'revision'),
              releasePlatform: any(named: 'releasePlatform'),
            ),
          );
          verifyNever(
            () => patcher.buildPatchArtifact(
              releaseVersion: any(named: 'releaseVersion'),
            ),
          );
        });

        test('builds the patch when keys are passed', () async {
          when(
            () => argResults.wasParsed(CommonArguments.privateKeyArg.name),
          ).thenReturn(true);
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
          ).thenReturn(true);
          when(
            () => argResults[CommonArguments.privateKeyArg.name],
          ).thenReturn(createTempFile('private.pem').path);
          when(
            () => argResults[CommonArguments.publicKeyArg.name],
          ).thenReturn(createTempFile('public.pem').path);

          await runWithOverrides(() => command.createPatch([patcher]));

          verify(
            () => codePushClientWrapper.publishPatch(
              appId: appId,
              releaseId: any(named: 'releaseId'),
              metadata: any(named: 'metadata'),
              track: any(named: 'track'),
              patchArtifactBundles: {
                ReleasePlatform.android: patchArtifactBundles,
              },
              sidecars: any(named: 'sidecars'),
            ),
          ).called(1);
        });
      });

      group('when the release embeds a managed key', () {
        const managedPem = 'managed-public-key-pem';

        void stubReleaseSigning(ArtifactSigning signing) {
          when(
            () => codePushClientWrapper.getReleaseArtifact(
              appId: any(named: 'appId'),
              releaseId: any(named: 'releaseId'),
              arch: 'aab',
              platform: ReleasePlatform.android,
            ),
          ).thenAnswer(
            (_) async => ReleaseArtifact(
              id: aabArtifact.id,
              releaseId: aabArtifact.releaseId,
              arch: aabArtifact.arch,
              platform: aabArtifact.platform,
              hash: aabArtifact.hash,
              size: aabArtifact.size,
              url: aabArtifact.url,
              canSideload: aabArtifact.canSideload,
              signing: signing,
            ),
          );
        }

        setUp(() {
          stubReleaseSigning(
            const ArtifactSigning(
              mode: 'managed',
              keyId: 7,
              publicKeyPem: managedPem,
            ),
          );
        });

        test('builds the patch against the release key', () async {
          await runWithOverrides(() => command.createPatch([patcher]));

          verify(() => patcher.releaseManagedPublicKeyPem = managedPem).called(
            1,
          );
        });

        test('rejects a key of your own', () async {
          when(
            () => argResults.wasParsed(CommonArguments.privateKeyArg.name),
          ).thenReturn(true);
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
          ).thenReturn(true);
          when(
            () => argResults[CommonArguments.privateKeyArg.name],
          ).thenReturn(createTempFile('private.pem').path);
          when(
            () => argResults[CommonArguments.publicKeyArg.name],
          ).thenReturn(createTempFile('public.pem').path);

          await expectLater(
            runWithOverrides(() => command.createPatch([patcher])),
            throwsA(
              isA<UsageException>().having(
                (e) => e.message,
                'message',
                'Release ${release.version} is signed with a Shorebird-managed '
                    'key, and Shorebird signs its patches. Remove '
                    '--public-key-path, --private-key-path.',
              ),
            ),
          );
        });

        test('exits when the server returns no key', () async {
          stubReleaseSigning(const ArtifactSigning(mode: 'managed', keyId: 7));

          await expectLater(
            runWithOverrides(() => command.createPatch([patcher])),
            exitsWithError(
              message: endsWith(
                'is signed with a Shorebird-managed key, but the server did '
                'not return it.',
              ),
              hint:
                  'Try again, and contact Shorebird support if this persists.',
              exitCode: ExitCode.software,
            ),
          );
          verifyNever(() => patcher.releaseManagedPublicKeyPem = any());
        });
      });

      group('when the release embeds no managed key', () {
        test('builds with the configured key', () async {
          await runWithOverrides(() => command.createPatch([patcher]));

          verifyNever(() => patcher.releaseManagedPublicKeyPem = any());
        });
      });

      group('correctly validates key pair', () {
        group('when no key pair is provided', () {
          test('is valid', () async {
            await expectLater(
              runWithOverrides(() => command.createPatch([patcher])),
              completes,
            );
          });
        });

        group('when given existing private and public key files', () {
          test('is valid', () async {
            when(
              () => argResults.wasParsed(CommonArguments.privateKeyArg.name),
            ).thenReturn(true);
            when(
              () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
            ).thenReturn(true);
            when(
              () => argResults[CommonArguments.privateKeyArg.name],
            ).thenReturn(createTempFile('private.pem').path);
            when(
              () => argResults[CommonArguments.publicKeyArg.name],
            ).thenReturn(createTempFile('public.pem').path);

            await expectLater(
              runWithOverrides(() => command.createPatch([patcher])),
              completes,
            );
          });
        });

        group(
          'when given an existing private key and nonexistent public key',
          () {
            test('throws a usage exception naming the missing key', () async {
              when(
                () => argResults.wasParsed(CommonArguments.privateKeyArg.name),
              ).thenReturn(true);
              when(
                () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
              ).thenReturn(false);
              when(
                () => argResults[CommonArguments.privateKeyArg.name],
              ).thenReturn(createTempFile('private.pem').path);

              await expectLater(
                runWithOverrides(() => command.createPatch([patcher])),
                throwsA(
                  isA<UsageException>().having(
                    (e) => e.message,
                    'message',
                    '--public-key-path and --private-key-path must be passed '
                        'together (missing --public-key-path).',
                  ),
                ),
              );
            });
          },
        );

        group(
          'when given an existing public key and nonexistent private key',
          () {
            test('throws a usage exception naming the missing key', () async {
              when(
                () => argResults.wasParsed(CommonArguments.privateKeyArg.name),
              ).thenReturn(false);
              when(
                () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
              ).thenReturn(true);
              when(
                () => argResults[CommonArguments.publicKeyArg.name],
              ).thenReturn(createTempFile('public.pem').path);

              await expectLater(
                runWithOverrides(() => command.createPatch([patcher])),
                throwsA(
                  isA<UsageException>().having(
                    (e) => e.message,
                    'message',
                    '--public-key-path and --private-key-path must be passed '
                        'together (missing --private-key-path).',
                  ),
                ),
              );
            });
          },
        );

        group('effective build-configuration compatibility', () {
          /// Makes the RELEASE's supplement record the effective config of a
          /// build made with [releaseFlavor]. Written through extractZip,
          /// which is where the real supplement lands.
          setUp(() {
            // The outer harness stubs wasParsed(any()) -> true, so
            // ForwardedArgs._argsNamed emits `--dart-define-from-file=null`
            // for every unstubbed option. That makes the PATCH's own config
            // unfingerprintable, and enforcement then (correctly) declines to
            // compare -- which would mask the mismatch this group exists to
            // catch. Give these options an honest "not parsed".
            for (final name in [
              CommonArguments.dartDefineArg.name,
              CommonArguments.dartDefineFromFileArg.name,
              CommonArguments.buildNameArg.name,
              CommonArguments.buildNumberArg.name,
              CommonArguments.splitDebugInfoArg.name,
              CommonArguments.exportMethodArg.name,
              CommonArguments.exportOptionsPlistArg.name,
            ]) {
              when(() => argResults.wasParsed(name)).thenReturn(false);
            }
          });

          void releaseRecordsFlavor(String releaseFlavor) {
            when(
              () => patcher.supplementaryReleaseArtifactArch,
            ).thenReturn('supplement');
            when(
              () => artifactManager.extractZip(
                zipFile: any(named: 'zipFile'),
                outputDirectory: any(named: 'outputDirectory'),
              ),
            ).thenAnswer((invocation) async {
              final out =
                  invocation.namedArguments[const Symbol('outputDirectory')]
                      as Directory;
              out.createSync(recursive: true);
              final config = RouteBBuildConfig.fromBuildArgs(
                const [],
                flavor: releaseFlavor,
              );
              File(
                p.join(out.path, Releaser.buildConfigFileName),
              ).writeAsStringSync(
                jsonEncode({'buildConfig': config!.toJson()}),
              );
            });
          }

          /// Makes the RELEASE's record say "unfingerprintable" -- the shape
          /// `Releaser.recordEffectiveBuildConfig` writes when the release
          /// itself used `--dart-define-from-file`.
          void releaseRecordsUnfingerprintable() {
            when(
              () => patcher.supplementaryReleaseArtifactArch,
            ).thenReturn('supplement');
            when(
              () => artifactManager.extractZip(
                zipFile: any(named: 'zipFile'),
                outputDirectory: any(named: 'outputDirectory'),
              ),
            ).thenAnswer((invocation) async {
              final out =
                  invocation.namedArguments[const Symbol('outputDirectory')]
                      as Directory;
              out.createSync(recursive: true);
              File(
                p.join(out.path, Releaser.buildConfigFileName),
              ).writeAsStringSync(
                jsonEncode({
                  'buildConfig': null,
                  'unfingerprintableReason':
                      'built with --dart-define-from-file',
                }),
              );
            });
          }

          // RED UNTIL ENFORCEMENT LANDS. Today the patch proceeds and
          // buildPatchArtifact IS called, so this fails — which is the point of
          // writing it before the fix.
          //
          // The assertion is deliberately NOT "the command exited non-zero".
          // The contract is that the refusal happens BEFORE any patch artifact
          // is produced, so the observable is that the build was never
          // attempted. A refusal after the build would satisfy an exit-code
          // assertion while violating the invariant.
          test(
            'refuses a patch whose effective config differs from the release, '
            'before buildPatchArtifact is called',
            () async {
              releaseRecordsFlavor('foo');
              when(() => argResults['flavor']).thenReturn('bar');

              await expectLater(
                runWithOverrides(() => command.createPatch([patcher])),
                throwsA(isA<ProcessExit>()),
              );

              // The refusal is necessary but NOT sufficient: the contract is
              // that it happens before anything is produced.
              verifyNever(
                () => patcher.buildPatchArtifact(
                  releaseVersion: any(named: 'releaseVersion'),
                ),
              );
            },
          );

          // THE CONTROL, at the same level. It must pass BOTH before and after
          // enforcement: the fix must refuse a mismatch without becoming
          // "refuse everything". If this ever goes red, the canonical form is
          // reading something it should not — most likely raw --flavor instead
          // of the synthesized FLUTTER_APP_FLAVOR define.
          test(
            'a matching effective config crosses the compatibility boundary',
            () async {
              releaseRecordsFlavor('foo');
              when(() => argResults['flavor']).thenReturn('foo');

              await runWithOverrides(() => command.createPatch([patcher]));

              verify(
                () => patcher.buildPatchArtifact(
                  releaseVersion: any(named: 'releaseVersion'),
                ),
              ).called(1);
            },
          );

          // ------------------------------------------------------------------
          // THE ASYMMETRIC CASE. Two things can make a comparison impossible,
          // and they are not the same thing:
          //
          //   the RELEASE was built with --dart-define-from-file
          //       -> nothing to compare, permanently, and re-releasing does not
          //          help. Warn and proceed. Covered by the control below.
          //
          //   the PATCH is invoked with --dart-define-from-file, against a
          //   release whose configuration IS known
          //       -> the release's config is in hand; the patch simply declines
          //          to state its own. That is a user-controllable opt-out of
          //          the whole check, and it opts out in precisely the case
          //          where a mismatch is most likely -- a patch pulling defines
          //          from a file the release never had.
          //
          // RED UNTIL THE FIX: today the second case warns and proceeds, so
          // buildPatchArtifact IS called and this fails.
          // ------------------------------------------------------------------
          test(
            'refuses when the release IS fingerprintable but the patch is not, '
            'before buildPatchArtifact is called',
            () async {
              releaseRecordsFlavor('foo');
              when(() => argResults['flavor']).thenReturn('foo');
              // the patch, and only the patch, becomes unfingerprintable
              when(
                () => argResults.wasParsed(
                  CommonArguments.dartDefineFromFileArg.name,
                ),
              ).thenReturn(true);
              when(
                () => argResults[CommonArguments.dartDefineFromFileArg.name],
              ).thenReturn(['defines.json']);

              await expectLater(
                runWithOverrides(() => command.createPatch([patcher])),
                throwsA(isA<ProcessExit>()),
              );

              // Same contract as the mismatch arm: the refusal is necessary
              // but not sufficient -- it must precede any artifact.
              verifyNever(
                () => patcher.buildPatchArtifact(
                  releaseVersion: any(named: 'releaseVersion'),
                ),
              );
            },
          );

          // THE CONTROL FOR THE OTHER NULL. A release that itself cannot be
          // fingerprinted must STILL be patchable -- there is nothing to
          // compare and re-releasing cannot help, so refusing would strand it
          // forever. This must stay green across the fix; if it goes red, the
          // fix collapsed the two null states back into one.
          test(
            'still patches when the RELEASE is the unfingerprintable one',
            () async {
              releaseRecordsUnfingerprintable();
              when(() => argResults['flavor']).thenReturn('foo');

              await runWithOverrides(() => command.createPatch([patcher]));

              verify(
                () => patcher.buildPatchArtifact(
                  releaseVersion: any(named: 'releaseVersion'),
                ),
              ).called(1);
            },
          );
        });

        group('when a supplemental release artifact exists', () {
          setUp(() {
            when(
              () => patcher.supplementaryReleaseArtifactArch,
            ).thenReturn('supplement');
          });

          group('Route B engine identity', () {
            // The hashes from the run that turned this warning into a refusal.
            const releaseEngine = 'ee001fd78fcd5e78e976d35284bd13e1caffff63';
            const stockEngine = '69f9831c360d9152862ec3897c67fb09ae843f3b';

            /// A supplement that marks this as a Route B release built by
            /// [engine]. Written through extractZip, which is where the real
            /// supplement lands.
            void routeBSupplement(String engine) {
              when(
                () => artifactManager.extractZip(
                  zipFile: any(named: 'zipFile'),
                  outputDirectory: any(named: 'outputDirectory'),
                ),
              ).thenAnswer((invocation) async {
                final out =
                    invocation.namedArguments[#outputDirectory] as Directory;
                File(
                  p.join(out.path, routeBProvenanceFileName),
                ).writeAsStringSync(
                  '{"engineRevision": "$engine", '
                  '"flutterRevision": "$flutterRevision"}',
                );
              });
            }

            test('refuses the mismatch, and uploads nothing', () async {
              // THE REPRODUCTION, at the command level. On device this exact
              // pairing produced a patch that installed, promoted, reported
              // itself active, and changed nothing.
              routeBSupplement(releaseEngine);
              when(
                () => shorebirdEnv.shorebirdEngineRevision,
              ).thenReturn(stockEngine);

              await expectLater(
                runWithOverrides(() => command.createPatch([patcher])),
                throwsA(
                  isA<ProcessExit>().having(
                    (e) => e.exitCode,
                    'exitCode',
                    ExitCode.software.code,
                  ),
                ),
              );

              verify(
                () => logger.err(
                  any(
                    that: allOf(
                      contains(releaseEngine),
                      contains(stockEngine),
                      contains('Nothing was uploaded'),
                    ),
                  ),
                ),
              ).called(1);
              // NOTHING UPLOADED is the load-bearing half. A refusal that still
              // published would be the same defect wearing a message.
              verifyNever(
                () => codePushClientWrapper.publishPatch(
                  appId: any(named: 'appId'),
                  releaseId: any(named: 'releaseId'),
                  track: any(named: 'track'),
                  patchArtifactBundles: any(named: 'patchArtifactBundles'),
                  metadata: any(named: 'metadata'),
                ),
              );
            });

            test('refuses BEFORE the patch is built', () async {
              // Ordering is the point: a refusal after the build still costs a
              // full compile, and — worse — the build is what restamps the
              // cache, so a late-only check reports the drift it caused.
              routeBSupplement(releaseEngine);
              when(
                () => shorebirdEnv.shorebirdEngineRevision,
              ).thenReturn(stockEngine);

              await expectLater(
                runWithOverrides(() => command.createPatch([patcher])),
                throwsA(isA<ProcessExit>()),
              );

              verifyNever(
                () => patcher.buildPatchArtifact(
                  releaseVersion: any(named: 'releaseVersion'),
                ),
              );
            });

            test('catches a stamp that drifts DURING the build', () async {
              // THE REASON THERE ARE TWO CHECKS. On the real run the stamps
              // agreed when the command started and the Flutter build rewrote
              // `bin/internal/engine.version` to the hash it downloaded — so a
              // single up-front check passes and the kernel is still produced by
              // the wrong frontend.
              routeBSupplement(releaseEngine);
              var reads = 0;
              when(() => shorebirdEnv.shorebirdEngineRevision).thenAnswer((_) {
                // First read is the pre-build gate; everything after it is
                // post-build, which is where the drift shows up.
                reads++;
                return reads == 1 ? releaseEngine : stockEngine;
              });

              await expectLater(
                runWithOverrides(() => command.createPatch([patcher])),
                throwsA(isA<ProcessExit>()),
              );

              // The build DID run — proving the first gate passed and the second
              // one is what fired.
              verify(
                () => patcher.buildPatchArtifact(
                  releaseVersion: any(named: 'releaseVersion'),
                ),
              ).called(1);
              verify(
                () => logger.err(
                  any(that: contains('rewrote its own cache stamp')),
                ),
              ).called(1);
              verifyNever(
                () => codePushClientWrapper.publishPatch(
                  appId: any(named: 'appId'),
                  releaseId: any(named: 'releaseId'),
                  track: any(named: 'track'),
                  patchArtifactBundles: any(named: 'patchArtifactBundles'),
                  metadata: any(named: 'metadata'),
                ),
              );
            });

            test('the control: matching hashes continue normally', () async {
              // A gate that refused everything would pass the tests above. The
              // normal path has to be asserted in the same breath.
              routeBSupplement(releaseEngine);
              when(
                () => shorebirdEnv.shorebirdEngineRevision,
              ).thenReturn(releaseEngine);

              await runWithOverrides(() => command.createPatch([patcher]));

              verify(
                () => patcher.buildPatchArtifact(
                  releaseVersion: any(named: 'releaseVersion'),
                ),
              ).called(1);
            });

            test('a release that is not Route B is unaffected', () async {
              // The invariant is Route B's. Extending it to every release would
              // invent a constraint this evidence does not support — and would
              // break every ordinary patch cut on a machine whose engine stamp
              // has moved for unrelated reasons.
              when(
                () => shorebirdEnv.shorebirdEngineRevision,
              ).thenReturn(stockEngine);

              await runWithOverrides(() => command.createPatch([patcher]));

              verify(
                () => patcher.buildPatchArtifact(
                  releaseVersion: any(named: 'releaseVersion'),
                ),
              ).called(1);
            });
          });

          test('downloads the supplemental release artifact', () async {
            await runWithOverrides(() => command.createPatch([patcher]));

            verify(
              () => codePushClientWrapper.maybeGetReleaseArtifact(
                appId: appId,
                releaseId: release.id,
                arch: 'supplement',
                platform: releasePlatform,
              ),
            ).called(1);
            verify(
              () => patcher.createPatchArtifacts(
                appId: appId,
                releaseId: release.id,
                releaseArtifact: any(named: 'releaseArtifact'),
                supplementDirectory: any(named: 'supplementDirectory'),
              ),
            ).called(1);
          });

          test('deletes the extracted supplement once patched', () async {
            await runWithOverrides(() => command.createPatch([patcher]));

            final supplementDirectory =
                verify(
                      () => patcher.createPatchArtifacts(
                        appId: appId,
                        releaseId: release.id,
                        releaseArtifact: any(named: 'releaseArtifact'),
                        supplementDirectory: captureAny(
                          named: 'supplementDirectory',
                        ),
                      ),
                    ).captured.single
                    as Directory;
            expect(supplementDirectory.existsSync(), isFalse);
          });

          group('when the artifact is not found', () {
            setUp(() {
              when(
                () => codePushClientWrapper.getReleaseArtifact(
                  appId: appId,
                  releaseId: release.id,
                  arch: 'supplement',
                  platform: releasePlatform,
                ),
              ).thenThrow(CodePushNotFoundException(message: 'Not found'));
            });

            test('gracefully continues to create patch', () async {
              await runWithOverrides(() => command.createPatch([patcher]));
              verify(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: release.id,
                  releaseArtifact: any(named: 'releaseArtifact'),
                  supplementDirectory: any(named: 'supplementDirectory'),
                ),
              ).called(1);
            });
          });

          group('when the supplement records build flags', () {
            String recorded(List<String> defines, {String? target}) =>
                json.encode(
                  BuildFlags(
                    dartDefines: {
                      for (final define in defines)
                        define.split('=').first: sha256
                            .convert(utf8.encode(define.split('=').last))
                            .toString(),
                    },
                    target: target,
                  ).toJson(),
                );

            void releaseBuiltWith(List<String> defines) {
              when(
                () => artifactManager.extractZip(
                  zipFile: any(named: 'zipFile'),
                  outputDirectory: any(named: 'outputDirectory'),
                ),
              ).thenAnswer((invocation) async {
                final outputDirectory =
                    invocation.namedArguments[#outputDirectory] as Directory;
                File(
                  p.join(outputDirectory.path, BuildFlags.fileName),
                ).writeAsStringSync(recorded(defines));
              });
            }

            void patchBuiltWith(List<String> defines) {
              when(() => argResults['dart-define']).thenReturn(defines);
              when(() => argResults['dart-define-from-file']).thenReturn(
                <String>[],
              );
            }

            setUp(() {
              when(() => patcher.target).thenReturn(null);
              releaseBuiltWith(['API_URL=https://a', 'SENTRY_DSN=x']);
            });

            test('builds the patch when they match', () async {
              patchBuiltWith(['API_URL=https://a', 'SENTRY_DSN=x']);

              await runWithOverrides(() => command.createPatch([patcher]));

              verify(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: release.id,
                  releaseArtifact: any(named: 'releaseArtifact'),
                  supplementDirectory: any(named: 'supplementDirectory'),
                ),
              ).called(1);
            });

            test('stops without a terminal when they differ', () async {
              when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);
              patchBuiltWith(['API_URL=https://b']);

              await expectLater(
                () => runWithOverrides(() => command.createPatch([patcher])),
                throwsA(
                  isA<CommandError>()
                      .having(
                        (e) => e.exitCode,
                        'exitCode',
                        ExitCode.usage.code,
                      )
                      .having(
                        (e) => e.code,
                        'code',
                        JsonErrorCode.interactivePromptRequired,
                      ),
                ),
              );
              verifyNever(() => logger.confirm(any()));
              verify(
                () => logger.warn(
                  any(
                    that: allOf(
                      contains('--dart-define missing: SENTRY_DSN'),
                      contains(
                        '--dart-define with a different value: API_URL',
                      ),
                      isNot(contains('https://')),
                    ),
                  ),
                ),
              ).called(1);
              verifyNever(
                () => patcher.createPatchArtifacts(
                  appId: any(named: 'appId'),
                  releaseId: any(named: 'releaseId'),
                  releaseArtifact: any(named: 'releaseArtifact'),
                  supplementDirectory: any(named: 'supplementDirectory'),
                ),
              );
            });

            test('goes on with --allow-build-flag-diffs', () async {
              when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);
              when(
                () => argResults['allow-build-flag-diffs'],
              ).thenReturn(true);
              patchBuiltWith(['API_URL=https://b', 'SENTRY_DSN=x']);

              await runWithOverrides(() => command.createPatch([patcher]));

              verifyNever(() => logger.confirm(any()));
              verify(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: release.id,
                  releaseArtifact: any(named: 'releaseArtifact'),
                  supplementDirectory: any(named: 'supplementDirectory'),
                ),
              ).called(1);
            });

            test('stops when the user declines', () async {
              when(() => shorebirdEnv.canAcceptUserInput).thenReturn(true);
              when(() => logger.confirm('Continue anyway?')).thenReturn(false);
              patchBuiltWith(['API_URL=https://b', 'SENTRY_DSN=x']);

              await expectLater(
                () => runWithOverrides(() => command.createPatch([patcher])),
                throwsA(
                  isA<PromptDeclinedExit>().having(
                    (e) => e.exitCode,
                    'exitCode',
                    declinedExitCode,
                  ),
                ),
              );
              verify(() => logger.err('Aborting.')).called(1);
              verifyNever(
                () => patcher.createPatchArtifacts(
                  appId: any(named: 'appId'),
                  releaseId: any(named: 'releaseId'),
                  releaseArtifact: any(named: 'releaseArtifact'),
                  supplementDirectory: any(named: 'supplementDirectory'),
                ),
              );
            });

            test('goes on when the user confirms', () async {
              when(() => shorebirdEnv.canAcceptUserInput).thenReturn(true);
              when(() => logger.confirm('Continue anyway?')).thenReturn(true);
              patchBuiltWith(['API_URL=https://b', 'SENTRY_DSN=x']);

              await runWithOverrides(() => command.createPatch([patcher]));

              verify(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: release.id,
                  releaseArtifact: any(named: 'releaseArtifact'),
                  supplementDirectory: any(named: 'supplementDirectory'),
                ),
              ).called(1);
            });
          });

          group('when the supplement contains an obfuscation map', () {
            // Wire up extractZip to actually write the obfuscation_map.json
            // so PatchCommand's `if (obfuscationMapFile != null)` block
            // fires. The flutter-version gating that drops --strip on
            // Android 3.44+ depends on `release.flutterRevision` resolving
            // to a Version, so we mock that per-test.
            setUp(() {
              when(
                () => artifactManager.extractZip(
                  zipFile: any(named: 'zipFile'),
                  outputDirectory: any(named: 'outputDirectory'),
                ),
              ).thenAnswer((invocation) async {
                final outputDirectory =
                    invocation.namedArguments[#outputDirectory] as Directory;
                File(
                  p.join(outputDirectory.path, 'obfuscation_map.json'),
                ).writeAsStringSync('{}');
              });
            });

            test(
              '''on Android with Flutter < 3.44, passes --strip in extraBuildArgs''',
              () async {
                when(
                  () => shorebirdFlutter.shouldPreStripLibappInGenSnapshot(
                    platform: any(named: 'platform'),
                    flutterRevision: any(named: 'flutterRevision'),
                  ),
                ).thenAnswer((_) async => true);

                await runWithOverrides(() => command.createPatch([patcher]));

                final captured =
                    verify(
                          () => patcher.extraBuildArgs = captureAny(),
                        ).captured.last
                        as List<String>;
                expect(
                  captured,
                  contains('--extra-gen-snapshot-options=--strip'),
                );
              },
            );

            test(
              '''on Android with Flutter 3.44+, omits --strip in extraBuildArgs''',
              () async {
                when(
                  () => shorebirdFlutter.shouldPreStripLibappInGenSnapshot(
                    platform: any(named: 'platform'),
                    flutterRevision: any(named: 'flutterRevision'),
                  ),
                ).thenAnswer((_) async => false);

                await runWithOverrides(() => command.createPatch([patcher]));

                final captured =
                    verify(
                          () => patcher.extraBuildArgs = captureAny(),
                        ).captured.last
                        as List<String>;
                expect(
                  captured,
                  isNot(contains('--extra-gen-snapshot-options=--strip')),
                );
              },
            );

            group('when the release Flutter can load obfuscation maps', () {
              setUp(() {
                when(
                  () => shorebirdFlutter.shouldPreStripLibappInGenSnapshot(
                    platform: any(named: 'platform'),
                    flutterRevision: any(named: 'flutterRevision'),
                  ),
                ).thenAnswer((_) async => false);
                stubReleaseFlutterVersion('3.41.2');
              });

              test('loads the release obfuscation map', () async {
                await runWithOverrides(() => command.createPatch([patcher]));

                final captured =
                    verify(
                          () => patcher.extraBuildArgs = captureAny(),
                        ).captured.last
                        as List<String>;
                expect(captured, contains('--obfuscate'));
                expect(
                  captured,
                  contains(
                    startsWith(
                      '--extra-gen-snapshot-options=--load-obfuscation-map=',
                    ),
                  ),
                );
                verify(
                  () => patcher.obfuscationMapPath = any(that: isNotNull),
                ).called(1);
              });
            });

            group('when the release Flutter is a side version', () {
              setUp(() {
                when(
                  () => shorebirdFlutter.shouldPreStripLibappInGenSnapshot(
                    platform: any(named: 'platform'),
                    flutterRevision: any(named: 'flutterRevision'),
                  ),
                ).thenAnswer((_) async => false);
                stubReleaseFlutterVersion('3.41.2-sb.1');
              });

              test('loads the release obfuscation map', () async {
                expect(
                  Version.parse('3.41.2-sb.1'),
                  lessThan(minimumObfuscationFlutterVersion),
                );

                await runWithOverrides(() => command.createPatch([patcher]));

                verify(
                  () => patcher.obfuscationMapPath = any(that: isNotNull),
                ).called(1);
              });
            });

            group('when the release Flutter cannot load obfuscation maps', () {
              setUp(() {
                when(
                  () => shorebirdFlutter.shouldPreStripLibappInGenSnapshot(
                    platform: any(named: 'platform'),
                    flutterRevision: any(named: 'flutterRevision'),
                  ),
                ).thenAnswer((_) async => true);
                stubReleaseFlutterVersion('3.38.9');
              });

              test('obfuscates an Android patch without the map', () async {
                await runWithOverrides(() => command.createPatch([patcher]));

                final captured =
                    verify(
                          () => patcher.extraBuildArgs = captureAny(),
                        ).captured.last
                        as List<String>;
                expect(captured, contains('--obfuscate'));
                expect(
                  captured,
                  isNot(
                    contains(
                      startsWith(
                        '--extra-gen-snapshot-options=--load-obfuscation-map',
                      ),
                    ),
                  ),
                );
                verify(() => patcher.obfuscationMapPath = null).called(1);
              });

              test(
                'exits for iOS, whose patches link against the release',
                () async {
                  when(() => patcher.releaseType).thenReturn(ReleaseType.ios);
                  when(
                    () => codePushClientWrapper.getReleaseArtifact(
                      appId: any(named: 'appId'),
                      releaseId: any(named: 'releaseId'),
                      arch: any(named: 'arch'),
                      platform: ReleasePlatform.ios,
                    ),
                  ).thenAnswer((_) async => aabArtifact);
                  when(
                    () => codePushClientWrapper.maybeGetReleaseArtifact(
                      appId: any(named: 'appId'),
                      releaseId: any(named: 'releaseId'),
                      arch: 'supplement',
                      platform: ReleasePlatform.ios,
                    ),
                  ).thenAnswer((_) async => supplementArtifact);

                  await expectLater(
                    () =>
                        runWithOverrides(() => command.createPatch([patcher])),
                    exitsWithError(
                      message:
                          'Release $releaseVersion was built with obfuscation '
                          'on Flutter 3.38.9, but patching an obfuscated iOS '
                          'release requires Flutter '
                          '$minimumObfuscationFlutterVersion or later.',
                      hint:
                          'Create a new release to patch. Run: shorebird '
                          'release ios --obfuscate '
                          '--flutter-version=$minimumObfuscationFlutterVersion',
                      exitCode: ExitCode.unavailable,
                    ),
                  );
                },
              );
            });
          });
        });

        group(
          'when --obfuscate is passed but release has no obfuscation map',
          () {
            setUp(() {
              when(() => argResults.wasParsed('obfuscate')).thenReturn(true);
              when(() => argResults['obfuscate']).thenReturn(true);
            });

            test('throws a usage exception naming both ways out', () async {
              await expectLater(
                () => runWithOverrides(() => command.createPatch([patcher])),
                throwsA(
                  isA<UsageException>().having(
                    (e) => e.message,
                    'message',
                    '--obfuscate was passed, but release $releaseVersion was '
                        'not built with obfuscation. A patch cannot change the '
                        'obfuscation mode of a release: re-run without '
                        '--obfuscate to patch this release, or create a new '
                        'release with --obfuscate.',
                  ),
                ),
              );
            });
          },
        );
      });
    });

    group('getPatcher', () {
      test('maps the correct platform to the patcher', () async {
        expect(command.getPatcher(ReleaseType.aar), isA<AarPatcher>());
        expect(command.getPatcher(ReleaseType.android), isA<AndroidPatcher>());
        expect(command.getPatcher(ReleaseType.ios), isA<IosPatcher>());
        expect(
          command.getPatcher(ReleaseType.iosFramework),
          isA<IosFrameworkPatcher>(),
        );
        expect(command.getPatcher(ReleaseType.linux), isA<LinuxPatcher>());
        expect(command.getPatcher(ReleaseType.macos), isA<MacosPatcher>());
        expect(command.getPatcher(ReleaseType.windows), isA<WindowsPatcher>());
      });
    });

    group('confirmCreatePatch', () {
      group('--confirm', () {
        Future<void> logSummary() => runWithOverrides(
          () => command.logPatchSummary(
            app: appMetadata,
            releaseVersion: releaseVersion,
            patchers: [patcher],
            patchArtifactBundles: {
              patcher.releaseType.releasePlatform: patchArtifactBundles,
            },
          ),
        );

        setUp(() {
          when(() => argResults['confirm']).thenReturn(true);
        });

        test('goes on when the user confirms', () async {
          when(
            () => logger.confirm(
              any(),
              defaultValue: any(named: 'defaultValue'),
              hint: any(named: 'hint'),
            ),
          ).thenReturn(true);

          await logSummary();

          verify(
            () => logger.confirm(
              'Would you like to continue?',
              defaultValue: true,
              hint: any(named: 'hint'),
            ),
          ).called(1);
        });

        test(
          'stops with exit 0 and an info line when the user declines',
          () async {
            when(
              () => logger.confirm(
                any(),
                defaultValue: any(named: 'defaultValue'),
                hint: any(named: 'hint'),
              ),
            ).thenReturn(false);

            await expectLater(
              logSummary(),
              throwsA(
                isA<ProcessExit>().having(
                  (e) => e.exitCode,
                  'exitCode',
                  ExitCode.success.code,
                ),
              ),
            );
            verify(() => logger.info('Aborting.')).called(1);
            verifyNever(() => logger.err('Aborting.'));
          },
        );

        test('refuses when nothing can answer, instead of approving', () async {
          when(
            () => logger.confirm(
              any(),
              defaultValue: any(named: 'defaultValue'),
              hint: any(named: 'hint'),
            ),
          ).thenThrow(
            const InteractivePromptRequiredException(
              promptText: 'Would you like to continue?',
              hint: 'hint',
            ),
          );

          await expectLater(
            logSummary(),
            throwsA(isA<InteractivePromptRequiredException>()),
          );
        });
      });

      group('when using a custom deployment track', () {
        setUp(() {
          when(() => argResults['track']).thenReturn('custom-track');
        });

        test('logs correct summary', () async {
          final expectedSummary = [
            '''📱 App: ${lightCyan.wrap(appDisplayName)} ${lightCyan.wrap('($appId)')}''',
            '📦 Release Version: ${lightCyan.wrap(releaseVersion)}',
            '''🕹️  Platform: ${lightCyan.wrap(patcher.releaseType.releasePlatform.displayName)} ${lightCyan.wrap('[arm32 (42 B)]')}''',
            '⚪️ Track: ${lightCyan.wrap('custom-track')}',
          ];
          await expectLater(
            runWithOverrides(
              () => command.logPatchSummary(
                app: appMetadata,
                releaseVersion: releaseVersion,
                patchers: [patcher],
                patchArtifactBundles: {
                  patcher.releaseType.releasePlatform: patchArtifactBundles,
                },
              ),
            ),
            completes,
          );
          verify(
            () => logger.info(any(that: contains(expectedSummary.join('\n')))),
          ).called(1);
        });
      });

      group('when has flavors', () {
        const flavor = 'development';
        setUp(() {
          when(() => argResults['flavor']).thenReturn(flavor);
        });

        test('logs correct summary', () async {
          final expectedSummary = [
            '''📱 App: ${lightCyan.wrap(appDisplayName)} ${lightCyan.wrap('($appId)')}''',
            '🍧 Flavor: ${lightCyan.wrap(flavor)}',
            '📦 Release Version: ${lightCyan.wrap(releaseVersion)}',
            '''🕹️  Platform: ${lightCyan.wrap(patcher.releaseType.releasePlatform.displayName)} ${lightCyan.wrap('[arm32 (42 B)]')}''',
            '🟢 Track: ${lightCyan.wrap('Stable')}',
          ];
          await expectLater(
            runWithOverrides(
              () => command.logPatchSummary(
                app: appMetadata,
                releaseVersion: releaseVersion,
                patchers: [patcher],
                patchArtifactBundles: {
                  patcher.releaseType.releasePlatform: patchArtifactBundles,
                },
              ),
            ),
            completes,
          );
          verify(
            () => logger.info(any(that: contains(expectedSummary.join('\n')))),
          ).called(1);
        });
      });

      group('when is staging', () {
        setUp(() {
          when(
            () => argResults['track'],
          ).thenReturn(DeploymentTrack.staging.channel);
        });

        test('logs correct summary', () async {
          final expectedSummary = [
            '''📱 App: ${lightCyan.wrap(appDisplayName)} ${lightCyan.wrap('($appId)')}''',
            '📦 Release Version: ${lightCyan.wrap(releaseVersion)}',
            '''🕹️  Platform: ${lightCyan.wrap(patcher.releaseType.releasePlatform.displayName)} ${lightCyan.wrap('[arm32 (42 B)]')}''',
            '🟠 Track: ${lightCyan.wrap('Staging')}',
          ];
          await expectLater(
            runWithOverrides(
              () => command.logPatchSummary(
                app: appMetadata,
                releaseVersion: releaseVersion,
                patchers: [patcher],
                patchArtifactBundles: {
                  patcher.releaseType.releasePlatform: patchArtifactBundles,
                },
              ),
            ),
            completes,
          );
          verify(
            () => logger.info(any(that: contains(expectedSummary.join('\n')))),
          ).called(1);
        });
      });

      group('when is beta', () {
        setUp(() {
          when(
            () => argResults['track'],
          ).thenReturn(DeploymentTrack.beta.channel);
        });

        test('logs correct summary', () async {
          final expectedSummary = [
            '''📱 App: ${lightCyan.wrap(appDisplayName)} ${lightCyan.wrap('($appId)')}''',
            '📦 Release Version: ${lightCyan.wrap(releaseVersion)}',
            '''🕹️  Platform: ${lightCyan.wrap(patcher.releaseType.releasePlatform.displayName)} ${lightCyan.wrap('[arm32 (42 B)]')}''',
            '🔵 Track: ${lightCyan.wrap('Beta')}',
          ];
          await expectLater(
            runWithOverrides(
              () => command.logPatchSummary(
                app: appMetadata,
                releaseVersion: releaseVersion,
                patchers: [patcher],
                patchArtifactBundles: {
                  patcher.releaseType.releasePlatform: patchArtifactBundles,
                },
              ),
            ),
            completes,
          );
          verify(
            () => logger.info(any(that: contains(expectedSummary.join('\n')))),
          ).called(1);
        });
      });

      group('when has link percentage', () {
        const linkPercentage = 62.1337;
        late Directory buildDirectory;

        setUp(() {
          buildDirectory = Directory.systemTemp.createTempSync();
          when(() => shorebirdEnv.buildDirectory).thenReturn(buildDirectory);
          when(() => patcher.linkPercentage).thenReturn(linkPercentage);
        });

        test('logs correct summary', () async {
          final debugInfoFile = File(
            p.join(buildDirectory.path, 'patch-debug.zip'),
          );
          final expectedSummary = [
            '''📱 App: ${lightCyan.wrap(appDisplayName)} ${lightCyan.wrap('($appId)')}''',
            '📦 Release Version: ${lightCyan.wrap(releaseVersion)}',
            '''🕹️  Platform: ${lightCyan.wrap(patcher.releaseType.releasePlatform.displayName)} ${lightCyan.wrap('[arm32 (42 B)]')}''',
            '🟢 Track: ${lightCyan.wrap('Stable')}',
            '''🔍 Debug Info: ${lightCyan.wrap(debugInfoFile.path)}''',
          ];
          await expectLater(
            runWithOverrides(
              () => command.logPatchSummary(
                app: appMetadata,
                releaseVersion: releaseVersion,
                patchers: [patcher],
                patchArtifactBundles: {
                  patcher.releaseType.releasePlatform: patchArtifactBundles,
                },
              ),
            ),
            completes,
          );
          verify(
            () => logger.info(any(that: contains(expectedSummary.join('\n')))),
          ).called(1);
        });

        group('when min-link-percentage is not specified', () {
          test('exits with an error below the default of 20%', () async {
            when(() => patcher.linkPercentage).thenReturn(12.3);
            await expectLater(
              runWithOverrides(
                () => command.assertMinLinkPercentage(patcher),
              ),
              exitsWithError(
                message:
                    'The link percentage of this patch (12.3%) '
                    'is below the minimum threshold (20%).',
                exitCode: ExitCode.software,
              ),
            );
          });
        });

        group('when min-link-percentage is specified', () {
          group('when link percentage is higher than min', () {
            const minLinkPercentageArg = '40';

            setUp(() {
              when(
                () => argResults[CommonArguments.minLinkPercentage.name],
              ).thenReturn(minLinkPercentageArg);
            });

            test('completes, does not print error message', () async {
              await expectLater(
                runWithOverrides(
                  () => command.assertMinLinkPercentage(patcher),
                ),
                completes,
              );
            });
          });

          group('when link percentage is lower than min', () {
            const minLinkPercentageArg = '70';

            setUp(() {
              when(
                () => argResults[CommonArguments.minLinkPercentage.name],
              ).thenReturn(minLinkPercentageArg);
            });

            test('exits with an error naming the threshold', () async {
              final debugInfoPath = runWithOverrides(
                () => Patcher.debugInfoFile.path,
              );
              await expectLater(
                runWithOverrides(
                  () => command.assertMinLinkPercentage(patcher),
                ),
                exitsWithError(
                  message:
                      'The link percentage of this patch ($linkPercentage%) '
                      'is below the minimum threshold (70%).',
                  hint:
                      'Not publishing. Lower --min-link-percentage to accept '
                      'this patch, or see $debugInfoPath for what could not '
                      'be linked.',
                  exitCode: ExitCode.software,
                ),
              );
            });
          });

          group('when min-link-percentage is invalid', () {
            void setMinLinkPercentage(String value) {
              when(
                () => argResults[CommonArguments.minLinkPercentage.name],
              ).thenReturn(value);
            }

            Future<void> expectUsageError(String value) async {
              setMinLinkPercentage(value);
              await expectLater(
                runWithOverrides(
                  () => command.assertMinLinkPercentage(patcher),
                ),
                throwsA(
                  isA<UsageException>().having(
                    (e) => e.message,
                    'message',
                    '--min-link-percentage must be an integer between 0 and '
                        '100 (got $value).',
                  ),
                ),
              );
            }

            test('above 100 prints error and exits', () async {
              await expectUsageError('101');
            });

            test('below 0 prints error and exits', () async {
              await expectUsageError('-1');
            });

            test('float prints error and exits', () async {
              await expectUsageError('50.5');
            });
          });

          group('when min-link-percentage is at boundary', () {
            test('0 is accepted', () async {
              when(
                () => argResults[CommonArguments.minLinkPercentage.name],
              ).thenReturn('0');
              when(() => patcher.linkPercentage).thenReturn(12.3);
              await expectLater(
                runWithOverrides(
                  () => command.assertMinLinkPercentage(patcher),
                ),
                completes,
              );
            });

            test('100 is accepted', () async {
              when(
                () => argResults[CommonArguments.minLinkPercentage.name],
              ).thenReturn('100');
              when(() => patcher.linkPercentage).thenReturn(100);
              await expectLater(
                runWithOverrides(
                  () => command.assertMinLinkPercentage(patcher),
                ),
                completes,
              );
            });
          });
        });
      });
    });

    group('when the Dart SDK does not match the engine', () {
      setUp(() {
        when(() => dartSdkCompatibility.validate()).thenThrow(
          DartSdkMismatchException(
            engineRevision: '70974f81',
            expectedDartSdkRevision: '6b58bb3a',
            actualDartSdkRevision: 'db98bdaa',
            flutterDirectory: '/flutter',
            shorebirdRoot: '/shorebird',
          ),
        );
      });

      test('fails with the remediation instead of building', () async {
        await expectLater(
          () => runWithOverrides(command.run),
          exitsWithError(
            message: contains('bin/internal/engine.version'),
            exitCode: ExitCode.config,
          ),
        );
        verifyNever(() => patcher.buildPatchArtifact());
      });
    });

    group('engine hydration and the coherence gate', () {
      // The release's revision MUST differ from the local pin. Sharing one
      // constant would make "asserted against the release's revision"
      // indistinguishable from "asserted against the ambient one", and the
      // regression these tests exist to catch would pass.
      const releaseOnlyRevision = 'release-pinned-revision-not-the-local-one';
      final revisionRelease = Release(
        id: release.id,
        appId: appId,
        version: releaseVersion,
        flutterRevision: releaseOnlyRevision,
        flutterVersion: flutterVersion,
        displayName: '1.2.3+1',
        platforms: const {
          releasePlatform: ReleasePlatformDetails(status: ReleaseStatus.active),
        },
        createdAt: DateTime(2023),
        updatedAt: DateTime(2023),
      );

      setUp(() {
        expect(
          releaseOnlyRevision,
          isNot(flutterRevision),
          reason: 'the release revision and the local pin must differ',
        );
        when(
          () => codePushClientWrapper.getRelease(
            appId: any(named: 'appId'),
            releaseVersion: any(named: 'releaseVersion'),
          ),
        ).thenAnswer((_) async => revisionRelease);
      });

      test(
        'hydrates the release revision BEFORE asserting coherence',
        () async {
          final exitCode = await runWithOverrides(command.run);
          expect(exitCode, equals(ExitCode.success.code));

          // Order is the whole point: asserting first judges a checkout whose
          // engine artifacts have not been fetched yet, and reports an absent
          // engine as an incoherent toolchain.
          verifyInOrder([
            () => shorebirdFlutter.installRevision(
              revision: releaseOnlyRevision,
              releasePlatform: ReleasePlatform.android,
            ),
            () => toolchainCoherence.assertCoherent(
              releasePlatform: ReleasePlatform.android,
            ),
          ]);
        },
      );

      test('hydrates ONLY the target platform', () async {
        await runWithOverrides(command.run);

        verify(
          () => shorebirdFlutter.installRevision(
            revision: releaseOnlyRevision,
            releasePlatform: ReleasePlatform.android,
          ),
        ).called(1);
        verifyNever(
          () => shorebirdFlutter.installRevision(
            revision: any(named: 'revision'),
            releasePlatform: ReleasePlatform.ios,
          ),
        );
      });

      test(
        'asserts coherence against the RELEASE revision, not the local pin',
        () async {
          String? revisionSeenByGate;
          when(
            () => toolchainCoherence.assertCoherent(
              releasePlatform: any(named: 'releasePlatform'),
            ),
          ).thenAnswer((_) async {
            revisionSeenByGate = shorebirdEnv.flutterRevision;
          });

          await runWithOverrides(command.run);

          expect(revisionSeenByGate, equals(releaseOnlyRevision));
          expect(
            revisionSeenByGate,
            isNot(flutterRevision),
            reason: 'the gate must not judge the ambient pin',
          );
        },
      );
    });

    group('when --track is blank', () {
      setUp(() {
        when(() => argResults['track']).thenReturn('   ');
      });

      test('is a usage error before building', () async {
        await expectLater(
          runWithOverrides(() => command.createPatch([patcher])),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              equals('Track name must not be blank.'),
            ),
          ),
        );
        verifyNever(
          () => patcher.buildPatchArtifact(
            releaseVersion: any(named: 'releaseVersion'),
          ),
        );
      });
    });

    group('when --track is too long', () {
      setUp(() {
        when(() => argResults['track']).thenReturn('a' * 129);
      });

      test('is a usage error before building', () async {
        await expectLater(
          runWithOverrides(() => command.createPatch([patcher])),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              equals('Track name must be at most 128 characters (got 129).'),
            ),
          ),
        );
      });
    });

    group('when flutter install fails', () {
      final error = Exception('Failed to install Flutter revision.');

      setUp(() {
        when(
          () => shorebirdFlutter.installRevision(
            revision: any(named: 'revision'),
            releasePlatform: any(named: 'releasePlatform'),
          ),
        ).thenThrow(error);
      });

      test('exits with code 70', () async {
        await expectLater(
          () => runWithOverrides(command.run),
          exitsWithCode(ExitCode.software),
        );
      });
    });

    group('when --release-version is missing or provided', () {
      group('when it is missing', () {
        setUp(() {
          when(
            () => argResults.wasParsed('release-version'),
          ).thenReturn(false);
        });

        test('prompts for the release when running interactively', () async {
          when(() => shorebirdEnv.canAcceptUserInput).thenReturn(true);

          final exitCode = await runWithOverrides(command.run);

          expect(exitCode, equals(ExitCode.success.code));
          // The release comes from the release picker, not from guessing the
          // version out of a build.
          verify(
            () => codePushClientWrapper.getReleases(appId: appId),
          ).called(1);
          verifyNever(() => patcher.extractReleaseVersionFromArtifact(any()));
        });
      });

      test('uses it when it is provided', () async {
        when(() => argResults.wasParsed('release-version')).thenReturn(true);
        when(() => argResults['release-version']).thenReturn(releaseVersion);

        final exitCode = await runWithOverrides(command.run);

        expect(exitCode, equals(ExitCode.success.code));
        verify(
          () => codePushClientWrapper.getRelease(
            appId: appId,
            releaseVersion: releaseVersion,
          ),
        ).called(1);
      });
    });

    group('when release version is specified', () {
      setUp(() {
        when(() => argResults['release-version']).thenReturn(releaseVersion);
      });

      test('executes commands in order, only builds app once', () async {
        final exitCode = await runWithOverrides(command.run);
        expect(exitCode, equals(ExitCode.success.code));

        verifyInOrder([
          () => patcher.assertPreconditions(),
          () => patcher.assertArgsAreValid(),
          () => shorebirdValidator.validateFlavors(
            flavorArg: null,
            releasePlatform: ReleasePlatform.android,
          ),
          () => cache.updateAll(),
          () => codePushClientWrapper.getApp(appId: appId),
          () => codePushClientWrapper.getRelease(
            appId: appId,
            releaseVersion: releaseVersion,
          ),
          () => patcher.prepareForRelease(appId: appId, release: release),
          () => codePushClientWrapper.getReleaseArtifact(
            appId: appId,
            releaseId: release.id,
            arch: patcher.primaryReleaseArtifactArch,
            platform: releasePlatform,
          ),
          () => patcher.buildPatchArtifact(releaseVersion: releaseVersion),
          () => patcher.assertUnpatchableDiffs(
            releaseArtifact: any(named: 'releaseArtifact'),
            releaseArchive: any(named: 'releaseArchive'),
            patchArchive: any(named: 'patchArchive'),
          ),
          () => patcher.createPatchArtifacts(
            appId: appId,
            releaseId: release.id,
            releaseArtifact: any(named: 'releaseArtifact'),
          ),
          () => codePushClientWrapper.publishPatch(
            appId: appId,
            releaseId: release.id,
            metadata: any(
              named: 'metadata',
              that: containsPair('inferred_release_version', isFalse),
            ),
            patchArtifactBundles: any(named: 'patchArtifactBundles'),
            sidecars: any(named: 'sidecars'),
            track: DeploymentTrack.stable,
          ),
        ]);
      });

      group('when building artifact throws ArtifactBuildException', () {
        late ArtifactBuildException exception;

        setUp(() {
          exception = MockArtifactBuildException();
          when(() => exception.message).thenReturn('oops');
          when(() => exception.fixRecommendation).thenReturn('fix it');
          when(
            () => patcher.buildPatchArtifact(
              releaseVersion: any(named: 'releaseVersion'),
            ),
          ).thenThrow(exception);
        });

        test('exits with the error and its fix as the hint', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithError(
              message: 'oops',
              hint: 'fix it',
              exitCode: ExitCode.software,
            ),
          );
        });
      });

      group('when building artifact throws generic Exception', () {
        late Exception exception;

        setUp(() {
          exception = Exception('oops');
          when(
            () => patcher.buildPatchArtifact(
              releaseVersion: any(named: 'releaseVersion'),
            ),
          ).thenThrow(exception);
        });

        test('exits with an error saying the build failed', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithError(
              message: 'Failed to build patch artifacts: $exception',
              exitCode: ExitCode.software,
            ),
          );
        });
      });

      group('when building artifact throws ProcessExit', () {
        late ProcessExit error;

        setUp(() {
          // A build step that already reported why it stopped.
          error = ProcessExit(ExitCode.unavailable.code);
          when(
            () => patcher.buildPatchArtifact(
              releaseVersion: any(named: 'releaseVersion'),
            ),
          ).thenThrow(error);
        });

        test('rethrows it as-is', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            throwsA(same(error)),
          );
        });
      });
    });

    group('when release version is latest', () {
      setUp(() {
        when(() => argResults['release-version']).thenReturn('latest');
      });

      group('when no releases for the target platform exist', () {
        setUp(() {
          when(
            () => codePushClientWrapper.getReleases(appId: any(named: 'appId')),
          ).thenAnswer(
            (_) async => [
              Release(
                id: 0,
                appId: appId,
                version: releaseVersion,
                flutterRevision: flutterRevision,
                flutterVersion: flutterVersion,
                displayName: '1.0.0+1',
                platforms: const {
                  ReleasePlatform.windows: ReleasePlatformDetails(
                    status: ReleaseStatus.active,
                  ),
                },
                createdAt: DateTime(2023),
                updatedAt: DateTime(2023),
              ),
            ],
          );
        });

        test('names the release command and exits', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithError(
              message:
                  'No ${releasePlatform.displayName} releases found for app '
                  '$appId.',
              hint:
                  'A patch needs a release to apply to (if this is the wrong '
                  'app, check app_id in shorebird.yaml or pass --flavor). Run: '
                  'shorebird release android',
            ),
          );

          verify(
            () => codePushClientWrapper.getReleases(appId: appId),
          ).called(1);
        });
      });

      group('when multiple releases for the target platform exist', () {
        setUp(() {
          when(
            () => codePushClientWrapper.getReleases(appId: any(named: 'appId')),
          ).thenAnswer(
            (_) async => [
              Release(
                id: 0,
                appId: appId,
                version: releaseVersion,
                flutterRevision: flutterRevision,
                flutterVersion: flutterVersion,
                displayName: releaseVersion,
                platforms: const {
                  releasePlatform: ReleasePlatformDetails(
                    status: ReleaseStatus.active,
                  ),
                },
                createdAt: DateTime(2024),
                updatedAt: DateTime(2024),
              ),
              Release(
                id: 1,
                appId: appId,
                version: '99.99.99+99',
                flutterRevision: flutterRevision,
                flutterVersion: flutterVersion,
                displayName: '99.99.99+99',
                platforms: const {
                  releasePlatform: ReleasePlatformDetails(
                    status: ReleaseStatus.active,
                  ),
                },
                createdAt: DateTime(2023),
                updatedAt: DateTime(2023),
              ),
            ],
          );
        });

        test('uses the latest version', () async {
          await expectLater(runWithOverrides(command.run), completes);
          verify(
            () => codePushClientWrapper.getReleases(appId: appId),
          ).called(1);
          verify(
            () => patcher.buildPatchArtifact(releaseVersion: releaseVersion),
          ).called(1);
        });
      });
    });

    group('when release version is not specified', () {
      setUp(() {
        when(() => argResults.wasParsed('release-version')).thenReturn(false);
        // Need 2+ releases so chooseRelease prompts instead of auto-selecting.
        final olderRelease = Release(
          id: 99,
          appId: appId,
          version: '0.0.1',
          flutterRevision: flutterRevision,
          flutterVersion: flutterVersion,
          displayName: '0.0.1',
          platforms: const {
            releasePlatform: ReleasePlatformDetails(
              status: ReleaseStatus.active,
            ),
          },
          createdAt: DateTime(2022),
          updatedAt: DateTime(2022),
        );
        when(
          () => codePushClientWrapper.getReleases(
            appId: any(named: 'appId'),
          ),
        ).thenAnswer((_) async => [release, olderRelease]);
      });

      test(
        'executes commands in order, prompts to determine release version',
        () async {
          final exitCode = await runWithOverrides(command.run);
          expect(exitCode, equals(ExitCode.success.code));

          final verificationResult = verifyInOrder([
            () => patcher.assertPreconditions(),
            () => patcher.assertArgsAreValid(),
            () => shorebirdValidator.validateFlavors(
              flavorArg: null,
              releasePlatform: ReleasePlatform.android,
            ),
            () => cache.updateAll(),
            () => codePushClientWrapper.getApp(appId: appId),
            () => codePushClientWrapper.getReleases(appId: appId),
            () => logger.chooseOne<Release>(
              'Which release would you like to patch?',
              choices: any(named: 'choices'),
              display: captureAny(named: 'display'),
              hint: any(named: 'hint'),
            ),
            () => codePushClientWrapper.getReleaseArtifact(
              appId: appId,
              releaseId: release.id,
              arch: patcher.primaryReleaseArtifactArch,
              platform: releasePlatform,
            ),
            () => patcher.assertUnpatchableDiffs(
              releaseArtifact: any(named: 'releaseArtifact'),
              releaseArchive: any(named: 'releaseArchive'),
              patchArchive: any(named: 'patchArchive'),
            ),
            () => patcher.createPatchArtifacts(
              appId: appId,
              releaseId: release.id,
              releaseArtifact: any(named: 'releaseArtifact'),
            ),
            () => codePushClientWrapper.publishPatch(
              appId: appId,
              releaseId: release.id,
              metadata: any(named: 'metadata'),
              patchArtifactBundles: any(named: 'patchArtifactBundles'),
              sidecars: any(named: 'sidecars'),
              track: DeploymentTrack.stable,
            ),
          ]);

          // Verify that the logger.chooseOne<Release> display function is
          // correct
          final displayFunctionCapture = verificationResult.captured.flattened
              .whereType<String Function(Release)>()
              .first;
          expect(
            displayFunctionCapture(release),
            equals('${release.version}  (Jan 1)'),
          );
        },
      );

      group('when prompting for releases, but there is none', () {
        setUp(() {
          when(
            () => codePushClientWrapper.getReleases(appId: any(named: 'appId')),
          ).thenAnswer((_) async => []);
        });

        test('names the release command and exits', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithError(
              message:
                  'No ${releasePlatform.displayName} releases found for app '
                  '$appId.',
              hint:
                  'A patch needs a release to apply to (if this is the wrong '
                  'app, check app_id in shorebird.yaml or pass --flavor). Run: '
                  'shorebird release android',
            ),
          );
        });

        group('with a flavor', () {
          const flavor = 'development';
          const flavorAppId = 'development-app-id';

          setUp(() {
            when(() => argResults['flavor']).thenReturn(flavor);
            when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
              const ShorebirdYaml(
                appId: appId,
                flavors: {flavor: flavorAppId},
              ),
            );
          });

          test('points at the flavor and names its release command', () async {
            await expectLater(
              () => runWithOverrides(command.run),
              exitsWithError(
                message:
                    'No ${releasePlatform.displayName} releases found for app '
                    '$flavorAppId.',
                hint:
                    'A patch needs a release to apply to (if this is the wrong '
                    'app, check flavors.$flavor in shorebird.yaml). Run: '
                    'shorebird release android --flavor=$flavor',
              ),
            );
          });
        });
      });

      group('when prompting for releases and multiple exist', () {
        setUp(() {
          when(
            () => codePushClientWrapper.getReleases(appId: any(named: 'appId')),
          ).thenAnswer(
            (_) async => [
              Release(
                id: 0,
                appId: appId,
                version: releaseVersion,
                flutterRevision: flutterRevision,
                flutterVersion: flutterVersion,
                displayName: releaseVersion,
                platforms: const {
                  releasePlatform: ReleasePlatformDetails(
                    status: ReleaseStatus.active,
                  ),
                },
                createdAt: DateTime(2023),
                updatedAt: DateTime(2023),
              ),
              Release(
                id: 1,
                appId: appId,
                version: releaseVersion,
                flutterRevision: flutterRevision,
                flutterVersion: flutterVersion,
                displayName: '2.0.0+1',
                platforms: const {
                  ReleasePlatform.macos: ReleasePlatformDetails(
                    status: ReleaseStatus.active,
                  ),
                  ReleasePlatform.windows: ReleasePlatformDetails(
                    status: ReleaseStatus.active,
                  ),
                },
                createdAt: DateTime(2023),
                updatedAt: DateTime(2023),
              ),
            ],
          );
        });

        test('only lists and uses releases '
            'for the specified platform', () async {
          await expectLater(runWithOverrides(command.run), completes);
          // Only one release matches the platform, so chooseRelease
          // auto-selects it without prompting.
          verifyNever(
            () => logger.chooseOne<Release>(
              any(),
              choices: any(named: 'choices'),
              display: any(named: 'display'),
            ),
          );

          verify(
            () => patcher.buildPatchArtifact(releaseVersion: releaseVersion),
          ).called(1);
        });
      });

      group('when running on CI without --release-version', () {
        setUp(() {
          when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);
        });

        // This fork never guesses the release version (upstream's guessing is
        // deprecated: shorebirdtech/shorebird#4354). It goes to the release
        // chooser, which refuses when it would have to prompt.
        group('when several releases exist', () {
          setUp(() {
            // The real logger, so the guard that refuses to prompt is the one
            // exercised rather than a mock told to throw.
            logger = ShorebirdLogger(level: Level.quiet);
            final olderRelease = Release(
              id: 99,
              appId: appId,
              version: '0.0.1',
              flutterRevision: flutterRevision,
              flutterVersion: flutterVersion,
              displayName: '0.0.1',
              platforms: const {
                releasePlatform: ReleasePlatformDetails(
                  status: ReleaseStatus.active,
                ),
              },
              createdAt: DateTime(2022),
              updatedAt: DateTime(2022),
            );
            when(
              () => codePushClientWrapper.getReleases(
                appId: any(named: 'appId'),
              ),
            ).thenAnswer((_) async => [release, olderRelease]);
          });

          test(
            'refuses at the chooser before building or publishing',
            () async {
              await expectLater(
                () => runWithOverrides(command.run),
                throwsA(
                  isA<InteractivePromptRequiredException>()
                      .having(
                        (e) => e.promptText,
                        'promptText',
                        'Which release would you like to patch?',
                      )
                      .having(
                        (e) => e.hint,
                        'hint',
                        contains('--release-version=<version>'),
                      ),
                ),
              );

              verifyNever(() => patcher.buildPatchArtifact());
              verifyNever(
                () => patcher.buildPatchArtifact(
                  releaseVersion: any(named: 'releaseVersion'),
                ),
              );
              verifyNever(
                () => patcher.extractReleaseVersionFromArtifact(any()),
              );
              verifyNever(
                () => codePushClientWrapper.publishPatch(
                  appId: any(named: 'appId'),
                  releaseId: any(named: 'releaseId'),
                  metadata: any(named: 'metadata'),
                  track: any(named: 'track'),
                  patchArtifactBundles: any(named: 'patchArtifactBundles'),
                  sidecars: any(named: 'sidecars'),
                ),
              );
            },
          );
        });

        group('when no releases exist', () {
          setUp(() {
            when(
              () => codePushClientWrapper.getReleases(
                appId: any(named: 'appId'),
              ),
            ).thenAnswer((_) async => []);
          });

          test('exits with the no-releases error, building nothing', () async {
            await expectLater(
              () => runWithOverrides(command.run),
              exitsWithError(
                message:
                    'No ${releasePlatform.displayName} releases found for app '
                    '$appId.',
              ),
            );

            verifyNever(() => patcher.buildPatchArtifact());
            verifyNever(
              () => patcher.buildPatchArtifact(
                releaseVersion: any(named: 'releaseVersion'),
              ),
            );
          });
        });

        group('when exactly one release exists', () {
          setUp(() {
            when(
              () => codePushClientWrapper.getReleases(
                appId: any(named: 'appId'),
              ),
            ).thenAnswer((_) async => [release]);
          });

          test('patches it without prompting or building twice', () async {
            final exitCode = await runWithOverrides(command.run);

            expect(exitCode, equals(ExitCode.success.code));
            verify(
              () => logger.info(any(that: startsWith('Using release'))),
            ).called(1);
            verifyNever(
              () => logger.chooseOne<Release>(
                any(),
                choices: any(named: 'choices'),
                display: any(named: 'display'),
                hint: any(named: 'hint'),
              ),
            );
            verifyNever(() => patcher.buildPatchArtifact());
            verifyNever(
              () => patcher.extractReleaseVersionFromArtifact(any()),
            );
            verify(
              () => patcher.buildPatchArtifact(releaseVersion: releaseVersion),
            ).called(1);
          });
        });
      });

      group('when running on CI with --release-version', () {
        setUp(() {
          when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);
          when(() => argResults.wasParsed('release-version')).thenReturn(true);
        });

        test('builds the patch once with the release settings', () async {
          await runWithOverrides(() => command.createPatch([patcher]));

          verifyNever(() => patcher.buildPatchArtifact());
          verifyNever(() => patcher.extractReleaseVersionFromArtifact(any()));
          verify(
            () => patcher.buildPatchArtifact(releaseVersion: releaseVersion),
          ).called(1);
        });

        test(
          'builds an obfuscated release\'s patch with its obfuscation map',
          () async {
            when(
              () => codePushClientWrapper.getRelease(
                appId: any(named: 'appId'),
                releaseVersion: any(named: 'releaseVersion'),
              ),
            ).thenAnswer(
              (_) async => Release(
                id: 0,
                appId: appId,
                version: releaseVersion,
                flutterRevision: flutterRevision,
                flutterVersion: '3.41.2',
                displayName: releaseVersion,
                platforms: const {
                  releasePlatform: ReleasePlatformDetails(
                    status: ReleaseStatus.active,
                  ),
                },
                createdAt: DateTime(2023),
                updatedAt: DateTime(2023),
              ),
            );
            when(
              () => patcher.supplementaryReleaseArtifactArch,
            ).thenReturn('supplement');
            when(
              () => artifactManager.extractZip(
                zipFile: any(named: 'zipFile'),
                outputDirectory: any(named: 'outputDirectory'),
              ),
            ).thenAnswer((invocation) async {
              final outputDirectory =
                  invocation.namedArguments[#outputDirectory] as Directory;
              File(
                p.join(outputDirectory.path, 'obfuscation_map.json'),
              ).writeAsStringSync('{}');
            });
            when(
              () => shorebirdFlutter.shouldPreStripLibappInGenSnapshot(
                platform: any(named: 'platform'),
                flutterRevision: any(named: 'flutterRevision'),
              ),
            ).thenAnswer((_) async => false);

            await runWithOverrides(() => command.createPatch([patcher]));

            verifyInOrder([
              () => patcher.obfuscationMapPath = any(that: isNotNull),
              () => patcher.extraBuildArgs = any(
                that: contains(
                  startsWith(
                    '--extra-gen-snapshot-options=--load-obfuscation-map=',
                  ),
                ),
              ),
              () => patcher.buildPatchArtifact(releaseVersion: releaseVersion),
            ]);
          },
        );

        test(
          'builds again with the key when the release embeds a managed key',
          () async {
            when(
              () => codePushClientWrapper.getReleaseArtifact(
                appId: any(named: 'appId'),
                releaseId: any(named: 'releaseId'),
                arch: 'aab',
                platform: ReleasePlatform.android,
              ),
            ).thenAnswer(
              (_) async => ReleaseArtifact(
                id: aabArtifact.id,
                releaseId: aabArtifact.releaseId,
                arch: aabArtifact.arch,
                platform: aabArtifact.platform,
                hash: aabArtifact.hash,
                size: aabArtifact.size,
                url: aabArtifact.url,
                canSideload: aabArtifact.canSideload,
                signing: const ArtifactSigning(
                  mode: 'managed',
                  keyId: 7,
                  publicKeyPem: 'managed-public-key-pem',
                ),
              ),
            );

            await runWithOverrides(() => command.createPatch([patcher]));

            verifyInOrder([
              () =>
                  patcher.releaseManagedPublicKeyPem = 'managed-public-key-pem',
              () => patcher.buildPatchArtifact(releaseVersion: releaseVersion),
            ]);
          },
        );

        group('when release Flutter version is not default', () {
          const releaseFlutterRevision = 'different-revision';

          setUp(() {
            when(
              () => codePushClientWrapper.getRelease(
                appId: any(named: 'appId'),
                releaseVersion: any(named: 'releaseVersion'),
              ),
            ).thenAnswer(
              (_) async => Release(
                id: 0,
                appId: appId,
                version: releaseVersion,
                flutterRevision: releaseFlutterRevision,
                flutterVersion: flutterVersion,
                displayName: '1.2.3+1',
                platforms: const {
                  releasePlatform: ReleasePlatformDetails(
                    status: ReleaseStatus.active,
                  ),
                },
                createdAt: DateTime(2023),
                updatedAt: DateTime(2023),
              ),
            );
          });

          test(
            'builds the patch with the release flutter version',
            () async {
              final exitCode = await runWithOverrides(command.run);
              expect(exitCode, equals(ExitCode.success.code));

              verifyInOrder([
                () => shorebirdFlutter.installRevision(
                  revision: releaseFlutterRevision,
                  releasePlatform: any(named: 'releasePlatform'),
                ),
                () => shorebirdEnv.copyWith(
                  flutterRevisionOverride: releaseFlutterRevision,
                ),
                () =>
                    patcher.buildPatchArtifact(releaseVersion: releaseVersion),
                () => codePushClientWrapper.publishPatch(
                  appId: any(named: 'appId'),
                  releaseId: any(named: 'releaseId'),
                  metadata: any(
                    named: 'metadata',
                    that: containsPair('inferred_release_version', isFalse),
                  ),
                  track: any(named: 'track'),
                  patchArtifactBundles: any(named: 'patchArtifactBundles'),
                  sidecars: any(named: 'sidecars'),
                ),
              ]);
            },
          );

          group("when the release's Flutter version is too old", () {
            setUp(() {
              when(
                () => patcher.minimumFlutterVersion,
              ).thenReturn(Version(3, 27, 4));
              // The CLI's own Flutter is new enough; the release's is not.
              when(() => shorebirdFlutter.getVersion()).thenAnswer(
                (_) async =>
                    shorebirdEnv.flutterRevision == releaseFlutterRevision
                    ? Version(3, 0, 0)
                    : Version(3, 27, 4),
              );
            });

            test(
              'exits with an error before building',
              () async {
                await expectLater(
                  () => runWithOverrides(() => command.createPatch([patcher])),
                  exitsWithError(
                    message: contains('patching with `android` needs at least'),
                    hint: contains('Run: shorebird release android'),
                    exitCode: ExitCode.software,
                  ),
                );

                verifyNever(() => patcher.buildPatchArtifact());
                verifyNever(
                  () => patcher.buildPatchArtifact(
                    releaseVersion: releaseVersion,
                  ),
                );
              },
            );
          });

          test(
            'updates cache with both default and release Flutter revisions',
            () async {
              await runWithOverrides(command.run);

              verifyInOrder([
                cache.updateAll,
                () => shorebirdEnv.copyWith(
                  flutterRevisionOverride: releaseFlutterRevision,
                ),
                cache.updateAll,
              ]);
            },
          );
        });
      });
    });

    group('--json', () {
      Future<T> runJson<T>(Future<T> Function() body) => runScoped(
        body,
        values: {isJsonModeRef.overrideWith(() => true)},
      );

      setUp(() {
        when(() => patcher.linkPercentage).thenReturn(97.5);
      });

      test('emits what was published', () async {
        final (:exitCode, :json) = await captureJson(
          () => runJson(() => runWithOverrides(command.run)),
        );

        expect(exitCode, equals(ExitCode.success.code));
        expect(json['status'], equals('success'));
        expect(
          json['data'],
          equals({
            'app_id': appId,
            'track': 'stable',
            'patches': [
              {
                'platform': 'android',
                'release_id': release.id,
                'release_version': release.version,
                'patch_id': 3,
                'patch_number': 2,
                'link_percentage': 97.5,
              },
            ],
          }),
        );
      });

      group('with --dry-run', () {
        setUp(() {
          when(() => argResults['dry-run']).thenReturn(true);
        });

        test('emits what would have been patched', () async {
          final captured = <String>[];
          await expectLater(
            captureStdout(
              () => runJson(() => runWithOverrides(command.run)),
              captured: captured,
            ),
            exitsWithCode(ExitCode.success),
          );

          expect(captured, hasLength(1));
          final envelope = jsonDecode(captured.single) as Map<String, dynamic>;
          expect(
            envelope['data'],
            equals({
              'dry_run': true,
              'app_id': appId,
              'platform': 'android',
              'release_id': release.id,
              'release_version': release.version,
              'link_percentage': 97.5,
            }),
          );
          verifyNever(() => logger.info('No issues detected.'));
        });
      });
    });

    group('when dry-run is specified', () {
      setUp(() {
        when(() => argResults['dry-run']).thenReturn(true);
      });

      test('fails when the link percentage is below the minimum', () async {
        when(() => patcher.linkPercentage).thenReturn(12.3);
        when(
          () => shorebirdEnv.buildDirectory,
        ).thenReturn(Directory.systemTemp.createTempSync());
        await expectLater(
          runWithOverrides(command.run),
          exitsWithError(
            message: contains('below the minimum threshold (20%)'),
            exitCode: ExitCode.software,
          ),
        );
        verifyNever(() => logger.info('No issues detected.'));
      });

      test('does not publish patch', () async {
        await expectLater(
          runWithOverrides(command.run),
          exitsWithCode(ExitCode.success),
        );

        verify(() => logger.info('No issues detected.')).called(1);

        verifyNever(
          () => logger.confirm(
            any(),
            defaultValue: any(named: 'defaultValue'),
            hint: any(named: 'hint'),
          ),
        );
        verifyNever(
          () => codePushClientWrapper.publishPatch(
            appId: appId,
            releaseId: release.id,
            metadata: any(named: 'metadata'),
            patchArtifactBundles: any(named: 'patchArtifactBundles'),
            sidecars: any(named: 'sidecars'),
            track: DeploymentTrack.stable,
          ),
        );
      });
    });

    group('when running on CI', () {
      test('does not prompt for confirmation', () async {
        when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);
        when(() => argResults.wasParsed('release-version')).thenReturn(true);

        final exitCode = await runWithOverrides(command.run);
        expect(exitCode, equals(ExitCode.success.code));

        verifyNever(
          () => logger.confirm(
            any(),
            defaultValue: any(named: 'defaultValue'),
            hint: any(named: 'hint'),
          ),
        );
      });
    });

    group('when the target release is in a draft state', () {
      setUp(() {
        when(
          () => codePushClientWrapper.getRelease(
            appId: any(named: 'appId'),
            releaseVersion: any(named: 'releaseVersion'),
          ),
        ).thenAnswer(
          (_) async => Release(
            id: 0,
            appId: appId,
            version: releaseVersion,
            flutterRevision: flutterRevision,
            flutterVersion: flutterVersion,
            displayName: '1.2.3+1',
            platforms: const {
              releasePlatform: ReleasePlatformDetails(
                status: ReleaseStatus.draft,
              ),
            },
            createdAt: DateTime(2023),
            updatedAt: DateTime(2023),
          ),
        );
      });

      test('exits with an error saying the release is incomplete', () async {
        await expectLater(
          () => runWithOverrides(command.run),
          exitsWithError(
            message:
                'Release ${release.version} is incomplete: the release '
                'command that created it was stopped or failed.',
            hint:
                'Re-run the release for this version, or create a new one. '
                'Run: shorebird release android',
            exitCode: ExitCode.software,
          ),
        );
      });
    });

    group('when the target release does not contain the provided platform', () {
      setUp(() {
        when(
          () => codePushClientWrapper.getRelease(
            appId: any(named: 'appId'),
            releaseVersion: any(named: 'releaseVersion'),
          ),
        ).thenAnswer(
          (_) async => Release(
            id: 0,
            appId: appId,
            version: releaseVersion,
            flutterRevision: flutterRevision,
            flutterVersion: flutterVersion,
            displayName: '1.2.3+1',
            platforms: const {
              ReleasePlatform.ios: ReleasePlatformDetails(
                status: ReleaseStatus.active,
              ),
            },
            createdAt: DateTime(2023),
            updatedAt: DateTime(2023),
          ),
        );
      });

      test('exits with an error saying the release has no build', () async {
        await expectLater(
          () => runWithOverrides(command.run),
          exitsWithError(
            message: 'Release ${release.version} has no Android build.',
            hint: 'Run: shorebird release android',
            exitCode: ExitCode.software,
          ),
        );
      });

      test('names the release version for an add-to-app patch', () {
        final aarPatcher = MockPatcher();
        when(() => aarPatcher.releaseType).thenReturn(ReleaseType.aar);
        final iosOnlyRelease = Release(
          id: 0,
          appId: appId,
          version: '2.0.0+3',
          flutterRevision: flutterRevision,
          flutterVersion: flutterVersion,
          displayName: '2.0.0+3',
          platforms: const {
            ReleasePlatform.ios: ReleasePlatformDetails(
              status: ReleaseStatus.active,
            ),
          },
          createdAt: DateTime(2023),
          updatedAt: DateTime(2023),
        );

        expect(
          () => command.assertReleaseContainsPlatform(
            release: iosOnlyRelease,
            patcher: aarPatcher,
          ),
          exitsWithError(
            message: 'Release 2.0.0+3 has no Android build.',
            hint: 'Run: shorebird release aar --release-version=2.0.0+3',
            exitCode: ExitCode.software,
          ),
        );
      });
    });

    group('when primary release artifact fails to download', () {
      final error = Exception('Failed to download primary release artifact.');

      setUp(() {
        when(
          () => artifactManager.downloadReleaseArtifact(
            any(),
            message: any(named: 'message'),
          ),
        ).thenThrow(error);
      });

      test('exits naming the failed download', () async {
        await expectLater(
          () => runWithOverrides(command.run),
          exitsWithError(
            message: startsWith('Could not download the release artifact: '),
            hint: 'Run the command again once that is fixed.',
            exitCode: ExitCode.software,
          ),
        );
      });
    });

    group('when unpatchable diffs exist', () {
      group('when user cancels', () {
        setUp(() {
          when(
            () => patcher.assertUnpatchableDiffs(
              releaseArtifact: any(named: 'releaseArtifact'),
              releaseArchive: any(named: 'releaseArchive'),
              patchArchive: any(named: 'patchArchive'),
            ),
          ).thenThrow(UserCancelledException());
        });

        test('exits 1 and prints Aborting. to stderr', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsDeclined,
          );
          verify(() => logger.err('Aborting.')).called(1);
        });
      });

      group('when UnpatchableChangeException is thrown', () {
        void throwsChanges(Set<UnpatchableChange> changes) {
          when(
            () => patcher.assertUnpatchableDiffs(
              releaseArtifact: any(named: 'releaseArtifact'),
              releaseArchive: any(named: 'releaseArchive'),
              patchArchive: any(named: 'patchArchive'),
            ),
          ).thenThrow(UnpatchableChangeException(changes));
        }

        test('for assets, exits naming the release and the flag', () async {
          throwsChanges({UnpatchableChange.asset});
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithError(
              message:
                  'Not publishing: assets changed since the release, and a '
                  "patch can't include those changes.",
              hint:
                  'To ship these changes, create a new release. '
                  'Run: shorebird release android\n'
                  'To publish the patch without them, pass '
                  '--allow-asset-diffs.',
              exitCode: ExitCode.software,
            ),
          );
        });

        test('for native code and assets, names both flags and warns of '
            'crashes', () async {
          throwsChanges({UnpatchableChange.native, UnpatchableChange.asset});
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithError(
              message:
                  'Not publishing: native code and assets changed since the '
                  "release, and a patch can't include those changes.",
              hint:
                  'To ship these changes, create a new release. '
                  'Run: shorebird release android\n'
                  'To publish the patch without them, pass '
                  '--allow-native-diffs --allow-asset-diffs.\n'
                  "Only do this if your Dart code doesn't depend on the "
                  'native changes: a mismatch between your Dart code and the '
                  "release's native code can crash your app.",
              exitCode: ExitCode.software,
            ),
          );
        });

        test('for an add-to-app release, asks for a new version', () async {
          when(() => patcher.releaseType).thenReturn(ReleaseType.aar);
          throwsChanges({UnpatchableChange.asset});
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithError(
              message: anything,
              hint: contains(
                'Run: shorebird release aar --release-version=<new version>',
              ),
              exitCode: ExitCode.software,
            ),
          );
        });
      });
    });

    group('when patching to the staging track', () {
      setUp(() {
        when(
          () => argResults['track'],
        ).thenReturn(DeploymentTrack.staging.channel);
      });

      test('publishes to the staging track', () async {
        final exitCode = await runWithOverrides(command.run);
        expect(exitCode, equals(ExitCode.success.code));

        verify(
          () => codePushClientWrapper.publishPatch(
            appId: appId,
            releaseId: release.id,
            metadata: any(named: 'metadata'),
            patchArtifactBundles: any(named: 'patchArtifactBundles'),
            sidecars: any(named: 'sidecars'),
            track: DeploymentTrack.staging,
          ),
        ).called(1);
      });
    });

    group('when --track=stable is given', () {
      test('does not record that it used the default', () async {
        final exitCode = await runWithOverrides(command.run);
        expect(exitCode, equals(ExitCode.success.code));

        verify(
          () => codePushClientWrapper.publishPatch(
            appId: any(named: 'appId'),
            releaseId: any(named: 'releaseId'),
            metadata: any(
              named: 'metadata',
              that: containsPair('used_default_track', isFalse),
            ),
            track: any(named: 'track'),
            patchArtifactBundles: any(named: 'patchArtifactBundles'),
            sidecars: any(named: 'sidecars'),
          ),
        ).called(1);
      });
    });

    group('when --track is not given', () {
      setUp(() {
        when(() => argResults['track']).thenReturn(null);
      });

      group('when it can ask', () {
        setUp(() {
          when(() => shorebirdEnv.canAcceptUserInput).thenReturn(true);
          when(
            () => logger.chooseOne<DeploymentTrack>(
              any(),
              choices: any(named: 'choices'),
              defaultValue: any(named: 'defaultValue'),
              display: any(named: 'display'),
            ),
          ).thenReturn(DeploymentTrack.beta);
        });

        test('asks for the track, defaulting to staging, before building '
            'and publishes to the chosen one', () async {
          final exitCode = await runWithOverrides(command.run);
          expect(exitCode, equals(ExitCode.success.code));

          verifyInOrder([
            () => logger.chooseOne<DeploymentTrack>(
              'Which track should this patch be published to?',
              choices: const [
                DeploymentTrack.staging,
                DeploymentTrack.beta,
                DeploymentTrack.stable,
              ],
              defaultValue: DeploymentTrack.staging,
              display: any(named: 'display'),
            ),
            () => patcher.buildPatchArtifact(
              releaseVersion: any(named: 'releaseVersion'),
            ),
            () => codePushClientWrapper.publishPatch(
              appId: appId,
              releaseId: release.id,
              metadata: any(named: 'metadata'),
              patchArtifactBundles: any(named: 'patchArtifactBundles'),
              sidecars: any(named: 'sidecars'),
              track: DeploymentTrack.beta,
            ),
          ]);
        });

        test('does not ask on a dry run', () async {
          when(() => argResults['dry-run']).thenReturn(true);

          await expectLater(
            runWithOverrides(command.run),
            exitsWithCode(ExitCode.success),
          );

          verifyNever(
            () => logger.chooseOne<DeploymentTrack>(
              any(),
              choices: any(named: 'choices'),
              defaultValue: any(named: 'defaultValue'),
              display: any(named: 'display'),
            ),
          );
        });
      });

      group('when it cannot ask', () {
        setUp(() {
          when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);
          when(() => argResults.wasParsed('release-version')).thenReturn(true);
        });

        test('warns, publishes to stable and records that it used the '
            'default', () async {
          final exitCode = await runWithOverrides(command.run);
          expect(exitCode, equals(ExitCode.success.code));

          verify(
            () => logger.warn(
              'No --track given, so this patch is published to the stable '
              'track, which reaches all users. A future release will require '
              '--track when it cannot ask. Pass --track=stable to keep '
              'publishing to stable, or --track=staging to test the patch '
              'before promoting it.',
            ),
          ).called(1);
          verify(
            () => codePushClientWrapper.publishPatch(
              appId: appId,
              releaseId: release.id,
              metadata: any(
                named: 'metadata',
                that: containsPair('used_default_track', isTrue),
              ),
              patchArtifactBundles: any(named: 'patchArtifactBundles'),
              sidecars: any(named: 'sidecars'),
              track: DeploymentTrack.stable,
            ),
          ).called(1);
          verifyNever(
            () => logger.chooseOne<DeploymentTrack>(
              any(),
              choices: any(named: 'choices'),
              defaultValue: any(named: 'defaultValue'),
              display: any(named: 'display'),
            ),
          );
        });
      });
    });

    group('when no platform argument is provided', () {
      setUp(() {
        when(() => argResults['platforms']).thenReturn(const <String>[]);
        command.testRunner = usageRunner();
      });

      test('throws a usage exception listing the valid platforms', () async {
        await expectLater(
          runWithOverrides(command.run),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              '''
No platform was provided.
Valid platforms: aar, android, ios, ios-framework, linux, macos, windows''',
            ),
          ),
        );
      });
    });

    group('when the platform argument is invalid', () {
      late MockShorebirdCliCommandRunner runner;
      late MockCommand patchesCommand;

      setUp(() {
        runner = usageRunner();
        patchesCommand = MockCommand();
        when(() => argResults.wasParsed('platforms')).thenReturn(false);
        when(() => argResults.arguments).thenReturn(['rollback']);
        when(() => argResults.rest).thenReturn(['rollback']);
        when(() => runner.commands).thenReturn({'patches': patchesCommand});
        when(
          () => patchesCommand.subcommands,
        ).thenReturn({'rollback': MockCommand()});
        command.testRunner = runner;
      });

      test('points at the patches subcommand of the same name', () async {
        await expectLater(
          runWithOverrides(command.run),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              '''
Invalid platform: "rollback".
Valid platforms: aar, android, ios, ios-framework, linux, macos, windows
Did you mean "shorebird patches rollback"?''',
            ),
          ),
        );
      });

      test('reports the invalid platform when no subcommand matches', () async {
        when(() => argResults.arguments).thenReturn(['web']);
        when(() => argResults.rest).thenReturn(['web']);
        await expectLater(
          runWithOverrides(command.run),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              '''
Invalid platform: "web".
Valid platforms: aar, android, ios, ios-framework, linux, macos, windows''',
            ),
          ),
        );
      });
    });

    group('reported patch metadata', () {
      group('when signing keys are provided', () {
        setUp(() {
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
          ).thenReturn(true);
          when(
            () => argResults.wasParsed(CommonArguments.privateKeyArg.name),
          ).thenReturn(true);
        });

        test('sets isSigned to true in PatchMetadata', () async {
          await runWithOverrides(command.run);
          verify(
            () => codePushClientWrapper.publishPatch(
              appId: any(named: 'appId'),
              releaseId: any(named: 'releaseId'),
              metadata: any(
                named: 'metadata',
                that: containsPair('is_signed', isTrue),
              ),
              track: any(named: 'track'),
              patchArtifactBundles: any(named: 'patchArtifactBundles'),
              sidecars: any(named: 'sidecars'),
            ),
          );
        });
      });

      group('when no signing keys are provided', () {
        setUp(() {
          when(
            () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
          ).thenReturn(false);
          when(
            () => argResults.wasParsed(CommonArguments.privateKeyArg.name),
          ).thenReturn(false);
        });

        test('sets isSigned to false in PatchMetadata', () async {
          await runWithOverrides(command.run);
          verify(
            () => codePushClientWrapper.publishPatch(
              appId: any(named: 'appId'),
              releaseId: any(named: 'releaseId'),
              metadata: any(
                named: 'metadata',
                that: containsPair('is_signed', isFalse),
              ),
              track: any(named: 'track'),
              patchArtifactBundles: any(named: 'patchArtifactBundles'),
              sidecars: any(named: 'sidecars'),
            ),
          );
        });
      });
    });
  });

  group('sortByUpdatedAt', () {
    test('sorts versions correctly', () {
      expect(
        [
          _FakeRelease(updatedAt: DateTime(2025, 05, 15)),
          _FakeRelease(updatedAt: DateTime(2025, 04, 15)),
          _FakeRelease(updatedAt: DateTime(2021, 09, 25)),
          _FakeRelease(updatedAt: DateTime(2024)),
        ]..sortByUpdatedAt(),
        equals([
          _FakeRelease(updatedAt: DateTime(2021, 09, 25)),
          _FakeRelease(updatedAt: DateTime(2024)),
          _FakeRelease(updatedAt: DateTime(2025, 04, 15)),
          _FakeRelease(updatedAt: DateTime(2025, 05, 15)),
        ]),
      );
    });
  });

  test('PatchCommand accepts flutter build options without --', () {
    final results = PatchCommand().argParser.parse([
      'android',
      '--no-tree-shake-icons',
      '-D',
      'FOO=a,b',
      '-P',
      'key=value',
    ]);
    expect(results.forwardedArgs, [
      '--dart-define=FOO=a,b',
      '--android-project-arg=key=value',
      '--no-tree-shake-icons',
    ]);
  });
}
