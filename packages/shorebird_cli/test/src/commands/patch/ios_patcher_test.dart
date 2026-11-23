// cspell:words chkstk ifaces movz posthog
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:macho/macho.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:platform/platform.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/archive_analysis/apple_archive_differ.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/code_signer.dart';
import 'package:shorebird_cli/src/command_error.dart';
import 'package:shorebird_cli/src/commands/apple_build_helpers.dart';
import 'package:shorebird_cli/src/commands/patch/patch.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/engine_config.dart';
import 'package:shorebird_cli/src/executables/aot_tools.dart';
import 'package:shorebird_cli/src/executables/xcodebuild.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/metadata/metadata.dart';
import 'package:shorebird_cli/src/os/operating_system_interface.dart';
import 'package:shorebird_cli/src/patch_diff_checker.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/route_b.dart';
import 'package:shorebird_cli/src/route_b_binding.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_compiler_cache.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_dependency_changes.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:shorebird_cli/src/route_b_provenance.dart';
import 'package:shorebird_cli/src/route_b_release_kernels.dart';
import 'package:shorebird_cli/src/route_b_survival.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/split_debug_info.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/src/base/process.dart';
import 'package:shorebird_cli/src/validators/validators.dart';
import 'package:shorebird_cli/src/version.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import '../../fakes.dart';
import '../../helpers.dart';
import '../../matchers.dart';
import '../../mocks.dart';
import '../../route_b_profile_fixture.dart';

/// A stand-in path for fallback values mocktail only needs to type-check.
const _nowhere = _NowhereFile();

