import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_compiler_cache.dart';
import 'package:shorebird_cli/src/route_b_container.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:shorebird_cli/src/route_b_provenance.dart';
import 'package:shorebird_cli/src/route_b_release_kernels.dart';
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

    File? routeBContainer;
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

    // Route B (selfhost): a code patch against a Route B release is only
    // meaningful if the RELEASE was built with patchable call sites. Checked
    // here, against the release artifact we just downloaded, because the
    // alternative is the worst failure in this project: the patch builds,
    // uploads, downloads, installs, validates, attaches, reports success — and
    // the app behaves identically, because AOT emitted direct calls that never
    // consult `Function.entry_point_`.
    //
    // Two ways in, and the first is the real one. A release that carries Route
    // B provenance says so itself, from its own uploaded bytes, so the branch
    // is taken for the right releases even on a machine whose engine has been
    // switched to something else. The local-engine check stays as a safety net
    // for releases cut before provenance existed: without it, a Route B release
    // built without the flag would fall through to the private AOT linker
    // instead of getting the "not patchable, cut a new release" diagnosis.
    if (!assetsOnly &&
        (hasRouteBReleaseProvenance(releaseSupplementDir) ||
            _engineSupportsIosCodePush())) {
      _verifyReleaseIsPatchable(releaseArtifactFile);
      // The release IS Route B. From here the only valid outcomes are a Route B
      // patch or an explicit refusal — never a fall through to the private
      // linker. Letting the legacy path catch a Route B release would leave the
      // old architecture as an accidental fallback, and it would fail somewhere
      // downstream with a message about a linker nobody asked for.
      final provenance = _readReleaseProvenance(releaseSupplementDir);
      final releaseArtifacts = _verifyReleaseArtifacts(
        releaseSupplementDir,
        provenance,
      );
      final compiler = await _resolveRouteBCompiler(provenance);
      _verifyReleaseKernelsAgree(compiler, releaseArtifacts);

      // COVERAGE BEFORE BYTECODE, deliberately. A patch that cannot be
      // represented has no business invoking a compiler, and more importantly
      // the ordering keeps failure attribution clean: a coverage rejection, a
      // compiler failure and a container failure are three different problems
      // and must never be reachable through one another.
      final coverage = _analyzeCoverage(compiler, releaseArtifacts);
      if (coverage.verdict != RouteBVerdict.accept) {
        _refuseCoverage(coverage);
      }

      final buildId = _readReleaseBuildId(releaseArtifactFile);
      routeBContainer = _produceRouteBContainer(
        compiler: compiler,
        coverage: coverage,
        importKernel: releaseArtifacts[routeBReleaseImportKernelFileName]!,
        releaseBuildId: buildId,
      );
    }

    // A Route B patch never links: the container IS the payload, and linking
    // would produce a `.vmcode` that is discarded. This also keeps a Route B
    // release off `aot-tools.dill` entirely.
    //
    // An assets-only patch carries no code, and the patch command drops the code
    // bundles before upload — so linking here would produce a `.vmcode` that is
    // immediately discarded. Skipping it also drops the only dependency on
    // `aot-tools.dill` (Shorebird's AOT linker, which we cannot build), which is
    // what makes an assets-only iOS patch possible without their toolchain.
    final useLinker =
        routeBContainer == null &&
        !assetsOnly &&
        AotTools.usesLinker(shorebirdEnv.flutterRevision);
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

    // The bytes the device must end up holding. For Route B that is the
    // container; `hash` is taken from this file and `size` from the artifact
    // below, because check_hash() on device runs against the INFLATED result.
    final patchBuildFile =
        routeBContainer ?? File(useLinker ? _vmcodeOutputPath : _aotOutputPath);

    final File patchFile;
    if (routeBContainer != null) {
      // The SAME differ every other platform uses, against a one-byte synthetic
      // base. The updater inflates every code artifact against the running
      // app's base snapshot — on iOS the four Dart blobs behind
      // SnapshotsDataHandle — and a container has nothing in common with those
      // bytes. Diffing against them would buy nothing AND force the producer to
      // reproduce the device's exact base, which needs `analyze_snapshot
      // --dump_blobs`, a Shorebird-fork tool we cannot build.
      //
      // Against a synthetic base the artifact is pure literal inserts, so
      // reconstruction never reads the base and is correct on any device. An
      // actually-empty base panics inside bidiff's suffix-array code, which is
      // why it is one zero byte rather than none.
      //
      // Verified byte-for-byte against the reference `route_b_artifact` tool,
      // which is why no separate publishing tool remains in the product path.
      final syntheticBase = File(
        p.join(shorebirdEnv.buildDirectory.path, 'route_b_base'),
      )..writeAsBytesSync(Uint8List(1));
      patchFile = File(
        await artifactManager.createDiff(
          releaseArtifactPath: syntheticBase.path,
          patchArtifactPath: routeBContainer.path,
        ),
      );
    } else if (useLinker && await aotTools.isGeneratePatchDiffBaseSupported()) {
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

  /// The engine hash that must select the compiler cell, read from the
  /// release's own uploaded bytes.
  ///
  /// A release with no provenance is RELEASE-INCOMPATIBLE, not "tooling
  /// unavailable": nothing can be republished to make it patchable, because
  /// there is no way to learn which of the fifteen engines published under this
  /// Flutter revision built it. Guessing from the current environment is the
  /// exact failure this record exists to prevent — it would validate a cell
  /// whose every hash matched and whose lineage was wrong.
  RouteBReleaseProvenance _readReleaseProvenance(Directory supplement) {
    final RouteBReleaseProvenance? provenance;
    try {
      provenance = readRouteBReleaseProvenance(supplement);
    } on FormatException catch (error) {
      logger.err(
        '''
This release's Route B provenance could not be read: ${error.message}

Nothing was uploaded. Create a new release and patch that instead.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    if (provenance == null) {
      logger.err(
        '''
This release does not record which engine built it, so the compiler that must produce its patches cannot be identified.

Releases cut by this version of Shorebird record it automatically. Create a new
release with this engine and patch that instead. Nothing was uploaded.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    return provenance;
  }

  /// Check every file the release says it uploaded, and hand back the ones
  /// the producer needs.
  ///
  /// Hashes, not presence. The supplement is uploaded as a second network call
  /// after the primary artifact, so a release can genuinely end up carrying a
  /// truncated one — and the release kernel's whole value is that it is the
  /// exact bytes this release compiled from, which a filename cannot establish.
  ///
  /// Filed as RELEASE-INCOMPATIBLE rather than tooling-invalid: the tooling is
  /// fine, the release's own bytes are not, and no republish fixes that.
  Map<String, File> _verifyReleaseArtifacts(
    Directory supplement,
    RouteBReleaseProvenance provenance,
  ) {
    // Two kernels, two jobs, both required. The AOT one is what coverage diffs
    // against; the --no-aot one is the only thing dart2bytecode --import-dill
    // can read. A release carrying one and not the other cannot be patched, and
    // the message says which is missing rather than "something is missing".
    const required = {
      routeBReleaseKernelFileName: 'the kernel it was compiled from',
      routeBReleaseImportKernelFileName:
          'the kernel a patch has to be compiled against',
    };
    final missing = required.entries
        .where((e) => !provenance.artifacts.containsKey(e.key))
        .toList();
    if (missing.isNotEmpty) {
      logger.err(
        '''
This release did not upload ${missing.map((e) => e.value).join(' or ')}, so a patch for it cannot be built.

Releases cut by this version of Shorebird upload both automatically; a release
whose build could not produce them says so at release time. Create a new release
with this engine and patch that instead. Nothing was uploaded.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    try {
      return verifyRouteBReleaseArtifacts(supplement, provenance);
    } on RouteBReleaseArtifactException catch (error) {
      logger.err(
        '''
This release's uploaded artifacts do not match what it recorded: ${error.message}

Nothing was uploaded. Create a new release and patch that instead.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }
  }

  /// Refuse a release whose two kernels do not describe the same program.
  ///
  /// The release side already checked this, on the machine that cut the
  /// release. Checking it again here is not redundancy for its own sake: it
  /// turns "two files happened to exist and hash correctly" into "same release
  /// engine, same release inputs, two intentionally different lowering modes".
  /// The producer must never be able to compile against an import kernel that
  /// describes a different program from the one coverage analyzed.
  void _verifyReleaseKernelsAgree(
    RouteBCompiler compiler,
    Map<String, File> releaseArtifacts,
  ) {
    final agrees = routeBReleaseKernelBuilder.agreesWith(
      compiler: compiler,
      importKernel: releaseArtifacts[routeBReleaseImportKernelFileName]!,
      aotKernel: releaseArtifacts[routeBReleaseKernelFileName]!,
    );
    if (agrees) return;

    logger.err(
      '''
The two kernels this release uploaded do not describe the same program, so a patch compiled against one would not match the other.

Nothing was uploaded. Create a new release and patch that instead.''',
    );
    throw ProcessExit(ExitCode.software.code);
  }

  /// Classify what changed, against the release's own kernel.
  RouteBCoverage _analyzeCoverage(
    RouteBCompiler compiler,
    Map<String, File> releaseArtifacts,
  ) {
    final patchKernel = File(_appDillCopyPath);
    if (!patchKernel.existsSync()) {
      logger.err(
        '''Could not find the kernel this patch build produced at ${patchKernel.path}.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    try {
      return routeBCoverageAnalyzer.analyze(
        compiler: compiler,
        baseDill: releaseArtifacts[routeBReleaseKernelFileName]!,
        patchedDill: patchKernel,
      );
    } on RouteBCompilerException catch (error) {
      logger.err(error.message);
      throw ProcessExit(ExitCode.software.code);
    } on FormatException catch (error) {
      logger.err(
        'The Route B coverage analysis could not be read: ${error.message}',
      );
      throw ProcessExit(ExitCode.software.code);
    }
  }

  /// Refuse the WHOLE patch, naming every target that cannot be carried.
  ///
  /// Never a subset. Shipping the representable part would leave the app
  /// running some functions from the patch and some from the release — a state
  /// nobody designed and nobody could reproduce.
  Never _refuseCoverage(RouteBCoverage coverage) {
    if (coverage.verdict == RouteBVerdict.inert) {
      logger.err(
        '''
Nothing in this patch differs from the release, so it would install and change nothing.

Nothing was uploaded.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    logger.err(coverage.refusalMessage);
    throw ProcessExit(ExitCode.software.code);
  }

  /// The release identity a container must be stamped with.
  String _readReleaseBuildId(File releaseArtifactFile) {
    final buildId = readMachOBuildId(releaseArtifactFile.readAsBytesSync());
    if (buildId != null) return buildId;

    // Never "any identity". A container with no release stamp would be applied
    // to whatever it reached.
    logger.err(
      '''
This release's App binary carries no build ID, so a patch for it could not be tied to it.

Nothing was uploaded. Create a new release and patch that instead.''',
    );
    throw ProcessExit(ExitCode.software.code);
  }

  /// Resolve the compiler cell belonging to the release's engine.
  ///
  /// The two [RouteBCompilerProblem] cases are kept distinct all the way to the
  /// user because their remediations are opposites: *unavailable* means nothing
  /// was ever published for this engine, so a new release will not help;
  /// *invalid* means the release is fine and the TOOLING is corrupt, so cutting
  /// a new release would fix nothing. A download failure is a third thing again
  /// and says nothing about the cell.
  Future<RouteBCompiler> _resolveRouteBCompiler(
    RouteBReleaseProvenance provenance,
  ) async {
    // Not (yet) a refusal. The patch's kernel is produced by whichever frontend
    // this machine is set up with, and the bytecode will be produced by the
    // release's engine — if those disagree the bytecode may fail to bind, on
    // device, long after this command reported success. We have not yet
    // demonstrated that, and manufacturing a gate ahead of the evidence would
    // block work for a reason we cannot yet defend. Wiring the producer is what
    // will settle whether this becomes an error.
    final ambient = shorebirdEnv.shorebirdEngineRevision;
    if (ambient != provenance.engineRevision) {
      logger.warn(
        '''
This release was built by engine ${provenance.engineRevision}, but this machine is set up with engine $ambient.

The patch will be compiled by the release's engine, which is correct. The kernel
it compiles, however, comes from the engine above.''',
      );
    }

    try {
      final compiler = await routeBCompilerResolver.resolve(
        engineRevision: provenance.engineRevision,
      );
      logger.detail(
        '[route-b] resolved compiler for engine '
        '${provenance.engineRevision}\n${compiler.provenance}',
      );
      return compiler;
    } on RouteBCompilerException catch (error) {
      logger.err(error.message);
      throw ProcessExit(ExitCode.software.code);
    } on RouteBCompilerDownloadException catch (error) {
      logger.err(error.message);
      throw ProcessExit(ExitCode.software.code);
    }
  }

  /// Refuse to proceed when the Route B producer is not available.
  ///
  /// Reached only for a release that IS Route B capable and whose compiler cell
  /// has now been downloaded and validated, so falling back to the private AOT
  /// linker here would be wrong twice over: it cannot work (we cannot build
  /// `aot-tools.dill`), and it would quietly re-establish the old architecture
  /// as the default for exactly the releases that have moved off it.
  ///
  /// Everything upstream of this line is real. What is missing is the
  /// compilation, coverage analysis and packing that turn the resolved compiler
  /// into an SBRBPTCH container, so the message says exactly that rather than
  /// blaming tooling that is present and valid.
  /// Compile the replacement bodies and pack the container.
  ///
  /// A failure here is deliberately NOT a coverage rejection: coverage already
  /// said these targets can be carried, so the compiler or the recorded source
  /// span disagreeing is a toolchain problem. Reporting it as "your patch
  /// cannot be represented" would send someone to change their Dart.
  File _produceRouteBContainer({
    required RouteBCompiler compiler,
    required RouteBCoverage coverage,
    required File importKernel,
    required String releaseBuildId,
  }) {
    final workingDirectory = Directory(
      p.join(shorebirdEnv.buildDirectory.path, 'route_b'),
    );
    final Uint8List bytes;
    try {
      bytes = routeBProducer.produce(
        compiler: compiler,
        coverage: coverage,
        importKernel: importKernel,
        releaseBuildId: releaseBuildId,
        workingDirectory: workingDirectory,
        projectRoot: projectRoot,
      );
    } on RouteBUnsupportedTarget catch (error) {
      logger.err(
        '''
This patch changes a function this version of Shorebird cannot yet turn into a replacement body:

  ${error.target}
      ${error.reason}

The whole patch is refused. This is not a problem with your release. Nothing was
uploaded.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    final container = File(p.join(workingDirectory.path, 'patch.sbrbptch'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    logger.detail(
      '[route-b] packed ${bytes.length} bytes for release $releaseBuildId '
      'at ${container.path}',
    );
    return container;
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
