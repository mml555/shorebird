import 'dart:io';
import 'dart:convert';

import 'package:args/args.dart';
import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/archive_analysis/archive_analysis.dart';
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
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/gen_snapshot_probe.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/metadata/metadata.dart';
import 'package:shorebird_cli/src/patch_diff_checker.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/route_b_provenance.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/toolchain_coherence.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import '../../fakes.dart';
import '../../helpers.dart';
import '../../matchers.dart';
import '../../mocks.dart';

class _FakeRelease extends Fake with EquatableMixin implements Release {
  _FakeRelease({required this.updatedAt});

  @override
  final DateTime updatedAt;

  @override
  List<Object?> get props => [updatedAt];
}

void main() {
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
      platformStatuses: const {releasePlatform: ReleaseStatus.active},
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
      podfileLockHash: null,
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
      podfileLockHash: null,
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
      podfileLockHash: null,
      canSideload: false,
    );

    late AotTools aotTools;
    late ArgResults argResults;
    late ArtifactBuilder artifactBuilder;
    late ArtifactManager artifactManager;
    late Cache cache;
    late DartSdkCompatibility dartSdkCompatibility;
    late CodePushClientWrapper codePushClientWrapper;
    late GenSnapshotProbe genSnapshotProbe;
    late ShorebirdLogger logger;
    late Patcher patcher;
    late Progress progress;
    late ShorebirdEnv shorebirdEnv;
    late ToolchainCoherence toolchainCoherence;
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
          dartSdkCompatibilityRef.overrideWith(
            () => dartSdkCompatibility,
          ),
          codePushClientWrapperRef.overrideWith(() => codePushClientWrapper),
          genSnapshotProbeRef.overrideWith(() => genSnapshotProbe),
          loggerRef.overrideWith(() => logger),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          toolchainCoherenceRef.overrideWith(() => toolchainCoherence),
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
      codePushClientWrapper = MockCodePushClientWrapper();
      genSnapshotProbe = MockGenSnapshotProbe();
      logger = MockShorebirdLogger();
      progress = MockProgress();
      patcher = MockPatcher();
      shorebirdEnv = MockShorebirdEnv();
      // The producer's coherence gate is exercised by
      // toolchain_coherence_test.dart, including its refusal path; here it is
      // stubbed coherent so these tests keep testing the command.
      toolchainCoherence = MockToolchainCoherence();
      when(
        () => toolchainCoherence.check(
          flutterDirectory: any(named: 'flutterDirectory'),
          engineRevision: any(named: 'engineRevision'),
          platform: any(named: 'platform'),
          publishedDartSdkZip: any(named: 'publishedDartSdkZip'),
        ),
      ).thenReturn([]);
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
      // wasParsed(any()) is stubbed true above, so ForwardedArgs._flagNamed
      // goes on to cast `this['obfuscate'] as bool`. patch_command now reads
      // forwardedArgs to compute the patch's effective configuration, so this
      // flag has to have a value or every test that reaches that point throws
      // "Null is not a subtype of bool".
      when(() => argResults[CommonArguments.obfuscateArg.name]).thenReturn(
        false,
      );
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

      when(
        () => artifactManager.downloadWithProgressUpdates(
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
          metadata: any(named: 'metadata'),
          track: any(named: 'track'),
          patchArtifactBundles: any(named: 'patchArtifactBundles'),
          sidecars: any(named: 'sidecars'),
        ),
      ).thenAnswer((_) async {});
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

      when(() => patcher.assertArgsAreValid()).thenAnswer((_) async {});
      when(() => patcher.assertPreconditions()).thenAnswer((_) async {});
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
      // Neither sidecar by default: no --assets, no --split-debug-info.
      when(patcher.assetsDirectory).thenAnswer((_) async => null);
      when(patcher.debugSymbolsDirectory).thenAnswer((_) async => null);
      when(
        () => patcher.createPatchArtifacts(
          appId: any(named: 'appId'),
          releaseId: any(named: 'releaseId'),
          releaseArtifact: any(named: 'releaseArtifact'),
          supplementDirectory: any(named: 'supplementDirectory'),
        ),
      ).thenAnswer((_) async => patchArtifactBundles);
      when(
        () => patcher.updatedPlatformMetadata(any()),
      ).thenAnswer((invocation) async {
        return invocation.positionalArguments.first
            as CreatePatchPlatformMetadata;
      });
      when(
        () => patcher.updatedEnvironmentMetadata(any()),
      ).thenAnswer((invocation) async {
        return invocation.positionalArguments.first as BuildEnvironmentMetadata;
      });
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
        () =>
            shorebirdFlutter.installRevision(
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
        ..testArgResults = argResults;
    });

    test('has non-empty description', () {
      expect(command.description, isNotEmpty);
    });

    group('run', () {
      group('when --staging is passed', () {
        setUp(() {
          when(() => argResults.wasParsed('staging')).thenReturn(true);
        });

        test(
          '''warns that staging flag will be deprecated and exits with usage code''',
          () async {
            await expectLater(
              runWithOverrides(command.run),
              completion(equals(ExitCode.usage.code)),
            );
            verify(
              () => logger.err(
                '''The --staging flag is deprecated and will be removed in a future release. Use --track=staging instead.''',
              ),
            ).called(1);
          },
        );
      });
    });

    group('--assets', () {
      test('is an opt-in flag', () {
        final parser = PatchCommand().argParser;

        expect(parser.options['assets']!.isFlag, isTrue);
        expect(parser.options['assets']!.negatable, isFalse);
        expect(parser.parse([])['assets'], isFalse);
        expect(parser.parse(['--assets'])['assets'], isTrue);
      });
    });

    group('--assets-only', () {
      test('is an opt-in flag', () {
        final parser = PatchCommand().argParser;

        expect(parser.options['assets-only']!.isFlag, isTrue);
        expect(parser.options['assets-only']!.negatable, isFalse);
        expect(parser.parse([])['assets-only'], isFalse);
        expect(parser.parse(['--assets-only'])['assets-only'], isTrue);
      });

      test('implies --assets', () {
        // A patch with neither code nor assets would carry nothing at all, so
        // requiring both flags together would only trip people up.
        final args = MockArgResults();
        when(() => args['assets']).thenReturn(false);
        when(() => args['assets-only']).thenReturn(true);
        final command = PatchCommand()..testArgResults = args;

        expect(command.assetsOnly, isTrue);
        expect(command.includeAssets, isTrue);
      });

      test('does not imply the reverse', () {
        final args = MockArgResults();
        when(() => args['assets']).thenReturn(true);
        when(() => args['assets-only']).thenReturn(false);
        final command = PatchCommand()..testArgResults = args;

        expect(command.includeAssets, isTrue);
        expect(command.assetsOnly, isFalse);
      });
    });

    group('createPatch', () {
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
            ).thenThrow(ValidationFailedException());
          });

          test('exits with code 78 (config)', () async {
            await expectLater(
              runWithOverrides(() => command.createPatch([patcher])),
              exitsWithCode(ExitCode.config),
            );
          });
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
            test('logs error and exits with usage code', () async {
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
                exitsWithCode(ExitCode.usage),
              );
              verify(
                () => logger.err(
                  'Both public and private keys must be provided.',
                ),
              ).called(1);
            });
          },
        );

        group(
          'when given an existing public key and nonexistent private key',
          () {
            test('fails and logs the err', () async {
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
                exitsWithCode(ExitCode.usage),
              );
              verify(
                () => logger.err(
                  'Both public and private keys must be provided.',
                ),
              ).called(1);
            });
          },
        );

        // ------------------------------------------------------------------
        // A2 — effective build-configuration compatibility.
        //
        // ONE app_id THROUGHOUT. This whole file drives a single `appId`, so a
        // refusal here can never come from app routing. That matters: on real
        // hardware a two-app_id shorebird.yaml produced a REFUSAL FOR THE WRONG
        // REASON ("Release not found", from getAppId(flavor:) resolving `bar`
        // to a different app), which reads exactly like the right one. The
        // wrong-flavor arm is only meaningful when routing cannot satisfy it.
        // ------------------------------------------------------------------
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

          group('when the supplement contains an obfuscation map', () {
            // The release's Flutter revision MUST differ from the locally
            // pinned one (`flutterRevision`, which is what
            // `shorebirdEnv.flutterRevision` returns until the `copyWith`
            // near the end of createPatch). Reusing one constant for both
            // makes `verify(... flutterRevision: X)` unable to tell the two
            // sources apart, so a gate that read the LOCAL pin — a real bug,
            // since the pin is still local at that point in createPatch —
            // would pass the test. Keep these distinct.
            const obfuscatedReleaseFlutterRevision =
                'release-pinned-revision-not-the-local-one';
            final obfuscatedRelease = Release(
              id: release.id,
              appId: appId,
              version: releaseVersion,
              flutterRevision: obfuscatedReleaseFlutterRevision,
              flutterVersion: flutterVersion,
              displayName: '1.2.3+1',
              platformStatuses: const {releasePlatform: ReleaseStatus.active},
              createdAt: DateTime(2023),
              updatedAt: DateTime(2023),
            );

            // Wire up extractZip to actually write the obfuscation_map.json
            // so PatchCommand's `if (obfuscationMapFile != null)` block
            // fires.
            setUp(() {
              expect(
                obfuscatedRelease.flutterRevision,
                isNot(flutterRevision),
                reason:
                    '''the release revision and the local pin must be distinguishable''',
              );
              when(
                () => codePushClientWrapper.getRelease(
                  appId: any(named: 'appId'),
                  releaseVersion: any(named: 'releaseVersion'),
                ),
              ).thenAnswer((_) async => obfuscatedRelease);
              when(
                () => codePushClientWrapper.getReleases(
                  appId: any(named: 'appId'),
                ),
              ).thenAnswer((_) async => [obfuscatedRelease]);
              when(
                () => logger.chooseOne<Release>(
                  any(),
                  choices: any(named: 'choices'),
                  display: any(named: 'display'),
                  hint: any(named: 'hint'),
                ),
              ).thenReturn(obfuscatedRelease);
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

            group(
              '''when the release's gen_snapshot does not carry --load-obfuscation-map''',
              () {
                setUp(() {
                  when(
                    () => genSnapshotProbe.supportsLoadObfuscationMap(
                      flutterRevision: any(named: 'flutterRevision'),
                      platform: any(named: 'platform'),
                    ),
                  ).thenAnswer((_) async => GenSnapshotFlagSupport.absent);
                  // Stubbed so that, absent the capability check, the patch
                  // would build and upload normally: these tests must fail
                  // because the CLI failed to refuse, not because a
                  // downstream mock was missing.
                  when(
                    () => shorebirdFlutter.shouldPreStripLibappInGenSnapshot(
                      platform: any(named: 'platform'),
                      flutterRevision: any(named: 'flutterRevision'),
                    ),
                  ).thenAnswer((_) async => true);
                });

                test('logs the real cause and exits before building', () async {
                  await expectLater(
                    () =>
                        runWithOverrides(() => command.createPatch([patcher])),
                    exitsWithCode(ExitCode.software),
                  );

                  final message =
                      verify(() => logger.err(captureAny())).captured.last
                          as String;
                  expect(
                    message,
                    contains(
                      '''does not carry the --load-obfuscation-map flag''',
                    ),
                  );
                  expect(
                    message,
                    contains(obfuscatedRelease.flutterRevision),
                  );
                  // The message must name the binary that was interrogated,
                  // not a version floor: the reader needs to know which
                  // gen_snapshot answered.
                  expect(message, contains('/path/to/gen_snapshot'));
                  expect(
                    message,
                    contains('an engine capability, not a Flutter version'),
                  );

                  // The whole point of the check is to fail before the build:
                  // gen_snapshot would otherwise exit 255 for every arch.
                  verifyNever(() => patcher.extraBuildArgs = any());
                  verifyNever(
                    () => patcher.createPatchArtifacts(
                      appId: any(named: 'appId'),
                      releaseId: any(named: 'releaseId'),
                      releaseArtifact: any(named: 'releaseArtifact'),
                      supplementDirectory: any(named: 'supplementDirectory'),
                    ),
                  );
                });

                test(
                  '''is probed for the release's Flutter revision, not the local pin''',
                  () async {
                    await expectLater(
                      () => runWithOverrides(
                        () => command.createPatch([patcher]),
                      ),
                      exitsWithCode(ExitCode.software),
                    );

                    // Distinct values, so this cannot pass if the
                    // implementation reads shorebirdEnv.flutterRevision.
                    verify(
                      () => genSnapshotProbe.supportsLoadObfuscationMap(
                        flutterRevision: obfuscatedReleaseFlutterRevision,
                        platform: releasePlatform,
                      ),
                    ).called(1);
                    verifyNever(
                      () => genSnapshotProbe.supportsLoadObfuscationMap(
                        flutterRevision: flutterRevision,
                        platform: any(named: 'platform'),
                      ),
                    );
                  },
                );
              },
            );

            group(
              '''when gen_snapshot support cannot be determined''',
              () {
                setUp(() {
                  when(
                    () => genSnapshotProbe.supportsLoadObfuscationMap(
                      flutterRevision: any(named: 'flutterRevision'),
                      platform: any(named: 'platform'),
                    ),
                  ).thenAnswer(
                    (_) async => GenSnapshotFlagSupport.indeterminate,
                  );
                  when(
                    () => shorebirdFlutter.shouldPreStripLibappInGenSnapshot(
                      platform: any(named: 'platform'),
                      flutterRevision: any(named: 'flutterRevision'),
                    ),
                  ).thenAnswer((_) async => true);
                });

                test('warns and proceeds with the patch', () async {
                  await runWithOverrides(() => command.createPatch([patcher]));

                  final message =
                      verify(() => logger.warn(captureAny())).captured.last
                          as String;
                  expect(
                    message,
                    contains(
                      '''Could not verify that gen_snapshot supports --load-obfuscation-map''',
                    ),
                  );
                  expect(
                    message,
                    contains(obfuscatedRelease.flutterRevision),
                  );
                  verify(
                    () => patcher.createPatchArtifacts(
                      appId: appId,
                      releaseId: obfuscatedRelease.id,
                      releaseArtifact: any(named: 'releaseArtifact'),
                      supplementDirectory: any(named: 'supplementDirectory'),
                    ),
                  ).called(1);
                });
              },
            );
          });
        });

        group(
          'when --obfuscate is passed but release has no obfuscation map',
          () {
            setUp(() {
              when(() => argResults.wasParsed('obfuscate')).thenReturn(true);
              when(() => argResults['obfuscate']).thenReturn(true);
            });

            test('logs error and exits', () async {
              await expectLater(
                () => runWithOverrides(() => command.createPatch([patcher])),
                exitsWithCode(ExitCode.software),
              );
              verify(
                () => logger.err(
                  '--obfuscate was passed, but the release was not built with '
                  'obfuscation. A patch cannot change the obfuscation mode of '
                  'a release.',
                ),
              ).called(1);
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
      // The threshold is parsed by parseMinLinkPercentage before any build and
      // handed to logPatchSummary; these tests pass it directly.
      var minLinkPercentage = 0;

      setUp(() => minLinkPercentage = 0);

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
                  ReleasePlatform.android: patchArtifactBundles,
                },
                minLinkPercentage: minLinkPercentage,
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
                  ReleasePlatform.android: patchArtifactBundles,
                },
                minLinkPercentage: minLinkPercentage,
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

        test('isStaging returns true', () {
          expect(command.isStaging, isTrue);
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
                  ReleasePlatform.android: patchArtifactBundles,
                },
                minLinkPercentage: minLinkPercentage,
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
                  ReleasePlatform.android: patchArtifactBundles,
                },
                minLinkPercentage: minLinkPercentage,
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
        const linkPercentage = 42.1337;
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
                  ReleasePlatform.android: patchArtifactBundles,
                },
                minLinkPercentage: minLinkPercentage,
              ),
            ),
            completes,
          );
          verify(
            () => logger.info(any(that: contains(expectedSummary.join('\n')))),
          ).called(1);
        });

        group('when min-link-percentage is specified', () {
          group('when link percentage is higher than min', () {
            setUp(() => minLinkPercentage = 40);

            test('completes, does not print error message', () async {
              await expectLater(
                runWithOverrides(
                  () => command.logPatchSummary(
                    app: appMetadata,
                    releaseVersion: releaseVersion,
                    patchers: [patcher],
                    patchArtifactBundles: {
                      ReleasePlatform.android: patchArtifactBundles,
                    },
                    minLinkPercentage: minLinkPercentage,
                  ),
                ),
                completes,
              );

              verifyNever(() {
                logger.err(
                  any(that: contains('is below the minimum threshold')),
                );
              });
            });
          });

          group('when link percentage is lower than min', () {
            setUp(() => minLinkPercentage = 50);

            test('prints error message and exits', () async {
              await expectLater(
                runWithOverrides(
                  () => command.logPatchSummary(
                    app: appMetadata,
                    releaseVersion: releaseVersion,
                    patchers: [patcher],
                    patchArtifactBundles: {
                      ReleasePlatform.android: patchArtifactBundles,
                    },
                    minLinkPercentage: minLinkPercentage,
                  ),
                ),
                exitsWithCode(ExitCode.software),
              );

              verify(
                () => logger.err(
                  '''The Android link percentage of this patch ($linkPercentage%) is below the minimum threshold (50%). Exiting.''',
                ),
              ).called(1);
            });
          });

          group('when min-link-percentage is invalid', () {
            Future<void> expectUsageError(String value) async {
              when(
                () => argResults[CommonArguments.minLinkPercentage.name],
              ).thenReturn(value);
              expect(
                () => runWithOverrides(command.parseMinLinkPercentage),
                exitsWithCode(ExitCode.usage),
              );
              verify(
                () => logger.err(
                  '--min-link-percentage must be an integer between 0 and 100 '
                  '(got $value).',
                ),
              ).called(1);
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
              expect(runWithOverrides(command.parseMinLinkPercentage), 0);
              await expectLater(
                runWithOverrides(
                  () => command.logPatchSummary(
                    app: appMetadata,
                    releaseVersion: releaseVersion,
                    patchers: [patcher],
                    patchArtifactBundles: {
                      ReleasePlatform.android: patchArtifactBundles,
                    },
                    minLinkPercentage: minLinkPercentage,
                  ),
                ),
                completes,
              );
            });

            test('100 is accepted', () async {
              when(
                () => argResults[CommonArguments.minLinkPercentage.name],
              ).thenReturn('100');
              expect(runWithOverrides(command.parseMinLinkPercentage), 100);
              minLinkPercentage = 100;
              when(() => patcher.linkPercentage).thenReturn(100);
              await expectLater(
                runWithOverrides(
                  () => command.logPatchSummary(
                    app: appMetadata,
                    releaseVersion: releaseVersion,
                    patchers: [patcher],
                    patchArtifactBundles: {
                      ReleasePlatform.android: patchArtifactBundles,
                    },
                    minLinkPercentage: minLinkPercentage,
                  ),
                ),
                completes,
              );
            });
          });
        });
      });

      group('when --confirm is passed', () {
        setUp(() {
          when(() => argResults['confirm']).thenReturn(true);
          when(() => shorebirdEnv.canAcceptUserInput).thenReturn(true);
        });

        group('when user confirms', () {
          setUp(() {
            when(
              () => logger.confirm(
                any(),
                defaultValue: any(named: 'defaultValue'),
                hint: any(named: 'hint'),
              ),
            ).thenReturn(true);
          });

          test('continues', () async {
            await expectLater(
              runWithOverrides(
                () => command.logPatchSummary(
                  app: appMetadata,
                  releaseVersion: releaseVersion,
                  patchers: [patcher],
                  patchArtifactBundles: {
                    ReleasePlatform.android: patchArtifactBundles,
                  },
                  minLinkPercentage: minLinkPercentage,
                ),
              ),
              completes,
            );
            verify(
              () => logger.confirm(
                'Would you like to continue?',
                defaultValue: true,
                hint: any(named: 'hint'),
              ),
            ).called(1);
          });
        });

        group('when user declines', () {
          setUp(() {
            when(
              () => logger.confirm(
                any(),
                defaultValue: any(named: 'defaultValue'),
                hint: any(named: 'hint'),
              ),
            ).thenReturn(false);
          });

          test('exits with success and prints Aborting.', () async {
            await expectLater(
              runWithOverrides(
                () => command.logPatchSummary(
                  app: appMetadata,
                  releaseVersion: releaseVersion,
                  patchers: [patcher],
                  patchArtifactBundles: {
                    ReleasePlatform.android: patchArtifactBundles,
                  },
                  minLinkPercentage: minLinkPercentage,
                ),
              ),
              exitsWithCode(ExitCode.success),
            );
            verify(() => logger.info('Aborting.')).called(1);
          });
        });
      });

      group('when --confirm is not passed', () {
        setUp(() {
          when(() => argResults['confirm']).thenReturn(false);
        });

        test('does not prompt for confirmation', () async {
          await expectLater(
            runWithOverrides(
              () => command.logPatchSummary(
                app: appMetadata,
                releaseVersion: releaseVersion,
                patchers: [patcher],
                patchArtifactBundles: {
                  ReleasePlatform.android: patchArtifactBundles,
                },
                minLinkPercentage: minLinkPercentage,
              ),
            ),
            completes,
          );
          verifyNever(
            () => logger.confirm(
              any(),
              defaultValue: any(named: 'defaultValue'),
              hint: any(named: 'hint'),
            ),
          );
        });
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
          exitsWithCode(ExitCode.config),
        );
        verify(
          () => logger.err(any(that: contains('bin/internal/engine.version'))),
        ).called(1);
        verifyNever(() => patcher.buildPatchArtifact());
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
            track: DeploymentTrack.stable,
            sidecars: any(named: 'sidecars'),
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

        test('logs error, fixes, and throws ProcessExit', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithCode(ExitCode.software),
          );
          verify(() => logger.err(exception.message)).called(1);
          verify(() => logger.info('fix it')).called(1);
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

        test('logs error, and throws ProcessExit', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithCode(ExitCode.software),
          );
          verify(
            () => logger.err('Failed to build patch artifacts: $exception'),
          ).called(1);
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
                platformStatuses: const {
                  ReleasePlatform.windows: ReleaseStatus.active,
                },
                createdAt: DateTime(2023),
                updatedAt: DateTime(2023),
              ),
            ],
          );
        });

        test('warns and exits', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithCode(ExitCode.usage),
          );

          verify(
            () => codePushClientWrapper.getReleases(appId: appId),
          ).called(1);
          verify(
            () => logger.warn(
              '''No releases found for app $appId covering ${releasePlatform.displayName}. You must first create a release before you can create a patch.''',
            ),
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
                platformStatuses: const {releasePlatform: ReleaseStatus.active},
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
                platformStatuses: const {releasePlatform: ReleaseStatus.active},
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
          platformStatuses: const {releasePlatform: ReleaseStatus.active},
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
              track: DeploymentTrack.stable,
              sidecars: any(named: 'sidecars'),
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

        test('warns and exits', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithCode(ExitCode.usage),
          );

          verify(
            () => logger.warn(
              '''No releases found for app $appId covering ${releasePlatform.displayName}. You must first create a release before you can create a patch.''',
            ),
          ).called(1);
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
                platformStatuses: const {releasePlatform: ReleaseStatus.active},
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
                platformStatuses: const {
                  ReleasePlatform.macos: ReleaseStatus.active,
                  ReleasePlatform.windows: ReleaseStatus.active,
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

      group('when running on CI', () {
        setUp(() {
          when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);
        });

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
                platformStatuses: const {releasePlatform: ReleaseStatus.active},
                createdAt: DateTime(2023),
                updatedAt: DateTime(2023),
              ),
            );
          });

          test(
            'builds app twice if release flutter version is not default',
            () async {
              final exitCode = await runWithOverrides(command.run);
              expect(exitCode, equals(ExitCode.success.code));

              verifyInOrder([
                () => logger.warn(
                  any(
                    that: startsWith(
                      'The release version to patch was not specified.',
                    ),
                  ),
                ),
                () => patcher.buildPatchArtifact(),
                () => patcher.extractReleaseVersionFromArtifact(any()),
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
                    that: containsPair('inferred_release_version', isTrue),
                  ),
                  patchArtifactBundles: any(named: 'patchArtifactBundles'),
                  track: any(named: 'track'),
                  sidecars: any(named: 'sidecars'),
                ),
              ]);
            },
          );

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

    group('when dry-run is specified', () {
      setUp(() {
        when(() => argResults['dry-run']).thenReturn(true);
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
            track: DeploymentTrack.stable,
            sidecars: any(named: 'sidecars'),
          ),
        );
      });
    });

    group('when --no-confirm is specified', () {
      setUp(() {
        when(() => argResults['confirm']).thenReturn(false);
      });

      test('does not prompt for confirmation', () async {
        await runWithOverrides(command.run);
        verifyNever(
          () => logger.confirm(
            any(),
            defaultValue: any(named: 'defaultValue'),
            hint: any(named: 'hint'),
          ),
        );
      });
    });

    group('when running on CI', () {
      test('does not prompt for confirmation', () async {
        when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);

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
            platformStatuses: const {releasePlatform: ReleaseStatus.draft},
            createdAt: DateTime(2023),
            updatedAt: DateTime(2023),
          ),
        );
      });

      test('logs error and exits with code 70', () async {
        await expectLater(
          () => runWithOverrides(command.run),
          exitsWithCode(ExitCode.software),
        );

        verify(
          () => logger.err('''
Release ${release.version} is in an incomplete state. It's possible that the original release was terminated or failed to complete.
Please re-run the release command for this version or create a new release.'''),
        ).called(1);
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
            platformStatuses: const {ReleasePlatform.ios: ReleaseStatus.active},
            createdAt: DateTime(2023),
            updatedAt: DateTime(2023),
          ),
        );
      });

      test('logs error and exits with code 70', () async {
        await expectLater(
          () => runWithOverrides(command.run),
          exitsWithCode(ExitCode.software),
        );

        verify(
          () => logger.err(
            '''No release exists for android in release version ${release.version}. Please run shorebird release android to create one.''',
          ),
        ).called(1);
      });
    });

    group('when primary release artifact fails to download', () {
      final error = Exception('Failed to download primary release artifact.');

      setUp(() {
        when(
          () => artifactManager.downloadWithProgressUpdates(
            any(),
            message: any(named: 'message'),
          ),
        ).thenThrow(error);
      });

      test('logs error and exits with code 70', () async {
        await expectLater(
          () => runWithOverrides(command.run),
          exitsWithCode(ExitCode.software),
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

        test('exits with code 0', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithCode(ExitCode.success),
          );
        });
      });

      group('when UnpatchableChangeException is thrown', () {
        setUp(() {
          when(
            () => patcher.assertUnpatchableDiffs(
              releaseArtifact: any(named: 'releaseArtifact'),
              releaseArchive: any(named: 'releaseArchive'),
              patchArchive: any(named: 'patchArchive'),
            ),
          ).thenThrow(UnpatchableChangeException());
        });

        test('logs and exits with code 70', () async {
          await expectLater(
            () => runWithOverrides(command.run),
            exitsWithCode(ExitCode.software),
          );

          verify(() => logger.info('Exiting.')).called(1);
        });
      });

      // The two groups above use thenThrow, which raises SYNCHRONOUSLY at call
      // time -- inside the try, where the catch clauses see it. The real
      // Patcher.assertUnpatchableDiffs is async and signals failure by
      // completing its Future with an error, which a `return` without `await`
      // hands to the caller before the try can observe it.
      //
      // So these two groups reproduce the async path the production code
      // actually takes. They FAIL against a bare `return patcher.assert...`
      // and pass against `return await`, which is what makes them a test of the
      // await rather than of the catch clause.
      group('when the failure is an async rejection', () {
        group('and the user cancels', () {
          setUp(() {
            when(
              () => patcher.assertUnpatchableDiffs(
                releaseArtifact: any(named: 'releaseArtifact'),
                releaseArchive: any(named: 'releaseArchive'),
                patchArchive: any(named: 'patchArchive'),
              ),
            ).thenAnswer((_) async => throw UserCancelledException());
          });

          test('exits with code 0', () async {
            await expectLater(
              () => runWithOverrides(command.run),
              exitsWithCode(ExitCode.success),
            );
          });
        });

        group('and the diff is unpatchable', () {
          setUp(() {
            when(
              () => patcher.assertUnpatchableDiffs(
                releaseArtifact: any(named: 'releaseArtifact'),
                releaseArchive: any(named: 'releaseArchive'),
                patchArchive: any(named: 'patchArchive'),
              ),
            ).thenAnswer((_) async => throw UnpatchableChangeException());
          });

          test('logs and exits with code 70', () async {
            await expectLater(
              () => runWithOverrides(command.run),
              exitsWithCode(ExitCode.software),
            );

            verify(() => logger.info('Exiting.')).called(1);
          });
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
            track: DeploymentTrack.staging,
            sidecars: any(named: 'sidecars'),
          ),
        ).called(1);
      });
    });

    group('when no platform argument is provided', () {
      setUp(() {
        when(() => argResults['platforms']).thenReturn(const <String>[]);
      });

      test('fails and log the correct message', () async {
        final exitCode = await runWithOverrides(command.run);

        expect(exitCode, equals(ExitCode.usage.code));

        verify(
          () => logger.err(
            '''No platforms were provided. Use the --platforms argument to provide one or more platforms''',
          ),
        ).called(1);
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
              patchArtifactBundles: any(named: 'patchArtifactBundles'),
              track: any(named: 'track'),
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
              patchArtifactBundles: any(named: 'patchArtifactBundles'),
              track: any(named: 'track'),
              sidecars: any(named: 'sidecars'),
            ),
          );
        });
      });
    });

    group('when patching multiple platforms', () {
      late Patcher iosPatcher;
      late Release multiPlatformRelease;

      /// Matches any call to publishPatch, for verifyNever.
      void verifyNothingPublished() {
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
      }

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
        when(() => iosPatcher.assertArgsAreValid()).thenAnswer((_) async {});
        when(() => iosPatcher.assertPreconditions()).thenAnswer((_) async {});
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
        when(() => iosPatcher.updatedPlatformMetadata(any())).thenAnswer((
          invocation,
        ) async {
          return invocation.positionalArguments.first
              as CreatePatchPlatformMetadata;
        });
        when(() => iosPatcher.updatedEnvironmentMetadata(any())).thenAnswer((
          invocation,
        ) async {
          return invocation.positionalArguments.first
              as BuildEnvironmentMetadata;
        });

        multiPlatformRelease = Release(
          id: 7,
          appId: appId,
          version: releaseVersion,
          flutterRevision: flutterRevision,
          flutterVersion: flutterVersion,
          displayName: '1.2.3+1',
          platformStatuses: const {
            ReleasePlatform.android: ReleaseStatus.active,
            ReleasePlatform.ios: ReleaseStatus.active,
          },
          createdAt: DateTime(2023),
          updatedAt: DateTime(2023),
        );
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
        command = PatchCommand(
          resolvePatcher: (releaseType) =>
              releaseType == ReleaseType.ios ? iosPatcher : patcher,
        )..testArgResults = argResults;
      });

      test('publishes a single patch carrying every platform', () async {
        await runWithOverrides(command.run);

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

      test('asserts all preconditions before building anything', () async {
        await runWithOverrides(command.run);

        verifyInOrder([
          patcher.assertPreconditions,
          iosPatcher.assertPreconditions,
          () => patcher.buildPatchArtifact(
            releaseVersion: any(named: 'releaseVersion'),
          ),
        ]);
      });

      group('when a later platform fails its preconditions', () {
        setUp(() {
          when(
            () => iosPatcher.assertPreconditions(),
          ).thenThrow(ProcessExit(ExitCode.unavailable.code));
        });

        test('builds nothing and publishes nothing', () async {
          await expectLater(
            runWithOverrides(command.run),
            exitsWithCode(ExitCode.unavailable),
          );

          // The whole point of preflighting: patching android+ios from a host
          // that can't build ios must not ship the android half.
          verifyNever(
            () => patcher.buildPatchArtifact(
              releaseVersion: any(named: 'releaseVersion'),
            ),
          );
          verifyNothingPublished();
        });
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
          verifyNothingPublished();
        });
      });

      group('when the release does not cover every platform', () {
        setUp(() {
          when(
            () => codePushClientWrapper.getRelease(
              appId: any(named: 'appId'),
              releaseVersion: any(named: 'releaseVersion'),
            ),
          ).thenAnswer((_) async => release); // android only
        });

        test('errors and publishes nothing', () async {
          await expectLater(
            runWithOverrides(command.run),
            exitsWithCode(ExitCode.software),
          );

          verify(
            () => logger.err(
              any(that: contains('No release exists for ios')),
            ),
          ).called(1);
          verifyNothingPublished();
        });
      });

      group('when --release-version=latest', () {
        setUp(() {
          when(() => argResults['release-version']).thenReturn('latest');
        });

        test('skips releases that do not cover every platform', () async {
          // Newer, but android-only: resolving "latest" per platform would
          // pick this for android and straddle two release versions.
          final androidOnly = Release(
            id: 9,
            appId: appId,
            version: '1.2.4+1',
            flutterRevision: flutterRevision,
            flutterVersion: flutterVersion,
            displayName: '1.2.4+1',
            platformStatuses: const {
              ReleasePlatform.android: ReleaseStatus.active,
            },
            createdAt: DateTime(2024),
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

        test('warns and exits when no release covers every platform', () async {
          when(
            () => codePushClientWrapper.getReleases(appId: any(named: 'appId')),
          ).thenAnswer((_) async => [release]); // android only

          await expectLater(
            runWithOverrides(command.run),
            exitsWithCode(ExitCode.usage),
          );

          verify(
            () => logger.warn(
              '''No releases found for app $appId covering Android and iOS. You must first create a release before you can create a patch.''',
            ),
          ).called(1);
          verifyNothingPublished();
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
}
