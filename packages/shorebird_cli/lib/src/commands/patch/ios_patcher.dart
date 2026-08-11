import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/archive/archive.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/patch/apple_patcher_mixin.dart';
import 'package:shorebird_cli/src/commands/patch/patcher.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/route_b.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_documentation.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/validators/validators.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

/// {@template ios_patcher}
/// Functions to create an iOS patch.
/// {@endtemplate}
class IosPatcher extends Patcher
    with ApplePatcherMixin, ApplePodfileLockPatcherMixin {
  /// {@macro ios_patcher}
  IosPatcher({
    required super.argResults,
    required super.argParser,
    required super.flavor,
    required super.target,
  });

  String get _aotOutputPath =>
      p.join(shorebirdEnv.buildDirectory.path, 'out.aot');

  String get _vmcodeOutputPath =>
      p.join(shorebirdEnv.buildDirectory.path, 'out.vmcode');

  String get _appDillCopyPath =>
      p.join(shorebirdEnv.buildDirectory.path, 'app.dill');

  /// The last build's link percentage.
  @visibleForTesting
  double? lastBuildLinkPercentage;

  /// The last build's link metadata.
  @visibleForTesting
  Json? lastBuildLinkMetadata;

  @override
  double? get linkPercentage => lastBuildLinkPercentage;

  @override
  Json? get linkMetadata => lastBuildLinkMetadata;

  @override
  ReleaseType get releaseType => ReleaseType.ios;

  @override
  String get primaryReleaseArtifactArch => 'xcarchive';

  @override
  String? get supplementaryReleaseArtifactArch => 'ios_supplement';

  @override
  List<Validator> get applePlatformValidators => doctor.iosCommandValidators;

  @override
  String? get localPodfileLockHash => shorebirdEnv.iosPodfileLockHash;

  @override
  String get podfileLockRelativePath => 'ios/Podfile.lock';

  @override
  Future<void> assertArgsAreValid() async {
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
  Future<File> buildPatchArtifact({String? releaseVersion}) async {
    final shouldCodesign = argResults['codesign'] == true;
    final (flutterVersionAndRevision, flutterVersion) = await (
      shorebirdFlutter.getVersionAndRevision(),
      shorebirdFlutter.getVersion(),
    ).wait;

    if ((flutterVersion ?? minimumSupportedIosFlutterVersion) <
        minimumSupportedIosFlutterVersion) {
      logger.err('''
iOS patches are not supported with Flutter versions older than $minimumSupportedIosFlutterVersion.
For more information see: ${supportedFlutterVersionsUrl.toLink()}''');
      throw ProcessExit(ExitCode.software.code);
    }

    final buildArgs = [
      ...argResults.forwardedArgs,
      ...extraBuildArgs,
      ...buildNameAndNumberArgsFromReleaseVersion(releaseVersion),
    ];

    // If buildIpa is called with a different codesign value than the
    // release was, we will erroneously report native diffs.
    final ipaBuildResult = await artifactBuilder.buildIpa(
      codesign: shouldCodesign,
      flavor: flavor,
      target: target,
      args: buildArgs,
      base64PublicKey: argResults.encodedPublicKey,
    );

    if (splitDebugInfoPath != null) {
      Directory(splitDebugInfoPath!).createSync(recursive: true);
    }
    await artifactBuilder.buildElfAotSnapshot(
      appDillPath: ipaBuildResult.kernelFile.path,
      outFilePath: _aotOutputPath,
      genSnapshotArtifact: ShorebirdArtifact.genSnapshotIos,
      additionalArgs: [
        ...ApplePatcherMixin.splitDebugInfoArgs(splitDebugInfoPath),
        ...obfuscationGenSnapshotArgs,
      ],
    );

    // Copy the kernel file to the build directory so that it can be used
    // to generate a patch.
    ipaBuildResult.kernelFile.copySync(_appDillCopyPath);

    return artifactManager.getXcarchiveDirectory()!.zipToTempFile();
  }

  @override
  Future<Map<Arch, PatchArtifactBundle>> createPatchArtifacts({
    required String appId,
    required int releaseId,
    required File releaseArtifact,
    Directory? supplementDirectory,
  }) async {
    // Verify that we have built a patch .xcarchive
    if (artifactManager.getXcarchiveDirectory()?.path == null) {
      logger.err('Unable to find .xcarchive directory');
      throw ProcessExit(ExitCode.software.code);
    }

    final unzipProgress = logger.progress('Extracting release artifact');

    late final String releaseXcarchivePath;
    {
      final tempDir = Directory.systemTemp.createTempSync();
      await artifactManager.extractZip(
        zipFile: releaseArtifact,
        outputDirectory: tempDir,
      );
      releaseXcarchivePath = tempDir.path;
    }

    final releaseSupplementDir =
        supplementDirectory ?? Directory.systemTemp.createTempSync();

    unzipProgress.complete();
    final appDirectory = artifactManager.getIosAppDirectory(
      xcarchiveDirectory: Directory(releaseXcarchivePath),
    );
    if (appDirectory == null) {
      logger.err('Unable to find release artifact .app directory');
      throw ProcessExit(ExitCode.software.code);
    }
    final releaseArtifactFile = File(
      p.join(appDirectory.path, 'Frameworks', 'App.framework', 'App'),
    );

    // Route B (selfhost): on an engine that supports iOS Dart code push, a code
    // patch is only meaningful if the RELEASE was built with patchable call
    // sites. Checked here, against the release artifact we just downloaded,
    // because the alternative is the worst failure in this project: the patch
    // builds, uploads, downloads, installs, validates, attaches, reports
    // success — and the app behaves identically, because AOT emitted direct
    // calls that never consult `Function.entry_point_`.
    //
    // Deliberately keyed on ENGINE capability rather than on "is iOS". A stock
    // engine has no interpreter for an attached function to enter through, so
    // it keeps the existing linker path untouched.
    if (!assetsOnly && _engineSupportsIosCodePush()) {
      _verifyReleaseIsPatchable(releaseArtifactFile);
      // The release IS Route B. From here the only valid outcomes are a Route B
      // patch or an explicit refusal — never a fall through to the private
      // linker. Letting the legacy path catch a Route B release would leave the
      // old architecture as an accidental fallback, and it would fail somewhere
      // downstream with a message about a linker nobody asked for.
      _requireRouteBProducer();
    }

    // An assets-only patch carries no code, and the patch command drops the code
    // bundles before upload — so linking here would produce a `.vmcode` that is
    // immediately discarded. Skipping it also drops the only dependency on
    // `aot-tools.dill` (Shorebird's AOT linker, which we cannot build), which is
    // what makes an assets-only iOS patch possible without their toolchain.
    final useLinker =
        !assetsOnly && AotTools.usesLinker(shorebirdEnv.flutterRevision);
    if (useLinker) {
      apple.copySupplementFilesToSnapshotDirs(
        releaseSupplementDir: releaseSupplementDir,
        releaseSnapshotDir: releaseArtifactFile.parent,
        patchSupplementDir: shorebirdEnv.iosSupplementDirectory,
        patchSnapshotDir: shorebirdEnv.buildDirectory,
      );

      final result = await apple.runLinker(
        kernelFile: File(_appDillCopyPath),
        releaseArtifact: releaseArtifactFile,
        splitDebugInfoArgs: [
          ...ApplePatcherMixin.splitDebugInfoArgs(splitDebugInfoPath),
          ...obfuscationGenSnapshotArgs,
        ],
        aotOutputFile: File(_aotOutputPath),
        vmCodeFile: File(_vmcodeOutputPath),
        ddMaxBytes: int.tryParse(
          platform.environment['SHOREBIRD_PATCH_DD_MAX_BYTES'] ?? '',
        ),
      );
      final linkPercentage = result.linkPercentage;
      final exitCode = result.exitCode;
      if (exitCode != ExitCode.success.code) throw ProcessExit(exitCode);
      if (linkPercentage != null &&
          linkPercentage < Patcher.linkPercentageWarningThreshold) {
        logger.warn(Patcher.lowLinkPercentageWarning(linkPercentage));
      }
      lastBuildLinkPercentage = linkPercentage;
      lastBuildLinkMetadata = result.linkMetadata;
    }

    final patchBuildFile = File(useLinker ? _vmcodeOutputPath : _aotOutputPath);

    final File patchFile;
    if (useLinker && await aotTools.isGeneratePatchDiffBaseSupported()) {
      final patchBaseProgress = logger.progress('Generating patch diff base');
      final analyzeSnapshotPath = shorebirdArtifacts.getArtifactPath(
        artifact: ShorebirdArtifact.analyzeSnapshotIos,
      );

      final File patchBaseFile;
      try {
        // If the aot_tools executable supports the dump_blobs command, we
        // can generate a stable diff base and use that to create a patch.
        patchBaseFile = await aotTools.generatePatchDiffBase(
          analyzeSnapshotPath: analyzeSnapshotPath,
          releaseSnapshot: releaseArtifactFile,
        );
        patchBaseProgress.complete();
      } on Exception catch (error) {
        patchBaseProgress.fail('$error');
        throw ProcessExit(ExitCode.software.code);
      }

      patchFile = File(
        await artifactManager.createDiff(
          releaseArtifactPath: patchBaseFile.path,
          patchArtifactPath: patchBuildFile.path,
        ),
      );
    } else {
      patchFile = patchBuildFile;
    }

    final patchFileSize = patchFile.statSync().size;
    final hash = sha256.convert(patchBuildFile.readAsBytesSync()).toString();
    final hashSignature = await signHash(hash);

    return {
      Arch.arm64: PatchArtifactBundle(
        arch: 'aarch64',
        path: patchFile.path,
        hash: hash,
        size: patchFileSize,
        hashSignature: hashSignature,
        podfileLockHash: shorebirdEnv.iosPodfileLockHash,
      ),
    };
  }

  /// Whether the engine this patch is being built with can run Route B
  /// patches at all.
  ///
  /// Keyed on the `InterpretCall` symbol rather than on the engine revision:
  /// the revision is a sha1 of the Flutter binary and Xcode re-signs embedded
  /// frameworks, changing the file without changing what it can do.
  bool _engineSupportsIosCodePush() {
    return isRouteBEngine(
      File(
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
      ),
    );
  }

  /// Refuse to proceed when the Route B producer is not available.
  ///
  /// Reached only for a release that IS Route B capable, so falling back to the
  /// private AOT linker here would be wrong twice over: it cannot work (we
  /// cannot build `aot-tools.dill`), and it would quietly re-establish the old
  /// architecture as the default for exactly the releases that have moved off
  /// it. An explicit refusal keeps the branch honest until the producer lands.
  void _requireRouteBProducer() {
    logger.err(
      '''
This release supports iOS Dart code push, but the tooling that produces those patches is not available in this build of Shorebird.

Producing one requires dart2bytecode from the same engine toolchain as the release, which is not yet published as a Shorebird artifact.

This is not a problem with your release or your Dart changes — the release is
patchable. Nothing was uploaded.''',
    );
    throw ProcessExit(ExitCode.software.code);
  }

  /// Refuse to build a code patch for a release that cannot accept one.
  ///
  /// This is a RELEASE-INCOMPATIBLE failure and it is deliberately distinct
  /// from "this patch cannot be represented": the remediation is to cut a new
  /// release, not to change the Dart being patched. Collapsing the two into a
  /// generic patch failure sends people to debug the wrong half.
  void _verifyReleaseIsPatchable(File releaseArtifactFile) {
    if (isPatchableRelease(releaseArtifactFile)) return;

    final counted = countPatchableCallSites(releaseArtifactFile);
    logger.err(
      '''
This release was not built with Route B patchable call sites (${counted.sites} sites, ${counted.perMiB.round()}/MiB), so it cannot accept a Dart code patch.

A patch built against it would install and report success without changing anything the app does.

Create a new release with this engine and patch that instead. Releases built by
this version of Shorebird request patchable call sites automatically.''',
    );
    throw ProcessExit(ExitCode.software.code);
  }

  @override
  Future<Directory?> assetsDirectory() async {
    // The locally built xcarchive, not the downloaded release one: these are
    // the assets this patch is shipping.
    final xcarchive = artifactManager.getXcarchiveDirectory();
    if (xcarchive == null) {
      logger.detail('Cannot resolve patch assets: no .xcarchive was built.');
      return null;
    }

    final app = artifactManager.getIosAppDirectory(
      xcarchiveDirectory: xcarchive,
    );
    if (app == null) {
      logger.detail(
        'Cannot resolve patch assets: no .app in ${xcarchive.path}',
      );
      return null;
    }

    return ArtifactManager.findFlutterAssetsDirectory(app);
  }

  @override
  Future<String> extractReleaseVersionFromArtifact(File artifact) async {
    final archivePath = artifactManager.getXcarchiveDirectory()?.path;
    if (archivePath == null) {
      logger.err('Unable to find .xcarchive directory');
      throw ProcessExit(ExitCode.software.code);
    }

    final plistFile = File(p.join(archivePath, 'Info.plist'));
    if (!plistFile.existsSync()) {
      logger.err('No Info.plist file found at ${plistFile.path}.');
      throw ProcessExit(ExitCode.software.code);
    }

    final plist = Plist(file: plistFile);
    try {
      return plist.versionNumber;
    } on Exception catch (error) {
      logger.err(
        'Failed to determine release version from ${plistFile.path}: $error',
      );
      throw ProcessExit(ExitCode.software.code);
    }
  }
}
