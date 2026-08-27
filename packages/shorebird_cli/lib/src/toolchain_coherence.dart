import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/src/base/process.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

/// A reference to a [ToolchainCoherence] instance.
final toolchainCoherenceRef = create(ToolchainCoherence.new);

/// The [ToolchainCoherence] instance available in the current zone.
ToolchainCoherence get toolchainCoherence => read(toolchainCoherenceRef);

/// One reason a toolchain is not coherent, with a stable code.
///
/// The code is what a caller may branch on; the prose is free to change, per
/// P4.3's rule that the code is the contract.
enum ToolchainIncoherence {
  /// The engine artifacts do not match the selected engine revision.
  engineArtifactsStale('ENGINE_ARTIFACTS_STALE'),

  /// The HOST DART SDK does not match the selected engine revision.
  ///
  /// The defect this exists for. `engine.stamp` and `engine-dart-sdk.stamp` are
  /// independent, so activating a cell by writing `engine.version` and
  /// refreshing the engine leaves the KERNEL PRODUCER behind.
  hostDartSdkStale('HOST_DART_SDK_STALE'),

  /// An iOS `gen_snapshot` does not support patchable call sites.
  genSnapshotNotPatchable('GEN_SNAPSHOT_NOT_PATCHABLE'),

  /// A required file was missing, so coherence could not be established.
  ///
  /// Not established is not the same as coherent, which is why this is a
  /// failure rather than a skip.
  undeterminable('COHERENCE_UNDETERMINABLE');

  const ToolchainIncoherence(this.wire);

  /// The stable token.
  final String wire;
}

/// A single coherence problem.
class ToolchainCoherenceProblem {
  /// {@macro toolchain_coherence_problem}
  const ToolchainCoherenceProblem({required this.code, required this.detail});

  /// Which invariant failed.
  final ToolchainIncoherence code;

  /// What was actually observed. Carries the identities, because "stale"
  /// without the two values is not actionable.
  final String detail;

  @override
  String toString() => '${code.wire}: $detail';
}

/// Verifies that a Flutter checkout is running the toolchain it claims to.
///
/// WHY THIS IS A PRODUCER GATE AND NOT A SCRIPT. A mixed toolchain — the cell's
/// `gen_snapshot` with a foreign host Dart SDK — produced two failures whose
/// symptoms surfaced layers away from their cause:
///
///  * a release that shipped WITHOUT patchable call sites, so the Route B
///    producer refused to patch it long after publication;
///  * an `app.dill` that aborted the mandatory P4.1 snapshot-profile writer
///    inside the Dart VM, indistinguishable from a serializer bug while
///    `gen_snapshot` was byte-identical to a known-good one.
///
/// Both are cheap to detect BEFORE artifacts are produced and expensive to
/// diagnose afterwards.
///
/// Deliberately takes explicit paths. The shell equivalent
/// (`selfhost/scripts/verify_toolchain_coherence.sh`) defaults to a local CDN
/// overlay, which is a workstation-specific assumption that must not leak into
/// the product.
class ToolchainCoherence {
  /// {@macro toolchain_coherence}
  const ToolchainCoherence();

