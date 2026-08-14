import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/dart_define_from_file.dart';
import 'package:shorebird_cli/src/commands/release/apple_releaser_mixin.dart';
import 'package:shorebird_cli/src/commands/release/releaser.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/flutter_injected_defines.dart';
import 'package:shorebird_cli/src/flutter_version_constraints.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform/apple/apple.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/route_b.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_compiler_cache.dart';
import 'package:shorebird_cli/src/route_b_provenance.dart';
import 'package:shorebird_cli/src/route_b_release_kernels.dart';
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/validators/validators.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// {@template ios_releaser}
/// Functions to build and publish an iOS release.
/// {@endtemplate}
class IosReleaser extends Releaser with AppleReleaserMixin {
  /// {@macro ios_releaser}
  IosReleaser({
    required super.argResults,
    required super.flavor,
    required super.target,
  });

  /// Whether to codesign the release.
  bool get codesign => argResults['codesign'] == true;

  @override
  ReleaseType get releaseType => ReleaseType.ios;

  @override
  String get supplementPlatformSubdir => 'ios';

  @override
  String get supplementArtifactArch => 'ios_supplement';

  @override
  String get artifactDisplayName => 'iOS app';

  @override
  List<Validator> get applePlatformValidators => doctor.iosCommandValidators;

  @override
  Future<void> assertArgsAreValid() async {
    assertReleaseVersionFlagNotProvided();

    await assertObfuscationIsSupported();

    final exportOptionsPlistFile = argResults.file(
      CommonArguments.exportOptionsPlistArg.name,
    );
    if (exportOptionsPlistFile != null) {
      try {
        assertValidExportOptionsPlist(exportOptionsPlistFile);
      } on InvalidExportOptionsPlistException catch (error) {
        logger.err(error.message);
        throw ProcessExit(ExitCode.usage.code);
      }
    }
  }

  @override
  Version? get minimumFlutterVersion => minimumSupportedIosFlutterVersion;

  @override
  Future<FileSystemEntity> buildReleaseArtifacts() async {
    if (!codesign) {
      logger
        ..info(
          '''Building for device with codesigning disabled. You will have to manually codesign before deploying to device.''',
        )
        ..warn(
          '''shorebird preview will not work for releases created with "--no-codesign". However, you can still preview your app by signing the generated .xcarchive in Xcode.''',
        )
        ..warn(
          '''
When you distribute the .xcarchive in Xcode, you MUST uncheck "Manage Version and Build Number" in the Distribute App dialog.

If left checked, Xcode will rewrite the build number in the uploaded IPA, so the version that ships to App Store Connect will not match the version Shorebird recorded for this release. Patches will then fail to apply.''',
        );
    }

    // Delete the Shorebird supplement directory if it exists.
    // This is to ensure that we don't accidentally upload stale artifacts
    // when building with older versions of Flutter.
    final shorebirdSupplementDir = artifactManager
        .getIosReleaseSupplementDirectory();
    if (shorebirdSupplementDir?.existsSync() ?? false) {
      shorebirdSupplementDir!.deleteSync(recursive: true);
    }

    final base64PublicKey = await getEncodedPublicKey();

    final buildArgs = [...argResults.forwardedArgs];
    addSplitDebugInfoDefault(buildArgs);
    await addObfuscationMapArgs(buildArgs);
    final wantsPatchableCalls = _addPatchableCallArgs(buildArgs);

    // Route B retention, declared BEFORE the build that must honour it.
    //
    // A dynamic interface is generated from a kernel, and the kernel a release
    // ships comes from this very build — so the circle is broken with a
    // kernel-only PREPASS rather than by building the whole IPA twice and
    // throwing one away. The extra cost is one frontend compilation.
    final routeBCompiler = isRouteBEngine(_routeBEngineBinary)
        ? await _resolveReleaseTooling()
        : null;
    if (routeBCompiler != null) {
      await _declareRetention(routeBCompiler, buildArgs);
    }

    final buildResult = await artifactBuilder.buildIpa(
      codesign: codesign,
      flavor: flavor,
      target: target,
      args: buildArgs,
      base64PublicKey: base64PublicKey,
      ddMaxBytes: ddMaxBytes,
    );

    verifyObfuscationMap();

    final xcarchiveDirectory = artifactManager.getXcarchiveDirectory();
    if (xcarchiveDirectory == null) {
      logger.err('Unable to find .xcarchive directory');
      throw ProcessExit(ExitCode.software.code);
    }

    final appDirectory = artifactManager.getIosAppDirectory(
      xcarchiveDirectory: xcarchiveDirectory,
    );

    if (appDirectory == null) {
      logger.err('Unable to find .app directory');
      throw ProcessExit(ExitCode.software.code);
    }

    if (wantsPatchableCalls) {
      _verifyPatchableRelease(appDirectory);
    }

    // Independent of who asked for the flag: a release built by a Route B
    // engine records which engine that was, whether the flag came from us or
    // from the caller's own --extra-gen-snapshot-options.
    if (routeBCompiler != null) {
      await _recordRouteBProvenance(
        routeBCompiler,
        appDirectory,
        buildResult.kernelFile,
        buildArgs,
      );
    }

    // When code signing is requested (the default), `flutter build ipa` is
    // expected to export a signed .ipa. Flutter treats the export step as
    // optional and exits 0 even when it fails (e.g. no signing certificate),
    // so we must verify the .ipa was actually produced. Otherwise we would
    // report a successful release and point the user at an .ipa that does not
    // exist. See https://github.com/shorebirdtech/shorebird/issues/3807.
    if (codesign) {
      final ipa = artifactManager.getIpa();
      // EXISTING IS NOT ENOUGH — IT MUST BE THIS BUILD'S. The export writes into
      // build/ios/ipa, which is not cleared between runs, so a failed export
      // leaves the PREVIOUS release's .ipa sitting there passing a presence
      // check. That is not hypothetical: a release published here with its
      // predecessor's .ipa as its stored artifact, and nothing said so.
      //
      // The .xcarchive was produced moments ago by this same invocation, so an
      // .ipa exported from it cannot be older. One that is, is a leftover.
      // Only when the file can actually be stat'd: the presence check keeps its
      // existing meaning otherwise, and this adds a refusal rather than
      // changing what counts as present.
      final stale =
          ipa != null &&
          ipa.existsSync() &&
          ipa.lastModifiedSync().isBefore(
            xcarchiveDirectory.statSync().modified,
          );
      if (ipa == null || stale) {
        logger.err(
          stale
              ? '''
Found an .ipa older than the .xcarchive this build just produced:

  ${ipa.path}

It is left over from an earlier build, so the IPA export step of "flutter build ipa" must have failed for this one (for example, due to a missing or invalid code signing certificate). Review the build output above for the underlying error. Releasing would upload the earlier build's .ipa.

Delete it and re-run, or if you do not need a signed IPA (for example, you will sign the .xcarchive in Xcode), re-run this command with --no-codesign.'''
              : '''
Unable to find generated IPA. This usually means that the IPA export step of "flutter build ipa" failed (for example, due to a missing or invalid code signing certificate). Review the build output above for the underlying error.

If you do not need a signed IPA (for example, you will sign the .xcarchive in Xcode), re-run this command with --no-codesign.''',
        );
        throw ProcessExit(ExitCode.software.code);
      }
    }

    return xcarchiveDirectory;
  }

