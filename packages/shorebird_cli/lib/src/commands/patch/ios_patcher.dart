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
import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_compiler_cache.dart';
import 'package:shorebird_cli/src/route_b_container.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:shorebird_cli/src/route_b_binding.dart';
import 'package:shorebird_cli/src/route_b_provenance.dart';
import 'package:shorebird_cli/src/route_b_survival.dart';
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
      // G4.1: THE DEFINES MUST MATCH, CHECKED BEFORE ANY COMPILATION.
      //
      // `const String.fromEnvironment` resolves at COMPILE time, so a patch built
      // with a different effective define set than its release does not fail -- it
      // bakes in a different constant and ships. Nothing downstream can catch it,
      // because by then the wrong value is already a literal.
      //
      // Placed here deliberately: before the compiler is resolved, before coverage,
      // before any kernel, bytecode or container exists. It is NOT before the
      // patch's own `flutter build ipa`, which runs in `buildPatchArtifact` --
      // the release supplement, and so the release's provenance, is not downloaded
      // until after that. Refusing ahead of that build means fetching the
      // supplement earlier in the patcher lifecycle, which is its own change;
      // that build alone produces nothing shippable.
      await _verifyBuildConfigAgrees(provenance);

      // P4.4. THE CONTRACT REVISION, before anything is compiled.
      //
      // A patch is only interpretable against one whole Route B contract --
      // analysis version, container format, probe revision, capability model.
      // A release cut under another revision may be perfectly fine and still
      // disagree with this CLI about what a patch MEANS, and every individual
      // check would pass while doing so.
      _verifyCompatibilityRevision(provenance);

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
        // WHAT THIS RELEASE GRANTED, from the release's own hash-verified
        // artifact. Absent for a release cut before manifests existed, and the
        // producer reads absence as "nothing provable" rather than as
        // permission — so an older release keeps working for everything that
        // worked before and refuses only the private references it cannot
        // vouch for.
        capabilities: _readReleaseCapabilities(releaseArtifacts),
        // G4.1. The release's own effective define set, already proven to match
        // this patch's by _verifyBuildConfigAgrees above, so the replacement
        // compiles with the constants the release compiled with.
        buildConfig: provenance.buildConfig,
        // P4.1. WHAT THIS RELEASE STILL CONTAINS, as opposed to what it
        // granted. Asked of the cell's own probe against the release's own
        // profile, bound to the digest of the artifact downloaded just above.
        survival: _releaseSurvivalOracle(
          compiler: compiler,
          releaseArtifacts: releaseArtifacts,
          releaseArtifact: releaseArtifactFile,
          provenance: provenance,
        ),
        // P4.4 layers 1 and 3. What this patch is bound to, recorded IN the
        // published container so any later reader can check it rather than
        // having to trust that the names lined up.
        releaseEvidence: _releaseEvidence(
          provenance: provenance,
          releaseArtifacts: releaseArtifacts,
          buildId: buildId,
        ),
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

  /// Refuse a release cut under a different Route B contract revision.
  ///
  /// A missing revision is a release from before the field existed. It cannot be
  /// established retroactively, and an unproven prerequisite is not a satisfied
  /// one -- the same rule the snapshot profile follows.
  void _verifyCompatibilityRevision(RouteBReleaseProvenance provenance) {
    final recorded = provenance.compatibilityRevision;
    if (recorded == routeBCompatibilityRevision) return;
    logger.err(
      recorded == null
          ? '''
This release recorded no Route B contract revision, so it predates the checks this version of Shorebird performs before publishing a patch.

The release itself is fine and keeps running. It cannot receive a new Route B code patch, because the prerequisites cannot be established against it. Create a new release and patch that instead. Nothing was uploaded.'''
          : '''
This release was cut under Route B contract revision $recorded and this Shorebird publishes revision $routeBCompatibilityRevision.

A patch is only interpretable against one whole contract, so these cannot be mixed even when every individual check passes. Create a new release with this version and patch that instead. Nothing was uploaded.''',
    );
    throw ProcessExit(ExitCode.software.code);
  }

  /// P4.4 layer 1, assembled from the release's own hash-verified artifacts.
  RouteBReleaseEvidence _releaseEvidence({
    required RouteBReleaseProvenance provenance,
    required Map<String, File> releaseArtifacts,
    required String buildId,
  }) {
    String? digest(String name) => provenance.artifacts[name];
    return RouteBReleaseEvidence(
      // From the release's own bytes, not from the sidecar's claim about them.
      releaseBuildId: buildId,
      engineRevision: provenance.engineRevision,
      compatibilityRevision:
          provenance.compatibilityRevision ?? routeBCompatibilityRevision,
      releaseArtifactSha256: provenance.releaseArtifactSha256,
      snapshotProfileSha256: digest(routeBSnapshotProfileFileName),
      capabilityManifestSha256: digest(routeBCapabilityManifestFileName),
      defineFingerprint: provenance.buildConfig?.fingerprint,
    );
  }

  /// P4.1's gate, bound to the artifact this patch will be applied to.
  ///
  /// NEVER returns null. A release that uploaded no profile, or no binding, is
  /// not a release this question can be skipped for -- an absent gate is
  /// indistinguishable from a gate that passed, and the failure it would hide
  /// is the silent one. So the oracle answers UNKNOWN, which refuses and names
  /// the missing sidecar.
  ///
  /// That does mean a release cut before this evidence existed cannot be
  /// patched. It is the intended reading of the invariant: if the system
  /// publishes a patch, every mechanically knowable prerequisite has already
  /// been proven against the exact release artifact.
  RouteBSurvivalOracle _releaseSurvivalOracle({
    required RouteBCompiler compiler,
    required Map<String, File> releaseArtifacts,
    required File releaseArtifact,
    required RouteBReleaseProvenance provenance,
  }) {
    final profile = releaseArtifacts[routeBSnapshotProfileFileName];
    final binding = releaseArtifacts[routeBProfileBindingFileName];
    if (profile == null || binding == null) {
      final missing = profile == null
          ? routeBSnapshotProfileFileName
          : routeBProfileBindingFileName;
      logger.detail(
        '[route-b] this release uploaded no $missing, so whether a call site '
        'for a target survived cannot be established',
      );
      return (targets) => {
        for (final t in targets)
          t: RouteBSurvivalVerdict(
            survival: RouteBSurvival.unknown,
            instrumentResult: 'RELEASE_EVIDENCE_ABSENT',
            detail: 'this release uploaded no $missing',
          ),
      };
    }
    return cellSurvivalOracle(
      compiler: compiler,
      profile: profile,
      binding: binding,
      // From the BYTES, not from anything the release asserted about itself.
      releaseArtifactSha256: sha256
          .convert(releaseArtifact.readAsBytesSync())
          .toString(),
      cellId: provenance.engineRevision,
    );
  }

  /// The capability set the release recorded, or null if it recorded none.
  ///
  /// A manifest that is present but unreadable is treated as absent rather than
  /// as a hard failure: it can only ever WIDEN what a patch may do, so failing
  /// closed costs a private reference and failing open would grant one the
  /// release never emitted. The artifact is hash-verified before it gets here,
  /// so an unreadable one means a generator wrote something this build does not
  /// understand.
  RouteBCapabilities? _readReleaseCapabilities(
    Map<String, File> releaseArtifacts,
  ) {
    final manifest = releaseArtifacts[routeBCapabilityManifestFileName];
    if (manifest == null) return null;
    final capabilities = RouteBCapabilities.read(manifest);
    if (capabilities == null) {
      logger.detail(
        '[route-b] ${manifest.path} could not be read; private references '
        'will be refused for want of evidence',
      );
    }
    return capabilities;
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
    // THE WARNING THAT USED TO LIVE HERE IS NOW A REFUSAL, over in
    // patch_command.dart (`_assertRouteBEngineIdentity`), and it runs twice:
    // before the patch build and again after it, because the build restamps
    // the cache.
    //
    // It said the bytecode "may fail to bind, on device, long after this
    // command reported success", and that we had not shown it. On 2026-08-12 it
    // was demonstrated on an iPhone 7: release `ee001fd7`, frontend `69f9831c`,
    // patch published and reported `code patch: 1`, app still running the
    // release's code. So the gate exists now, and it is deliberately NOT
    // repeated here — a warning printed beside a refusal reads as though the
    // mismatch were still a matter of degree.
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
    RouteBCapabilities? capabilities,
    RouteBBuildConfig? buildConfig,
    RouteBSurvivalOracle? survival,
    RouteBReleaseEvidence? releaseEvidence,
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
        capabilities: capabilities,
        buildConfig: buildConfig,
        survival: survival,
        releaseEvidence: releaseEvidence,
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
  /// Refuses when this patch's effective build configuration differs from the
  /// release's.
  ///
  /// Compares the EFFECTIVE define set, never the command line: two invocations
  /// that supply the same defines in a different order compile to byte-identical
  /// kernels (measured by `probes/g41_define_semantics.sh`), so refusing on
  /// textual inequality would reject a patch with nothing wrong with it.
  ///
  /// The flavor this patch actually compiles with, by Flutter's precedence —
  /// mirroring `IosReleaser`'s getter of the same name, so the release half and
  /// the patch half resolve it identically.
  ///
  /// `--flavor` never arrives through the build args: `forwardedArgs` carries
  /// only `--dart-define=` and `--enable-experiment=`, and this CLI passes
  /// flavor to `buildIpa` as a separate parameter. So the patch side
  /// synthesized NO `FLUTTER_APP_FLAVOR` while a flavored release records a
  /// real one, and the configuration check refused the MATCHING case —
  /// `--flavor foo` patching a `--flavor foo` release — reporting a defines
  /// difference that was an artifact of the comparison, not of the programs.
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

  Future<void> _verifyBuildConfigAgrees(
    RouteBReleaseProvenance provenance,
  ) async {
    final releaseConfig = provenance.buildConfig;
    final patchArgs = [...argResults.forwardedArgs, ...extraBuildArgs];
    final patchConfig = RouteBBuildConfig.fromBuildArgs(
      patchArgs,
      flavor: await _appleFlavor,
    );

    if (releaseConfig == null) {
      // Two different causes with different remediations, so they are named
      // rather than collapsed: a release cut before this field existed cannot be
      // compared, and a release built with an unfingerprintable option never can.
      logger.warn(
        '''This release records no comparable build configuration, so its --dart-define values cannot be checked against this patch's. If it was built with ${routeBUnfingerprintableOptions.join(', ')}, that is expected and permanent; if it predates configuration provenance, cut a new release to get the check.''',
      );
      return;
    }
    if (patchConfig == null) {
      logger.err(
        '''This patch was invoked with ${routeBUnfingerprintableOptions.join(', ')}, whose effective define set cannot be determined, so it cannot be shown to match the release's.''',
      );
      throw ProcessExit(ExitCode.usage.code);
    }
    if (releaseConfig.agreesWith(patchConfig)) {
      logger.detail(
        '[route-b] build configuration matches the release '
        '(fingerprint ${releaseConfig.fingerprint})',
      );
      return;
    }

    logger
      ..err('''
This patch's Dart defines differ from the release's, so its compiled constants would not match the release it patches:

${releaseConfig.describeDifference(patchConfig)}

release fingerprint: ${releaseConfig.fingerprint}
patch fingerprint:   ${patchConfig.fingerprint}''')
      ..info(
        '''Re-run `shorebird patch` with the same --dart-define values the release was built with. Order and redundant repetitions do not matter; the effective values do.''',
      );
    throw ProcessExit(ExitCode.usage.code);
  }

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