  /// Checks the invariants for [platform]. Returns an empty list when coherent.
  ///
  /// SCOPED BY PLATFORM ON PURPOSE. The invariant is *a producer may only build
  /// a platform when the toolchain components that platform uses are coherent
  /// with the engine revision it claims* — not *every platform supported
  /// anywhere in this checkout must be qualified before any platform may
  /// build*.
  ///
  /// The engine cell is an **iOS Route B specialization**, activated by
  /// overwriting `engine.version` for the whole checkout. The first version of
  /// this gate therefore required Route B iOS compilers before an ANDROID
  /// release could run, which is not a safety property — it is a scope mistake,
  /// and it blocked Android entirely because no cell carries Android artifacts.
  ///
  /// [publishedDartSdkZip] is optional: when a caller can name the artifact
  /// source for [engineRevision], the host `dartaotruntime` is compared to it
  /// BYTE FOR BYTE, which is the check that actually caught the defect. When it
  /// is absent the stamp comparisons still run — they would also have caught
  /// it, and they need no knowledge of where artifacts come from.
  List<ToolchainCoherenceProblem> check({
    required Directory flutterDirectory,
    required String engineRevision,
    required ReleasePlatform platform,
    File? publishedDartSdkZip,
    Directory? publishedIosEngineDir,
  }) {
    final problems = <ToolchainCoherenceProblem>[];
    final cache = Directory(p.join(flutterDirectory.path, 'bin', 'cache'));

    String? readStamp(String name) {
      final f = File(p.join(cache.path, name));
      if (!f.existsSync()) return null;
      return f.readAsStringSync().trim();
    }

    void requireStamp(String name, ToolchainIncoherence code, String what) {
      final value = readStamp(name);
      if (value == null) {
        problems.add(
          ToolchainCoherenceProblem(
            code: ToolchainIncoherence.undeterminable,
            detail: '$name is missing, so $what cannot be confirmed',
          ),
        );
        return;
      }
      if (value != engineRevision) {
        problems.add(
          ToolchainCoherenceProblem(
            code: code,
            detail: '$name is $value but engine.version is $engineRevision',
          ),
        );
      }
    }

    requireStamp(
      'engine.stamp',
      ToolchainIncoherence.engineArtifactsStale,
      'the engine artifacts',
    );
    requireStamp(
      'engine-dart-sdk.stamp',
      ToolchainIncoherence.hostDartSdkStale,
      'the host Dart SDK',
    );

    // iOS ONLY. These are the compilers that produce an iOS Route B release; an
    // Android build never invokes them, so their state says nothing about
    // whether an Android artifact can be trusted.
    if (_usesIosCompilers(platform)) {
    // The iOS compilers must be Route B ones. Checked by looking for the flag
    // NAME inside the binary, never by running it with `--version`: that
    // exits 0 whatever flags precede it and once certified a stock binary as
    // capable.
    for (final mode in const ['ios', 'ios-profile', 'ios-release']) {
      final gs = File(
        p.join(
          cache.path,
          'artifacts',
          'engine',
          mode,
          'gen_snapshot_arm64',
        ),
      );
      if (!gs.existsSync()) {
        problems.add(
          ToolchainCoherenceProblem(
            code: ToolchainIncoherence.undeterminable,
            detail: '${gs.path} is missing',
          ),
        );
        continue;
      }
      if (!_containsFlagName(gs, 'patchable_static_calls')) {
        problems.add(
          ToolchainCoherenceProblem(
            code: ToolchainIncoherence.genSnapshotNotPatchable,
            detail:
                '$mode/gen_snapshot_arm64 does not support '
                'patchable_static_calls; a release built with it could not be '
                'patched',
          ),
        );
      }
    }

    // AND THE CACHED ENGINE MUST BE THIS CELL'S ENGINE.
    //
    // Everything above this line can pass over the wrong engine, which is not
    // hypothetical — it happened on 2026-08-27 activating cell 4792f0ec:
    //
    //   engine.version, engine.stamp, engine-dart-sdk.stamp
    //                                        all named 4792f0ec
    //   cached ios-release engine            ca7d2c0d's, a week old
    //   gen_snapshot patchable_static_calls  present
    //   verdict                              COHERENT
    //
    // The stamp comparisons read stamp CONTENTS, and a stamp asserts what the
    // cache is CLAIMED to hold; `flutter --version` writes `engine.stamp` while
    // fetching only HOST artifacts, so it can assert iOS bytes that never
    // arrived. And `patchable_static_calls` is carried by EVERY Route B cell,
    // so it separates Route B from stock and never this cell from its
    // predecessor — a capability signal being read as an identity one.
    //
    // A release cut then would have been built against the previous runtime
    // while every report named the new cell. So the engine bytes are compared
    // against the ones this cell actually published.
    problems.addAll(
      _compareIosEngines(
        flutterDirectory: flutterDirectory,
        engineRevision: engineRevision,
        publishedIosEngineDir: publishedIosEngineDir,
      ),
    );
    }

    if (publishedDartSdkZip != null) {
      problems.addAll(
        _compareHostDartSdk(
          flutterDirectory: flutterDirectory,
          publishedDartSdkZip: publishedDartSdkZip,
        ),
      );
    }

    return problems;
  }

