import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/release/apple_releaser_mixin.dart';
import 'package:shorebird_cli/src/commands/release/releaser.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/flutter_version_constraints.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform/apple/apple.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/route_b.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_compiler_cache.dart';
import 'package:shorebird_cli/src/route_b_provenance.dart';
import 'package:shorebird_cli/src/route_b_release_kernels.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
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
      _declareRetention(routeBCompiler, buildArgs);
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
      _recordRouteBProvenance(
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
    if (codesign && artifactManager.getIpa() == null) {
      logger.err(
        '''
Unable to find generated IPA. This usually means that the IPA export step of "flutter build ipa" failed (for example, due to a missing or invalid code signing certificate). Review the build output above for the underlying error.

If you do not need a signed IPA (for example, you will sign the .xcarchive in Xcode), re-run this command with --no-codesign.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    return xcarchiveDirectory;
  }

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
  void _recordRouteBProvenance(
    RouteBCompiler compiler,
    Directory appDirectory,
    File releaseKernel,
    List<String> buildArgs,
  ) {
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
    final artifacts = <String, String>{};
    if (releaseKernel.existsSync()) {
      artifacts[routeBReleaseKernelFileName] = captureRouteBReleaseKernel(
        supplement,
        releaseKernel,
      );
      // The second kernel, produced by the RELEASE ENGINE's own frontend rather
      // than by whatever this machine has. Both release kernels then come from
      // one lineage as a matter of structure, not of who ran the build.
      _captureImportKernel(
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
  void _captureImportKernel({
    required RouteBCompiler compiler,
    required Directory supplement,
    required File releaseKernel,
    required List<String> buildArgs,
    required Map<String, String> artifacts,
  }) {
    final builder = routeBReleaseKernelBuilder;
    final importKernel = builder.build(
      compiler: compiler,
      projectRoot: projectRoot,
      // The release's own entrypoint, not a guess at one. `flutter build ipa`
      // was handed exactly this.
      entrypoint: target ?? p.join('lib', 'main.dart'),
      buildArgs: buildArgs,
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
  void _declareRetention(RouteBCompiler compiler, List<String> buildArgs) {
    final work = Directory(
      p.join(shorebirdEnv.buildDirectory.path, 'route_b'),
    );
    final builder = routeBReleaseKernelBuilder;

    final prepass = builder.buildPrepass(
      compiler: compiler,
      projectRoot: projectRoot,
      entrypoint: target ?? p.join('lib', 'main.dart'),
      buildArgs: buildArgs,
      outputFile: File(p.join(work.path, 'prepass.dill')),
    );
    if (prepass == null) return;

    final interface = builder.generateDynamicInterface(
      compiler: compiler,
      prepassKernel: prepass,
      outputFile: File(p.join(work.path, 'dynamic_interface.yaml')),
    );
    if (interface == null) return;

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
