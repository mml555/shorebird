import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:platform/platform.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/archive_analysis/apple_archive_differ.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/code_signer.dart';
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
import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/route_b_compiler_cache.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:shorebird_cli/src/route_b_release_kernels.dart';
import 'package:shorebird_cli/src/route_b_binding.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/src/base/process.dart';
import 'package:shorebird_cli/src/route_b_provenance.dart';
import 'package:shorebird_cli/src/route_b_survival.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_documentation.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/validators/validators.dart';
import 'package:shorebird_cli/src/version.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import '../../fakes.dart';
import '../../helpers.dart';
import '../../matchers.dart';
import '../../mocks.dart';

/// A stand-in path for fallback values mocktail only needs to type-check.
const _nowhere = _NowhereFile();

class _NowhereFile implements File {
  const _NowhereFile();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
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
    late Directory flutterDirectory;
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

    group('linkPercentage', () {
      group('when linking has not occurred', () {
        test('returns null', () {
          expect(patcher.linkPercentage, isNull);
        });
      });

      group('when linking has occurred', () {
        const linkPercentage = 42.1337;

        setUp(() {
          patcher.lastBuildLinkPercentage = linkPercentage;
        });

        test('returns correct link percentage', () {
          expect(patcher.linkPercentage, equals(linkPercentage));
        });
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
              supportedOperatingSystems: {Platform.macOS},
            ),
          ).called(1);
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
          'returns normally when manageAppVersionAndBuildNumber is absent',
          () async {
            final file = writePlist(
              '<key>method</key><string>app-store</string>',
            );
            when(
              () => argResults[CommonArguments.exportOptionsPlistArg.name],
            ).thenReturn(file.path);

            await expectLater(
              runWithOverrides(patcher.assertArgsAreValid),
              completes,
            );
          },
        );

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
              confirmNativeChanges: false,
            ),
          ).thenAnswer((_) async => noChangeDiffStatus);
        });

        test('returns diff status from patchDiffChecker', () async {
          final diffStatus = await runWithOverrides(
            () => patcher.assertUnpatchableDiffs(
              releaseArtifact: FakeReleaseArtifact(),
              releaseArchive: File(''),
              patchArchive: File(''),
            ),
          );
          expect(diffStatus, equals(noChangeDiffStatus));
          verifyNever(
            () => logger.warn(
              '''Your ios/Podfile.lock is different from the one used to build the release.''',
            ),
          );
        });
      });

      group('when native changes are detected', () {
        const nativeChangeDiffStatus = DiffStatus(
          hasAssetChanges: false,
          hasNativeChanges: true,
        );

        const podfileLockHash = 'podfile-lock-hash';

        setUp(() {
          when(
            () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
              localArchive: any(named: 'localArchive'),
              releaseArchive: any(named: 'releaseArchive'),
              archiveDiffer: any(named: 'archiveDiffer'),
              allowAssetChanges: any(named: 'allowAssetChanges'),
              allowNativeChanges: any(named: 'allowNativeChanges'),
              confirmNativeChanges: false,
            ),
          ).thenAnswer((_) async => nativeChangeDiffStatus);

          when(
            () => shorebirdEnv.iosPodfileLockHash,
          ).thenReturn(podfileLockHash);
        });

        group('when release has podspec lock hash', () {
          group('when release podspec lock hash matches patch', () {
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

            test('does not warn of native changes', () async {
              final diffStatus = await runWithOverrides(
                () => patcher.assertUnpatchableDiffs(
                  releaseArtifact: releaseArtifact,
                  releaseArchive: File(''),
                  patchArchive: File(''),
                ),
              );
              expect(diffStatus, equals(nativeChangeDiffStatus));
              verifyNever(
                () => logger.warn(
                  '''Your ios/Podfile.lock is different from the one used to build the release.''',
                ),
              );
            });
          });

          group('when release podspec lock hash does not match patch', () {
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

            group('when native diffs are allowed', () {
              setUp(() {
                when(() => argResults['allow-native-diffs']).thenReturn(true);
              });

              test(
                'logs warning, does not prompt for confirmation to proceed',
                () async {
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
                  verifyNever(
                    () => logger.confirm(any(), hint: any(named: 'hint')),
                  );
                },
              );
            });

            group('when native diffs are not allowed', () {
              group('when in an environment that accepts user input', () {
                setUp(() {
                  when(() => shorebirdEnv.canAcceptUserInput).thenReturn(true);
                });

                group('when user opts to continue at prompt', () {
                  setUp(() {
                    when(
                      () => logger.confirm(any(), hint: any(named: 'hint')),
                    ).thenReturn(true);
                  });

                  test('returns diff status from patchDiffChecker', () async {
                    final diffStatus = await runWithOverrides(
                      () => patcher.assertUnpatchableDiffs(
                        releaseArtifact: releaseArtifact,
                        releaseArchive: File(''),
                        patchArchive: File(''),
                      ),
                    );
                    expect(diffStatus, equals(nativeChangeDiffStatus));
                  });
                });

                group('when user aborts at prompt', () {
                  setUp(() {
                    when(
                      () => logger.confirm(any(), hint: any(named: 'hint')),
                    ).thenReturn(false);
                  });

                  test('throws UserCancelledException', () async {
                    await expectLater(
                      () => runWithOverrides(
                        () => patcher.assertUnpatchableDiffs(
                          releaseArtifact: releaseArtifact,
                          releaseArchive: File(''),
                          patchArchive: File(''),
                        ),
                      ),
                      throwsA(isA<UserCancelledException>()),
                    );
                  });
                });
              });

              group(
                'when in an environment that does not accept user input',
                () {
                  setUp(() {
                    when(
                      () => shorebirdEnv.canAcceptUserInput,
                    ).thenReturn(false);
                  });

                  test('throws UnpatchableChangeException', () async {
                    await expectLater(
                      () => runWithOverrides(
                        () => patcher.assertUnpatchableDiffs(
                          releaseArtifact: releaseArtifact,
                          releaseArchive: File(''),
                          patchArchive: File(''),
                        ),
                      ),
                      throwsA(isA<UnpatchableChangeException>()),
                    );
                  });
                },
              );
            });
          });
        });

        group('when release does not have podspec lock hash', () {});
      });
    });

    group('buildPatchArtifact', () {
      const flutterVersionAndRevision = '3.22.2 (83305b5088)';
      setUp(() {
        when(
          () => shorebirdFlutter.getVersionAndRevision(),
        ).thenAnswer((_) async => flutterVersionAndRevision);
        when(
          () => shorebirdFlutter.getVersion(),
        ).thenAnswer((_) async => Version(3, 22, 2));
      });

      group('when specified flutter version is less than minimum', () {
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
          when(
            () => shorebirdFlutter.getVersion(),
          ).thenAnswer((_) async => Version(3, 0, 0));
        });

        test('logs error and exits with code 70', () async {
          await expectLater(
            () => runWithOverrides(patcher.buildPatchArtifact),
            exitsWithCode(ExitCode.software),
          );

          verify(
            () => logger.err('''
iOS patches are not supported with Flutter versions older than $minimumSupportedIosFlutterVersion.
For more information see: ${supportedFlutterVersionsUrl.toLink()}'''),
          ).called(1);
        });
      });

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
              () => codeSigner.base64PublicKey(any()),
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
            patcher.obfuscationMapPath = obfuscationMapFile.path;
            patcher.extraBuildArgs = [
              '--obfuscate',
              '--extra-gen-snapshot-options='
                  '--load-obfuscation-map=${obfuscationMapFile.path}',
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
      const preLinkerFlutterRevision =
          '83305b5088e6fe327fb3334a73ff190828d85713';
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
        }) {
          final artifacts = <String, String>{};
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
              importKernel: any(named: 'importKernel'),
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
                if (flavor != null) 'FLUTTER_APP_FLAVOR': flavor,
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
                // be flavored entirely by `default-flavor`, and reading the flag
                // alone would record "no flavor" for it.
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

                // The LC_UUID written into the fixture App binary (bytes 1..16),
                // which is what OS::GetAppBuildId reports on device. Read from
                // the shipped bytes, so re-signing cannot change it.
                final buildId =
                    verify(
                          () => routeBProducer.produce(
                            compiler: any(named: 'compiler'),
                            coverage: any(named: 'coverage'),
                            importKernel: any(named: 'importKernel'),
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

            test('hands the producer the release\'s own capability set', () {
              // The producer decides a private reference against THIS, so the
              // manifest has to arrive from the release's hash-verified
              // artifact. Reading it anywhere else -- regenerating it, or
              // trusting the policy name -- would let a patch reference a member
              // this release never retained.
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
                            importKernel: any(named: 'importKernel'),
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

            test('P5.1: refuses a release with no build configuration',
                () async {
              // This used to WARN AND CONTINUE, which made absent evidence read
              // as agreement. It is also what the RELEASE side already intends:
              // ios_releaser records buildConfig: null only when a build's
              // define expansion disagreed with Flutter's own, and marks that
              // release unpatchable when it is cut.
              //
              // Distinct from the legacy case on purpose: an old release also
              // predates the contract revision and is refused EARLIER, by P4.4,
              // with a message about the epoch. Reaching here means a
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
                      // It must NOT read as an old release: that would send an
                      // operator to cut a new release when the real cause is a
                      // define expansion that disagreed with Flutter's.
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
                  importKernel: any(named: 'importKernel'),
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

            test('P5.1 MUTATION: with the check gone, the same patch proceeds',
                () async {
              // The mutation is the release recording a COMPARABLE empty
              // configuration instead of none, with everything else identical.
              // The same patch then reaches the producer -- which is what makes
              // the row above a demonstration that this check is what refused,
              // rather than something else along the way.
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
                  importKernel: any(named: 'importKernel'),
                  releaseBuildId: any(named: 'releaseBuildId'),
                  workingDirectory: any(named: 'workingDirectory'),
                  projectRoot: any(named: 'projectRoot'),
                  capabilities: any(named: 'capabilities'),
                  buildConfig: any(named: 'buildConfig'),
                  survival: any(named: 'survival'),
                  releaseEvidence: any(named: 'releaseEvidence'),
                ),
              ).called(1);
            });

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
                  importKernel: any(named: 'importKernel'),
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
              // Both revisions named: "these cannot be mixed" is only actionable
              // if you can see which two.
              verify(
                () => logger.err(
                  any(
                    that: allOf(
                      contains(
                        'revision ${routeBCompatibilityRevision + 1}',
                      ),
                      contains('publishes revision '
                          '$routeBCompatibilityRevision'),
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
                              importKernel: any(named: 'importKernel'),
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
                  final verdict = oracle!(['package:app/main.dart#v'])[
                      'package:app/main.dart#v'];
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
                            importKernel: any(named: 'importKernel'),
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

            test('ships the container through the normal artifact path', () async {
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

      group('when uses linker', () {
        const linkPercentage = 50.0;
        late File analyzeSnapshotFile;
        late File genSnapshotFile;

        setUp(() {
          final shorebirdRoot = Directory.systemTemp.createTempSync();
          flutterDirectory = Directory(
            p.join(shorebirdRoot.path, 'bin', 'cache', 'flutter'),
          );
          genSnapshotFile = File(
            p.join(
              flutterDirectory.path,
              'bin',
              'cache',
              'artifacts',
              'engine',
              'ios-release',
              'gen_snapshot_arm64',
            ),
          );
          analyzeSnapshotFile = File(
            p.join(
              flutterDirectory.path,
              'bin',
              'cache',
              'artifacts',
              'engine',
              'ios-release',
              'analyze_snapshot_arm64',
            ),
          )..createSync(recursive: true);

          when(
            () => apple.runLinker(
              kernelFile: any(named: 'kernelFile'),
              aotOutputFile: any(named: 'aotOutputFile'),
              releaseArtifact: any(named: 'releaseArtifact'),
              splitDebugInfoArgs: any(named: 'splitDebugInfoArgs'),
              vmCodeFile: any(named: 'vmCodeFile'),
            ),
          ).thenAnswer(
            (_) async =>
                const LinkResult.success(linkPercentage: linkPercentage),
          );
          when(
            aotTools.isGeneratePatchDiffBaseSupported,
          ).thenAnswer((_) async => false);
          when(
            () => artifactManager.getIosAppDirectory(
              xcarchiveDirectory: any(named: 'xcarchiveDirectory'),
            ),
          ).thenReturn(Directory(p.join(projectRoot.path, 'build', 'ios')));
          when(
            () => artifactManager.getIosAppDirectory(
              xcarchiveDirectory: any(named: 'xcarchiveDirectory'),
            ),
          ).thenReturn(Directory(p.join(projectRoot.path, 'build', 'ios')));
          when(
            () => artifactManager.getIosAppDirectory(
              xcarchiveDirectory: any(named: 'xcarchiveDirectory'),
            ),
          ).thenReturn(
            Directory(
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
            ),
          );
          when(
            () => shorebirdEnv.flutterRevision,
          ).thenReturn(postLinkerFlutterRevision);
          when(
            () => shorebirdArtifacts.getArtifactPath(
              artifact: ShorebirdArtifact.analyzeSnapshotIos,
            ),
          ).thenReturn(analyzeSnapshotFile.path);
          when(
            () => shorebirdArtifacts.getArtifactPath(
              artifact: ShorebirdArtifact.genSnapshotIos,
            ),
          ).thenReturn(genSnapshotFile.path);
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

        group('when linking fails', () {
          group('when .app does not exist', () {
            setUp(() {
              when(
                () => artifactManager.getIosAppDirectory(
                  xcarchiveDirectory: any(named: 'xcarchiveDirectory'),
                ),
              ).thenReturn(null);
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

              verify(
                () => logger.err(
                  any(
                    that: startsWith(
                      'Unable to find release artifact .app directory',
                    ),
                  ),
                ),
              ).called(1);
            });
          });
        });

        group('when generate patch diff base is supported', () {
          setUp(() {
            when(
              () => aotTools.isGeneratePatchDiffBaseSupported(),
            ).thenAnswer((_) async => true);
            when(
              () => aotTools.generatePatchDiffBase(
                analyzeSnapshotPath: any(named: 'analyzeSnapshotPath'),
                releaseSnapshot: any(named: 'releaseSnapshot'),
              ),
            ).thenAnswer((_) async => File(''));
          });

          group('when we fail to generate patch diff base', () {
            setUp(() {
              when(
                () => aotTools.generatePatchDiffBase(
                  analyzeSnapshotPath: any(named: 'analyzeSnapshotPath'),
                  releaseSnapshot: any(named: 'releaseSnapshot'),
                ),
              ).thenThrow(Exception('oops'));

              setUpProjectRootArtifacts();
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

              verify(() => progress.fail('Exception: oops')).called(1);
            });
          });

          group('when linking and patch diff generation succeeds', () {
            const diffPath = 'path/to/diff';

            setUp(() {
              when(
                () => artifactManager.createDiff(
                  releaseArtifactPath: any(named: 'releaseArtifactPath'),
                  patchArtifactPath: any(named: 'patchArtifactPath'),
                ),
              ).thenAnswer((_) async => diffPath);
              setUpProjectRootArtifacts();
            });

            test('returns linked patch artifact in patch bundle', () async {
              final patchBundle = await runWithOverrides(
                () => patcher.createPatchArtifacts(
                  appId: appId,
                  releaseId: releaseId,
                  releaseArtifact: releaseArtifactFile,
                ),
              );

              expect(patchBundle, hasLength(1));
              expect(
                patchBundle[Arch.arm64],
                isA<PatchArtifactBundle>().having(
                  (b) => b.path,
                  'path',
                  endsWith(diffPath),
                ),
              );
            });

            group('when class table link info & debug info are present', () {
              setUp(() {
                File(
                  p.join(supplementDirectory.path, 'App.ct.link'),
                ).createSync(recursive: true);
                File(
                  p.join(supplementDirectory.path, 'App.class_table.json'),
                ).createSync(recursive: true);
              });

              test('returns linked patch artifact in patch bundle', () async {
                final patchBundle = await runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                );

                expect(patchBundle, hasLength(1));
                expect(
                  patchBundle[Arch.arm64],
                  isA<PatchArtifactBundle>().having(
                    (b) => b.path,
                    'path',
                    endsWith(diffPath),
                  ),
                );
              });

              test('sets link percentage', () async {
                expect(patcher.linkPercentage, isNull);
                await runWithOverrides(
                  () => patcher.createPatchArtifacts(
                    appId: appId,
                    releaseId: releaseId,
                    releaseArtifact: releaseArtifactFile,
                    supplementDirectory: supplementDirectory,
                  ),
                );
                expect(patcher.linkPercentage, isNotNull);
              });
            });

            group('when code signing the patch', () {
              setUp(() {
                final tempDir = Directory.systemTemp.createTempSync();
                final privateKey = File(
                  p.join(tempDir.path, 'test-private.pem'),
                )..createSync();
                final publicKey = File(p.join(tempDir.path, 'test-public.pem'))
                  ..writeAsStringSync('public-key-pem');

                when(
                  () => argResults[CommonArguments.privateKeyArg.name],
                ).thenReturn(privateKey.path);
                when(
                  () => argResults[CommonArguments.publicKeyArg.name],
                ).thenReturn(publicKey.path);

                when(
                  () => codeSigner.sign(
                    message: any(named: 'message'),
                    privateKeyPemFile: any(named: 'privateKeyPemFile'),
                  ),
                ).thenAnswer((invocation) {
                  final message = invocation.namedArguments[#message] as String;
                  return '$message-signature';
                });
                when(
                  () => codeSigner.verify(
                    message: any(named: 'message'),
                    signature: any(named: 'signature'),
                    publicKeyPem: any(named: 'publicKeyPem'),
                  ),
                ).thenReturn(true);
              });

              test(
                '''returns patch artifact bundles with proper hash signatures''',
                () async {
                  final result = await runWithOverrides(
                    () => patcher.createPatchArtifacts(
                      appId: appId,
                      releaseId: releaseId,
                      releaseArtifact: releaseArtifactFile,
                    ),
                  );

                  // Hash the patch artifacts and append '-signature' to get the
                  // expected signatures, per the mock of [codeSigner.sign]
                  // above.
                  const expectedSignature =
                      '''e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855-signature''';

                  expect(
                    result.values.first.hashSignature,
                    equals(expectedSignature),
                  );
                },
              );
            });
          });
        });

        group('when generate patch diff base is not supported', () {
          setUp(() {
            when(
              aotTools.isGeneratePatchDiffBaseSupported,
            ).thenAnswer((_) async => false);
            setUpProjectRootArtifacts();
          });

          test('returns vmcode file as patch file', () async {
            final patchBundle = await runWithOverrides(
              () => patcher.createPatchArtifacts(
                appId: appId,
                releaseId: releaseId,
                releaseArtifact: releaseArtifactFile,
              ),
            );

            expect(patchBundle, hasLength(1));
            expect(
              patchBundle[Arch.arm64],
              isA<PatchArtifactBundle>().having(
                (b) => b.path,
                'path',
                endsWith('out.vmcode'),
              ),
            );
          });
        });
      });

      group('when does not use linker', () {
        setUp(() {
          when(
            () => shorebirdEnv.flutterRevision,
          ).thenReturn(preLinkerFlutterRevision);
          when(
            () => aotTools.isGeneratePatchDiffBaseSupported(),
          ).thenAnswer((_) async => false);

          setUpProjectRootArtifacts();
        });

        test('returns base patch artifact in patch bundle', () async {
          final patchArtifacts = await runWithOverrides(
            () => patcher.createPatchArtifacts(
              appId: appId,
              releaseId: releaseId,
              releaseArtifact: releaseArtifactFile,
            ),
          );

          expect(patchArtifacts, hasLength(1));
          verifyNever(
            () => aotTools.link(
              base: any(named: 'base'),
              patch: any(named: 'patch'),
              analyzeSnapshot: any(named: 'analyzeSnapshot'),
              genSnapshot: any(named: 'genSnapshot'),
              kernel: any(named: 'kernel'),
              outputPath: any(named: 'outputPath'),
            ),
          );
        });
      });

      group('when podfile lock hash is not null', () {
        setUp(() {
          when(
            () => shorebirdEnv.iosPodfileLockHash,
          ).thenReturn('podfile-lock-hash');

          when(
            () => shorebirdEnv.flutterRevision,
          ).thenReturn(preLinkerFlutterRevision);
          when(
            () => aotTools.isGeneratePatchDiffBaseSupported(),
          ).thenAnswer((_) async => false);

          setUpProjectRootArtifacts();
        });

        test('returns patch artifact bundle with podfile lock hash', () async {
          final patchBundle = await runWithOverrides(
            () => patcher.createPatchArtifacts(
              appId: appId,
              releaseId: releaseId,
              releaseArtifact: releaseArtifactFile,
            ),
          );

          expect(patchBundle, hasLength(1));
          expect(
            patchBundle[Arch.arm64],
            isA<PatchArtifactBundle>().having(
              (b) => b.podfileLockHash,
              'podfileLockHash',
              equals('podfile-lock-hash'),
            ),
          );
        });
      });

      group('when podfile lock hash is null', () {
        setUp(() {
          when(() => shorebirdEnv.iosPodfileLockHash).thenReturn(null);

          when(
            () => shorebirdEnv.flutterRevision,
          ).thenReturn(preLinkerFlutterRevision);
          when(
            () => aotTools.isGeneratePatchDiffBaseSupported(),
          ).thenAnswer((_) async => false);

          setUpProjectRootArtifacts();
        });

        test(
          'returns patch artifact bundle without podfile lock hash',
          () async {
            final patchBundle = await runWithOverrides(
              () => patcher.createPatchArtifacts(
                appId: appId,
                releaseId: releaseId,
                releaseArtifact: releaseArtifactFile,
              ),
            );

            expect(patchBundle, hasLength(1));
            expect(
              patchBundle[Arch.arm64],
              isA<PatchArtifactBundle>().having(
                (b) => b.podfileLockHash,
                'podfileLockHash',
                isNull,
              ),
            );
          },
        );
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
      setUp(() {
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
      });

      group('when xcarchive directory does not exist', () {
        setUp(() {
          when(() => artifactManager.getXcarchiveDirectory()).thenReturn(null);
        });

        test('exit with code 70', () async {
          await expectLater(
            () => runWithOverrides(
              () => patcher.extractReleaseVersionFromArtifact(File('')),
            ),
            exitsWithCode(ExitCode.software),
          );
        });
      });

      group('when Info.plist does not exist', () {
        setUp(() {
          try {
            File(
              p.join(
                projectRoot.path,
                'build',
                'ios',
                'framework',
                'Release',
                'App.xcframework',
                'Info.plist',
              ),
            ).deleteSync(recursive: true);
          } on Exception {
            // ignore
          }
        });

        test('exit with code 70', () async {
          await expectLater(
            () => runWithOverrides(
              () => patcher.extractReleaseVersionFromArtifact(File('')),
            ),
            exitsWithCode(ExitCode.software),
          );
        });
      });

      group('when empty Info.plist does exist', () {
        setUp(() {
          File(
              p.join(
                projectRoot.path,
                'build',
                'ios',
                'framework',
                'Release',
                'App.xcframework',
                'Info.plist',
              ),
            )
            ..createSync(recursive: true)
            ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict></dict>
</plist>
''');
        });

        test('exits with code 70 and logs error', () async {
          await expectLater(
            runWithOverrides(
              () => patcher.extractReleaseVersionFromArtifact(File('')),
            ),
            exitsWithCode(ExitCode.software),
          );
          verify(
            () => logger.err(
              any(that: startsWith('Failed to determine release version')),
            ),
          ).called(1);
        });
      });

      group('when Info.plist does exist', () {
        setUp(() {
          File(
              p.join(
                projectRoot.path,
                'build',
                'ios',
                'framework',
                'Release',
                'App.xcframework',
                'Info.plist',
              ),
            )
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