  /// Whether [platform] is produced by the iOS compiler set.
  ///
  /// Only `ios` today. Written as a predicate rather than an equality so a new
  /// Apple target that reuses these `gen_snapshot` binaries is added here
  /// deliberately, instead of silently skipping the capability check.
  bool _usesIosCompilers(ReleasePlatform platform) =>
      platform == ReleasePlatform.ios;

  /// A one-line statement of what was checked, for the producer to log.
  ///
  /// Says explicitly when the iOS Route B capability was NOT evaluated. Silence
  /// there would make later evidence ambiguous: a green coherence line on an
  /// Android build must not read as a claim about the iOS half.
  String describe({
    required ReleasePlatform platform,
    required String engineRevision,
  }) {
    final ios = _usesIosCompilers(platform);
    final suffix = ios
        ? ' | iOS engine identity: VERIFIED against the published cell'
        : ' | iOS Route B capability: NOT EVALUATED'
              ' | iOS engine identity: NOT EVALUATED';
    return 'COHERENT platform=${platform.name} engine=$engineRevision$suffix';
  }

  /// Whether [binary] contains [flag] as a NUL/newline-delimited token.
  ///
  /// The VM stores flag names as plain strings in the executable, so their
  /// presence is a reliable capability signal and needs no execution.
  bool _containsFlagName(File binary, String flag) {
    final needle = flag.codeUnits;
    final bytes = binary.readAsBytesSync();
    outer:
    for (var i = 0; i + needle.length <= bytes.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (bytes[i + j] != needle[j]) continue outer;
      }
      // Require a non-identifier byte on both sides so `patchable_static_calls`
      // is not matched inside a longer name.
      final before = i == 0 ? 0 : bytes[i - 1];
      final afterIndex = i + needle.length;
      final after = afterIndex < bytes.length ? bytes[afterIndex] : 0;
      if (!_isIdentifierByte(before) && !_isIdentifierByte(after)) return true;
    }
    return false;
  }

  bool _isIdentifierByte(int b) =>
      (b >= 0x30 && b <= 0x39) ||
      (b >= 0x41 && b <= 0x5a) ||
      (b >= 0x61 && b <= 0x7a) ||
      b == 0x5f;

  List<ToolchainCoherenceProblem> _compareHostDartSdk({
    required Directory flutterDirectory,
    required File publishedDartSdkZip,
  }) {
    final local = File(
      p.join(
        flutterDirectory.path,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        'dartaotruntime',
      ),
    );
    if (!local.existsSync()) {
      return [
        ToolchainCoherenceProblem(
          code: ToolchainIncoherence.undeterminable,
          detail: '${local.path} is missing',
        ),
      ];
    }
    if (!publishedDartSdkZip.existsSync()) {
      return [
        ToolchainCoherenceProblem(
          code: ToolchainIncoherence.undeterminable,
          detail:
              'the published dart-sdk archive '
              '${publishedDartSdkZip.path} is missing, so the host Dart SDK '
              'could not be compared byte for byte',
        ),
      ];
    }

    final localDigest = sha256.convert(local.readAsBytesSync()).toString();
    final publishedDigest = _dartaotruntimeDigestFromZip(publishedDartSdkZip);
    if (publishedDigest == null) {
      return [
        ToolchainCoherenceProblem(
          code: ToolchainIncoherence.undeterminable,
          detail:
              'could not read dart-sdk/bin/dartaotruntime out of '
              '${publishedDartSdkZip.path}',
        ),
      ];
    }
    if (localDigest != publishedDigest) {
      return [
        ToolchainCoherenceProblem(
          code: ToolchainIncoherence.hostDartSdkStale,
          detail:
              "the checkout's dartaotruntime "
              '(${localDigest.substring(0, 16)}) '
              'is not the one published for this engine '
              '(${publishedDigest.substring(0, 16)}), so kernels would be '
              'produced by a foreign compiler',
        ),
      ];
    }
    return [];
  }

  /// Byte-compares each cached iOS engine against the one this cell published.
  ///
  /// FAIL-CLOSED IN EVERY DIRECTION, which is where this deliberately differs
  /// from the shell verifier. That script may report "not cached yet" as fine,
  /// because it is a diagnostic run at any time. This runs immediately before
  /// artifacts are produced, and at that moment an engine that is absent, or a
  /// published source that cannot be read, means the identity was NOT
  /// ESTABLISHED — which is not the same as coherent.
  List<ToolchainCoherenceProblem> _compareIosEngines({
    required Directory flutterDirectory,
    required String engineRevision,
    required Directory? publishedIosEngineDir,
  }) {
    if (publishedIosEngineDir == null) {
      return [
        ToolchainCoherenceProblem(
          code: ToolchainIncoherence.undeterminable,
          detail:
              '$publishedIosEngineDirEnvVar is not set, so the cached iOS '
              'engines could not be compared against the ones published for '
              '$engineRevision. Stamps alone cannot establish this: they '
              'record what the cache is claimed to hold',
        ),
      ];
    }
    if (!publishedIosEngineDir.existsSync()) {
      return [
        ToolchainCoherenceProblem(
          code: ToolchainIncoherence.undeterminable,
          detail:
              'the published iOS engine root '
              '${publishedIosEngineDir.path} does not exist, so the cached '
              'engines could not be compared against it',
        ),
      ];
    }

    final problems = <ToolchainCoherenceProblem>[];
    for (final mode in const ['ios', 'ios-profile', 'ios-release']) {
      final cached = File(
        p.join(
          flutterDirectory.path,
          'bin',
          'cache',
          'artifacts',
          'engine',
          mode,
          'Flutter.xcframework',
          'ios-arm64',
          'Flutter.framework',
          'Flutter',
        ),
      );
      if (!cached.existsSync()) {
        problems.add(
          ToolchainCoherenceProblem(
            code: ToolchainIncoherence.undeterminable,
            detail:
                '${cached.path} is missing, so the $mode engine identity was '
                'not established. An absent engine is not a matching one',
          ),
        );
        continue;
      }
      final publishedZip = File(
        p.join(publishedIosEngineDir.path, mode, 'artifacts.zip'),
      );
      if (!publishedZip.existsSync()) {
        problems.add(
          ToolchainCoherenceProblem(
            code: ToolchainIncoherence.undeterminable,
            detail:
                'the $mode engine is cached but ${publishedZip.path} is '
                'missing, so there is nothing to compare it against',
          ),
        );
        continue;
      }
      final publishedDigest = _iosEngineDigestFromZip(publishedZip);
      if (publishedDigest == null) {
        problems.add(
          ToolchainCoherenceProblem(
            code: ToolchainIncoherence.undeterminable,
            detail:
                'could not read the ios-arm64 engine slice out of '
                '${publishedZip.path}',
          ),
        );
        continue;
      }
      final cachedDigest = sha256.convert(cached.readAsBytesSync()).toString();
      if (cachedDigest != publishedDigest) {
        problems.add(
          ToolchainCoherenceProblem(
            code: ToolchainIncoherence.engineArtifactsStale,
            detail:
                'the cached $mode engine (${cachedDigest.substring(0, 16)}) is '
                'not the one published for $engineRevision '
                '(${publishedDigest.substring(0, 16)}). The stamps agree with '
                'engine.version, so they are asserting bytes that were never '
                'fetched',
          ),
        );
      }
    }
    return problems;
  }

  /// Digest of the ios-arm64 engine slice inside [zip], or null.
  String? _iosEngineDigestFromZip(File zip) {
    final result = Process.runSync(
      'unzip',
      [
        '-p',
        zip.path,
        'Flutter.xcframework/ios-arm64/Flutter.framework/Flutter',
      ],
      stdoutEncoding: null,
    );
    if (result.exitCode != 0) return null;
    final bytes = result.stdout as List<int>;
    if (bytes.isEmpty) return null;
    return sha256.convert(bytes).toString();
  }

  /// Digest of `dart-sdk/bin/dartaotruntime` inside [zip], or null.
  ///
  /// Shells out to `unzip -p` rather than taking an archive dependency: this
  /// runs once per release, and the alternative is a new package in the
  /// dependency graph for a single read.
  String? _dartaotruntimeDigestFromZip(File zip) {
    final result = Process.runSync(
      'unzip',
      ['-p', zip.path, 'dart-sdk/bin/dartaotruntime'],
      stdoutEncoding: null,
    );
    if (result.exitCode != 0) return null;
    final bytes = result.stdout as List<int>;
    if (bytes.isEmpty) return null;
    return sha256.convert(bytes).toString();
  }

  /// Refuses to continue when the toolchain is not coherent.
  ///
  /// Called from the release and patch paths BEFORE artifacts are produced.
  /// Both failures this guards against were discovered after publication,
  /// where they cost a release each and looked like defects in other layers.
  ///
  /// A METHOD rather than a top-level function so that overriding
  /// [toolchainCoherenceRef] in a test intercepts the whole gate, including the
  /// environment reads. As a free function it forced every command test to stub
  /// `flutterDirectory` just to get past a check it was not testing.
  void assertCoherent({required ReleasePlatform releasePlatform}) {
    final zipPath = platform.environment[publishedDartSdkZipEnvVar];
    final iosEngineDir = platform.environment[publishedIosEngineDirEnvVar];
    final engineRevision = shorebirdEnv.shorebirdEngineRevision;
    final problems = check(
      flutterDirectory: shorebirdEnv.flutterDirectory,
      engineRevision: engineRevision,
      platform: releasePlatform,
      publishedDartSdkZip: zipPath == null ? null : File(zipPath),
      publishedIosEngineDir:
          iosEngineDir == null ? null : Directory(iosEngineDir),
    );
    if (problems.isEmpty) {
      logger.detail(
        describe(platform: releasePlatform, engineRevision: engineRevision),
      );
      return;
    }

    logger
      ..err('The Flutter toolchain is not coherent with its engine revision.')
      ..err('')
      ..err('platform: ${releasePlatform.name}')
      ..err('engine.version: $engineRevision');
    for (final problem in problems) {
      logger.err('  - $problem');
    }
    logger
      ..err('')
      ..err(
        'Refusing to build. A mixed toolchain produces artifacts that look '
        'correct and are not: a release can ship without patchable call '
        'sites, or a kernel built by a foreign compiler can abort the '
        'mandatory snapshot-profile step inside the Dart VM.',
      )
      ..err(
        'Reactivate the engine cell so the engine artifacts AND the host '
        'Dart SDK are refreshed together, then retry.',
      );
    throw ProcessExit(ExitCode.config.code);
  }

}


/// Env var naming the published `dart-sdk-*.zip` for the active engine.
///
/// Optional. When set, the host `dartaotruntime` is compared to it byte for
/// byte. It is an ENV VAR rather than a baked path because where artifacts are
/// published is a deployment fact, and hard-coding a local CDN overlay would
/// put a workstation assumption inside the product.
const publishedDartSdkZipEnvVar = 'SHOREBIRD_PUBLISHED_DART_SDK_ZIP';

/// Env var naming the root under which the active engine's iOS artifacts are
/// published, holding `<mode>/artifacts.zip` for `ios`, `ios-profile` and
/// `ios-release`.
///
/// REQUIRED for an iOS build, unlike [publishedDartSdkZipEnvVar]. The stamps
/// cannot substitute for it: on 2026-08-27 all three stamps named the new cell
/// while the cached iOS engines were the previous cell's, and every other check
/// passed. Absent identity is not established identity, so an iOS producer
/// refuses rather than proceeding on stamps alone.
///
/// An ENV VAR rather than a baked path because where artifacts are published is
/// a deployment fact; hard-coding a local CDN overlay would put a workstation
/// assumption inside the product.
const publishedIosEngineDirEnvVar = 'SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR';