class _NowhereFile implements File {
  const _NowhereFile();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  useTempWorkingDirectory();
  group(IosPatcher, () {
    late AotTools aotTools;
    late Apple apple;
    late ArgParser argParser;
    late ArgResults argResults;
    late ArtifactBuilder artifactBuilder;
    late ArtifactManager artifactManager;
    late CodePushClientWrapper codePushClientWrapper;
    late CodeSigner codeSigner;
    late Doctor doctor;
    late Directory projectRoot;
    late EngineConfig engineConfig;
    late FlavorValidator flavorValidator;
    late ShorebirdLogger logger;
    late OperatingSystemInterface operatingSystemInterface;
    late PatchDiffChecker patchDiffChecker;
    late Progress progress;
    late RouteBCompilerResolver routeBCompilerResolver;
    late RouteBCoverageAnalyzer routeBCoverageAnalyzer;
    late RouteBProducer routeBProducer;
    late RouteBReleaseKernelBuilder routeBReleaseKernelBuilder;
    late ShorebirdArtifacts shorebirdArtifacts;
    late ShorebirdProcess shorebirdProcess;
    late ShorebirdEnv shorebirdEnv;
    late ShorebirdFlutter shorebirdFlutter;
    late ShorebirdValidator shorebirdValidator;
    late XcodeBuild xcodeBuild;
    late IosPatcher patcher;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          aotToolsRef.overrideWith(() => aotTools),
          appleRef.overrideWith(() => apple),
          artifactBuilderRef.overrideWith(() => artifactBuilder),
          artifactManagerRef.overrideWith(() => artifactManager),
          codePushClientWrapperRef.overrideWith(() => codePushClientWrapper),
          codeSignerRef.overrideWith(() => codeSigner),
          doctorRef.overrideWith(() => doctor),
          engineConfigRef.overrideWith(() => engineConfig),
          loggerRef.overrideWith(() => logger),
          osInterfaceRef.overrideWith(() => operatingSystemInterface),
          patchDiffCheckerRef.overrideWith(() => patchDiffChecker),
          processRef.overrideWith(() => shorebirdProcess),
          routeBCompilerResolverRef.overrideWith(() => routeBCompilerResolver),
          routeBCoverageAnalyzerRef.overrideWith(() => routeBCoverageAnalyzer),
          routeBProducerRef.overrideWith(() => routeBProducer),
          routeBReleaseKernelBuilderRef.overrideWith(
            () => routeBReleaseKernelBuilder,
          ),
          shorebirdArtifactsRef.overrideWith(() => shorebirdArtifacts),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          shorebirdFlutterRef.overrideWith(() => shorebirdFlutter),
          shorebirdValidatorRef.overrideWith(() => shorebirdValidator),
          xcodeBuildRef.overrideWith(() => xcodeBuild),
        },
      );
    }

    setUpAll(() {
      registerFallbackValue(FakeArgResults());
      registerFallbackValue(Directory(''));
      registerFallbackValue(File(''));
      registerFallbackValue(const AppleArchiveDiffer());
      registerFallbackValue(ReleasePlatform.ios);
      registerFallbackValue(ShorebirdArtifact.genSnapshotIos);
      registerFallbackValue(Uri.parse('https://example.com'));
      registerFallbackValue(
        RouteBCoverage.fromJson(
          jsonEncode({
            'analysisVersion': supportedRouteBAnalysisVersion,
            'verdict': 'accept',
            'changed': <String>[],
            'added': <String>[],
            'removed': <String>[],
            'patchable': <String>[],
            'conditional': <String>[],
            'rejections': <Object>[],
            'refusalSummary': null,
          }),
        ),
      );
      registerFallbackValue(
        const RouteBCompiler(
          runtime: _nowhere,
          compilerSnapshot: _nowhere,
          platformDill: _nowhere,
          analyzer: _nowhere,
          frontend: _nowhere,
          interfaceGenerator: _nowhere,
          releaseProbe: _nowhere,
          flutterPlatformDill: _nowhere,
          provenance: '',
        ),
      );
    });

    setUp(() {
      aotTools = MockAotTools();
      apple = MockApple();
      argParser = MockArgParser();
      argResults = MockArgResults();
      artifactBuilder = MockArtifactBuilder();
      artifactManager = MockArtifactManager();
      codePushClientWrapper = MockCodePushClientWrapper();
      codeSigner = MockCodeSigner();
      when(
        () => codeSigner.canonicalPublicKeyPem(any()),
      ).thenAnswer(
        (invocation) => invocation.positionalArguments.single as String,
      );
      doctor = MockDoctor();
      engineConfig = MockEngineConfig();
      flavorValidator = MockFlavorValidator();
      operatingSystemInterface = MockOperatingSystemInterface();
      patchDiffChecker = MockPatchDiffChecker();
      progress = MockProgress();
      projectRoot = Directory.systemTemp.createTempSync();
      routeBCompilerResolver = MockRouteBCompilerResolver();
      routeBCoverageAnalyzer = MockRouteBCoverageAnalyzer();
      routeBProducer = MockRouteBProducer();
      routeBReleaseKernelBuilder = MockRouteBReleaseKernelBuilder();
      logger = MockShorebirdLogger();
      shorebirdArtifacts = MockShorebirdArtifacts();
      shorebirdProcess = MockShorebirdProcess();
      shorebirdEnv = MockShorebirdEnv();
      shorebirdFlutter = MockShorebirdFlutter();
      shorebirdValidator = MockShorebirdValidator();
      xcodeBuild = MockXcodeBuild();

      when(() => argParser.options).thenReturn({});

      when(() => argResults.options).thenReturn([]);
      when(() => argResults.rest).thenReturn([]);
      when(() => argResults.wasParsed(any())).thenReturn(false);

      when(() => logger.progress(any())).thenReturn(progress);

      when(
        () => shorebirdEnv.getShorebirdProjectRoot(),
      ).thenReturn(projectRoot);
      when(
        () => shorebirdEnv.buildDirectory,
      ).thenReturn(Directory(p.join(projectRoot.path, 'build')));
      when(() => shorebirdEnv.iosSupplementDirectory).thenReturn(
        Directory(p.join(projectRoot.path, 'build', 'shorebird', 'ios')),
      );
      when(() => shorebirdEnv.iosPodfileLockHash).thenReturn(null);

      when(aotTools.isLinkDebugInfoSupported).thenAnswer((_) async => false);

      patcher = IosPatcher(
        argParser: argParser,
        argResults: argResults,
        flavor: null,
        target: null,
      );
    });

    group('primaryReleaseArtifactArch', () {
      test('is "xcarchive"', () {
        expect(patcher.primaryReleaseArtifactArch, 'xcarchive');
      });
    });

    group('supplementaryReleaseArtifactArch', () {
      test('is "ios_supplement"', () {
        expect(patcher.supplementaryReleaseArtifactArch, 'ios_supplement');
      });
    });

    group('releaseType', () {
      test('is ReleaseType.ios', () {
        expect(patcher.releaseType, ReleaseType.ios);
      });
    });

    group('minimumFlutterVersion', () {
      test('is minimumPatchableIosFlutterVersion', () {
        expect(
          patcher.minimumFlutterVersion,
          minimumPatchableIosFlutterVersion,
        );
      });
    });

    group('assertPreconditions', () {
      setUp(() {
        when(() => doctor.iosCommandValidators).thenReturn([flavorValidator]);
      });

      group('when validation succeeds', () {
        setUp(() {
          when(
            () => shorebirdValidator.validatePreconditions(
              checkUserIsAuthenticated: any(named: 'checkUserIsAuthenticated'),
              checkShorebirdInitialized: any(
                named: 'checkShorebirdInitialized',
              ),
              validators: any(named: 'validators'),
              supportedOperatingSystems: any(
                named: 'supportedOperatingSystems',
              ),
            ),
          ).thenAnswer((_) async {});
        });

        test('returns normally', () async {
          await expectLater(
            () => runWithOverrides(patcher.assertPreconditions),
            returnsNormally,
          );
        });
      });

      group('when validation fails', () {
        setUp(() {
          final exception = ValidationFailedException();
          when(
            () => shorebirdValidator.validatePreconditions(
              checkUserIsAuthenticated: any(named: 'checkUserIsAuthenticated'),
              checkShorebirdInitialized: any(
                named: 'checkShorebirdInitialized',
              ),
              validators: any(named: 'validators'),
            ),
          ).thenThrow(exception);
        });

        test('exits with code 70', () async {
          final exception = ValidationFailedException();
          when(
            () => shorebirdValidator.validatePreconditions(
              checkUserIsAuthenticated: any(named: 'checkUserIsAuthenticated'),
              checkShorebirdInitialized: any(
                named: 'checkShorebirdInitialized',
              ),
              validators: any(named: 'validators'),
              supportedOperatingSystems: any(
                named: 'supportedOperatingSystems',
              ),
            ),
          ).thenThrow(exception);
          await expectLater(
            () => runWithOverrides(patcher.assertPreconditions),
            exitsWithCode(exception.exitCode),
          );
          verify(
            () => shorebirdValidator.validatePreconditions(
              checkUserIsAuthenticated: true,
              checkShorebirdInitialized: true,
              validators: [flavorValidator],
              supportedOperatingSystems: {NativePlatform.macOS},
            ),
          ).called(1);
        });
      });
    });

    group('assertEngineCanPatch', () {
      late Directory flutterDir;
      late Directory localEngineSrc;

      const declining =
          'InterpretCall ... This $iosPatchesDeclinedMarker, not starting '
          'the Shorebird updater.';

      void writeFile(File file, String contents) => file
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);

      void writeEngine(String? contents) {
        if (contents == null) return;
        writeFile(
          iosReleaseEngineBinary(flutterDirectory: flutterDir),
          contents,
        );
      }

      void writeLocalEngine(String contents) => writeFile(
        iosReleaseEngineBinary(
          flutterDirectory: flutterDir,
          localEngineSrcPath: localEngineSrc.path,
          localEngine: 'ios_release',
        ),
        contents,
      );

      void useLocalEngine() {
        when(() => engineConfig.localEngineSrcPath).thenReturn(
          localEngineSrc.path,
        );
        when(() => engineConfig.localEngine).thenReturn('ios_release');
      }

      Matcher refusal() => throwsA(
        isA<CommandError>()
            .having((e) => e.exitCode, 'exitCode', ExitCode.unavailable.code)
            .having(
              (e) => e.message,
              'message',
              allOf(
                startsWith('This release cannot be patched'),
                contains('never start the updater'),
              ),
            )
            .having(
              (e) => e.hint,
              'hint',
              contains('Create a new release'),
            ),
      );

      setUp(() {
        flutterDir = Directory.systemTemp.createTempSync('engine_check_');
        localEngineSrc = Directory.systemTemp.createTempSync('local_engine_');
        when(() => shorebirdEnv.flutterDirectory).thenReturn(flutterDir);
      });

      tearDown(() {
        flutterDir.deleteSync(recursive: true);
        localEngineSrc.deleteSync(recursive: true);
      });

      test('exits with a clear error when the engine declines iOS patches', () {
        writeEngine(declining);
        expect(() => runWithOverrides(patcher.assertEngineCanPatch), refusal());
      });

      test('proceeds when the engine can run iOS patches', () async {
        writeEngine('...InterpretCall...');
        await expectLater(
          runWithOverrides(patcher.assertEngineCanPatch),
          completes,
        );
      });

      test(
        'proceeds, and says so in detail, when the binary is absent',
        () async {
          writeEngine(null);
          await expectLater(
            runWithOverrides(patcher.assertEngineCanPatch),
            completes,
          );
          verify(
            () => logger.detail(any(that: contains('not found'))),
          ).called(1);
        },
      );

      group('when building with --local-engine', () {
        setUp(useLocalEngine);

        test('refuses a declining local engine, not looking at the cache', () {
          writeEngine('...InterpretCall...');
          writeLocalEngine(declining);
          expect(
            () => runWithOverrides(patcher.assertEngineCanPatch),
            refusal(),
          );
        });

        test('is not refused for a stale declining cached engine', () async {
          writeEngine(declining);
          writeLocalEngine('...InterpretCall...');
          await expectLater(
            runWithOverrides(patcher.assertEngineCanPatch),
            completes,
          );
        });
      });
    });

    group('assertArgsAreValid', () {
      test('returns normally when --export-options-plist is absent', () async {
        await expectLater(
          runWithOverrides(patcher.assertArgsAreValid),
          completes,
        );
      });

      group('when --export-options-plist is provided', () {
        late Directory tempDir;

        setUp(() {
          tempDir = Directory.systemTemp.createTempSync(
            'export_options_patcher_',
          );
        });

        tearDown(() {
          tempDir.deleteSync(recursive: true);
        });

        File writePlist(String body) {
          return File(p.join(tempDir.path, 'ExportOptions.plist'))
            ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
$body
</dict>
</plist>
''');
        }

        test(
          '''logs error and exits with usage when manageAppVersionAndBuildNumber is true''',
          () async {
            final file = writePlist(
              '<key>manageAppVersionAndBuildNumber</key><true/>',
            );
            when(
              () => argResults[CommonArguments.exportOptionsPlistArg.name],
            ).thenReturn(file.path);

            await expectLater(
              () => runWithOverrides(patcher.assertArgsAreValid),
              exitsWithCode(ExitCode.usage),
            );
            verify(
              () => logger.err(
                any(that: contains('manageAppVersionAndBuildNumber')),
              ),
            ).called(1);
          },
        );
      });
    });

    group('assertUnpatchableDiffs', () {
      const podfileLockHash = 'podfile-lock-hash';

      setUp(() {
        when(
          () => shorebirdEnv.iosPodfileLockHash,
        ).thenReturn(podfileLockHash);
      });

      group('when no native changes are detected', () {
        const noChangeDiffStatus = DiffStatus(
          hasAssetChanges: false,
          hasNativeChanges: false,
        );

        setUp(() {
          when(
            () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
              localArchive: any(named: 'localArchive'),
              releaseArchive: any(named: 'releaseArchive'),
              archiveDiffer: any(named: 'archiveDiffer'),
              allowAssetChanges: any(named: 'allowAssetChanges'),
              allowNativeChanges: any(named: 'allowNativeChanges'),
            ),
          ).thenAnswer((_) async => noChangeDiffStatus);
        });

        test(
          'returns diff status without warning when Podfile.lock matches',
          () async {
            const releaseArtifact = ReleaseArtifact(
              id: 0,
              releaseId: 0,
              arch: 'aarch64',
              platform: ReleasePlatform.ios,
              hash: '#',
              size: 42,
              url: 'https://example.com',
              podfileLockHash: podfileLockHash,
              canSideload: true,
            );

            final diffStatus = await runWithOverrides(
              () => patcher.assertUnpatchableDiffs(
                releaseArtifact: releaseArtifact,
                releaseArchive: File(''),
                patchArchive: File(''),
              ),
            );
            expect(diffStatus, equals(noChangeDiffStatus));
            verifyNever(() => logger.warn(any()));
            verifyNever(() => logger.info(any()));
          },
        );

        test(
          'logs informational note and does not fail when Podfile.lock changed '
          'but compiled native binaries are identical',
          () async {
            const releaseArtifact = ReleaseArtifact(
              id: 0,
              releaseId: 0,
              arch: 'aarch64',
              platform: ReleasePlatform.ios,
              hash: '#',
              size: 42,
              url: 'https://example.com',
              podfileLockHash: 'non-matching podfile-lock-hash',
              canSideload: true,
            );

            final diffStatus = await runWithOverrides(
              () => patcher.assertUnpatchableDiffs(
                releaseArtifact: releaseArtifact,
                releaseArchive: File(''),
                patchArchive: File(''),
              ),
            );
            expect(diffStatus, equals(noChangeDiffStatus));
            verify(
              () => logger.info(
                'Your ios/Podfile.lock changed from the release, but all '
                'compiled native binaries are identical.',
              ),
            ).called(1);
            verifyNever(() => logger.warn(any()));
          },
        );
      });

      group('when native changes are detected', () {
        const nativeChangeDiffStatus = DiffStatus(
          hasAssetChanges: false,
          hasNativeChanges: true,
        );

        setUp(() {
          when(
            () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
              localArchive: any(named: 'localArchive'),
              releaseArchive: any(named: 'releaseArchive'),
              archiveDiffer: any(named: 'archiveDiffer'),
              allowAssetChanges: any(named: 'allowAssetChanges'),
              allowNativeChanges: any(named: 'allowNativeChanges'),
            ),
          ).thenAnswer((_) async => nativeChangeDiffStatus);
        });

        test(
          'does not log extra Podfile.lock warning when Podfile.lock matches',
          () async {
            const releaseArtifact = ReleaseArtifact(
              id: 0,
              releaseId: 0,
              arch: 'aarch64',
              platform: ReleasePlatform.ios,
              hash: '#',
              size: 42,
              url: 'https://example.com',
              podfileLockHash: podfileLockHash,
              canSideload: true,
            );

            final diffStatus = await runWithOverrides(
              () => patcher.assertUnpatchableDiffs(
                releaseArtifact: releaseArtifact,
                releaseArchive: File(''),
                patchArchive: File(''),
              ),
            );
            expect(diffStatus, equals(nativeChangeDiffStatus));
            verifyNever(() => logger.warn(any()));
          },
        );

        test(
          'logs Podfile.lock warning when Podfile.lock also differs',
          () async {
            const releaseArtifact = ReleaseArtifact(
              id: 0,
              releaseId: 0,
              arch: 'aarch64',
              platform: ReleasePlatform.ios,
              hash: '#',
              size: 42,
              url: 'https://example.com',
              podfileLockHash: 'non-matching podfile-lock-hash',
              canSideload: true,
            );

            final diffStatus = await runWithOverrides(
              () => patcher.assertUnpatchableDiffs(
                releaseArtifact: releaseArtifact,
                releaseArchive: File(''),
                patchArchive: File(''),
              ),
            );
            expect(diffStatus, equals(nativeChangeDiffStatus));
            verify(
              () => logger.warn(
                '''
Your ios/Podfile.lock is different from the one used to build the release.
This may indicate that the patch contains native changes, which cannot be applied with a patch. Proceeding may result in unexpected behavior or crashes.''',
              ),
            ).called(1);
          },
        );

        test(
          'does not log Podfile.lock warning when release has no '
          'podfileLockHash',
          () async {
            const releaseArtifact = ReleaseArtifact(
              id: 0,
              releaseId: 0,
              arch: 'aarch64',
              platform: ReleasePlatform.ios,
              hash: '#',
              size: 42,
              url: 'https://example.com',
              canSideload: true,
            );

            final diffStatus = await runWithOverrides(
              () => patcher.assertUnpatchableDiffs(
                releaseArtifact: releaseArtifact,
                releaseArchive: File(''),
                patchArchive: File(''),
              ),
            );
            expect(diffStatus, equals(nativeChangeDiffStatus));
            verifyNever(() => logger.warn(any()));
          },
        );
      });

      group('end-to-end with real PatchDiffChecker and synthetic archives', () {
        late Directory tempDir;

        setUp(() {
          tempDir = Directory.systemTemp.createTempSync('ios_patch_diff_e2e_');
          when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);
        });

        tearDown(() {
          tempDir.deleteSync(recursive: true);
        });

        File writeSyntheticArchive(
          String fileName,
          Map<String, List<int>> files,
        ) {
          final archive = Archive();
          for (final entry in files.entries) {
            archive.addFile(
              ArchiveFile(entry.key, entry.value.length, entry.value),
            );
          }
          final file = File(p.join(tempDir.path, fileName))
            ..writeAsBytesSync(ZipEncoder().encode(archive));
          return file;
        }

        Uint8List xmlPlist(String version) => Uint8List.fromList(
          utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
'''),
        );

        R runWithRealPatchDiffChecker<R>(R Function() body) {
          return runWithOverrides(
            () => runScoped(
              body,
              values: {
                patchDiffCheckerRef.overrideWith(PatchDiffChecker.new),
              },
            ),
          );
        }

        test(
          'safe mock: Podfile.lock header bump with LC_UUID and unused '
          '___chkstk_darwin on Runner logs informational note and succeeds',
          () async {
            const runnerPath = 'Products/Applications/Runner.app/Runner';
            const posthogBinPath =
                'Products/Applications/Runner.app/Frameworks/PostHog.framework/PostHog';
            const posthogPlistPath =
                'Products/Applications/Runner.app/Frameworks/PostHog.framework/Info.plist';

            final releaseRunner = MachOBuilder.buildThin(
              uuid: MachOBuilder.defaultUuid,
              textInstructions: [Arm64Encoder.movz(0, 1), Arm64Encoder.ret()],
              symbols: const [MachOSymbolSpec(name: '_main')],
            );
            final patchRunner = MachOBuilder.buildThin(
              uuid: MachOBuilder.alternateUuid,
              textInstructions: [Arm64Encoder.movz(0, 1), Arm64Encoder.ret()],
              symbols: const [
                MachOSymbolSpec(name: '_main'),
                MachOSymbolSpec.undefined('___chkstk_darwin'),
              ],
            );
            final posthogBin = MachOBuilder.buildThin(
              fileType: MachOFileType.dylib,
              textInstructions: [Arm64Encoder.movz(0, 7), Arm64Encoder.ret()],
            );

            final releaseZip = writeSyntheticArchive('release.zip', {
              runnerPath: releaseRunner,
              posthogBinPath: posthogBin,
              posthogPlistPath: xmlPlist('3.71.6'),
            });
            final patchZip = writeSyntheticArchive('patch.zip', {
              runnerPath: patchRunner,
              posthogBinPath: posthogBin,
              posthogPlistPath: xmlPlist('3.71.6'),
            });

            const releaseArtifact = ReleaseArtifact(
              id: 0,
              releaseId: 0,
              arch: 'aarch64',
              platform: ReleasePlatform.ios,
              hash: '#',
              size: 42,
              url: 'https://example.com',
              podfileLockHash: 'cocoapods-1.15.2-hash',
              canSideload: true,
            );

            final status = await runWithRealPatchDiffChecker(
              () => patcher.assertUnpatchableDiffs(
                releaseArtifact: releaseArtifact,
                releaseArchive: releaseZip,
                patchArchive: patchZip,
              ),
            );

            expect(status.hasNativeChanges, isFalse);
            verify(
              () => logger.info(
                'Your ios/Podfile.lock changed from the release, but all '
                'compiled native binaries are identical.',
              ),
            ).called(1);
          },
        );

        test(
          'adversarial mock: unchanged Podfile.lock with local Swift/SPM '
          'instruction change blocks patch and prints symbol diff',
          () async {
            const runnerPath = 'Products/Applications/Runner.app/Runner';

            final releaseRunner = MachOBuilder.buildThin(
              textInstructions: [Arm64Encoder.movz(0, 1), Arm64Encoder.ret()],
              symbols: const [MachOSymbolSpec(name: '_AppDelegate_init')],
              functionStartOffsets: const [0],
            );
            final patchRunner = MachOBuilder.buildThin(
              textInstructions: [Arm64Encoder.movz(0, 2), Arm64Encoder.ret()],
              symbols: const [MachOSymbolSpec(name: '_AppDelegate_init')],
              functionStartOffsets: const [0],
            );

            final releaseZip = writeSyntheticArchive('release_local.zip', {
              runnerPath: releaseRunner,
            });
            final patchZip = writeSyntheticArchive('patch_local.zip', {
              runnerPath: patchRunner,
            });

            const releaseArtifact = ReleaseArtifact(
              id: 0,
              releaseId: 0,
              arch: 'aarch64',
              platform: ReleasePlatform.ios,
              hash: '#',
              size: 42,
              url: 'https://example.com',
              podfileLockHash: podfileLockHash,
              canSideload: true,
            );

            await expectLater(
              () => runWithRealPatchDiffChecker(
                () => patcher.assertUnpatchableDiffs(
                  releaseArtifact: releaseArtifact,
                  releaseArchive: releaseZip,
                  patchArchive: patchZip,
                ),
              ),
              throwsA(
                isA<UnpatchableChangeException>().having(
                  (e) => e.changes,
                  'changes',
                  {UnpatchableChange.native},
                ),
              ),
            );

            verify(
              () => logger.info(any(that: contains('_AppDelegate_init'))),
            ).called(1);
          },
        );

        test(
          'adversarial mock: Podfile.lock and embedded PostHog.framework '
          'selector + Info.plist version change blocks patch and prints '
          'framework version and selector diff',
          () async {
            const posthogBinPath =
                'Products/Applications/Runner.app/Frameworks/PostHog.framework/PostHog';
            const posthogPlistPath =
                'Products/Applications/Runner.app/Frameworks/PostHog.framework/Info.plist';

            final releasePosthog = MachOBuilder.buildThin(
              fileType: MachOFileType.dylib,
              objcSelectors: const ['setupWithConfig:'],
            );
            final patchPosthog = MachOBuilder.buildThin(
              fileType: MachOFileType.dylib,
              objcSelectors: const [
                'setupWithConfig:',
                'captureEvent:properties:',
              ],
            );

            final releaseZip = writeSyntheticArchive('release_pod.zip', {
              posthogBinPath: releasePosthog,
              posthogPlistPath: xmlPlist('3.71.6'),
            });
            final patchZip = writeSyntheticArchive('patch_pod.zip', {
              posthogBinPath: patchPosthog,
              posthogPlistPath: xmlPlist('3.71.7'),
            });

            const releaseArtifact = ReleaseArtifact(
              id: 0,
              releaseId: 0,
              arch: 'aarch64',
              platform: ReleasePlatform.ios,
              hash: '#',
              size: 42,
              url: 'https://example.com',
              podfileLockHash: 'old-podfile-lock-hash',
              canSideload: true,
            );

            await expectLater(
              () => runWithRealPatchDiffChecker(
                () => patcher.assertUnpatchableDiffs(
                  releaseArtifact: releaseArtifact,
                  releaseArchive: releaseZip,
                  patchArchive: patchZip,
                ),
              ),
              throwsA(
                isA<UnpatchableChangeException>().having(
                  (e) => e.changes,
                  'changes',
                  {UnpatchableChange.native},
                ),
              ),
            );

            verify(
              () => logger.info(
                any(
                  that: contains(
                    'Objective-C selector added: captureEvent:properties:',
                  ),
                ),
              ),
            ).called(1);
            verify(
              () => logger.info(
                any(
                  that: allOf(
                    contains('Framework versions differ from the release:'),
                    contains('  PostHog.framework 3.71.6+1 -> 3.71.7+1'),
                  ),
                ),
              ),
            ).called(1);
          },
        );
      });
    });

    group('buildPatchArtifact', () {
      group('when build fails with ProcessException', () {
        const exception = ProcessException('flutter', [
          'build',
          'ipa',
        ], 'Build failed');

        setUp(() {
          when(
            () => artifactBuilder.buildIpa(
              codesign: any(named: 'codesign'),
              args: any(named: 'args'),
              flavor: any(named: 'flavor'),
              target: any(named: 'target'),
            ),
          ).thenThrow(exception);
        });

        test('throws exception', () async {
          await expectLater(
            () => runWithOverrides(patcher.buildPatchArtifact),
            throwsA(exception),
          );
        });
      });

      group('when build fails with ArtifactBuildException', () {
        final exception = ArtifactBuildException('Build failed');
        setUp(() {
          when(
            () => artifactBuilder.buildIpa(
              codesign: any(named: 'codesign'),
              args: any(named: 'args'),
              flavor: any(named: 'flavor'),
              target: any(named: 'target'),
            ),
          ).thenThrow(exception);
        });

        test('throws exception', () async {
          await expectLater(
            () => runWithOverrides(patcher.buildPatchArtifact),
            throwsA(exception),
          );
        });
      });

      group('when elf aot snapshot build fails', () {
        const exception = FileSystemException('error');
        setUp(() {
          when(
            () => artifactBuilder.buildIpa(
              codesign: any(named: 'codesign'),
              args: any(named: 'args'),
              flavor: any(named: 'flavor'),
              target: any(named: 'target'),
            ),
          ).thenAnswer(
            (_) async =>
                AppleBuildResult(kernelFile: File('/path/to/app.dill')),
          );
          when(
            () => artifactBuilder.buildElfAotSnapshot(
              appDillPath: any(named: 'appDillPath'),
              outFilePath: any(named: 'outFilePath'),
              genSnapshotArtifact: any(named: 'genSnapshotArtifact'),
              additionalArgs: any(named: 'additionalArgs'),
            ),
          ).thenThrow(exception);
        });

        test('throws exception', () async {
          await expectLater(
            () => runWithOverrides(patcher.buildPatchArtifact),
            throwsA(exception),
          );
        });
      });

      group('when build succeeds', () {
        late File kernelFile;
        setUp(() {
          kernelFile = File(
            p.join(Directory.systemTemp.createTempSync().path, 'app.dill'),
          )..createSync(recursive: true);
          when(
            () => artifactBuilder.buildIpa(
              codesign: any(named: 'codesign'),
              args: any(named: 'args'),
              flavor: any(named: 'flavor'),
              target: any(named: 'target'),
              base64PublicKey: any(named: 'base64PublicKey'),
              ddMaxBytes: any(named: 'ddMaxBytes'),
            ),
          ).thenAnswer((_) async => AppleBuildResult(kernelFile: kernelFile));
          when(() => artifactManager.getXcarchiveDirectory()).thenReturn(
            Directory(
              p.join(
                projectRoot.path,
                'build',
                'ios',
                'framework',
                'Release',
                'App.xcframework',
              ),
            )..createSync(recursive: true),
          );
          when(
            () => artifactBuilder.buildElfAotSnapshot(
              appDillPath: any(named: 'appDillPath'),
              outFilePath: any(named: 'outFilePath'),
              genSnapshotArtifact: any(named: 'genSnapshotArtifact'),
              additionalArgs: any(named: 'additionalArgs'),
            ),
          ).thenAnswer(
            (invocation) async =>
                File(invocation.namedArguments[#outFilePath] as String)
                  ..createSync(recursive: true),
          );
        });

        group('when --split-debug-info is provided', () {
          final tempDir = Directory.systemTemp.createTempSync();
          final splitDebugInfoPath = p.join(tempDir.path, 'symbols');
          final splitDebugInfoFile = File(
            p.join(splitDebugInfoPath, 'app.ios-arm64.symbols'),
          );
          setUp(() {
            when(
              () =>
                  argResults.wasParsed(CommonArguments.splitDebugInfoArg.name),
            ).thenReturn(true);
            when(
              () => argResults[CommonArguments.splitDebugInfoArg.name],
            ).thenReturn(splitDebugInfoPath);
          });

          test('forwards --split-debug-info to builder', () async {
            try {
              await runWithOverrides(patcher.buildPatchArtifact);
            } on Exception {
              // ignore
            }
            verify(
              () => artifactBuilder.buildElfAotSnapshot(
                appDillPath: any(named: 'appDillPath'),
                outFilePath: any(named: 'outFilePath'),
                genSnapshotArtifact: any(named: 'genSnapshotArtifact'),
                additionalArgs: [
                  '--dwarf-stack-traces',
                  '--resolve-dwarf-paths',
                  '--save-debugging-info=${splitDebugInfoFile.path}',
                  '--strip',
                ],
              ),
            ).called(1);
          });
        });

        group('when the default --split-debug-info is added', () {
          test('saves the patch snapshot symbols there', () async {
            patcher.extraBuildArgs = [
              '--split-debug-info=$defaultSplitDebugInfoPath',
            ];
            try {
              await runWithOverrides(patcher.buildPatchArtifact);
            } on Exception {
              // ignore
            }
            final symbolsPath = p.join(
              p.absolute(defaultSplitDebugInfoPath),
              'app.ios-arm64.symbols',
            );
            verify(
              () => artifactBuilder.buildElfAotSnapshot(
                appDillPath: any(named: 'appDillPath'),
                outFilePath: any(named: 'outFilePath'),
                genSnapshotArtifact: any(named: 'genSnapshotArtifact'),
                additionalArgs: [
                  '--dwarf-stack-traces',
                  '--resolve-dwarf-paths',
                  '--save-debugging-info=$symbolsPath',
                  '--strip',
                ],
              ),
            ).called(1);
          });
        });

        group('when releaseVersion is provided', () {
          test('forwards --build-name and --build-number to builder', () async {
            await runWithOverrides(
              () => patcher.buildPatchArtifact(releaseVersion: '1.2.3+4'),
            );
            verify(
              () => artifactBuilder.buildIpa(
                flavor: any(named: 'flavor'),
                codesign: any(named: 'codesign'),
                target: any(named: 'target'),
                args: any(
                  named: 'args',
                  that: containsAll(['--build-name=1.2.3', '--build-number=4']),
                ),
              ),
            ).called(1);
          });
        });

        group('when platform was specified via arg results rest', () {
          setUp(() {
            when(() => argResults.rest).thenReturn(['ios', '--verbose']);
          });

          test('returns xcarchive zip', () async {
            final artifact = await runWithOverrides(patcher.buildPatchArtifact);
            expect(p.basename(artifact.path), endsWith('.zip'));
            verify(
              () => artifactBuilder.buildIpa(
                codesign: any(named: 'codesign'),
                args: ['--verbose'],
              ),
            ).called(1);
          });
        });

        group('when the key pair is provided', () {
          setUp(() {
            when(
              () => codeSigner.base64PublicKeyFromPem(any()),
            ).thenReturn('public_key_encoded');
          });

          test('calls the buildIpa passing the key', () async {
            when(
              () => argResults.wasParsed(CommonArguments.publicKeyArg.name),
            ).thenReturn(true);

            final key = createTempFile('public.pem')
              ..writeAsStringSync('public_key');

            when(
              () => argResults[CommonArguments.publicKeyArg.name],
            ).thenReturn(key.path);
            when(
              () => argResults[CommonArguments.publicKeyArg.name],
            ).thenReturn(key.path);
            await runWithOverrides(patcher.buildPatchArtifact);

            verify(
              () => artifactBuilder.buildIpa(
                codesign: any(named: 'codesign'),
                args: any(named: 'args'),
                flavor: any(named: 'flavor'),
                target: any(named: 'target'),
                base64PublicKey: 'public_key_encoded',
              ),
            ).called(1);
          });

          test('passes a key from --public-key-cmd to buildIpa', () async {
            when(
              () => argResults[CommonArguments.publicKeyCmd.name],
            ).thenReturn('print-key');
            when(
              () => argResults.wasParsed(CommonArguments.publicKeyCmd.name),
            ).thenReturn(true);
            when(
              () => codeSigner.runPublicKeyCmd('print-key'),
            ).thenAnswer((_) async => 'pem-from-cmd');
            await runWithOverrides(patcher.buildPatchArtifact);

            verify(
              () => codeSigner.base64PublicKeyFromPem('pem-from-cmd'),
            ).called(1);

            verify(
              () => artifactBuilder.buildIpa(
                codesign: any(named: 'codesign'),
                args: any(named: 'args'),
                flavor: any(named: 'flavor'),
                target: any(named: 'target'),
                base64PublicKey: 'public_key_encoded',
              ),
            ).called(1);
          });
        });

        test('returns xcarchive zip', () async {
          final artifact = await runWithOverrides(patcher.buildPatchArtifact);
          expect(p.basename(artifact.path), endsWith('.zip'));
        });

        test('copies app.dill to build directory', () async {
          final copiedKernelFile = File(
            p.join(projectRoot.path, 'build', 'app.dill'),
          );
          expect(copiedKernelFile.existsSync(), isFalse);
          await runWithOverrides(patcher.buildPatchArtifact);
          expect(copiedKernelFile.existsSync(), isTrue);
        });

        group('when extraBuildArgs has obfuscation flags', () {
          late File obfuscationMapFile;

          setUp(() {
            obfuscationMapFile =
                File(
                    p.join(
                      Directory.systemTemp.createTempSync().path,
                      'obfuscation_map.json',
                    ),
                  )
                  ..createSync(recursive: true)
                  ..writeAsStringSync('{"key": "value"}');
          });

          test('includes obfuscation flags in build args', () async {
            final loadMapOption =
                '--load-obfuscation-map=${obfuscationMapFile.path}';
            patcher
              ..obfuscate = true
              ..obfuscationMapPath = obfuscationMapFile.path
              ..extraBuildArgs = [
                '--obfuscate',
                '--extra-gen-snapshot-options=$loadMapOption',
                '--split-debug-info=build/shorebird/symbols',
              ];
            await runWithOverrides(patcher.buildPatchArtifact);

            final captured = verify(
              () => artifactBuilder.buildIpa(
                codesign: any(named: 'codesign'),
                args: captureAny(named: 'args'),
                flavor: any(named: 'flavor'),
                target: any(named: 'target'),
                base64PublicKey: any(named: 'base64PublicKey'),
                ddMaxBytes: any(named: 'ddMaxBytes'),
              ),
            ).captured;

            final args = captured.last as List<String>;
            expect(args, contains('--obfuscate'));
            expect(
              args.any((a) => a.startsWith('--split-debug-info=')),
              isTrue,
            );
            expect(
              args,
              contains(
                '--extra-gen-snapshot-options='
                '--load-obfuscation-map=${obfuscationMapFile.path}',
              ),
            );
          });
        });

        group('when extraBuildArgs is empty', () {
          test('does not inject obfuscation flags', () async {
            await runWithOverrides(patcher.buildPatchArtifact);

            final captured = verify(
              () => artifactBuilder.buildIpa(
                codesign: any(named: 'codesign'),
                args: captureAny(named: 'args'),
                flavor: any(named: 'flavor'),
                target: any(named: 'target'),
                base64PublicKey: any(named: 'base64PublicKey'),
                ddMaxBytes: any(named: 'ddMaxBytes'),
              ),
            ).captured;

            final args = captured.last as List<String>;
            expect(args, isNot(contains('--obfuscate')));
            expect(
              args.any(
                (a) => a.startsWith(
                  '--extra-gen-snapshot-options=--load-obfuscation-map',
                ),
              ),
              isFalse,
            );
          });
        });
      });
    });

    group('createPatchArtifacts', () {
      const postLinkerFlutterRevision = // cspell: disable-next-line
          'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef';
      const appId = 'appId';
      const arch = 'aarch64';
      const releaseId = 1;
      const linkFileName = 'out.vmcode';
      const elfAotSnapshotFileName = 'out.aot';
      const releaseArtifact = ReleaseArtifact(
        id: 0,
        releaseId: releaseId,
        arch: arch,
        platform: ReleasePlatform.ios,
        hash: '#',
        size: 42,
        url: 'https://example.com',
        podfileLockHash: 'podfile-lock-hash',
        canSideload: true,
      );
      late File releaseArtifactFile;
      late Directory supplementDirectory;

      void setUpProjectRootArtifacts() {
        File(
          p.join(projectRoot.path, 'build', elfAotSnapshotFileName),
        ).createSync(recursive: true);
        Directory(
          p.join(
            projectRoot.path,
            'build',
            'ios',
            'framework',
            'Release',
            'App.xcframework',
          ),
        ).createSync(recursive: true);
        File(
          p.join(
            projectRoot.path,
            'build',
            'ios',
            'framework',
            'Release',
            'App.xcframework',
            'Products',
            'Applications',
            'Runner.app',
            'Frameworks',
            'App.framework',
            'App',
          ),
        ).createSync(recursive: true);
        File(
          p.join(projectRoot.path, 'build', 'ios', 'shorebird', 'App.ct.link'),
        ).createSync(recursive: true);
        File(
          p.join(
            projectRoot.path,
            'build',
            'ios',
            'shorebird',
            'App.class_table.json',
          ),
        ).createSync(recursive: true);
        File(
          p.join(projectRoot.path, 'build', linkFileName),
        ).createSync(recursive: true);
      }

      setUp(() {
        releaseArtifactFile = File(
          p.join(
            Directory.systemTemp.createTempSync().path,
            'release.xcarchive',
          ),
        )..createSync(recursive: true);
        supplementDirectory = Directory.systemTemp.createTempSync();

        when(
          () => codePushClientWrapper.getReleaseArtifact(
            appId: any(named: 'appId'),
            releaseId: any(named: 'releaseId'),
            arch: any(named: 'arch'),
            platform: any(named: 'platform'),
          ),
        ).thenAnswer((_) async => releaseArtifact);
        when(() => artifactManager.downloadFile(any())).thenAnswer((_) async {
          final tempDirectory = Directory.systemTemp.createTempSync();
          final file = File(p.join(tempDirectory.path, 'libapp.so'))
            ..createSync();
          return file;
        });
        when(
          () => artifactManager.extractZip(
            zipFile: any(named: 'zipFile'),
            outputDirectory: any(named: 'outputDirectory'),
          ),
        ).thenAnswer((invocation) async {
          final zipFile = invocation.namedArguments[#zipFile] as File;
          final outDir =
              invocation.namedArguments[#outputDirectory] as Directory;
          File(
            p.join(outDir.path, '${p.basename(zipFile.path)}.zip'),
          ).createSync();
        });
        when(() => artifactManager.getXcarchiveDirectory()).thenReturn(
          Directory(
            p.join(
              projectRoot.path,
              'build',
              'ios',
              'framework',
              'Release',
              'App.xcframework',
            ),
          ),
        );
        when(
          () => artifactManager.getIosAppDirectory(
            xcarchiveDirectory: any(named: 'xcarchiveDirectory'),
          ),
        ).thenReturn(projectRoot);
        when(() => engineConfig.localEngine).thenReturn(null);

        // Route B: the patcher asks whether the cached iOS engine carries the
        // interpreter, to decide whether a code patch even makes sense. An
        // empty temp dir has no engine, so the default is "stock engine" —
        // the existing linker behaviour every pre-existing test expects.
        when(
          () => shorebirdEnv.flutterDirectory,
        ).thenReturn(Directory.systemTemp.createTempSync('flutter'));
      });

      // Route B (selfhost). On an engine that can run iOS Dart code push, a
      // code patch is only meaningful against a release built with patchable
      // call sites. This refusal is deliberately DISTINCT from "this patch
      // cannot be represented": the remediation is a new release, not
      // different Dart, and collapsing them sends people to debug the wrong
      // half.
      group('when the engine supports iOS Dart code push', () {
        // Two different engines under the same Flutter revision, which is the
        // situation this fork is actually in: fifteen engine hashes are
        // published under `c15ef637`, so nothing about the release's Flutter
        // revision distinguishes them.
        const releaseEngineRevision =
            'aaaaaaaa1111aaaaaaaa2222aaaaaaaa3333aaaa';
        const ambientEngineRevision =
            'bbbbbbbb1111bbbbbbbb2222bbbbbbbb3333bbbb';

        late Directory flutterDir;
        late Directory supplementDirectory;

        void writeReleaseProvenance({
          required String engineRevision,
          bool withKernel = true,
          bool corruptKernel = false,
          String? capabilityManifest,
          RouteBBuildConfig? buildConfig,
          // P5.1: a release with NO comparable configuration is now refused, so
          // a fixture that expects to get further has to record one. Defaulted
          // to the empty-but-known configuration, which is what a build with no
          // defines actually has -- and `omitBuildConfig` expresses the other
          // case, which is a release whose evidence is missing.
          bool omitBuildConfig = false,
          // Explicitly nullable, and defaulted to the current revision, so a
          // test can express "recorded none" as well as "recorded another".
          int? compatibilityRevision = routeBCompatibilityRevision,
          String? appPackageName = 'app',
          // The release's dynamic interface and snapshot profile. The profile's
          // recorded digest is its real one unless [profileDigest] says
          // otherwise; [omitProfileDigest] records none.
          String? interfaceYaml,
          String? snapshotProfile,
          String? profileDigest,
          bool omitProfileDigest = false,
        }) {
          final artifacts = <String, String>{};
          if (interfaceYaml != null) {
            final file = File(
              p.join(supplementDirectory.path, routeBInterfaceFileName),
            )..writeAsStringSync(interfaceYaml);
            artifacts[routeBInterfaceFileName] = sha256
                .convert(file.readAsBytesSync())
                .toString();
          }
          if (snapshotProfile != null) {
            final file = File(
              p.join(supplementDirectory.path, routeBSnapshotProfileFileName),
            )..writeAsStringSync(snapshotProfile);
            if (!omitProfileDigest) {
              artifacts[routeBSnapshotProfileFileName] =
                  profileDigest ??
                  sha256.convert(file.readAsBytesSync()).toString();
            }
          }
          if (capabilityManifest != null) {
            final manifest = File(
              p.join(
                supplementDirectory.path,
                routeBCapabilityManifestFileName,
              ),
            )..writeAsStringSync(capabilityManifest);
            artifacts[routeBCapabilityManifestFileName] = sha256
                .convert(manifest.readAsBytesSync())
                .toString();
          }
          if (withKernel) {
            for (final name in [
              routeBReleaseKernelFileName,
              routeBReleaseImportKernelFileName,
            ]) {
              final kernel = File(p.join(supplementDirectory.path, name))
                ..writeAsStringSync('KERNEL-$name');
              artifacts[name] = sha256
                  .convert(kernel.readAsBytesSync())
                  .toString();
            }
            if (corruptKernel) {
              // The bytes the release recorded and the bytes it uploaded are
              // different claims; the supplement is a second network call and
              // can genuinely arrive truncated.
              File(
                p.join(
                  supplementDirectory.path,
                  routeBReleaseKernelFileName,
                ),
              ).writeAsStringSync('TRUNCATED');
            }
          }
          writeRouteBReleaseProvenance(
            supplementDirectory,
            RouteBReleaseProvenance(
              engineRevision: engineRevision,
              flutterRevision: 'cccccccc1111cccccccc2222cccccccc3333cccc',
              patchableCallSites: 4000,
              patchableCallSitesPerMiB: 1788,
              artifacts: artifacts,
              buildConfig: omitBuildConfig
                  ? null
                  : buildConfig ?? RouteBBuildConfig.fromBuildArgs(const []),
              // P4.4: a release with no contract revision is refused before
              // anything else, so every fixture that expects to get FURTHER
              // than that has to record one.
              compatibilityRevision: compatibilityRevision,
              appPackageName: appPackageName,
            ),
          );
        }

        /// A minimal Mach-O carrying an LC_UUID and [sites] patchable call
        /// pairs, so both the patchability scan and the build-ID read work on
        /// the same bytes they do in production.
        void writeReleaseAppBinary({required int sites}) {
          const headerWords = 6; // 24-byte LC_UUID after a 32-byte header
          final words = Uint32List(1024 * 32)
            ..fillRange(0, 1024 * 32, 0xD503201F);
          final header = ByteData.sublistView(words)
            ..setUint32(0, 0xfeedfacf, Endian.little)
            ..setUint32(16, 1, Endian.little) // ncmds
            ..setUint32(32, 0x1b, Endian.little) // LC_UUID
            ..setUint32(36, 24, Endian.little); // cmdsize
          for (var i = 0; i < 16; i++) {
            header.setUint8(40 + i, i + 1);
          }
          for (var i = 0; i < sites; i++) {
            final at = (headerWords + 8) + i * 4;
            words[at] = 0xF840701E; // ldur lr, [r0, #7]
            words[at + 1] = 0xD63F03C0; // blr lr
          }
          File(
              p.join(projectRoot.path, 'Frameworks', 'App.framework', 'App'),
            )
            ..createSync(recursive: true)
            ..writeAsBytesSync(words.buffer.asUint8List());
        }

        setUp(() {
          flutterDir = Directory.systemTemp.createTempSync('flutter');
          File(
              p.join(
                flutterDir.path,
                'bin',
                'cache',
                'artifacts',
                'engine',
                'ios-release',
                'Flutter.xcframework',
                'ios-arm64',
                'Flutter.framework',
                'Flutter',
              ),
            )
            ..createSync(recursive: true)
            ..writeAsStringSync('...InterpretCall...');
          when(() => shorebirdEnv.flutterDirectory).thenReturn(flutterDir);
          // The app and the Flutter SDK's own packages only, so the
          // dependency check has nothing to analyze unless a test adds one.
          writePackageConfig(projectRoot, {
            'app': '../',
            'flutter': p
                .toUri(p.join(flutterDir.path, 'packages', 'flutter'))
                .toString(),
            'sky_engine': p
                .toUri(p.join(flutterDir.path, 'bin', 'cache', 'pkg'))
                .toString(),
          });

          supplementDirectory = Directory.systemTemp.createTempSync(
            'supplement',
          );
          when(
            () => shorebirdEnv.shorebirdEngineRevision,
          ).thenReturn(releaseEngineRevision);
          when(
            () => routeBReleaseKernelBuilder.agreesWith(
              compiler: any(named: 'compiler'),
              importKernel: any(named: 'importKernel'),
              aotKernel: any(named: 'aotKernel'),
            ),
          ).thenReturn(true);
          when(
            () => routeBCoverageAnalyzer.analyze(
              compiler: any(named: 'compiler'),
              baseDill: any(named: 'baseDill'),
              patchedDill: any(named: 'patchedDill'),
              includePrefixes: any(named: 'includePrefixes'),
            ),
          ).thenReturn(
            RouteBCoverage.fromJson(
              jsonEncode({
                'analysisVersion': supportedRouteBAnalysisVersion,
                'verdict': 'accept',
                'changed': ['package:app/main.dart#routeBValue'],
                'added': <String>[],
                'removed': <String>[],
                'patchable': ['package:app/main.dart#routeBValue'],
                'conditional': <String>[],
                'rejections': <Object>[],
                'refusalSummary': null,
              }),
            ),
          );
          // The SAME differ every other platform uses. Route B passes it a
          // one-byte synthetic base, which was verified byte-for-byte against
          // the reference route_b_artifact tool.
          when(
            () => artifactManager.createDiff(
              releaseArtifactPath: any(named: 'releaseArtifactPath'),
              patchArtifactPath: any(named: 'patchArtifactPath'),
            ),
          ).thenAnswer((_) async {
            final diff = File(p.join(projectRoot.path, 'route_b.artifact'))
              ..createSync(recursive: true)
              ..writeAsBytesSync(List<int>.filled(64, 7));
            return diff.path;
          });
          // Stands in for compile+pack; the real bytes are gated by
          // host_equivalence.sh against the reference packer.
          when(
            () => routeBProducer.produce(
              compiler: any(named: 'compiler'),
              coverage: any(named: 'coverage'),
              releaseImportKernel: any(named: 'releaseImportKernel'),
              releaseBuildId: any(named: 'releaseBuildId'),
              workingDirectory: any(named: 'workingDirectory'),
              projectRoot: any(named: 'projectRoot'),
              capabilities: any(named: 'capabilities'),
              buildConfig: any(named: 'buildConfig'),
              survival: any(named: 'survival'),
              releaseEvidence: any(named: 'releaseEvidence'),
            ),
          ).thenAnswer(
            (invocation) => Uint8List.fromList(
              utf8.encode(
                'SBRBPTCH-for-${invocation.namedArguments[#releaseBuildId]}',
              ),
            ),
          );
          // The patch build's own kernel, which coverage diffs against the
          // release's.
          File(p.join(projectRoot.path, 'build', 'app.dill'))
            ..createSync(recursive: true)
            ..writeAsStringSync('PATCH-KERNEL');
          when(
            () => routeBCompilerResolver.resolve(
              engineRevision: any(named: 'engineRevision'),
            ),
          ).thenAnswer(
            (_) async => RouteBCompiler(
              runtime: File(p.join(flutterDir.path, 'dartaotruntime')),
              compilerSnapshot: File(
                p.join(flutterDir.path, 'dart2bytecode.aot'),
              ),
              platformDill: File(p.join(flutterDir.path, 'vm_platform.dill')),
              analyzer: File(p.join(flutterDir.path, 'route_b_analyze.aot')),
              frontend: File(
                p.join(flutterDir.path, 'route_b_gen_kernel.aot'),
              ),
              interfaceGenerator: File(
                p.join(flutterDir.path, 'route_b_gen_dynamic_interface.aot'),
              ),
              releaseProbe: File(
                p.join(flutterDir.path, 'route_b_release_probe.aot'),
              ),
              flutterPlatformDill: File(
                p.join(flutterDir.path, 'flutter_platform_strong.dill'),
              ),
              provenance: 'engine revision  : $releaseEngineRevision',
            ),
          );
        });

        group('when the release was not built with patchable calls', () {
          setUp(() => writeReleaseAppBinary(sites: 2));

          test('refuses, naming the release as the thing to fix', () async {
            await expectLater(
              () => runWithOverrides(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: releaseId,
                  releaseArtifact: releaseArtifactFile,
                ),
              ),
              exitsWithCode(ExitCode.software),
            );

            verify(
              () => logger.err(
                any(
                  that: allOf(
                    contains('was not built with Route B patchable call sites'),
                    contains('Create a new release'),
                  ),
                ),
              ),
            ).called(1);
          });
        });

        group('when the release IS patchable', () {
          setUp(() => writeReleaseAppBinary(sites: 4000));

          test(
            'refuses a release that does not record its engine',
            () async {
              // A release cut before provenance existed is
              // RELEASE-INCOMPATIBLE, not "tooling unavailable": there is no
              // way to learn which of the engines published under this Flutter
              // revision built it, and guessing from the environment is the
              // failure the record exists to prevent.
              await expectLater(
                () => runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                  ),
                ),
                exitsWithCode(ExitCode.software),
              );

              verifyNever(
                () => routeBCompilerResolver.resolve(
                  engineRevision: any(named: 'engineRevision'),
                ),
              );
              verify(
                () => logger.err(
                  any(
                    that: allOf(
                      contains('does not record which engine built it'),
                      contains('Nothing was uploaded'),
                    ),
                  ),
                ),
              ).called(1);
            },
          );

          group('when the release records a FLAVOR', () {
            // G4.2. `--flavor` never reaches the configuration comparison
            // through the build args: `forwardedArgs` carries only
            // `--dart-define=` and `--enable-experiment=`, and the CLI passes
            // flavor to `buildIpa` as a separate parameter. So the patch side
            // synthesized no FLUTTER_APP_FLAVOR at all, and the arm that got
            // refused was the MATCHING one.
            //
            // Flutter reduces `--flavor foo` to exactly one compiler fact, the
            // FLUTTER_APP_FLAVOR define, which is why the release side records
            // it in `effectiveDefines` rather than as a second fingerprint
            // field.
            RouteBBuildConfig flavored(String? flavor) => RouteBBuildConfig(
              rawArgs: [if (flavor != null) '--flavor=$flavor'],
              effectiveDefines: {
                'FLUTTER_APP_FLAVOR': ?flavor,
              },
            );

            /// A patcher invoked with `--flavor $flavor`, which the shared
            /// `patcher` cannot express: it is built with `flavor: null`.
            IosPatcher patcherWithFlavor(String? flavor) => IosPatcher(
              argParser: argParser,
              argResults: argResults,
              flavor: flavor,
              target: null,
            );

            Future<void> runPatch(IosPatcher subject) async {
              try {
                await runWithOverrides(
                  () => subject.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                );
              } on Object {
                // Only the configuration check is under test here. Whether the
                // stages after it complete is the subject of other tests, and
                // failing there must not read as a flavor result.
              }
            }

            setUp(() {
              writeReleaseProvenance(
                engineRevision: releaseEngineRevision,
                buildConfig: flavored('foo'),
              );
              when(() => shorebirdEnv.getPubspecYaml()).thenReturn(null);
            });

            test('accepts a patch built with the SAME flavor', () async {
              // The regression test for the fix. Before it, this case was
              // refused, reporting FLUTTER_APP_FLAVOR "absent in this patch"
              // for a patch whose program had the identical flavor.
              await runPatch(patcherWithFlavor('foo'));

              verifyNever(
                () => logger.err(
                  any(
                    that: contains(
                      RouteBBuildSemanticsProblem.mismatch.wire,
                    ),
                  ),
                ),
              );
              verify(
                () => logger.detail(
                  any(
                    that: contains('build configuration matches the release'),
                  ),
                ),
              ).called(1);
            });

            test('refuses a patch built with a DIFFERENT flavor', () async {
              await expectLater(
                () => runWithOverrides(
                  () => patcherWithFlavor('bar').createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                ),
                exitsWithCode(ExitCode.usage),
              );

              verify(
                () => logger.err(
                  any(
                    that: allOf(
                      contains(RouteBBuildSemanticsProblem.mismatch.wire),
                      contains(
                        'FLUTTER_APP_FLAVOR: "foo" in the release, '
                        '"bar" in this patch',
                      ),
                    ),
                  ),
                ),
              ).called(1);
            });

            test('refuses an UNFLAVORED patch of a flavored release', () async {
              await expectLater(
                () => runWithOverrides(
                  () => patcherWithFlavor(null).createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                ),
                exitsWithCode(ExitCode.usage),
              );

              verify(
                () => logger.err(
                  any(
                    that: contains(
                      'FLUTTER_APP_FLAVOR: "foo" in the release, '
                      'absent in this patch',
                    ),
                  ),
                ),
              ).called(1);
            });

            test(
              'accepts a patch flavored ONLY by pubspec default-flavor',
              () async {
                // The path with no command-line token to notice: a release can
                // be flavored entirely by `default-flavor`, and reading the
                // flag alone would record "no flavor" for it.
                final pubspec = MockPubspec();
                when(
                  () => pubspec.flutter,
                ).thenReturn({'default-flavor': 'foo'});
                when(() => shorebirdEnv.getPubspecYaml()).thenReturn(pubspec);

                await runPatch(patcherWithFlavor(null));

                verifyNever(
                  () => logger.err(
                    any(
                      that: contains(
                        RouteBBuildSemanticsProblem.mismatch.wire,
                      ),
                    ),
                  ),
                );
                verify(
                  () => logger.detail(
                    any(
                      that: contains('build configuration matches the release'),
                    ),
                  ),
                ).called(1);
              },
            );
          });

          group('when the release records its engine', () {
            setUp(() {
              writeReleaseProvenance(engineRevision: releaseEngineRevision);
              // Most fixtures use an old analysis version; the gate itself is
              // tested below with the flag off.
              when(
                () => argResults['allow-unchecked-sdk-calls'],
              ).thenReturn(true);
            });

            Future<void> patchAnalyzedWithPackage(String? name) async {
              final pubspec = MockPubspec();
              when(() => pubspec.name).thenReturn(name ?? '');
              when(() => pubspec.flutter).thenReturn(null);
              when(
                () => shorebirdEnv.getPubspecYaml(),
              ).thenReturn(name == null ? null : pubspec);
              await runWithOverrides(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: releaseId,
                  releaseArtifact: releaseArtifactFile,
                  supplementDirectory: supplementDirectory,
                ),
              );
            }

            test('runs the analyzer with the release time --include '
                'prefix, from the name the release recorded', () async {
              // w16: without it the analyzer reads every non-dart: library as
              // the app and refuses a patch that touches no framework member.
              // The pubspec has since been renamed; the release's name wins.
              await patchAnalyzedWithPackage('renamed');
              verify(
                () => routeBCoverageAnalyzer.analyze(
                  compiler: any(named: 'compiler'),
                  baseDill: any(named: 'baseDill'),
                  patchedDill: any(named: 'patchedDill'),
                  includePrefixes: ['package:app/'],
                ),
              ).called(1);
            });

            test(
              'a release that recorded no name uses the pubspec name',
              () async {
                writeReleaseProvenance(
                  engineRevision: releaseEngineRevision,
                  appPackageName: null,
                );
                writePackageConfig(projectRoot, {'fromPubspec': '../'});
                // The shared fixture's member is in package:app, which this
                // app is not; its dependency pass sees no change.
                when(
                  () => routeBCoverageAnalyzer.analyze(
                    compiler: any(named: 'compiler'),
                    baseDill: any(named: 'baseDill'),
                    patchedDill: any(named: 'patchedDill'),
                    includePrefixes: routeBDependencyIncludePrefixes,
                  ),
                ).thenReturn(
                  RouteBCoverage.fromJson(
                    jsonEncode({
                      'analysisVersion': supportedRouteBAnalysisVersion,
                      'verdict': 'inert',
                      'changed': <String>[],
                      'added': <String>[],
                      'removed': <String>[],
                      'patchable': <String>[],
                      'conditional': <String>[],
                      'rejections': <Object>[],
                      'refusalSummary': null,
                    }),
                  ),
                );
                await patchAnalyzedWithPackage('fromPubspec');
                verify(
                  () => routeBCoverageAnalyzer.analyze(
                    compiler: any(named: 'compiler'),
                    baseDill: any(named: 'baseDill'),
                    patchedDill: any(named: 'patchedDill'),
                    includePrefixes: ['package:fromPubspec/'],
                  ),
                ).called(1);
              },
            );

            test('refuses, rather than treating every library as the app, '
                'when no package name is known', () async {
              writeReleaseProvenance(
                engineRevision: releaseEngineRevision,
                appPackageName: null,
              );
              await expectLater(
                patchAnalyzedWithPackage(null),
                throwsA(isA<ProcessExit>()),
              );
              verify(
                () => logger.err(any(that: contains('package name'))),
              ).called(1);
              verifyNever(
                () => routeBCoverageAnalyzer.analyze(
                  compiler: any(named: 'compiler'),
                  baseDill: any(named: 'baseDill'),
                  patchedDill: any(named: 'patchedDill'),
                  includePrefixes: any(named: 'includePrefixes'),
                ),
              );
            });

            test('refuses an empty pubspec name the same way', () async {
              writeReleaseProvenance(
                engineRevision: releaseEngineRevision,
                appPackageName: null,
              );
              final pubspec = MockPubspec();
              when(() => pubspec.name).thenReturn('');
              when(() => pubspec.flutter).thenReturn(null);
              when(() => shorebirdEnv.getPubspecYaml()).thenReturn(pubspec);
              await expectLater(
                runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                ),
                throwsA(isA<ProcessExit>()),
              );
              verify(
                () => logger.err(any(that: contains('package name'))),
              ).called(1);
              verifyNever(
                () => routeBCoverageAnalyzer.analyze(
                  compiler: any(named: 'compiler'),
                  baseDill: any(named: 'baseDill'),
                  patchedDill: any(named: 'patchedDill'),
                  includePrefixes: any(named: 'includePrefixes'),
                ),
              );
            });

            group('a change outside the app package', () {
              // The a6a48cf6 device run: an edit to `tally`, a path package
              // next to the app, was left out of a published patch without a
              // word, because the analysis saw `package:<app>/` only.
              const depPrefixes = routeBDependencyIncludePrefixes;

              RouteBCoverage dependencyCoverage({
                List<String> changed = const [],
                List<String> removed = const [],
                List<Map<String, Object>> rejections = const [],
                String? verdict,
                int analysisVersion = routeBDeclarationsAnalysisVersion,
              }) => RouteBCoverage.fromJson(
                jsonEncode({
                  'analysisVersion': analysisVersion,
                  'verdict':
                      verdict ?? (rejections.isEmpty ? 'accept' : 'reject'),
                  'changed': changed,
                  'added': <String>[],
                  'removed': removed,
                  'patchable': changed,
                  'conditional': <String>[],
                  'rejections': rejections,
                  'refusalSummary': null,
                }),
              );

              void stubDependencyAnalysis(RouteBCoverage coverage) {
                when(
                  () => routeBCoverageAnalyzer.analyze(
                    compiler: any(named: 'compiler'),
                    baseDill: any(named: 'baseDill'),
                    patchedDill: any(named: 'patchedDill'),
                    includePrefixes: depPrefixes,
                  ),
                ).thenReturn(coverage);
              }

              void stubAppAnalysis(RouteBCoverage coverage) {
                when(
                  () => routeBCoverageAnalyzer.analyze(
                    compiler: any(named: 'compiler'),
                    baseDill: any(named: 'baseDill'),
                    patchedDill: any(named: 'patchedDill'),
                    includePrefixes: ['package:app/'],
                  ),
                ).thenReturn(coverage);
              }

              String pubCache(String path) => p
                  .toUri(p.join(projectRoot.parent.path, '.pub-cache', path))
                  .toString();

              setUp(() {
                writePackageConfig(projectRoot, {
                  'app': '../',
                  'tally': '../../packages/tally',
                  'collection': pubCache('hosted/pub.dev/collection-1.19.1'),
                  'forked': pubCache('git/forked-0123abcd'),
                  'flutter_gen': 'flutter_gen',
                  'flutter': p
                      .toUri(p.join(flutterDir.path, 'packages', 'flutter'))
                      .toString(),
                });
              });

              Future<void> patch() => runWithOverrides(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: releaseId,
                  releaseArtifact: releaseArtifactFile,
                  supplementDirectory: supplementDirectory,
                ),
              );

              Future<String> refusal() async {
                await expectLater(patch(), throwsA(isA<ProcessExit>()));
                return verify(
                      () => logger.err(captureAny()),
                    ).captured.single
                    as String;
              }

              test('refuses a changed dependency member, naming it', () async {
                stubDependencyAnalysis(
                  dependencyCoverage(
                    changed: ['package:tally/tally.dart#tallyLabel'],
                  ),
                );
                await expectLater(patch(), throwsA(isA<ProcessExit>()));
                verify(
                  () => logger.err(
                    any(
                      that: allOf(
                        contains('package:tally/tally.dart#tallyLabel'),
                        contains('outside the app'),
                        contains('Nothing was uploaded.'),
                      ),
                    ),
                  ),
                ).called(1);
                verifyNever(
                  () => routeBProducer.produce(
                    compiler: any(named: 'compiler'),
                    coverage: any(named: 'coverage'),
                    releaseImportKernel: any(named: 'releaseImportKernel'),
                    releaseBuildId: any(named: 'releaseBuildId'),
                    workingDirectory: any(named: 'workingDirectory'),
                    projectRoot: any(named: 'projectRoot'),
                    capabilities: any(named: 'capabilities'),
                    buildConfig: any(named: 'buildConfig'),
                    survival: any(named: 'survival'),
                    releaseEvidence: any(named: 'releaseEvidence'),
                  ),
                );
              });

              test('refuses a changed dependency declaration', () async {
                stubDependencyAnalysis(
                  dependencyCoverage(
                    rejections: [
                      {
                        'target': 'package:tally/tally.dart#kPrefix',
                        'category': 'declaration',
                        'reason': 'a const changed',
                      },
                    ],
                  ),
                );
                await expectLater(patch(), throwsA(isA<ProcessExit>()));
                verify(
                  () => logger.err(
                    any(that: contains('package:tally/tally.dart#kPrefix')),
                  ),
                ).called(1);
              });

              test('analyzes every other package, and not the app or the '
                  'Flutter SDK, and passes when none changed', () async {
                stubDependencyAnalysis(dependencyCoverage());
                await patch();
                verify(
                  () => routeBCoverageAnalyzer.analyze(
                    compiler: any(named: 'compiler'),
                    baseDill: any(named: 'baseDill'),
                    patchedDill: any(named: 'patchedDill'),
                    includePrefixes: depPrefixes,
                  ),
                ).called(1);
                verify(
                  () => routeBCoverageAnalyzer.analyze(
                    compiler: any(named: 'compiler'),
                    baseDill: any(named: 'baseDill'),
                    patchedDill: any(named: 'patchedDill'),
                    includePrefixes: ['package:app/'],
                  ),
                ).called(1);
              });

              test('refuses a removed dependency member: a deleted override '
                  "would leave the release's running", () async {
                stubDependencyAnalysis(
                  dependencyCoverage(
                    removed: ['package:tally/tally.dart#Counter.toString'],
                  ),
                );
                final message = await refusal();
                expect(
                  message,
                  allOf(
                    contains('tally (path package at '),
                    contains('packages/tally'),
                    contains('removed'),
                    contains('package:tally/tally.dart#Counter.toString'),
                    contains('ship them in a new release'),
                  ),
                );
              });

              test('refuses a rejected new dependency member', () async {
                stubDependencyAnalysis(
                  dependencyCoverage(
                    rejections: [
                      {
                        'target': 'package:tally/tally.dart#Counter.==',
                        'category': 'added',
                        'reason': 'a new override',
                      },
                    ],
                  ),
                );
                expect(
                  await refusal(),
                  contains('added       package:tally/tally.dart#Counter.=='),
                );
              });

              test('refuses a package the release had and this build does '
                  'not', () async {
                stubDependencyAnalysis(
                  dependencyCoverage(
                    removed: ['package:old_name/old_name.dart#greet'],
                  ),
                );
                expect(
                  await refusal(),
                  allOf(
                    contains(
                      "old_name (in the release, not in this build's "
                      'dependencies)',
                    ),
                    contains('(removed, or renamed) needs a new release'),
                  ),
                );
              });

              test('names a hosted package with its version, and '
                  'pubspec.lock', () async {
                stubDependencyAnalysis(
                  dependencyCoverage(
                    changed: ['package:collection/src/functions.dart#groupBy'],
                  ),
                );
                expect(
                  await refusal(),
                  allOf(
                    contains('collection (hosted, 1.19.1 in this build)'),
                    contains("restore the release's pubspec.lock"),
                  ),
                );
              });

              test('names a git dependency', () async {
                stubDependencyAnalysis(
                  dependencyCoverage(changed: ['package:forked/a.dart#f']),
                );
                expect(
                  await refusal(),
                  allOf(
                    contains('forked (git dependency at '),
                    contains('git'),
                  ),
                );
              });

              test(
                'names flutter_gen as localizations from .arb files',
                () async {
                  stubDependencyAnalysis(
                    dependencyCoverage(
                      changed: [
                        'package:flutter_gen/gen_l10n/l10n_en.dart#L.get:title',
                      ],
                    ),
                  );
                  expect(
                    await refusal(),
                    allOf(
                      contains(
                        'flutter_gen (localizations generated from your .arb '
                        'files)',
                      ),
                      contains('an .arb change needs a new release'),
                    ),
                  );
                },
              );

              test('lists the first 20, then how many more', () async {
                stubDependencyAnalysis(
                  dependencyCoverage(
                    changed: [
                      for (var i = 0; i < 25; i++)
                        'package:tally/tally.dart#f${i.toString().padLeft(2, '0')}',
                    ],
                  ),
                );
                final message = await refusal();
                expect(message, contains('package:tally/tally.dart#f19'));
                expect(
                  message,
                  isNot(contains('package:tally/tally.dart#f20')),
                );
                expect(message, contains('... and 5 more'));
              });

              test('ignores the app and the Flutter SDK', () async {
                stubDependencyAnalysis(
                  dependencyCoverage(
                    changed: [
                      'package:app/main.dart#routeBValue',
                      'package:flutter/src/painting/box.dart#Box.get:hashCode',
                      'dart:core#print',
                    ],
                  ),
                );
                await patch();
                verifyNever(
                  () => logger.err(any(that: contains('outside the app'))),
                );
              });

              test(
                'a dependency-only edit is named, not called inert',
                () async {
                  stubAppAnalysis(dependencyCoverage(verdict: 'inert'));
                  stubDependencyAnalysis(
                    dependencyCoverage(
                      changed: ['package:tally/tally.dart#tallyLabel'],
                    ),
                  );
                  expect(
                    await refusal(),
                    contains('package:tally/tally.dart#tallyLabel'),
                  );
                },
              );

              test('runs after a rejected app verdict, not before', () async {
                stubAppAnalysis(
                  dependencyCoverage(
                    changed: ['package:app/main.dart#routeBValue'],
                    rejections: [
                      {
                        'target': 'package:app/main.dart#kValue',
                        'category': 'declaration',
                        'reason': 'a const changed',
                      },
                    ],
                  ),
                );
                await expectLater(patch(), throwsA(isA<ProcessExit>()));
                verifyNever(
                  () => routeBCoverageAnalyzer.analyze(
                    compiler: any(named: 'compiler'),
                    baseDill: any(named: 'baseDill'),
                    patchedDill: any(named: 'patchedDill'),
                    includePrefixes: depPrefixes,
                  ),
                );
              });

              test(
                'runs after the analysis-version gate, not before',
                () async {
                  when(
                    () => argResults['allow-unchecked-sdk-calls'],
                  ).thenReturn(false);
                  stubAppAnalysis(
                    RouteBCoverage.fromJson(
                      jsonEncode({
                        'analysisVersion': 18,
                        'verdict': 'accept',
                        'changed': ['package:app/main.dart#routeBValue'],
                        'carried': <String>[],
                        'callers': <String, Object>{},
                        'added': <String>[],
                        'helpers': <String>[],
                        'unusedHelpers': <String>[],
                        'removed': <String>[],
                        'patchable': ['package:app/main.dart#routeBValue'],
                        'conditional': <String>[],
                        'sources': <String, Object?>{},
                        'externalReferences': {
                          'package:app/main.dart#routeBValue': <Object>[],
                        },
                        'rejections': <Object>[],
                        'refusalSummary': null,
                      }),
                    ),
                  );
                  await expectLater(patch(), throwsA(isA<ProcessExit>()));
                  verify(
                    () => logger.err(
                      any(
                        that: contains('predates the extension/dynamic-call'),
                      ),
                    ),
                  ).called(1);
                  verifyNever(
                    () => routeBCoverageAnalyzer.analyze(
                      compiler: any(named: 'compiler'),
                      baseDill: any(named: 'baseDill'),
                      patchedDill: any(named: 'patchedDill'),
                      includePrefixes: depPrefixes,
                    ),
                  );
                },
              );

              test('refuses below analysis 14, which cannot see a changed '
                  'dependency const, when there are dependencies', () async {
                stubDependencyAnalysis(
                  dependencyCoverage(
                    analysisVersion: routeBDeclarationsAnalysisVersion - 1,
                  ),
                );
                final message = await refusal();
                expect(
                  message,
                  allOf(
                    contains('cannot check its dependencies'),
                    contains('predates analysis version 14 (it has 13)'),
                    contains(
                      'Packages it cannot check: collection, flutter_gen, '
                      'forked, tally',
                    ),
                    contains('Nothing was uploaded.'),
                  ),
                );
                verifyNever(
                  () => routeBProducer.produce(
                    compiler: any(named: 'compiler'),
                    coverage: any(named: 'coverage'),
                    releaseImportKernel: any(named: 'releaseImportKernel'),
                    releaseBuildId: any(named: 'releaseBuildId'),
                    workingDirectory: any(named: 'workingDirectory'),
                    projectRoot: any(named: 'projectRoot'),
                    capabilities: any(named: 'capabilities'),
                    buildConfig: any(named: 'buildConfig'),
                    survival: any(named: 'survival'),
                    releaseEvidence: any(named: 'releaseEvidence'),
                  ),
                );
              });

              test('below analysis 14, an app with no dependencies outside '
                  'the Flutter SDK still patches', () async {
                writePackageConfig(projectRoot, {
                  'app': '../',
                  'flutter': p
                      .toUri(p.join(flutterDir.path, 'packages', 'flutter'))
                      .toString(),
                });
                stubDependencyAnalysis(
                  dependencyCoverage(
                    analysisVersion: routeBDeclarationsAnalysisVersion - 1,
                  ),
                );
                await patch();
                verifyNever(
                  () => logger.err(any(that: contains('cannot check'))),
                );
              });

              test('refuses, rather than skipping the check, without a '
                  'package config', () async {
                File(
                  p.join(projectRoot.path, '.dart_tool', 'package_config.json'),
                ).deleteSync();
                await expectLater(patch(), throwsA(isA<ProcessExit>()));
                verify(
                  () => logger.err(any(that: contains('flutter pub get'))),
                ).called(1);
              });

              test('refuses when the dependency analysis fails', () async {
                when(
                  () => routeBCoverageAnalyzer.analyze(
                    compiler: any(named: 'compiler'),
                    baseDill: any(named: 'baseDill'),
                    patchedDill: any(named: 'patchedDill'),
                    includePrefixes: depPrefixes,
                  ),
                ).thenThrow(
                  RouteBCompilerException(
                    RouteBCompilerProblem.invalid,
                    'analyzer died',
                  ),
                );
                await expectLater(patch(), throwsA(isA<ProcessExit>()));
                verify(() => logger.err('analyzer died')).called(1);
              });
            });

            group('the extension/dynamic-call gate (analysis 19)', () {
              void coverageAt(int version) {
                final coverage = RouteBCoverage.fromJson(
                  jsonEncode({
                    'analysisVersion': version,
                    'verdict': 'accept',
                    'changed': ['package:app/main.dart#routeBValue'],
                    'carried': <String>[],
                    'callers': <String, Object>{},
                    'added': <String>[],
                    'helpers': <String>[],
                    'unusedHelpers': <String>[],
                    'removed': <String>[],
                    'patchable': ['package:app/main.dart#routeBValue'],
                    'conditional': <String>[],
                    'sources': <String, Object?>{},
                    'externalReferences': {
                      'package:app/main.dart#routeBValue': <Object>[],
                    },
                    'rejections': <Object>[],
                    'refusalSummary': null,
                  }),
                );
                when(
                  () => routeBCoverageAnalyzer.analyze(
                    compiler: any(named: 'compiler'),
                    baseDill: any(named: 'baseDill'),
                    patchedDill: any(named: 'patchedDill'),
                    includePrefixes: any(named: 'includePrefixes'),
                  ),
                ).thenReturn(coverage);
              }

              Future<void> patch() => runWithOverrides(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: releaseId,
                  releaseArtifact: releaseArtifactFile,
                  supplementDirectory: supplementDirectory,
                ),
              );

              test('analysis 18 is refused without the flag', () async {
                when(
                  () => argResults['allow-unchecked-sdk-calls'],
                ).thenReturn(false);
                coverageAt(18);
                await expectLater(patch(), throwsA(isA<ProcessExit>()));
                verify(
                  () => logger.err(
                    any(
                      that: allOf(
                        contains('predates the extension/dynamic-call check'),
                        contains('Update to a cell with analysis 19+'),
                        contains('--allow-unchecked-sdk-calls'),
                      ),
                    ),
                  ),
                ).called(1);
                expect(
                  patcher.usedUncheckedSdkCalls,
                  isFalse,
                );
              });

              test('analysis 18 with the flag warns and records it', () async {
                coverageAt(18);
                // The retention check after the gate has no interface to read
                // here and refuses; only the gate's own effects are under test.
                await patch().then<void>((_) {}, onError: (Object _) {});
                verify(
                  () => logger.warn(
                    any(that: contains('--allow-unchecked-sdk-calls')),
                  ),
                ).called(1);
                final metadata = await patcher.updatedPlatformMetadata(
                  CreatePatchPlatformMetadata.forTest(),
                );
                expect(metadata.allowUncheckedSdkCalls, isTrue);
                expect(
                  metadata.toJson()['allow_unchecked_sdk_calls'],
                  isTrue,
                );
              });

              test('analysis 19 needs no flag and records nothing', () async {
                when(
                  () => argResults['allow-unchecked-sdk-calls'],
                ).thenReturn(false);
                coverageAt(routeBSelectorCallsAnalysisVersion);
                await patch().then<void>((_) {}, onError: (Object _) {});
                verifyNever(
                  () => logger.err(any(that: contains('cannot be checked'))),
                );
                final metadata = await patcher.updatedPlatformMetadata(
                  CreatePatchPlatformMetadata.forTest(),
                );
                expect(metadata.allowUncheckedSdkCalls, isNull);
                expect(
                  metadata.toJson().containsKey('allow_unchecked_sdk_calls'),
                  isFalse,
                );
              });
            });

            group('the await gate (analysis 24)', () {
              const interfaceYaml = """
callable:
  - library: 'package:app/main.dart'
""";

              void coverageAt(
                int version, {
                List<Map<String, Object?>> refs = const [],
                bool noKeys = false,
                bool reject = false,
              }) {
                final coverage = RouteBCoverage.fromJson(
                  jsonEncode({
                    'analysisVersion': version,
                    'verdict': reject ? 'reject' : 'accept',
                    'changed': ['package:app/main.dart#routeBValue'],
                    'carried': <String>[],
                    'callers': <String, Object>{},
                    'added': <String>[],
                    'helpers': <String>[],
                    'unusedHelpers': <String>[],
                    'removed': <String>[],
                    'patchable': ['package:app/main.dart#routeBValue'],
                    'conditional': <String>[],
                    'sources': <String, Object?>{},
                    'externalReferences': {
                      if (!noKeys) 'package:app/main.dart#routeBValue': refs,
                    },
                    'rejections': reject
                        ? [
                            {
                              'target': 'package:app/main.dart#kValue',
                              'category': 'declaration',
                              'reason': 'a const changed',
                            },
                          ]
                        : <Object>[],
                    'refusalSummary': null,
                  }),
                );
                when(
                  () => routeBCoverageAnalyzer.analyze(
                    compiler: any(named: 'compiler'),
                    baseDill: any(named: 'baseDill'),
                    patchedDill: any(named: 'patchedDill'),
                    includePrefixes: any(named: 'includePrefixes'),
                  ),
                ).thenReturn(coverage);
              }

              // A release that allocates a TickerFuture; [tickerThen] says
              // whether it compiled that class's `then`.
              String profile({
                required bool tickerThen,
                bool ticker = true,
                bool futureThen = true,
              }) => routeBProfile({
                'Object': const RouteBProfileClass(
                  'Object',
                  routeBCoreLibrary,
                  fns: {'==': '[Optimized] =='},
                ),
                'Future': const RouteBProfileClass(
                  'Future',
                  'dart:async',
                  parent: 'Object',
                ),
                '_Future': RouteBProfileClass(
                  '_Future',
                  'dart:async',
                  parent: 'Object',
                  ifaces: const ['Future'],
                  fns: {if (futureThen) 'then': '[Optimized] then'},
                ),
                if (ticker)
                  'TickerFuture': RouteBProfileClass(
                    'TickerFuture',
                    'package:flutter/src/scheduler/ticker.dart',
                    parent: 'Object',
                    ifaces: const ['Future'],
                    allocated: true,
                    fns: {if (tickerThen) 'then': '[Optimized] then'},
                  ),
              });

              void release({
                String? snapshotProfile,
                bool flag = false,
                bool withInterface = true,
              }) {
                when(
                  () => argResults['allow-unchecked-sdk-calls'],
                ).thenReturn(flag);
                writeReleaseProvenance(
                  engineRevision: releaseEngineRevision,
                  interfaceYaml: withInterface ? interfaceYaml : null,
                  snapshotProfile: snapshotProfile,
                );
              }

              Future<void> patchAndSwallow() => runWithOverrides(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: releaseId,
                  releaseArtifact: releaseArtifactFile,
                  supplementDirectory: supplementDirectory,
                ),
              ).then<void>((_) {}, onError: (Object _) {});

              final errors = <String>[];
              List<String> awaitErrors() =>
                  errors.where((m) => m.contains('`await` check')).toList();
              setUp(() {
                errors.clear();
                when(() => logger.err(any())).thenAnswer((invocation) {
                  errors.add(invocation.positionalArguments.first as String);
                });
              });

              test('refuses at 23 when the release has a Future with no '
                  'compiled then', () async {
                release(snapshotProfile: profile(tickerThen: false));
                coverageAt(23);
                await expectLater(
                  runWithOverrides(
                    () => patcher.createPatchArtifacts(
                      appId: appId,
                      releaseId: releaseId,
                      releaseArtifact: releaseArtifactFile,
                      supplementDirectory: supplementDirectory,
                    ),
                  ),
                  throwsA(isA<ProcessExit>()),
                );
                expect(
                  awaitErrors().single,
                  allOf(
                    contains('analysis version 23, needs 24 or later'),
                    contains('TickerFuture'),
                    contains('upgrading the CLI does not help'),
                    contains('--allow-unchecked-sdk-calls'),
                    contains('Nothing was uploaded.'),
                  ),
                );
                expect(patcher.usedUncheckedSdkCalls, isFalse);
              });

              test('passes at 24 with the same release', () async {
                release(snapshotProfile: profile(tickerThen: false));
                coverageAt(routeBAwaitAnalysisVersion);
                await patchAndSwallow();
                expect(awaitErrors(), isEmpty);
              });

              test('passes at 23 when every Future has a then', () async {
                release(snapshotProfile: profile(tickerThen: true));
                coverageAt(23);
                await patchAndSwallow();
                expect(awaitErrors(), isEmpty);
              });

              test('passes at 23 with no Future subtype but _Future, even if '
                  '_Future has no then', () async {
                release(
                  snapshotProfile: profile(
                    tickerThen: false,
                    ticker: false,
                    futureThen: false,
                  ),
                );
                coverageAt(23);
                await patchAndSwallow();
                expect(awaitErrors(), isEmpty);
              });

              test('the flag skips it and records the choice', () async {
                release(
                  snapshotProfile: profile(tickerThen: false),
                  flag: true,
                );
                coverageAt(23);
                await patchAndSwallow();
                expect(awaitErrors(), isEmpty);
                verify(
                  () => logger.warn(any(that: contains('the `await` check'))),
                ).called(1);
                final metadata = await patcher.updatedPlatformMetadata(
                  CreatePatchPlatformMetadata.forTest(),
                );
                expect(metadata.allowUncheckedSdkCalls, isTrue);
              });

              test('refuses at 23 when the release has no readable '
                  'interface', () async {
                release(
                  snapshotProfile: profile(tickerThen: true),
                  withInterface: false,
                );
                // No carried member names anything, so retention is not asked.
                coverageAt(23, noKeys: true);
                await patchAndSwallow();
                expect(
                  awaitErrors().single,
                  contains('no readable $routeBInterfaceFileName'),
                );
              });

              test('with no readable interface, the flag lets it by', () async {
                release(
                  snapshotProfile: profile(tickerThen: true),
                  withInterface: false,
                  flag: true,
                );
                coverageAt(23, noKeys: true);
                await patchAndSwallow();
                expect(awaitErrors(), isEmpty);
              });

              test('runs before the reject verdict is reported', () async {
                release(snapshotProfile: profile(tickerThen: false));
                coverageAt(23, reject: true);
                await patchAndSwallow();
                expect(awaitErrors(), hasLength(1));
                expect(errors, hasLength(1));
              });

              test('runs after the retention check, not before', () async {
                release(snapshotProfile: profile(tickerThen: false));
                coverageAt(
                  23,
                  refs: const [
                    {
                      'kind': 'class',
                      'library': 'package:other/other.dart',
                      'class': 'Unkept',
                      'member': null,
                      'private': false,
                    },
                  ],
                );
                await patchAndSwallow();
                expect(awaitErrors(), isEmpty);
                expect(
                  errors.single,
                  contains('uses code the release never used'),
                );
              });
            });

            group('the per-release SDK-member check', () {
              // `String.split` is on the device list; whether THIS release
              // kept it is the snapshot profile's say.
              const ref = {
                'kind': 'instance',
                'library': 'dart:core',
                'class': 'String',
                'member': 'split',
                'private': false,
              };
              const interfaceYaml = """
callable:
  - library: 'package:app/main.dart'
""";

              void coverageCalling(List<Map<String, Object?>> refs) {
                final coverage = RouteBCoverage.fromJson(
                  jsonEncode({
                    'analysisVersion': routeBSelectorCallsAnalysisVersion,
                    'verdict': 'accept',
                    'changed': ['package:app/main.dart#routeBValue'],
                    'carried': <String>[],
                    'callers': <String, Object>{},
                    'added': <String>[],
                    'helpers': <String>[],
                    'unusedHelpers': <String>[],
                    'removed': <String>[],
                    'patchable': ['package:app/main.dart#routeBValue'],
                    'conditional': <String>[],
                    'sources': <String, Object?>{},
                    'externalReferences': {
                      'package:app/main.dart#routeBValue': refs,
                    },
                    'rejections': <Object>[],
                    'refusalSummary': null,
                  }),
                );
                when(
                  () => routeBCoverageAnalyzer.analyze(
                    compiler: any(named: 'compiler'),
                    baseDill: any(named: 'baseDill'),
                    patchedDill: any(named: 'patchedDill'),
                    includePrefixes: any(named: 'includePrefixes'),
                  ),
                ).thenReturn(coverage);
              }

              // A profile whose String classes have `split` (or not).
              String profile({
                required bool hasSplit,
                Map<String, RouteBProfileClass> more = const {},
              }) => routeBProfile({
                ...more,
                'Object': const RouteBProfileClass(
                  'Object',
                  routeBCoreLibrary,
                  fns: {'==': '[Optimized] =='},
                ),
                'String': const RouteBProfileClass(
                  'String',
                  routeBCoreLibrary,
                  parent: 'Object',
                ),
                '_StringBase': RouteBProfileClass(
                  '_StringBase@0150898',
                  routeBCoreLibrary,
                  parent: 'Object',
                  ifaces: const ['String'],
                  fns: {
                    '_a': '[Optimized] _a',
                    if (hasSplit) 'split': '[Optimized] split',
                  },
                ),
                '_OneByteString': const RouteBProfileClass(
                  '_OneByteString@0150898',
                  routeBCoreLibrary,
                  parent: '_StringBase',
                  fns: {'_b': '[Optimized] _b'},
                ),
                '_TwoByteString': const RouteBProfileClass(
                  '_TwoByteString@0150898',
                  routeBCoreLibrary,
                  parent: '_StringBase',
                  fns: {'_c': '[Optimized] _c'},
                ),
              });

              void release({
                String? snapshotProfile,
                String? profileDigest,
                bool omitProfileDigest = false,
                bool flag = false,
                List<Map<String, Object?>> refs = const [ref],
              }) {
                when(
                  () => argResults['allow-unchecked-sdk-calls'],
                ).thenReturn(flag);
                writeReleaseProvenance(
                  engineRevision: releaseEngineRevision,
                  interfaceYaml: interfaceYaml,
                  snapshotProfile: snapshotProfile,
                  profileDigest: profileDigest,
                  omitProfileDigest: omitProfileDigest,
                );
                coverageCalling(refs);
              }

              Future<void> patchAndSwallow() => runWithOverrides(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: releaseId,
                  releaseArtifact: releaseArtifactFile,
                  supplementDirectory: supplementDirectory,
                ),
              ).then<void>((_) {}, onError: (Object _) {});

              /// What the patcher told the developer about SDK members.
              final errors = <String>[];
              List<String> sdkErrors() =>
                  errors.where((m) => m.contains('split')).toList();
              setUp(() {
                errors.clear();
                when(() => logger.err(any())).thenAnswer((invocation) {
                  errors.add(invocation.positionalArguments.first as String);
                });
              });

              test('a profile that hashes to its recorded digest and has the '
                  'member lets the patch through', () async {
                release(snapshotProfile: profile(hasSplit: true));
                await patchAndSwallow();
                expect(sdkErrors(), isEmpty);
              });

              test('refuses when the profile lacks the member, so the '
                  'profile reached the check', () async {
                release(snapshotProfile: profile(hasSplit: false));
                await patchAndSwallow();
                expect(
                  sdkErrors().single,
                  allOf(
                    contains('has no `split` on `_OneByteString`'),
                    contains('--allow-unchecked-sdk-calls'),
                  ),
                );
              });

              test('refuses when the release uploaded no profile', () async {
                release();
                await patchAndSwallow();
                expect(
                  sdkErrors().single,
                  allOf(
                    contains('route_b_snapshot_profile.json'),
                    contains('cannot be checked'),
                  ),
                );
              });

              test('refuses a profile that is not the one the release '
                  'recorded', () async {
                release(
                  snapshotProfile: profile(hasSplit: true),
                  profileDigest: 'ab' * 32,
                );
                await patchAndSwallow();
                expect(
                  errors.single,
                  contains(
                    'route_b_snapshot_profile.json does not match the hash',
                  ),
                );
              });

              test(
                'refuses when the release recorded no digest for it',
                () async {
                  release(
                    snapshotProfile: profile(hasSplit: true),
                    omitProfileDigest: true,
                  );
                  await patchAndSwallow();
                  expect(sdkErrors().single, contains('cannot be checked'));
                },
              );

              test('--allow-unchecked-sdk-calls skips the SDK-member check '
                  'against the profile, and does not unlock a member off the '
                  'list', () async {
                const offList = {
                  'kind': 'instance',
                  'library': 'dart:core',
                  'class': 'String',
                  'member': 'notAMeasuredMember',
                  'private': false,
                };
                release(
                  snapshotProfile: profile(hasSplit: false),
                  flag: true,
                  refs: [ref, offList],
                );
                await patchAndSwallow();
                expect(sdkErrors(), isEmpty);
                expect(
                  errors.where((m) => m.contains('notAMeasuredMember')),
                  isNotEmpty,
                );
                final metadata = await patcher.updatedPlatformMetadata(
                  CreatePatchPlatformMetadata.forTest(),
                );
                expect(metadata.allowUncheckedSdkCalls, isTrue);
              });

              group('an extension getter the release called itself', () {
                // No interface lists an `Ext|get#x`; only the profile can show
                // the release kept it, so the flag must not drop the profile.
                const stars = 'Stars|get#stars';
                const starsRef = {
                  'kind': 'top-level',
                  'library': 'package:app/main.dart',
                  'class': null,
                  'member': stars,
                  'private': false,
                };
                List<String> starsErrors() =>
                    errors.where((m) => m.contains(stars)).toList();
                String profileWithStars() => profile(
                  hasSplit: false,
                  more: {
                    'top': const RouteBProfileClass(
                      '::',
                      'package:app/main.dart',
                      fns: {stars: '[Optimized] $stars'},
                    ),
                  },
                );

                test('is kept under --allow-unchecked-sdk-calls', () async {
                  release(
                    snapshotProfile: profileWithStars(),
                    flag: true,
                    refs: [ref, starsRef],
                  );
                  await patchAndSwallow();
                  expect(starsErrors(), isEmpty);
                  expect(sdkErrors(), isEmpty);
                });

                test('is kept without the flag', () async {
                  release(
                    snapshotProfile: profileWithStars(),
                    refs: [starsRef],
                  );
                  await patchAndSwallow();
                  expect(starsErrors(), isEmpty);
                });

                test('is still refused under --allow-unchecked-sdk-calls when '
                    'the release uploaded no profile, and says why', () async {
                  release(flag: true, refs: [starsRef]);
                  await patchAndSwallow();
                  expect(
                    starsErrors().single,
                    allOf(
                      contains('the extension member `$stars`'),
                      contains('uploaded no route_b_snapshot_profile'),
                      contains('cannot be checked'),
                    ),
                  );
                });

                test('a profile that is not the one the release recorded '
                    "(another release's) is refused under "
                    '--allow-unchecked-sdk-calls before anything is '
                    'checked', () async {
                  // The release's provenance check refuses the mismatched
                  // artifact itself, so the profile never vouches for it.
                  release(
                    snapshotProfile: profileWithStars(),
                    profileDigest: 'ab' * 32,
                    flag: true,
                    refs: [starsRef],
                  );
                  await patchAndSwallow();
                  expect(
                    errors.single,
                    contains(
                      'route_b_snapshot_profile.json does not match the hash',
                    ),
                  );
                });

                test('is still refused under --allow-unchecked-sdk-calls when '
                    'the profile is unreadable', () async {
                  release(
                    snapshotProfile: 'not a profile',
                    flag: true,
                    refs: [starsRef],
                  );
                  await patchAndSwallow();
                  expect(
                    starsErrors().single,
                    allOf(
                      contains('the extension member `$stars`'),
                      contains('is unreadable'),
                    ),
                  );
                });

                test('is still refused under --allow-unchecked-sdk-calls when '
                    'the profile has only a lazy-compile stub', () async {
                  release(
                    snapshotProfile: profile(
                      hasSplit: false,
                      more: {
                        'top': const RouteBProfileClass(
                          '::',
                          'package:app/main.dart',
                          fns: {stars: '[Stub] CompileFunction'},
                        ),
                      },
                    ),
                    flag: true,
                    refs: [starsRef],
                  );
                  await patchAndSwallow();
                  expect(
                    starsErrors().single,
                    contains('the extension member `$stars`'),
                  );
                });

                test('a private one is still refused under '
                    '--allow-unchecked-sdk-calls', () async {
                  const private = '_Stars|get#stars';
                  release(
                    snapshotProfile: profile(
                      hasSplit: false,
                      more: {
                        'top': const RouteBProfileClass(
                          '::',
                          'package:app/main.dart',
                          fns: {private: '[Optimized] $private'},
                        ),
                      },
                    ),
                    flag: true,
                    refs: [
                      {...starsRef, 'member': private, 'private': true},
                    ],
                  );
                  await patchAndSwallow();
                  expect(
                    errors.where((m) => m.contains(private)).single,
                    contains('the extension member `$private`'),
                  );
                });
              });

              test('under --allow-unchecked-sdk-calls a readable profile '
                  'that lacks a bare dart:core class still refuses it (the '
                  'loader aborts on a missing class)', () async {
                const numRef = {
                  'kind': 'class',
                  'library': 'dart:core',
                  'class': 'num',
                  'member': null,
                  'private': false,
                };
                // `profile` holds Object and String in dart:core, not num.
                release(
                  snapshotProfile: profile(hasSplit: true),
                  flag: true,
                  refs: [numRef],
                );
                await patchAndSwallow();
                expect(
                  errors.where((m) => m.contains('`num`')),
                  isNotEmpty,
                );
              });
            });

            test(
              'resolves the compiler for the RELEASE engine, not the '
              'environment',
              () async {
                // The whole point. This machine is set up with a DIFFERENT
                // engine, and fifteen engine hashes share one Flutter
                // revision, so an environment-relative lookup would validate a
                // cell whose every hash matched and whose lineage was wrong.
                when(
                  () => shorebirdEnv.shorebirdEngineRevision,
                ).thenReturn(ambientEngineRevision);

                await runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                );

                verify(
                  () => routeBCompilerResolver.resolve(
                    engineRevision: releaseEngineRevision,
                  ),
                ).called(1);
                verifyNever(
                  () => routeBCompilerResolver.resolve(
                    engineRevision: ambientEngineRevision,
                  ),
                );
                // AND IT NO LONGER WARNS. The mismatch used to print a warning
                // here on the argument that the failure had not been shown; it
                // was demonstrated on device on 2026-08-12 (release ee001fd7,
                // frontend 69f9831c: patch published, `code patch: 1`, app
                // running the release's code), so it is now refused in
                // patch_command before anything is built or uploaded.
                //
                // Asserted as an absence because a warning printed beside a
                // refusal reads as though the mismatch were a matter of degree
                // — and because reaching this code at all means the refusal did
                // not fire, which is what the patch_command tests cover.
                verifyNever(
                  () => logger.warn(
                    any(
                      that: allOf(
                        contains(releaseEngineRevision),
                        contains(ambientEngineRevision),
                      ),
                    ),
                  ),
                );
              },
            );

            test('refuses a release that uploaded no kernel', () async {
              // Coverage diffs the patch against the release's OWN kernel.
              // Without it there is nothing to compare, and regenerating one
              // from source at patch time would answer a different question.
              writeReleaseProvenance(
                engineRevision: releaseEngineRevision,
                withKernel: false,
              );

              await expectLater(
                () => runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                ),
                exitsWithCode(ExitCode.software),
              );

              verifyNever(
                () => routeBCompilerResolver.resolve(
                  engineRevision: any(named: 'engineRevision'),
                ),
              );
              verify(
                () => logger.err(
                  any(
                    that: contains(
                      'did not upload the kernel it was compiled from',
                    ),
                  ),
                ),
              ).called(1);
            });

            test('refuses a kernel that does not match its hash', () async {
              writeReleaseProvenance(
                engineRevision: releaseEngineRevision,
                corruptKernel: true,
              );

              await expectLater(
                () => runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                ),
                exitsWithCode(ExitCode.software),
              );

              verify(
                () => logger.err(
                  any(
                    that: allOf(
                      contains('do not match what it recorded'),
                      contains(routeBReleaseKernelFileName),
                    ),
                  ),
                ),
              ).called(1);
            });

            test('refuses a release whose provenance is unreadable', () async {
              File(
                p.join(supplementDirectory.path, 'route_b.json'),
              ).writeAsStringSync('{not json');

              await expectLater(
                () => runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                ),
                exitsWithCode(ExitCode.software),
              );

              verifyNever(
                () => routeBCompilerResolver.resolve(
                  engineRevision: any(named: 'engineRevision'),
                ),
              );
              verify(
                () => logger.err(
                  any(that: contains('provenance could not be read')),
                ),
              ).called(1);
            });

            test(
              'reports an unpublished cell as tooling unavailable',
              () async {
                when(
                  () => routeBCompilerResolver.resolve(
                    engineRevision: any(named: 'engineRevision'),
                  ),
                ).thenThrow(
                  RouteBCompilerException(
                    RouteBCompilerProblem.unavailable,
                    'has not been published for engine x',
                  ),
                );

                await expectLater(
                  () => runWithOverrides(
                    () => patcher.createPatchArtifacts(
                      appId: appId,
                      releaseId: releaseId,
                      releaseArtifact: releaseArtifactFile,
                      supplementDirectory: supplementDirectory,
                    ),
                  ),
                  exitsWithCode(ExitCode.software),
                );

                verify(
                  () => logger.err(
                    any(that: contains('has not been published for engine x')),
                  ),
                ).called(1);
              },
            );

            test('reports a corrupt cell as tooling invalid', () async {
              when(
                () => routeBCompilerResolver.resolve(
                  engineRevision: any(named: 'engineRevision'),
                ),
              ).thenThrow(
                RouteBCompilerException(
                  RouteBCompilerProblem.invalid,
                  'failed validation: the bundle is missing dartaotruntime',
                ),
              );

              await expectLater(
                () => runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                ),
                exitsWithCode(ExitCode.software),
              );

              verify(
                () => logger.err(
                  any(
                    that: contains(
                      'the bundle is missing dartaotruntime',
                    ),
                  ),
                ),
              ).called(1);
            });

            test('reports an unreachable host as a download failure', () async {
              // Neither "unavailable" nor "invalid": an unreachable host says
              // nothing about the cell, and filing it under either would send
              // someone to republish tooling that is fine.
              when(
                () => routeBCompilerResolver.resolve(
                  engineRevision: any(named: 'engineRevision'),
                ),
              ).thenThrow(
                RouteBCompilerDownloadException('Could not reach https://x'),
              );

              await expectLater(
                () => runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                ),
                exitsWithCode(ExitCode.software),
              );

              verify(
                () => logger.err(
                  any(that: contains('Could not reach https://x')),
                ),
              ).called(1);
            });

            test('refuses when the release kernels disagree', () async {
              // Two files that exist and hash correctly are not the same claim
              // as two lowerings of one program. The producer must never
              // compile against an import kernel describing something else.
              when(
                () => routeBReleaseKernelBuilder.agreesWith(
                  compiler: any(named: 'compiler'),
                  importKernel: any(named: 'importKernel'),
                  aotKernel: any(named: 'aotKernel'),
                ),
              ).thenReturn(false);

              await expectLater(
                () => runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                ),
                exitsWithCode(ExitCode.software),
              );

              verifyNever(
                () => routeBCoverageAnalyzer.analyze(
                  compiler: any(named: 'compiler'),
                  baseDill: any(named: 'baseDill'),
                  patchedDill: any(named: 'patchedDill'),
                  includePrefixes: any(named: 'includePrefixes'),
                ),
              );
              verify(
                () => logger.err(
                  any(that: contains('do not describe the same program')),
                ),
              ).called(1);
            });

            test(
              'warns when the analyzer cannot see declaration edits',
              () async {
                await runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                );

                verify(
                  () => logger.warn(
                    any(that: contains('predates analysis version 14')),
                  ),
                ).called(1);
              },
            );

            test(
              'does not warn when the analyzer sees declaration edits',
              () async {
                when(
                  () => routeBCoverageAnalyzer.analyze(
                    compiler: any(named: 'compiler'),
                    baseDill: any(named: 'baseDill'),
                    patchedDill: any(named: 'patchedDill'),
                    includePrefixes: any(named: 'includePrefixes'),
                  ),
                ).thenReturn(
                  RouteBCoverage.fromJson(
                    jsonEncode({
                      'analysisVersion': routeBDeclarationsAnalysisVersion,
                      'verdict': 'accept',
                      'changed': ['package:app/main.dart#routeBValue'],
                      'added': <String>[],
                      'removed': <String>[],
                      'patchable': ['package:app/main.dart#routeBValue'],
                      'conditional': <String>[],
                      'rejections': <Object>[],
                      'refusalSummary': null,
                    }),
                  ),
                );

                await runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                );

                verifyNever(
                  () => logger.warn(
                    any(that: contains('predates analysis version')),
                  ),
                );
              },
            );

            test('analyzes coverage against the RELEASE kernel', () async {
              await runWithOverrides(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: releaseId,
                  releaseArtifact: releaseArtifactFile,
                  supplementDirectory: supplementDirectory,
                ),
              );

              final captured = verify(
                () => routeBCoverageAnalyzer.analyze(
                  compiler: any(named: 'compiler'),
                  baseDill: captureAny(named: 'baseDill'),
                  patchedDill: captureAny(named: 'patchedDill'),
                  includePrefixes: any(named: 'includePrefixes'),
                ),
              ).captured;
              expect(
                (captured[0] as File).path,
                p.join(supplementDirectory.path, routeBReleaseKernelFileName),
              );
              expect(
                (captured[1] as File).path,
                p.join(projectRoot.path, 'build', 'app.dill'),
              );
            });

            test('refuses the WHOLE patch on any rejection', () async {
              // 4 changed, 3 representable, 1 not. Shipping the 3 would leave
              // the app running some functions from the patch and some from
              // the release.
              when(
                () => routeBCoverageAnalyzer.analyze(
                  compiler: any(named: 'compiler'),
                  baseDill: any(named: 'baseDill'),
                  patchedDill: any(named: 'patchedDill'),
                  includePrefixes: any(named: 'includePrefixes'),
                ),
              ).thenReturn(
                RouteBCoverage.fromJson(
                  jsonEncode({
                    'analysisVersion': supportedRouteBAnalysisVersion,
                    'verdict': 'reject',
                    'changed': ['a#alpha', 'a#beta', 'a#gamma', 'a#Shape.d'],
                    'added': <String>[],
                    'removed': <String>[],
                    'patchable': ['a#alpha', 'a#beta', 'a#gamma'],
                    'conditional': <String>[],
                    'rejections': [
                      {
                        'target': 'a#Shape.d',
                        'category': 'unreachable',
                        'reason':
                            'abstract; call sites dispatch to '
                            'implementations',
                      },
                    ],
                    'refusalSummary': '1 changed member(s) are not reachable',
                  }),
                ),
              );

              await expectLater(
                () => runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                ),
                exitsWithCode(ExitCode.software),
              );

              verify(
                () => logger.err(
                  any(
                    that: allOf(
                      contains('1 of 4 changed members'),
                      contains('a#Shape.d'),
                      contains('abstract; call sites dispatch'),
                      contains('The whole patch is refused'),
                    ),
                  ),
                ),
              ).called(1);
            });

            test(
              'refuses an inert patch rather than shipping a no-op',
              () async {
                when(
                  () => routeBCoverageAnalyzer.analyze(
                    compiler: any(named: 'compiler'),
                    baseDill: any(named: 'baseDill'),
                    patchedDill: any(named: 'patchedDill'),
                    includePrefixes: any(named: 'includePrefixes'),
                  ),
                ).thenReturn(
                  RouteBCoverage.fromJson(
                    jsonEncode({
                      'analysisVersion': supportedRouteBAnalysisVersion,
                      'verdict': 'inert',
                      'changed': <String>[],
                      'added': <String>[],
                      'removed': <String>[],
                      'patchable': <String>[],
                      'conditional': <String>[],
                      'rejections': <Object>[],
                      'refusalSummary': null,
                    }),
                  ),
                );

                await expectLater(
                  () => runWithOverrides(
                    () => patcher.createPatchArtifacts(
                      appId: appId,
                      releaseId: releaseId,
                      releaseArtifact: releaseArtifactFile,
                      supplementDirectory: supplementDirectory,
                    ),
                  ),
                  exitsWithCode(ExitCode.software),
                );

                verify(
                  () => logger.err(
                    any(that: contains('would install and change nothing')),
                  ),
                ).called(1);
              },
            );

            test(
              'stamps the container with the shipped release identity',
              () async {
                await runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                );

                // The LC_UUID written into the fixture App binary (bytes
                // 1..16), which is what OS::GetAppBuildId reports on device.
                // Read from the shipped bytes, so re-signing cannot change it.
                final buildId =
                    verify(
                          () => routeBProducer.produce(
                            compiler: any(named: 'compiler'),
                            coverage: any(named: 'coverage'),
                            releaseImportKernel: any(
                              named: 'releaseImportKernel',
                            ),
                            releaseBuildId: captureAny(named: 'releaseBuildId'),
                            workingDirectory: any(named: 'workingDirectory'),
                            projectRoot: any(named: 'projectRoot'),
                            capabilities: any(named: 'capabilities'),
                            buildConfig: any(named: 'buildConfig'),
                            survival: any(named: 'survival'),
                            releaseEvidence: any(named: 'releaseEvidence'),
                          ),
                        ).captured.single
                        as String;
                expect(buildId, '0102030405060708090a0b0c0d0e0f10');
              },
            );

            test("hands the producer the release's own capability set", () {
              // The producer decides a private reference against THIS, so the
              // manifest has to arrive from the release's hash-verified
              // artifact. Reading it anywhere else -- regenerating it, or
              // trusting the policy name -- would let a patch reference a
              // member this release never retained.
              writeReleaseProvenance(
                engineRevision: releaseEngineRevision,
                capabilityManifest: jsonEncode({
                  'policy': 'p2',
                  'privateInstanceCallable': ['package:app/main.dart#_S#_c'],
                  'privateClassesConstructible': ['package:app/main.dart#_S'],
                }),
              );

              return runWithOverrides(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: releaseId,
                  releaseArtifact: releaseArtifactFile,
                  supplementDirectory: supplementDirectory,
                ),
              ).then((_) {
                final capabilities =
                    verify(
                          () => routeBProducer.produce(
                            compiler: any(named: 'compiler'),
                            coverage: any(named: 'coverage'),
                            releaseImportKernel: any(
                              named: 'releaseImportKernel',
                            ),
                            releaseBuildId: any(named: 'releaseBuildId'),
                            workingDirectory: any(named: 'workingDirectory'),
                            projectRoot: any(named: 'projectRoot'),
                            capabilities: captureAny(named: 'capabilities'),
                            buildConfig: any(named: 'buildConfig'),
                            survival: any(named: 'survival'),
                            releaseEvidence: any(named: 'releaseEvidence'),
                          ),
                        ).captured.single
                        as RouteBCapabilities?;
                expect(capabilities, isNotNull);
                expect(capabilities!.policy, 'p2');
                expect(
                  capabilities.refuseInstanceMember(
                    library: 'package:app/main.dart',
                    className: '_S',
                    member: '_c',
                  ),
                  isNull,
                );
              });
            });

            test(
              'P5.1: refuses a release with no build configuration',
              () async {
                // This used to WARN AND CONTINUE, which made absent evidence
                // read as agreement. It is also what the RELEASE side already
                // intends: ios_releaser records buildConfig: null only when a
                // build's define expansion disagreed with Flutter's own, and
                // marks that release unpatchable when it is cut.
                //
                // Distinct from the legacy case on purpose: an old release also
                // predates the contract revision and is refused EARLIER, by
                // P4.4, with a message about the epoch. Reaching here means a
                // revision-capable release whose evidence is incomplete.
                writeReleaseProvenance(
                  engineRevision: releaseEngineRevision,
                  omitBuildConfig: true,
                );
                await expectLater(
                  runWithOverrides(
                    () => patcher.createPatchArtifacts(
                      appId: appId,
                      releaseId: releaseId,
                      releaseArtifact: releaseArtifactFile,
                      supplementDirectory: supplementDirectory,
                    ),
                  ),
                  throwsA(isA<ProcessExit>()),
                );
                verify(
                  () => logger.err(
                    any(
                      that: allOf(
                        contains(
                          RouteBBuildSemanticsProblem.evidenceAbsent.wire,
                        ),
                        // It must NOT read as an old release: that would send
                        // an operator to cut a new release when the real cause
                        // is a define expansion that disagreed with Flutter's.
                        contains('this is not an old release'),
                      ),
                    ),
                  ),
                ).called(1);
                // And nothing was produced.
                verifyNever(
                  () => routeBProducer.produce(
                    compiler: any(named: 'compiler'),
                    coverage: any(named: 'coverage'),
                    releaseImportKernel: any(named: 'releaseImportKernel'),
                    releaseBuildId: any(named: 'releaseBuildId'),
                    workingDirectory: any(named: 'workingDirectory'),
                    projectRoot: any(named: 'projectRoot'),
                    capabilities: any(named: 'capabilities'),
                    buildConfig: any(named: 'buildConfig'),
                    survival: any(named: 'survival'),
                    releaseEvidence: any(named: 'releaseEvidence'),
                  ),
                );
              },
            );

            test(
              'P5.1 MUTATION: with the check gone, the same patch proceeds',
              () async {
                // The mutation is the release recording a COMPARABLE empty
                // configuration instead of none, with everything else
                // identical. The same patch then reaches the producer -- which
                // is what makes the row above a demonstration that this check
                // is what refused, rather than something else along the way.
                writeReleaseProvenance(engineRevision: releaseEngineRevision);
                await runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                );
                verify(
                  () => routeBProducer.produce(
                    compiler: any(named: 'compiler'),
                    coverage: any(named: 'coverage'),
                    releaseImportKernel: any(named: 'releaseImportKernel'),
                    releaseBuildId: any(named: 'releaseBuildId'),
                    workingDirectory: any(named: 'workingDirectory'),
                    projectRoot: any(named: 'projectRoot'),
                    capabilities: any(named: 'capabilities'),
                    buildConfig: any(named: 'buildConfig'),
                    survival: any(named: 'survival'),
                    releaseEvidence: any(named: 'releaseEvidence'),
                  ),
                ).called(1);
              },
            );

            test('P4.4: refuses a release with no contract revision', () async {
              // A release cut before the field existed. It cannot be
              // established retroactively, and this refuses BEFORE resolving a
              // cell or compiling anything -- if the contract does not match,
              // everything downstream is uninterpretable.
              writeReleaseProvenance(
                engineRevision: releaseEngineRevision,
                compatibilityRevision: null,
              );
              await expectLater(
                runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                ),
                throwsA(isA<ProcessExit>()),
              );
              verify(
                () => logger.err(
                  any(that: contains('recorded no Route B contract revision')),
                ),
              ).called(1);
              verifyNever(
                () => routeBProducer.produce(
                  compiler: any(named: 'compiler'),
                  coverage: any(named: 'coverage'),
                  releaseImportKernel: any(named: 'releaseImportKernel'),
                  releaseBuildId: any(named: 'releaseBuildId'),
                  workingDirectory: any(named: 'workingDirectory'),
                  projectRoot: any(named: 'projectRoot'),
                  capabilities: any(named: 'capabilities'),
                  buildConfig: any(named: 'buildConfig'),
                  survival: any(named: 'survival'),
                  releaseEvidence: any(named: 'releaseEvidence'),
                ),
              );
            });

            test('P4.4: refuses a release from a DIFFERENT revision', () async {
              writeReleaseProvenance(
                engineRevision: releaseEngineRevision,
                compatibilityRevision: routeBCompatibilityRevision + 1,
              );
              await expectLater(
                runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                ),
                throwsA(isA<ProcessExit>()),
              );
              // Both revisions named: "these cannot be mixed" is only
              // actionable if you can see which two.
              verify(
                () => logger.err(
                  any(
                    that: allOf(
                      contains(
                        'revision ${routeBCompatibilityRevision + 1}',
                      ),
                      contains(
                        'publishes revision '
                        '$routeBCompatibilityRevision',
                      ),
                    ),
                  ),
                ),
              ).called(1);
            });

            test(
              'P4.1: refuses when the release uploaded no snapshot profile',
              () {
                // An absent gate is indistinguishable from a gate that passed,
                // so a release with no profile does not get the question
                // SKIPPED -- it gets UNKNOWN, which refuses. That is the
                // intended reading of the invariant: if a patch publishes,
                // every mechanically knowable prerequisite was already proven
                // against the exact release artifact.
                return runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                ).then((_) {
                  final oracle =
                      verify(
                            () => routeBProducer.produce(
                              compiler: any(named: 'compiler'),
                              coverage: any(named: 'coverage'),
                              releaseImportKernel: any(
                                named: 'releaseImportKernel',
                              ),
                              releaseBuildId: any(named: 'releaseBuildId'),
                              workingDirectory: any(named: 'workingDirectory'),
                              projectRoot: any(named: 'projectRoot'),
                              capabilities: any(named: 'capabilities'),
                              buildConfig: any(named: 'buildConfig'),
                              survival: captureAny(named: 'survival'),
                              releaseEvidence: any(named: 'releaseEvidence'),
                            ),
                          ).captured.single
                          as RouteBSurvivalOracle?;
                  // Never null: omitting the oracle would BE the missing gate.
                  expect(oracle, isNotNull);
                  final verdict = oracle!([
                    'package:app/main.dart#v',
                  ])['package:app/main.dart#v'];
                  expect(verdict, isNotNull);
                  expect(verdict!.survival, RouteBSurvival.unknown);
                  expect(verdict.instrumentResult, 'RELEASE_EVIDENCE_ABSENT');
                  expect(verdict.permitsPublication, isFalse);
                });
              },
            );

            test('passes no capability set when the release recorded none', () {
              // A release cut before manifests existed. Null is not an empty
              // grant: the producer refuses a private reference for want of
              // evidence, and everything that worked before still works.
              return runWithOverrides(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: releaseId,
                  releaseArtifact: releaseArtifactFile,
                  supplementDirectory: supplementDirectory,
                ),
              ).then((_) {
                final capabilities =
                    verify(
                          () => routeBProducer.produce(
                            compiler: any(named: 'compiler'),
                            coverage: any(named: 'coverage'),
                            releaseImportKernel: any(
                              named: 'releaseImportKernel',
                            ),
                            releaseBuildId: any(named: 'releaseBuildId'),
                            workingDirectory: any(named: 'workingDirectory'),
                            projectRoot: any(named: 'projectRoot'),
                            capabilities: captureAny(named: 'capabilities'),
                            buildConfig: any(named: 'buildConfig'),
                            survival: any(named: 'survival'),
                            releaseEvidence: any(named: 'releaseEvidence'),
                          ),
                        ).captured.single
                        as RouteBCapabilities?;
                expect(capabilities, isNull);
              });
            });

            test('ships the container through the normal '
                'artifact path', () async {
              // A Route B release must never reach the private-linker path.
              // That fallback cannot work here and would quietly leave the old
              // architecture as the default for exactly the releases that
              // moved off it.
              final bundles = await runWithOverrides(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: releaseId,
                  releaseArtifact: releaseArtifactFile,
                  supplementDirectory: supplementDirectory,
                ),
              );

              verifyNever(
                () => apple.runLinker(
                  kernelFile: any(named: 'kernelFile'),
                  releaseArtifact: any(named: 'releaseArtifact'),
                  splitDebugInfoArgs: any(named: 'splitDebugInfoArgs'),
                  aotOutputFile: any(named: 'aotOutputFile'),
                  vmCodeFile: any(named: 'vmCodeFile'),
                ),
              );

              // Diffed against a ONE-BYTE synthetic base, not the release: the
              // updater's base on iOS is the four Dart blobs, which a container
              // has nothing in common with and which the producer cannot
              // reproduce without a Shorebird-fork tool.
              final base =
                  verify(
                        () => artifactManager.createDiff(
                          releaseArtifactPath: captureAny(
                            named: 'releaseArtifactPath',
                          ),
                          patchArtifactPath: any(named: 'patchArtifactPath'),
                        ),
                      ).captured.single
                      as String;
              expect(File(base).readAsBytesSync(), [0]);

              // hash from the CONTAINER, size from the ARTIFACT: check_hash()
              // on device runs against the inflated result.
              final bundle = bundles[Arch.arm64]!;
              expect(
                bundle.hash,
                sha256
                    .convert(
                      utf8.encode(
                        'SBRBPTCH-for-0102030405060708090a0b0c0d0e0f10',
                      ),
                    )
                    .toString(),
              );
              expect(bundle.size, 64);
            });
          });
        });

        group('when assets-only', () {
          setUp(() {
            writeReleaseAppBinary(sites: 2);
            patcher.assetsOnly = true;
            // The assets-only path still reads the AOT output it would have
            // uploaded; the fixture does not create it by default.
            File(p.join(projectRoot.path, 'build', 'out.aot'))
              ..createSync(recursive: true)
              ..writeAsBytesSync(List<int>.filled(64, 0));
          });

          test('does not check patchability', () async {
            // An assets-only patch carries no Dart, so patchable call sites
            // are irrelevant to it and refusing would be wrong.
            await runWithOverrides(
              () => patcher.createPatchArtifacts(
                appId: appId,
                releaseId: releaseId,
                releaseArtifact: releaseArtifactFile,
              ),
            );

            verifyNever(
              () => logger.err(
                any(
                  that: contains(
                    'was not built with Route B patchable call sites',
                  ),
                ),
              ),
            );
          });
        });
      });

      group('when patch .xcarchive does not exist', () {
        setUp(() {
          when(() => artifactManager.getXcarchiveDirectory()).thenReturn(null);
        });

        test('logs error and exits with code 70', () async {
          await expectLater(
            () => runWithOverrides(
              () => patcher.createPatchArtifacts(
                appId: appId,
                releaseId: releaseId,
                releaseArtifact: releaseArtifactFile,
              ),
            ),
            exitsWithCode(ExitCode.software),
          );
        });
      });

      group('when linking', () {
        late Directory appDirectory;

        setUp(() {
          appDirectory = Directory(
            p.join(
              projectRoot.path,
              'build',
              'ios',
              'framework',
              'Release',
              'App.xcframework',
              'Products',
              'Applications',
              'Runner.app',
            ),
          );
          when(
            () => artifactManager.getIosAppDirectory(
              xcarchiveDirectory: any(named: 'xcarchiveDirectory'),
            ),
          ).thenReturn(appDirectory);
          when(
            () => shorebirdEnv.flutterRevision,
          ).thenReturn(postLinkerFlutterRevision);
          when(
            () => apple.runLinker(
              kernelFile: any(named: 'kernelFile'),
              aotOutputFile: any(named: 'aotOutputFile'),
              releaseArtifact: any(named: 'releaseArtifact'),
              splitDebugInfoArgs: any(named: 'splitDebugInfoArgs'),
              vmCodeFile: any(named: 'vmCodeFile'),
              ddMaxBytes: any(named: 'ddMaxBytes'),
            ),
          ).thenAnswer(
            (_) async => const LinkResult.success(linkPercentage: 100),
          );
          when(
            () => shorebirdArtifacts.getArtifactPath(
              artifact: ShorebirdArtifact.analyzeSnapshotIos,
            ),
          ).thenReturn('path/to/analyze_snapshot');
          when(
            aotTools.isGeneratePatchDiffBaseSupported,
          ).thenAnswer((_) async => true);
          when(
            () => aotTools.generatePatchDiffBase(
              analyzeSnapshotPath: any(named: 'analyzeSnapshotPath'),
              releaseSnapshot: any(named: 'releaseSnapshot'),
              outputDirectory: any(named: 'outputDirectory'),
            ),
          ).thenAnswer((invocation) async {
            final outputDirectory =
                invocation.namedArguments[#outputDirectory] as Directory;
            return File(p.join(outputDirectory.path, 'diff_base'))
              ..createSync();
          });
          when(
            () => artifactManager.createDiff(
              releaseArtifactPath: any(named: 'releaseArtifactPath'),
              patchArtifactPath: any(named: 'patchArtifactPath'),
            ),
          ).thenAnswer((_) async => 'path/to/diff');
          setUpProjectRootArtifacts();
        });

        group('when the patch is assets-only', () {
          setUp(() {
            patcher.assetsOnly = true;
            setUpProjectRootArtifacts();
          });

          test('does not invoke the linker', () async {
            await runWithOverrides(
              () => patcher.createPatchArtifacts(
                appId: appId,
                releaseId: releaseId,
                releaseArtifact: releaseArtifactFile,
              ),
            );

            // The revision DOES support the linker — this group's setUp makes
            // usesLinker true — so this asserts assetsOnly is what suppresses
            // it. Linking is the only step needing aot-tools.dill, so skipping
            // it is what lets an assets-only iOS patch be built without
            // Shorebird's AOT linker.
            verifyNever(
              () => apple.runLinker(
                kernelFile: any(named: 'kernelFile'),
                aotOutputFile: any(named: 'aotOutputFile'),
                releaseArtifact: any(named: 'releaseArtifact'),
                splitDebugInfoArgs: any(named: 'splitDebugInfoArgs'),
                vmCodeFile: any(named: 'vmCodeFile'),
              ),
            );
          });

          test('leaves link percentage unset', () async {
            await runWithOverrides(
              () => patcher.createPatchArtifacts(
                appId: appId,
                releaseId: releaseId,
                releaseArtifact: releaseArtifactFile,
              ),
            );

            // Nothing was linked, so reporting a percentage would be a fiction.
            expect(patcher.linkPercentage, isNull);
          });
        });

        // The link, diff and bundle steps themselves are tested once in
        // apple_patcher_mixin_test.dart; these cover the iOS wiring.
        test(
          'links against the App binary in the release .app, using the '
          'release supplement',
          () async {
            await runWithOverrides(
              () => patcher.createPatchArtifacts(
                appId: appId,
                releaseId: releaseId,
                releaseArtifact: releaseArtifactFile,
                supplementDirectory: supplementDirectory,
              ),
            );

            verify(
              () => apple.runLinker(
                kernelFile: any(named: 'kernelFile'),
                aotOutputFile: any(named: 'aotOutputFile'),
                releaseArtifact: any(
                  named: 'releaseArtifact',
                  that: isA<File>().having(
                    (f) => f.path,
                    'path',
                    p.join(
                      appDirectory.path,
                      'Frameworks',
                      'App.framework',
                      'App',
                    ),
                  ),
                ),
                splitDebugInfoArgs: any(named: 'splitDebugInfoArgs'),
                vmCodeFile: any(named: 'vmCodeFile'),
                ddMaxBytes: any(named: 'ddMaxBytes'),
              ),
            ).called(1);
            verify(
              () => apple.copySupplementFilesToSnapshotDirs(
                releaseSupplementDir: supplementDirectory,
                releaseSnapshotDir: any(named: 'releaseSnapshotDir'),
                patchSupplementDir: any(named: 'patchSupplementDir'),
                patchSnapshotDir: any(named: 'patchSnapshotDir'),
              ),
            ).called(1);
          },
        );

        test('passes --dd-max-bytes to the linker', () async {
          when(
            () => argResults[CommonArguments.ddMaxBytesArg.name],
          ).thenReturn('8192');

          await runWithOverrides(
            () => patcher.createPatchArtifacts(
              appId: appId,
              releaseId: releaseId,
              releaseArtifact: releaseArtifactFile,
            ),
          );

          verify(
            () => apple.runLinker(
              kernelFile: any(named: 'kernelFile'),
              aotOutputFile: any(named: 'aotOutputFile'),
              releaseArtifact: any(named: 'releaseArtifact'),
              splitDebugInfoArgs: any(named: 'splitDebugInfoArgs'),
              vmCodeFile: any(named: 'vmCodeFile'),
              ddMaxBytes: 8192,
            ),
          ).called(1);
        });

        test('bundles the local Podfile.lock hash', () async {
          when(
            () => shorebirdEnv.iosPodfileLockHash,
          ).thenReturn('podfile-lock-hash');

          final patchBundle = await runWithOverrides(
            () => patcher.createPatchArtifacts(
              appId: appId,
              releaseId: releaseId,
              releaseArtifact: releaseArtifactFile,
            ),
          );

          expect(
            patchBundle[Arch.arm64]!.podfileLockHash,
            equals('podfile-lock-hash'),
          );
        });

        test('leaves no temporary files behind', () async {
          final systemTemp = createSystemTemp();
          await runWithSystemTemp(
            systemTemp,
            () => runWithOverrides(
              () => patcher.createPatchArtifacts(
                appId: appId,
                releaseId: releaseId,
                releaseArtifact: releaseArtifactFile,
              ),
            ),
          );

          expect(systemTemp.listSync(), isEmpty);
        });

        test('keeps a supplement directory it was given', () async {
          await runWithOverrides(
            () => patcher.createPatchArtifacts(
              appId: appId,
              releaseId: releaseId,
              releaseArtifact: releaseArtifactFile,
              supplementDirectory: supplementDirectory,
            ),
          );

          expect(supplementDirectory.existsSync(), isTrue);
        });

        group('when the release .app does not exist', () {
          setUp(() {
            when(
              () => artifactManager.getIosAppDirectory(
                xcarchiveDirectory: any(named: 'xcarchiveDirectory'),
              ),
            ).thenReturn(null);
          });

          test('exits with an error saying the .app is missing', () async {
            await expectLater(
              () => runWithOverrides(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: releaseId,
                  releaseArtifact: releaseArtifactFile,
                ),
              ),
              exitsWithError(
                message:
                    'The release .xcarchive downloaded from Shorebird has no '
                    'Products/Applications/*.app directory.',
                hint: allOf(
                  startsWith('Re-run to download it again.'),
                  endsWith('Run: shorebird release ios'),
                ),
                exitCode: ExitCode.software,
              ),
            );
          });
        });

        group('when the release artifact is damaged', () {
          setUp(() {
            when(
              () => artifactManager.extractZip(
                zipFile: any(named: 'zipFile'),
                outputDirectory: any(named: 'outputDirectory'),
              ),
            ).thenThrow(
              ArchiveException('zip: end of central directory not found'),
            );
          });

          test('fails progress and exits naming the fix', () async {
            await expectLater(
              () => runWithOverrides(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: releaseId,
                  releaseArtifact: releaseArtifactFile,
                ),
              ),
              exitsWithError(
                message:
                    'The release artifact downloaded from Shorebird is '
                    'damaged: zip: end of central directory not found',
                hint: allOf(
                  startsWith('Re-run to download it again.'),
                  endsWith('Run: shorebird release ios'),
                ),
                exitCode: ExitCode.software,
              ),
            );
            verify(() => progress.fail()).called(1);
          });
        });
      });
    });

    group('assetsDirectory', () {
      late Directory xcarchive;
      late Directory app;

      setUp(() {
        xcarchive = Directory.systemTemp.createTempSync();
        app = Directory(p.join(xcarchive.path, 'Products', 'Runner.app'))
          ..createSync(recursive: true);
        when(
          () => artifactManager.getXcarchiveDirectory(),
        ).thenReturn(xcarchive);
        when(
          () => artifactManager.getIosAppDirectory(
            xcarchiveDirectory: any(named: 'xcarchiveDirectory'),
          ),
        ).thenReturn(app);
      });

      test('is null when no xcarchive was built', () async {
        when(() => artifactManager.getXcarchiveDirectory()).thenReturn(null);

        await expectLater(
          runWithOverrides(patcher.assetsDirectory),
          completion(isNull),
        );
      });

      test('is null when the xcarchive has no .app', () async {
        when(
          () => artifactManager.getIosAppDirectory(
            xcarchiveDirectory: any(named: 'xcarchiveDirectory'),
          ),
        ).thenReturn(null);

        await expectLater(
          runWithOverrides(patcher.assetsDirectory),
          completion(isNull),
        );
      });

      test('is null when the .app has no flutter_assets', () async {
        await expectLater(
          runWithOverrides(patcher.assetsDirectory),
          completion(isNull),
        );
      });

      test('finds flutter_assets inside the built .app', () async {
        final assets = Directory(
          p.join(app.path, 'Frameworks', 'App.framework', 'flutter_assets'),
        )..createSync(recursive: true);

        final result = await runWithOverrides(patcher.assetsDirectory);

        expect(result?.path, equals(assets.path));
      });

      test('reads the patch xcarchive, not the downloaded release', () async {
        Directory(
          p.join(app.path, 'Frameworks', 'App.framework', 'flutter_assets'),
        ).createSync(recursive: true);

        await runWithOverrides(patcher.assetsDirectory);

        // getXcarchiveDirectory() is the locally built archive; resolving
        // against the release archive would ship the release's assets.
        verify(() => artifactManager.getXcarchiveDirectory()).called(1);
      });
    });

    group('extractReleaseVersionFromArtifact', () {
      late File infoPlist;

      setUp(() {
        final xcarchiveDirectory = Directory(
          p.join(
            projectRoot.path,
            'build',
            'ios',
            'archive',
            'Runner.xcarchive',
          ),
        );
        infoPlist = File(p.join(xcarchiveDirectory.path, 'Info.plist'));
        when(
          () => artifactManager.getXcarchiveDirectory(),
        ).thenReturn(xcarchiveDirectory);
      });

      group('when xcarchive directory does not exist', () {
        setUp(() {
          when(() => artifactManager.getXcarchiveDirectory()).thenReturn(null);
        });

        test('exits with an error naming the expected archive path', () async {
          await expectLater(
            () => runWithOverrides(
              () => patcher.extractReleaseVersionFromArtifact(File('')),
            ),
            exitsWithError(
              message:
                  'No .xcarchive found in '
                  '${p.join(projectRoot.path, 'build', 'ios', 'archive')}, '
                  'where `flutter build ipa` writes it.',
              hint: 'Re-run with --verbose to see the build output.',
              exitCode: ExitCode.software,
            ),
          );
        });
      });

      group('when Info.plist does not exist', () {
        test('exits with an error and the hint', () async {
          await expectLater(
            () => runWithOverrides(
              () => patcher.extractReleaseVersionFromArtifact(File('')),
            ),
            exitsWithError(
              message: 'No Info.plist file found at ${infoPlist.path}',
              hint: passReleaseVersionHint,
              exitCode: ExitCode.software,
            ),
          );
        });
      });

      group('when empty Info.plist does exist', () {
        setUp(() {
          infoPlist
            ..createSync(recursive: true)
            ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict></dict>
</plist>
''');
        });

        test('exits with an error and the hint', () async {
          await expectLater(
            runWithOverrides(
              () => patcher.extractReleaseVersionFromArtifact(File('')),
            ),
            exitsWithError(
              message: startsWith('Failed to determine release version'),
              hint: passReleaseVersionHint,
              exitCode: ExitCode.software,
            ),
          );
        });
      });

      group('when Info.plist does exist', () {
        setUp(() {
          infoPlist
            ..createSync(recursive: true)
            ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ApplicationProperties</key>
	<dict>
		<key>ApplicationPath</key>
		<string>Applications/Runner.app</string>
		<key>Architectures</key>
		<array>
			<string>arm64</string>
		</array>
		<key>CFBundleIdentifier</key>
		<string>com.shorebird.timeShift</string>
		<key>CFBundleShortVersionString</key>
		<string>1.2.3</string>
		<key>CFBundleVersion</key>
		<string>1</string>
	</dict>
	<key>ArchiveVersion</key>
	<integer>2</integer>
	<key>Name</key>
	<string>Runner</string>
	<key>SchemeName</key>
	<string>Runner</string>
</dict>
</plist>
''');
        });

        test('returns correct version', () async {
          await expectLater(
            runWithOverrides(
              () => patcher.extractReleaseVersionFromArtifact(File('')),
            ),
            completion('1.2.3+1'),
          );
        });
      });
    });

    group('updatedPlatformMetadata', () {
      group('when linker is not enabled', () {
        test('leaves the link fields unset', () async {
          const metadata = CreatePatchPlatformMetadata(
            hasAssetChanges: false,
            hasNativeChanges: true,
          );

          expect(
            runWithOverrides(() => patcher.updatedPlatformMetadata(metadata)),
            completion(metadata),
          );
        });
      });

      group('when linker is enabled', () {
        const linkPercentage = 100.0;
        const linkMetadata = {'link': 'metadata'};

        setUp(() {
          patcher
            ..lastBuildLinkPercentage = linkPercentage
            ..lastBuildLinkMetadata = linkMetadata;
        });

        test('adds the link percentage and metadata', () async {
          const metadata = CreatePatchPlatformMetadata(
            hasAssetChanges: true,
            hasNativeChanges: false,
          );

          expect(
            runWithOverrides(() => patcher.updatedPlatformMetadata(metadata)),
            completion(
              const CreatePatchPlatformMetadata(
                hasAssetChanges: true,
                hasNativeChanges: false,
                linkPercentage: linkPercentage,
                linkMetadata: linkMetadata,
              ),
            ),
          );
        });
      });
    });

    group('updatedEnvironmentMetadata', () {
      const flutterRevision = '853d13d954df3b6e9c2f07b72062f33c52a9a64b';
      const operatingSystem = 'Mac OS X';
      const operatingSystemVersion = '10.15.7';
      const xcodeVersion = '11';

      setUp(() {
        when(() => xcodeBuild.version()).thenAnswer((_) async => xcodeVersion);
      });

      test('adds the xcode version and leaves other fields alone', () async {
        const metadata = BuildEnvironmentMetadata(
          flutterRevision: flutterRevision,
          operatingSystem: operatingSystem,
          operatingSystemVersion: operatingSystemVersion,
          shorebirdVersion: packageVersion,
          shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
          usesShorebirdCodePushPackage: false,
        );

        expect(
          runWithOverrides(() => patcher.updatedEnvironmentMetadata(metadata)),
          completion(metadata.copyWith(xcodeVersion: xcodeVersion)),
        );
      });
    });
  }, testOn: 'mac-os');
}

/// Writes `.dart_tool/package_config.json` under [projectRoot], one entry per
/// package name and root URI (relative to `.dart_tool/`, as pub writes them).
void writePackageConfig(Directory projectRoot, Map<String, String> roots) {
  File(p.join(projectRoot.path, '.dart_tool', 'package_config.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (final MapEntry(:key, :value) in roots.entries)
            {'name': key, 'rootUri': value, 'packageUri': 'lib/'},
        ],
      }),
    );
}