  /// The interface this release declared its retention with, if any.
  File? _retentionInterface;

  /// How this release's retention was actually produced, if it was.
  ///
  /// The interface says WHAT was retained; this says which kernel supplied the
  /// private half, whether the import/prepass agreement passed, and why it fell
  /// back if it did. It travels with the release so a later patch reasons about
  /// the contract this release really emitted rather than the one policy promises.
  File? _retentionEvidence;

  /// The capability set this release granted, per target, if it recorded one.
  ///
  /// The patch side accepts a private reference against THIS. Null means the
  /// release granted nothing provable, which refuses private references rather
  /// than permitting them.
  File? _retentionManifest;

  /// The iOS engine binary this build will link against.
  File get _routeBEngineBinary => File(
    p.join(
      shorebirdEnv.flutterDirectory.path,
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
  );

  /// Record, with the release, which engine built it.
  ///
  /// This is the only moment the engine hash is knowable and true. At patch
  /// time `shorebirdEnv.shorebirdEngineRevision` reads `engine.version` out of
  /// the Flutter checkout, a mutable local file this fork's own scripts rewrite
  /// to switch experimental engines — and fifteen engine hashes share the one
  /// pinned Flutter revision, so `release.flutterRevision` cannot recover it
  /// either. Written into the supplement, it travels with the release as bytes
  /// and stops being a fact about whoever runs `shorebird patch`.
  ///
  /// See `route_b_provenance.dart` for why the supplement rather than a field
  /// on the release.
  /// The flavor that actually reaches the compiler, by Flutter's precedence.
  ///
  /// `--flavor` if given, else `pubspec.yaml`'s `default-flavor` — a release can be
  /// flavored with nothing on the command line, and reading only the flag would
  /// record "no flavor" for it. Nothing in this CLI read `default-flavor` before
  /// G4.2, which is exactly why that path had no way to be noticed.
  String? get _resolvedFlavor => RouteBBuildConfig.resolveFlavor(
    cliFlavor: flavor,
    pubspecFlutterSection: shorebirdEnv.getPubspecYaml()?.flutter,
  );

  /// [_resolvedFlavor], spelled the way the SHIPPED kernel will spell it.
  ///
  /// On iOS, Flutter does not put the token you typed into
  /// `FLUTTER_APP_FLAVOR`. It parses the flavor from the Xcode CONFIGURATION and
  /// returns the SCHEME's own casing (`common.dart`'s
  /// `_addFlavorToDartDefines`, `xcode_project.dart`'s
  /// `parseFlavorFromConfiguration`). So `--flavor foo` against a scheme named
  /// `Foo` ships a kernel compiled with `FLUTTER_APP_FLAVOR=Foo`.
  ///
  /// Route B compiles its own kernels, so using the token here would describe a
  /// DIFFERENT Dart program than the one that ships — the same defect G4.2
  /// closed for the define's KEY, still open in its VALUE. Resolved once and
  /// cached: the lookup shells out to `xcodebuild -list`.
  late final Future<String?> _appleFlavor = _resolveAppleFlavor();

  Future<String?> _resolveAppleFlavor() async {
    final resolved = _resolvedFlavor;
    if (resolved == null || resolved.isEmpty) return resolved;
    final root = shorebirdEnv.getFlutterProjectRoot();
    if (root == null) return resolved;
    return xcodeBuild.flavorScheme(
      projectPath: p.join(root.path, 'ios', 'Runner.xcodeproj'),
      flavor: resolved,
    );
  }

  /// Checks this build's `--dart-define-from-file` expansion against the define
  /// set FLUTTER ITSELF resolved for this same build, and returns the reason to
  /// decline, or null when there is nothing to decline about.
  ///
  /// WHY A RELEASE-TIME CHECK AND NOT A UNIT TEST. Expanding the option means
  /// porting Flutter's `.json`/`.env` parser, and a port that is merely tested
  /// against its author's idea of the rules is exactly the hand-reconstruction
  /// this design refused for two releases. What makes the option supportable is
  /// that Flutter writes its own answer to `ios/Flutter/Generated.xcconfig`
  /// (`DART_DEFINES`, base64 `K=V` — `build_info.dart:396`), so every release
  /// that uses the option is measured rather than trusted. `probes/g41b_define_from_file.sh`
  /// is the same comparison run against a fixture; this is it run against the
  /// user's real build.
  ///
  /// DECLINING IS THE SAFE DIRECTION, and it lands exactly where this option
  /// already was: no Route B artifacts and `buildConfig: null`, which the patch
  /// side already handles as "permanently not comparable". So a wrong expansion
  /// costs patchability, never a wrong patch.
  /// The defines Flutter injects into this build, read from Flutter's own
  /// answer and shared by all three Route B kernels.
  ///
  /// Resolved ONCE, for the same reason the compiler cell is: the prepass, the
  /// early import kernel and the supplement's import kernel must describe one
  /// program, and three independent reads are three chances to describe three.
  Map<String, String>? _injectedDefines;

  /// Asks Flutter to resolve this build's defines without building anything.
  ///
  /// WHY FLUTTER IS ASKED RATHER THAN IMITATED. The six values are not derivable
  /// from anything this CLI already knows, and each has a failure mode that
  /// produces a plausible wrong answer — `FLUTTER_ENGINE_REVISION` in particular
  /// comes from the engine's own `engine_stamp.json` and is NOT
  /// `shorebirdEnv.shorebirdEngineRevision`. `flutter_injected_defines.dart`
  /// records each trap with its source line.
  ///
  /// `--config-only` is what makes asking cheap: the `configOnly` early return
  /// (`ios/mac.dart:375`) sits AFTER `updateGeneratedXcodeProperties` (`:347`),
  /// so Flutter writes its resolved `DART_DEFINES` and stops before compiling.
  ///
  /// No user define arguments are passed, deliberately: `_addFlutterVersionToDartDefines`
  /// and `_addFeatureFlagsToDartDefines` read only `globals.flutterVersion` and
  /// `flutter config`, never a build argument, so the injected set is invariant
  /// across them — and forwarding a `--dart-define-from-file` here would make a
  /// bad file fail this step instead of the check that exists to report it.
  Future<Map<String, String>?> _resolveInjectedDefines() async {
    final root = shorebirdEnv.getFlutterProjectRoot();
    if (root == null) return null;

    final ShorebirdProcessResult result;
    try {
      result = await process.run('flutter', [
        'build',
        'ios',
        '--config-only',
        '--no-codesign',
      ], workingDirectory: root.path);
    } on Exception {
      return null;
    }
    if (result.exitCode != 0) return null;

    return FlutterInjectedDefines.fromGeneratedXcconfig(
      File(p.join(root.path, 'ios', 'Flutter', 'Generated.xcconfig')),
    );
  }

  /// Whether the injected defines the kernels were compiled with are still the
  /// ones Flutter used for the REAL build, which rewrote the same file.
  ///
  /// This is what keeps the pre-build read from being a guess. It is the same
  /// shape as [_defineExpansionDisagreement] and lands in the same place: a
  /// disagreement costs patchability, never correctness.
  String? _injectedDefineDisagreement() {
    final used = _injectedDefines;
    if (used == null) return null;

    final root = shorebirdEnv.getFlutterProjectRoot();
    if (root == null) return null;
    final shipped = FlutterInjectedDefines.fromGeneratedXcconfig(
      File(p.join(root.path, 'ios', 'Flutter', 'Generated.xcconfig')),
    );
    if (shipped == null) {
      return "Flutter's injected defines could not be re-read after the build";
    }

    final disagreeing = <String>[
      for (final key in {...used.keys, ...shipped.keys})
        if (used[key] != shipped[key]) key,
    ]..sort();
    if (disagreeing.isEmpty) return null;
    return 'the defines Flutter injected changed between this release\'s '
        'kernels and its build, on: ${disagreeing.join(', ')}';
  }

  String? _defineExpansionDisagreement(List<String> buildArgs) {
    if (DartDefineFromFileExpansion.pathsIn(buildArgs).isEmpty) return null;

    final expansion = DartDefineFromFileExpansion.expand(buildArgs);
    if (!expansion.ok) return expansion.failureReason;

    final root = shorebirdEnv.getFlutterProjectRoot();
    if (root == null) {
      return 'the project root could not be found, so the expansion could not '
          'be checked against Flutter';
    }
    final resolved = DartDefineFromFileExpansion.decodeGeneratedXcconfig(
      File(p.join(root.path, 'ios', 'Flutter', 'Generated.xcconfig')),
    );
    if (resolved == null) {
      return "Flutter's own resolved define set could not be read from "
          'ios/Flutter/Generated.xcconfig';
    }

    // FLUTTER_APP_FLAVOR is exempt on evidence, not by convenience: Flutter
    // rewrites it at the xcodebuild stage from the Xcode CONFIGURATION, which
    // returns the SCHEME's casing, AFTER this file was written from the CLI
    // token. Measured on `selfhost/fixtures/flavored_app` — the xcconfig says
    // `foo` for the build whose shipped kernel contains `Foo`. The flavor has
    // its own threading and its own probe; it is not this check's subject.
    final disagreeing = expansion.disagreementWith(
      resolved,
      exempt: const {'FLUTTER_APP_FLAVOR'},
    );
    if (disagreeing.isEmpty) return null;
    return 'this build expanded --dart-define-from-file differently than '
        'Flutter did, on: ${disagreeing.join(', ')}';
  }

  Future<void> _recordRouteBProvenance(
    RouteBCompiler compiler,
    Directory appDirectory,
    File releaseKernel,
    List<String> buildArgs,
  ) async {
    final supplement = artifactManager.getReleaseSupplementDirectory(
      platformSubdir: supplementPlatformSubdir,
      create: true,
    );
    if (supplement == null) {
      // No project root: nothing downstream can upload a supplement either.
      logger.warn(
        '''Could not record which engine built this release; patches for it will be refused.''',
      );
      return;
    }

    final appBinary = File(
      p.join(appDirectory.path, 'Frameworks', 'App.framework', 'App'),
    );
    final counted = appBinary.existsSync()
        ? countPatchableCallSites(appBinary)
        : (sites: 0, perMiB: 0.0);

    // The kernel THIS build compiled, taken from this build's own output.
    // A patch's coverage analysis diffs against it, so a kernel regenerated
    // from the same source at patch time would answer the wrong question --
    // "what differs from a kernel I just built" rather than "what differs from
    // what shipped". Captured here, while it is unambiguously the release's.
    // Measured before anything is recorded, because its answer decides whether
    // this release is patchable at all.
    final defineDisagreement =
        _defineExpansionDisagreement(buildArgs) ??
        // G4.1c: the injected map was read from a `--config-only` pass BEFORE
        // this build. The real build rewrote the same file, so this is the read
        // that turns the earlier one from a guess into a measurement.
        _injectedDefineDisagreement();

    final artifacts = <String, String>{};
    if (defineDisagreement != null) {
      // Not fatal, and deliberately identical to how this option behaved before
      // it was supported: the app is fine and installable, it simply cannot be
      // patched. What is new is that the reason is MEASURED and named, rather
      // than being a standing refusal for the whole option.
      logger.warn(
        '''Patches for this release will be refused: $defineDisagreement.''',
      );
    } else if (releaseKernel.existsSync()) {
      artifacts[routeBReleaseKernelFileName] = captureRouteBReleaseKernel(
        supplement,
        releaseKernel,
      );
      // The second kernel, produced by the RELEASE ENGINE's own frontend rather
      // than by whatever this machine has. Both release kernels then come from
      // one lineage as a matter of structure, not of who ran the build.
      // The interface travels with the release for the patch build to reuse.
      if (_retentionInterface case final interface?) {
        artifacts[routeBInterfaceFileName] = captureRouteBReleaseKernel(
          supplement,
          interface,
          as: routeBInterfaceFileName,
        );
      }
      // Travels with the interface, because the two are only meaningful together:
      // the interface is the emitted set, this is how it came to be that set.
      if (_retentionEvidence case final evidence?) {
        artifacts[routeBRetentionEvidenceFileName] = captureRouteBReleaseKernel(
          supplement,
          evidence,
          as: routeBRetentionEvidenceFileName,
        );
      }
      // The capability set itself, which is what the patch side gates on. It is
      // in `artifacts` so its hash is provenance-covered like every other
      // release artifact: a manifest that could be edited between release and
      // patch would be a way to grant capabilities the release never emitted.
      if (_retentionManifest case final capabilities?) {
        artifacts[routeBCapabilityManifestFileName] =
            captureRouteBReleaseKernel(
              supplement,
              capabilities,
              as: routeBCapabilityManifestFileName,
            );
      }
      await _captureImportKernel(
        compiler: compiler,
        supplement: supplement,
        releaseKernel: releaseKernel,
        buildArgs: buildArgs,
        artifacts: artifacts,
      );
    } else {
      // Not fatal at release time: the release itself is fine and installable.
      // It simply cannot be patched, and the patch side says so by name.
      logger.warn(
        '''Could not capture this release's kernel (${releaseKernel.path}); patches for it will be refused.''',
      );
    }

    final engineRevision = shorebirdEnv.shorebirdEngineRevision;
    final file = writeRouteBReleaseProvenance(
      supplement,
      RouteBReleaseProvenance(
        engineRevision: engineRevision,
        flutterRevision: shorebirdEnv.flutterRevision,
        patchableCallSites: counted.sites,
        patchableCallSitesPerMiB: counted.perMiB,
        artifacts: artifacts,
        // G4.1. Captured from the SAME buildArgs the release compiled with,
        // at the one moment they are unambiguously this release's. Null when the
        // release's effective define set could not be established — which since
        // `--dart-define-from-file` became supported means the expansion
        // DISAGREED with Flutter's own, not that the option was used. The patch
        // side distinguishes null from an empty-but-known configuration, which
        // is comparable.
        buildConfig: defineDisagreement != null
            ? null
            : RouteBBuildConfig.fromBuildArgs(
                buildArgs,
                flavor: await _appleFlavor,
              ),
      ),
    );
    logger.detail(
      '[route-b] recorded engine $engineRevision and '
      '${artifacts.length} artifact(s) in ${file.path}',
    );
  }

  /// Produce and record the release's `--no-aot` kernel.
  ///
  /// Every failure here degrades to "this release is not patchable" with a
  /// named reason, never to a release that fails to publish: the app itself is
  /// fine and installable, and refusing to ship it because a patch-time input
  /// could not be prepared would be the wrong trade. The patch side reports the
  /// absence precisely.
  Future<void> _captureImportKernel({
    required RouteBCompiler compiler,
    required Directory supplement,
    required File releaseKernel,
    required List<String> buildArgs,
    required Map<String, String> artifacts,
  }) async {
    final builder = routeBReleaseKernelBuilder;
    final importKernel = builder.build(
      compiler: compiler,
      projectRoot: projectRoot,
      // The release's own entrypoint, not a guess at one. `flutter build ipa`
      // was handed exactly this.
      entrypoint: target ?? p.join('lib', 'main.dart'),
      buildArgs: buildArgs,
      // G4.1c: a patch BINDS against this kernel, so it carries the same
      // injected defines the release compiled with -- the map read before the
      // prepass, so all three kernels describe one program.
      injectedDefines: _injectedDefines,
      // G4.2: a patch BINDS against this kernel, so it must carry the release's
      // flavor too.
      flavor: await _appleFlavor,
      outputFile: File(
        p.join(supplement.path, routeBReleaseImportKernelFileName),
      ),
    );
    if (importKernel == null) return;

    // Forwarding the release's inputs correctly is a promise until it is
    // checked. If the two kernels disagree about what the program contains,
    // this release must not advertise itself as patchable.
    if (!builder.agreesWith(
      compiler: compiler,
      importKernel: importKernel,
      aotKernel: releaseKernel,
    )) {
      importKernel.deleteSync();
      return;
    }

    artifacts[routeBReleaseImportKernelFileName] = captureRouteBReleaseKernel(
      supplement,
      importKernel,
      as: routeBReleaseImportKernelFileName,
    );
  }

  /// The compiler cell belonging to the engine this release is being built
  /// with, or null if it cannot be resolved.
  ///
  /// Resolved ONCE and threaded, so the retention interface, the import kernel
  /// and the patch-time compiler are provably one lineage rather than three
  /// lookups that happen to agree.
  Future<RouteBCompiler?> _resolveReleaseTooling() async {
    try {
      return await routeBCompilerResolver.resolve(
        engineRevision: shorebirdEnv.shorebirdEngineRevision,
      );
    } on Exception catch (error) {
      logger.warn(
        '''Could not resolve this engine's Route B tooling ($error); this release will not be patchable.''',
      );
      return null;
    }
  }

  /// Run the kernel prepass, generate the retention interface, and point the
  /// real build at it.
  ///
  /// Every failure degrades to "this release retains nothing extra" with a
  /// named reason. The app is fine and installable either way; what is lost is
  /// the ability to patch it with a body that names a symbol.
  Future<void> _declareRetention(
    RouteBCompiler compiler,
    List<String> buildArgs,
  ) async {
    final work = Directory(
      p.join(shorebirdEnv.buildDirectory.path, 'route_b'),
    );
    final builder = routeBReleaseKernelBuilder;

    // G4.1c: read BEFORE the prepass, because the prepass decides retention and
    // must describe the program the release ships. Flutter injects six defines
    // into every build -- measured on an app with no flavor and no
    // `--dart-define` at all -- and until this landed no Route B kernel had any
    // of them.
    _injectedDefines = await _resolveInjectedDefines();
    if (_injectedDefines == null) {
      // Degrade the way every other Route B failure degrades: a NARROWER
      // release, never a failed one. Returning here means no prepass, no
      // interface and no import kernel, which the patch side already reports as
      // "not patchable". The alternative -- compiling with an empty injected set
      // -- is exactly the bug this closes, done silently.
      logger.warn(
        '''Could not read the defines Flutter injects into this build, so this release's retention was not declared; patches for it will be refused.''',
      );
      return;
    }

    final prepass = builder.buildPrepass(
      compiler: compiler,
      projectRoot: projectRoot,
      entrypoint: target ?? p.join('lib', 'main.dart'),
      buildArgs: buildArgs,
      injectedDefines: _injectedDefines,
      // G4.2: the prepass decides RETENTION, so it must describe the same program
      // the release ships. Without this it was compiled with no
      // FLUTTER_APP_FLAVOR while the release had one.
      flavor: await _appleFlavor,
      outputFile: File(p.join(work.path, 'prepass.dill')),
    );
    if (prepass == null) return;

    // THE PRIVATE-ENUMERATION SOURCE, decided here and recorded, because the
    // analyzer must later read what this release actually did rather than infer
    // it from a policy name.
    //
    // The import kernel is built BEFORE the interface, which is a reordering: it
    // is the only kernel with the full private surface, since the prepass has been
    // tree-shaken. It is also the kernel a patch will be built against, so if the
    // two disagree the private names taken from it would describe a program the
    // release does not contain.
    //
    // THE INVARIANT THIS PROTECTS: a disagreement may REDUCE PATCHABILITY, and
    // must never turn into a failed release. So this path has no fatal branch --
    // every outcome produces an interface and continues.
    //
    // Built into `work/`, deliberately NOT reusing or pre-empting the supplement
    // copy that `_captureImportKernel` makes after the real build. That costs one
    // extra kernel compile per release, and the alternative is a kernel produced
    // before `flutter build ipa` standing in for one produced after it, which is
    // exactly the divergence being guarded against.
    final earlyImport = builder.build(
      compiler: compiler,
      projectRoot: projectRoot,
      entrypoint: target ?? p.join('lib', 'main.dart'),
      buildArgs: buildArgs,
      // G4.1c: the same map the prepass used, not a second read. `agreesWith`
      // compares these two kernels, so a divergence here would fall back to
      // prepass-only private enumeration SILENTLY -- the narrowing f06fa056
      // already had to close once for the flavor.
      injectedDefines: _injectedDefines,
      // G4.2, and this call site was MISSED by the commit that made the rule.
      // 25f8a3b8 says it threaded the flavor into "all three places that decide
      // what a patch is checked and bound against" — but cd453304 had already
      // created a FOURTH, and this is it. The consequence is specific to what
      // this kernel is for: it is the private-ENUMERATION source, so
      // without the define a flavored release would name its private
      // surface from a kernel
      // compiled against a different Dart program than the one it shipped, and
      // would then compare that kernel against a prepass that does carry the
      // define. Both halves of the guard read the wrong program.
      //
      // It cannot fail a release — every branch below falls back — which is
      // exactly what makes it worth pinning: the failure mode is a SILENT
      // narrowing back to prepass-only enumeration, and prepass-only
      // enumeration is the thing that does not build on a real app
      // (PARITY.md section 4).
      //
      // It must be `_appleFlavor`, NOT `_resolvedFlavor`, and the difference is
      // not cosmetic. The prepass above spells the flavor the way the SHIPPED
      // kernel spells it — Flutter parses it from the Xcode CONFIGURATION and
      // returns the SCHEME's casing, so `--flavor foo` against scheme `Foo`
      // ships `FLUTTER_APP_FLAVOR=Foo`. `agreesWith` below compares THIS kernel
      // against THAT prepass, so spelling them differently makes the two
      // disagree on a flavored release whose scheme casing differs from the
      // typed token — and a disagreement falls back to prepass-only
      // enumeration, silently, which is the exact defect this call site was
      // added to close.
      flavor: await _appleFlavor,
      outputFile: File(p.join(work.path, 'early_import.dill')),
    );

    File? privateEnumerationKernel;
    final String enumerationSource;
    final String? fallbackReason;
    if (earlyImport == null) {
      enumerationSource = 'prepass';
      fallbackReason =
          'the import kernel could not be built before the release';
    } else if (!builder.agreesWith(
      compiler: compiler,
      importKernel: earlyImport,
      aotKernel: prepass,
      consequence:
          'private enumeration falls back to the release prepass, so this '
          'release will retain a narrower set of private members',
    )) {
      enumerationSource = 'prepass';
      fallbackReason =
          'the import kernel and the release prepass do not describe the same '
          'program';
    } else {
      privateEnumerationKernel = earlyImport;
      enumerationSource = 'import';
      fallbackReason = null;
    }

    // THE CAPABILITY MANIFEST, generated with the interface and by the same
    // pass. It is what the PATCH side accepts a private reference against, so
    // it describes this release's emitted set rather than the policy's intent
    // -- the two diverge exactly when the fallback above happens.
    final manifest = File(p.join(work.path, routeBCapabilityManifestFileName));
    final interface = builder.generateDynamicInterface(
      compiler: compiler,
      prepassKernel: prepass,
      outputFile: File(p.join(work.path, 'dynamic_interface.yaml')),
      privateEnumerationKernel: privateEnumerationKernel,
      manifestFile: manifest,
    );
    if (interface == null) return;
    // Only if it was actually written. A generator too old to know --manifest
    // succeeds and emits nothing, and an absent manifest must read as "granted
    // nothing provable" rather than as an empty grant.
    if (manifest.existsSync()) _retentionManifest = manifest;

    // THE CONCRETE CONTRACT, written beside the interface and captured with it.
    //
    // G3.6b consumes THIS, not the policy: an analyzer that accepted a private
    // reference because "private members are supported" would accept one this
    // release fell back and never retained. The interface itself is the exact
    // emitted set; this records which kernel produced it and why.
    _retentionEvidence = File(p.join(work.path, 'retention.json'))
      ..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'privateEnumerationSource': enumerationSource,
          'importPrepassAgreement': earlyImport == null
              ? 'not-checked'
              : (fallbackReason == null ? 'passed' : 'failed'),
          if (fallbackReason != null) 'fallbackReason': fallbackReason,
          'interfaceBytes': interface.lengthSync(),
        }),
      );
    if (fallbackReason != null) {
      logger.info(
        '''Route B retention: narrower contract — private members enumerated from the release prepass because $fallbackReason. The release is unaffected; patches referencing a private member the release does not itself use will be refused.''',
      );
    }

    // Kept for the supplement: the PATCH build has to compile against the same
    // interface, or its kernel and the release's disagree about almost every
    // member and coverage refuses a one-line change.
    _retentionInterface = interface;

    // Reaches the release's kernel through Flutter's own pass-through, so the
    // ONE real build honours it. frontend_server owns the flag.
    // `--extra-front-end-options`, hyphenated exactly like that. Flutter
    // rejects `--extra-frontend-options` with "Could not find an option named",
    // which surfaces as a failed build long after the prepass has succeeded.
    buildArgs.add(
      '--extra-front-end-options=--dynamic-interface=${interface.path}',
    );

    // The tax, every release, so a widening cannot go unnoticed. Named SDK
    // retention measured at +0.006-0.009 % on the A0 probe; a whole `dart:core`
    // library item measured at +310 %, which is why this list is names.
    logger.info(
      '''Route B retention: ${routeBRetainedSdkMembers.length} named SDK members, interface ${interface.lengthSync()} bytes.''',
    );
  }

  /// Ask gen_snapshot for the patchable call form, on engines that can use it.
  ///
  /// Route B redirects a shipped AOT call site to attached bytecode by making
  /// the call dispatch through the callee's `Function`. That is off by default,
  /// so a release built without it CANNOT be patched -- and the failure is
  /// silent in the worst way: the patch installs, validates, resolves its
  /// target and attaches successfully, and the app's behaviour is unchanged,
  /// because AOT emitted a direct call that never reads
  /// `Function.entry_point_`.
  ///
  /// Only added for an engine that actually carries the interpreter. On a stock
  /// engine the flag would cost size (~+4.5% on the reference app) and buy
  /// nothing, since there is no `InterpretCall` for an attached function to
  /// enter through.
  ///
  /// Returns whether the release is expected to come out patchable, which is
  /// what [_verifyPatchableRelease] is then entitled to insist on.
  bool _addPatchableCallArgs(List<String> buildArgs) {
    if (!isRouteBEngine(_routeBEngineBinary)) return false;

    // Respect an explicit choice. Someone measuring the flag's cost, or
    // deliberately shipping a non-patchable build on a Route B engine, must be
    // able to; we just will not verify what they did not ask for.
    if (buildArgs.any((a) => a.contains('patchable_static_calls'))) {
      return false;
    }

    logger.info(
      '''This engine supports iOS Dart code push, so this release is being built with patchable call sites (~+4.5% app size). Without them a patch would install and change nothing.''',
    );
    buildArgs.add('--extra-gen-snapshot-options=--patchable_static_calls');
    return true;
  }

  /// Refuse to publish a release that cannot actually be patched.
  ///
  /// Passing the flag and the flag taking effect are different claims, and only
  /// the second is observable in the bytes that ship. Checking the built binary
  /// catches a stale artifact cache, an engine that ignored the option, and a
  /// future change to the call form -- none of which any log would report.
  void _verifyPatchableRelease(Directory appDirectory) {
    final appBinary = File(
      p.join(appDirectory.path, 'Frameworks', 'App.framework', 'App'),
    );
    if (!appBinary.existsSync()) {
      logger.warn(
        '''Could not find ${appBinary.path} to verify patchable call sites; this release may not be patchable.''',
      );
      return;
    }

    final result = countPatchableCallSites(appBinary);
    if (result.perMiB >= routeBPatchableSitesPerMiBThreshold) {
      logger.detail(
        '''Verified patchable call sites: ${result.sites} (${result.perMiB.round()}/MiB).''',
      );
      return;
    }

    logger.err(
      '''
This release was built with patchable call sites requested, but the compiled app does not contain them (${result.sites} sites, ${result.perMiB.round()}/MiB).

Publishing it would produce a release that accepts patches and ignores them: a patch would install, report success, and never change what the app does.

This usually means a stale engine artifact cache. Try:
  ${lightCyan.wrap('shorebird cache clean')}''',
    );
    throw ProcessExit(ExitCode.software.code);
  }

  @override
  Future<String> getReleaseVersion({
    required FileSystemEntity releaseArtifactRoot,
  }) async {
    final plistFile = File(p.join(releaseArtifactRoot.path, 'Info.plist'));
    if (!plistFile.existsSync()) {
      logger.err('No Info.plist file found at ${plistFile.path}');
      throw ProcessExit(ExitCode.software.code);
    }

    try {
      return Plist(file: plistFile).versionNumber;
    } on Exception catch (error) {
      logger.err(
        '''Failed to determine release version from ${plistFile.path}: $error''',
      );
      throw ProcessExit(ExitCode.software.code);
    }
  }

  @override
  Future<void> uploadReleaseArtifacts({
    required Release release,
    required String appId,
  }) async {
    final xcarchiveDirectory = artifactManager.getXcarchiveDirectory()!;
    await codePushClientWrapper.createIosReleaseArtifacts(
      appId: appId,
      releaseId: release.id,
      xcarchivePath: xcarchiveDirectory.path,
      runnerPath: artifactManager
          .getIosAppDirectory(xcarchiveDirectory: xcarchiveDirectory)!
          .path,
      isCodesigned: codesign,
      podfileLockHash: shorebirdEnv.iosPodfileLockHash,
    );

    await uploadSupplementArtifact(appId: appId, releaseId: release.id);
  }

  @override
  String get postReleaseInstructions {
    final relativeArchivePath = p.relative(
      artifactManager.getXcarchiveDirectory()!.path,
    );
    if (codesign) {
      const ipaSearchString = 'build/ios/ipa/*.ipa';
      return '''

Your next step is to upload your app to App Store Connect.

To upload to the App Store, do one of the following:
    1. Open ${lightCyan.wrap(relativeArchivePath)} in Xcode and use the "Distribute App" flow.
    2. Drag and drop the ${lightCyan.wrap(ipaSearchString)} bundle into the Apple Transporter macOS app (https://apps.apple.com/us/app/transporter/id1450874784).
    3. Run ${lightCyan.wrap('xcrun altool --upload-app --type ios -f $ipaSearchString --apiKey your_api_key --apiIssuer your_issuer_id')}.
       See "man altool" for details about how to authenticate with the App Store Connect API key.
''';
    } else {
      return '''

Your next step is to submit the archive at ${lightCyan.wrap(relativeArchivePath)} to the App Store using Xcode.

You can open the archive in Xcode by running:
    ${lightCyan.wrap('open $relativeArchivePath')}

${styleBold.wrap('Make sure to uncheck "Manage Version and Build Number" in the Distribute App dialog.')}
If left checked, Xcode will rewrite the build number in the uploaded IPA, so the version that ships will not match the one Shorebird recorded for this release, and patches will fail to apply.
''';
    }
  }
}
