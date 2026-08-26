// Route B (selfhost): the engine hash a release was built with, carried BY the
// release.
//
// Compiler-cell selection must be release-relative, never environment-relative.
// Nothing in the system satisfied that before this file existed:
//
//   * `Release` records `flutter_revision` and nothing about the engine.
//   * `shorebirdEnv.shorebirdEngineRevision` reads
//     `<flutterDir>/bin/internal/engine.version`, a MUTABLE local file that this
//     fork's own workflow rewrites to select an experimental engine
//     (`selfhost/engine/release_assetsonly.sh`,
//     `selfhost/scripts/accept_android_default.sh`,
//     `selfhost/scripts/airgap_acceptance.sh`).
//   * fifteen engine hashes are published under the single Flutter revision
//     `c15ef637`, so the release's Flutter revision cannot distinguish them.
//   * `Flutter.framework/Info.plist`'s `FlutterEngine` key is the FLUTTER
//     revision, so the shipped bytes do not carry it either.
//
// A resolver can be perfectly correct and still validate the wrong cell if its
// engine hash comes from ambient state, and that failure wears the disguise of
// a passing check: every hash matches, the capability probe passes, and the
// compiler is still from the wrong lineage.
//
// So the release records the hash at the one moment it is known to be true —
// while the release is being built — and the patch reads it back out of the
// release's own uploaded bytes. The value can no longer come from the machine
// running `shorebird patch` at all, which is a stronger guarantee than passing
// it as a parameter would be.
//
// A server-side `engine_revision` field on the release is the eventual home for
// this; it is a wire-contract change gated by `selfhost/compatibility.yaml`.
// Until then the sidecar is the record, and the two must agree once both exist.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_build_config.dart';

/// The release's own kernel, as it fed that release's AOT compilation.
///
/// Not a kernel regenerated from the same source later. Coverage analysis
/// compares the release's compiled members against the patch's, so a
/// regenerated base would re-open the ambient-state problem one level up: the
/// diff would answer "what differs from a kernel I just built" instead of
/// "what differs from what shipped". `flutter build ipa` produces exactly one
/// `app.dill` and it is captured straight out of that build.
const routeBReleaseKernelFileName = 'release_app.dill';

/// The release's `--no-aot --no-link-platform` kernel.
///
/// A second kernel, not a duplicate: `dart2bytecode --import-dill` crashes its
/// CFE on the AOT kernel above, and `flutter build ipa` emits no other. They
/// answer different questions and both are required.
const routeBReleaseImportKernelFileName = 'release_import.dill';

/// The retention interface the release was compiled with.
///
/// Uploaded with the release because the PATCH build must use the same one.
/// A release kernel annotated with a dynamic interface and a patch kernel
/// without one disagree about almost every member: the first attempt reported
/// 4,830 changed members and refused, when one function had changed.
const routeBInterfaceFileName = 'dynamic_interface.yaml';

/// How the release's retention was produced, beside the interface that is its
/// result.
///
/// The interface is the exact emitted set. This records the things the set alone
/// cannot answer: which kernel supplied the PRIVATE half, whether the
/// import/prepass agreement passed, and why it fell back if it did.
///
/// It exists so the analyzer can accept a private reference on the strength of
/// what a release ACTUALLY retained rather than what the retention policy
/// nominally promises. Those diverge exactly when the agreement check fails --
/// which is a narrower release, not a failed one, and therefore invisible unless
/// it is written down.
const routeBRetentionEvidenceFileName = 'route_b_retention.json';

/// The capability set the release actually granted, per target.
///
/// Separate from the interface it was generated beside, because the interface
/// text cannot answer the question a patch has to ask. Retaining a class grants
/// an implicit public constructor that appears in NO line of the interface, and
/// a member emitted without its enclosing class is operationally inert -- so a
/// reader of the YAML would both understate and overstate what was granted.
///
/// Separate from the retention evidence too: the evidence says HOW the set was
/// produced, this says WHAT is in it.
const routeBCapabilityManifestFileName = 'route_b_capabilities.json';

/// The release's own v8 snapshot profile, as gen_snapshot emitted it.
///
/// P4.1's evidence. It says, per member, whether a supported invocation site
/// survived compilation -- the one thing the runtime cannot report, because a
/// patch whose target was folded away attaches successfully and reports
/// `applied 1/1 targets` while changing nothing.
///
/// Emitted during the build that produced the shipped binary, not regenerated
/// later: a profile from a second compilation of the same source describes a
/// different program than the one users are running.
const routeBSnapshotProfileFileName = 'route_b_snapshot_profile.json';

/// What the snapshot profile beside it is evidence ABOUT.
///
/// Separate from the profile because the profile itself carries no identity: it
/// names no artifact, no cell, and no format version. Without this, a profile
/// is a plausible-looking document about some compilation, and matching bundle
/// versions, source revisions, filenames and even target names would not make
/// it evidence about the artifact being patched.
///
/// Records `release_artifact_sha256` -- the digest of the App binary the
/// profile describes -- and the probe revision the release was written for.
/// The probe refuses every target when either disagrees.
const routeBProfileBindingFileName = 'route_b_profile_binding.json';

/// The Route B provenance sidecar's name inside a release's supplement.
///
/// Lives beside `obfuscation_map.json`, which already establishes the pattern:
/// a fact about how the release was built, carried with the release, and read
/// back by the patcher to decide how the patch must be built.
const routeBProvenanceFileName = 'route_b.json';

/// What a Route B release records about the toolchain that produced it.
class RouteBReleaseProvenance {
  /// {@macro route_b_release_provenance}
  const RouteBReleaseProvenance({
    required this.engineRevision,
    required this.flutterRevision,
    required this.patchableCallSites,
    required this.patchableCallSitesPerMiB,
    this.artifacts = const {},
    this.buildConfig,
    this.releaseArtifactSha256,
    this.compatibilityRevision,
    this.releaseTarget,
  });

  /// Parses a sidecar's contents.
  ///
  /// Throws [FormatException] rather than returning null on malformed input:
  /// "no provenance" and "unreadable provenance" have different remediations
  /// and must not collapse into one.
  factory RouteBReleaseProvenance.fromJson(String contents) {
    final Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } on FormatException catch (error) {
      throw FormatException(
        '$routeBProvenanceFileName is not valid JSON: '
        '${error.message}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        '$routeBProvenanceFileName is not a JSON object',
      );
    }

    final engineRevision = decoded['engineRevision'];
    if (engineRevision is! String || engineRevision.isEmpty) {
      throw const FormatException(
        '$routeBProvenanceFileName records no engineRevision',
      );
    }
    final flutterRevision = decoded['flutterRevision'];
    if (flutterRevision is! String || flutterRevision.isEmpty) {
      throw const FormatException(
        '$routeBProvenanceFileName records no flutterRevision',
      );
    }

    final artifacts = <String, String>{};
    if (decoded['artifacts'] case final Map<String, dynamic> recorded) {
      for (final entry in recorded.entries) {
        final hash = entry.value;
        if (hash is! String || hash.isEmpty) {
          throw FormatException(
            '$routeBProvenanceFileName records no hash for ${entry.key}',
          );
        }
        artifacts[entry.key] = hash;
      }
    }

    // G4.1. ABSENT and UNFINGERPRINTABLE are different states and neither may
    // read as "no defines": a release built before this field existed cannot be
    // compared at all, and a release built with --dart-define-from-file cannot
    // either. Both come back null here, and the patch side distinguishes them from
    // an empty-but-known configuration, which IS comparable.
    RouteBBuildConfig? buildConfig;
    if (decoded['buildConfig'] case final Map<String, dynamic> recorded) {
      buildConfig = RouteBBuildConfig.fromJson(recorded);
    }

    return RouteBReleaseProvenance(
      engineRevision: engineRevision,
      flutterRevision: flutterRevision,
      artifacts: artifacts,
      buildConfig: buildConfig,
      // Evidence, not a gate: the patch side re-counts from the shipped bytes
      // rather than believing these. They are here so a later failure can be
      // attributed to a specific release rather than to "some release".
      patchableCallSites: (decoded['patchableCallSites'] as num?)?.toInt() ?? 0,
      patchableCallSitesPerMiB:
          (decoded['patchableCallSitesPerMiB'] as num?)?.toDouble() ?? 0,
      // P4.4 layer 1. Null for a release cut before these existed, which the
      // patch side reads as "cannot be established" rather than as agreement.
      releaseArtifactSha256: decoded['releaseArtifactSha256'] as String?,
      compatibilityRevision: (decoded['compatibilityRevision'] as num?)?.toInt(),
      releaseTarget: decoded['releaseTarget'] as String?,
    );
  }

  /// The engine revision that built this release. The compiler cell is keyed
  /// on exactly this value.
  final String engineRevision;

  /// The Flutter revision that built this release. Recorded so a mismatch
  /// against the release's own `flutter_revision` is visible, rather than
  /// having to be inferred.
  final String flutterRevision;

  /// How many patchable call sites the shipped `App` binary contained.
  final int patchableCallSites;

  /// [patchableCallSites] per MiB of the shipped `App` binary.
  final double patchableCallSitesPerMiB;

  /// Supplement-relative filename -> sha256, for every file the release owns
  /// besides this record.
  ///
  /// A map rather than a named field per artifact, because the set is known to
  /// be growing: `dart2bytecode --import-dill` cannot read the AOT kernel (its
  /// CFE crashes in `DillExtensionBuilder`), so a second, non-AOT kernel is
  /// coming. Adding an entry then costs a producer change and no reader change
  /// — every recorded artifact is verified by the same loop.
  final Map<String, String> artifacts;

  /// The build configuration this release was compiled with, or null when it
  /// cannot be compared — either the release predates this field, or it used an
  /// option whose effective define set cannot be determined
  /// ([routeBUnfingerprintableOptions]).
  ///
  /// Null is NOT "no defines". A release with an empty configuration records an
  /// empty [RouteBBuildConfig], which a patch can match; null means the comparison
  /// is unavailable, and the patch side says which of the two it is.
  final RouteBBuildConfig? buildConfig;

  /// sha256 of the App binary this release shipped.
  ///
  /// P4.4 layer 1. The digests in [artifacts] cover the SIDECARS; this covers
  /// the thing they are evidence about. Null for a release cut before it was
  /// recorded, which cannot be established later -- the bytes are whatever the
  /// release uploaded, and hashing them at patch time would prove only that
  /// they hash to themselves.
  final String? releaseArtifactSha256;

  /// The Route B contract revision this release was cut under.
  ///
  /// Not a file format version: it moves when any part of the publication
  /// contract moves, because a patch is only interpretable against one whole
  /// contract. Null for a release that predates the field.
  final int? compatibilityRevision;

  /// The entry point this release was built from, if it was recorded.
  ///
  /// **INSTRUMENTATION, NOT POLICY.** `--target` is deliberately NOT part of the
  /// build-semantics comparison: the P5 differential matrix
  /// (`evidence/p5_build_identity_matrix.md`) could not produce a patch that was
  /// accepted against a release while differing in executable semantics solely
  /// because a different target was used, and gating on a string that has not
  /// been shown to matter would refuse patches nobody can fix.
  ///
  /// It is recorded so that IF such a case is ever found, the evidence is
  /// already in the release rather than needing to be reconstructed from a
  /// user's shell history. Compared only in the log.
  final String? releaseTarget;

  /// Renders the sidecar. Pretty-printed: it is small, it is read by people
  /// debugging a release, and it ships inside a zip either way.
  String toJson() => const JsonEncoder.withIndent('  ').convert({
    'engineRevision': engineRevision,
    'flutterRevision': flutterRevision,
    'patchableCallSites': patchableCallSites,
    'patchableCallSitesPerMiB': patchableCallSitesPerMiB,
    'artifacts': artifacts,
    if (releaseArtifactSha256 != null)
      'releaseArtifactSha256': releaseArtifactSha256,
    if (compatibilityRevision != null)
      'compatibilityRevision': compatibilityRevision,
    if (releaseTarget != null) 'releaseTarget': releaseTarget,
    if (buildConfig != null) 'buildConfig': buildConfig!.toJson(),
  });
}

/// Where in the patch flow an engine-identity check ran.
///
/// Both checks exist because the FIRST one can pass and then stop being true:
/// `flutter build` validates its cache mid-command and rewrites
/// `bin/internal/engine.version` to the hash it actually downloaded, which under
/// a CDN that maps an experimental hash onto a stock one is a DIFFERENT hash.
enum RouteBEngineCheck {
  /// Before the patch's Flutter build — so nothing is compiled or uploaded.
  beforeBuild,

  /// After it, because the build itself can restamp the cache underneath the
  /// first check.
  afterBuild,
}

/// THE INVARIANT: a Route B patch must not be produced from a frontend identity
/// different from the release's recorded engine identity.
///
/// Returns null when they agree, or the refusal to print when they do not.
///
/// WHY THIS IS A REFUSAL AND NOT A WARNING. It was a warning until 2026-08-12,
/// on the argument that the failure had not been demonstrated. It has now been
/// demonstrated end to end on an iPhone 7: release `ee001fd7`, active frontend
/// `69f9831c`, and the result was a patch that compiled, published, downloaded,
/// installed, promoted, and reported `code patch: 1` while the app went on
/// running the release's own code. Every signal said success. Nothing about the
/// device's behaviour changed.
///
/// WHY BYTE-EQUIVALENT ARTIFACTS ARE NOT AN EXCEPTION. That run's two engine
/// hashes addressed byte-identical engine artifacts — the experimental hash was
/// minted by cloning the stock one. It still failed. What differs across the
/// two identities is not the artifact bytes but which frontend produced the
/// patch's KERNEL, and the bytecode is compiled by the release's cell against
/// that kernel. So artifact equivalence is not kernel compatibility, and
/// an equivalence exception would re-admit exactly the failure this refuses.
String? routeBEngineIdentityRefusal({
  required String releaseEngineRevision,
  required String activeEngineRevision,
  required RouteBEngineCheck check,
}) {
  if (releaseEngineRevision == activeEngineRevision) return null;
  final drifted = check == RouteBEngineCheck.afterBuild;
  return '''
This release was built by engine $releaseEngineRevision, but the patch's kernel would come from engine $activeEngineRevision.

${drifted ? '''
The two agreed when this command started and no longer do: the Flutter build
rewrote its own cache stamp. That is why the check runs twice — passing it once
is not the same as it being true when the kernel is produced.''' : '''
A patch is bytecode compiled by the RELEASE's engine against a kernel produced by
the engine above. When those differ the bytecode does not bind to the release's
code.'''}

This is not a theoretical risk. It has been reproduced on device: the patch built,
uploaded, downloaded, installed and reported itself active, and the app kept
running the release's own code. Delivery cannot detect it and neither can the
device, so it is refused here.

Byte-identical engine artifacts are NOT sufficient — that case is precisely the
one that failed, because what changed was the frontend that produced the kernel,
not the artifacts.

Nothing was uploaded. Point this checkout at $releaseEngineRevision and re-run:

  echo $releaseEngineRevision > <flutterDir>/bin/internal/engine.version

then restamp bin/cache/{engine,ios-sdk,engine-dart-sdk}.stamp to match. If a
build has rewritten them again, re-check afterwards rather than before.''';
}

/// Whether an extracted release supplement carries Route B provenance at all.
///
/// Separate from [readRouteBReleaseProvenance] because it answers a different
/// question — "is this a Route B release?" — and must not throw on a malformed
/// sidecar: a release whose provenance is corrupt is still a Route B release,
/// and it needs the Route B diagnosis rather than a silent fall through to the
/// private AOT linker.
bool hasRouteBReleaseProvenance(Directory supplement) =>
    File(p.join(supplement.path, routeBProvenanceFileName)).existsSync();

/// Reads the Route B provenance from an extracted release supplement.
///
/// Returns null when the release carries none — which means the release
/// predates this record, not that it is corrupt. Throws [FormatException] when
/// one is present but unreadable.
RouteBReleaseProvenance? readRouteBReleaseProvenance(Directory supplement) {
  final file = File(p.join(supplement.path, routeBProvenanceFileName));
  if (!file.existsSync()) return null;
  return RouteBReleaseProvenance.fromJson(file.readAsStringSync());
}

/// Writes [provenance] into a release supplement directory, creating it if
/// needed, and returns the file written.
File writeRouteBReleaseProvenance(
  Directory supplement,
  RouteBReleaseProvenance provenance,
) {
  supplement.createSync(recursive: true);
  return File(p.join(supplement.path, routeBProvenanceFileName))
    ..writeAsStringSync(provenance.toJson());
}

/// A release-owned file the patch cannot use.
class RouteBReleaseArtifactException implements Exception {
  /// {@macro route_b_release_artifact_exception}
  RouteBReleaseArtifactException(this.message);

  /// What is wrong, naming the file.
  final String message;

  @override
  String toString() => message;
}

/// Verifies every artifact [provenance] records, and returns them by name.
///
/// Hashes are checked, not just presence. The supplement is uploaded as a
/// separate call from the primary release artifact, so a release CAN end up
/// with a truncated or half-written one; and the whole point of the release
/// kernel is that it is the exact bytes the release compiled from, which a
/// filename cannot establish.
///
/// Throws [RouteBReleaseArtifactException]; the caller decides how to file it.
Map<String, File> verifyRouteBReleaseArtifacts(
  Directory supplement,
  RouteBReleaseProvenance provenance,
) {
  final resolved = <String, File>{};
  for (final entry in provenance.artifacts.entries) {
    final file = File(p.join(supplement.path, entry.key));
    if (!file.existsSync()) {
      throw RouteBReleaseArtifactException(
        'the release records ${entry.key} but did not upload it',
      );
    }
    final actual = sha256.convert(file.readAsBytesSync()).toString();
    if (actual != entry.value) {
      throw RouteBReleaseArtifactException(
        '${entry.key} does not match the hash the release recorded '
        '(recorded ${entry.value.substring(0, 16)}…, '
        'got ${actual.substring(0, 16)}…)',
      );
    }
    resolved[entry.key] = file;
  }
  return resolved;
}

/// Copies [kernel] into [supplement] under [as] and returns its sha256, for
/// recording in the provenance sidecar.
String captureRouteBReleaseKernel(
  Directory supplement,
  File kernel, {
  String as = routeBReleaseKernelFileName,
}) {
  supplement.createSync(recursive: true);
  final destination = File(p.join(supplement.path, as));
  if (destination.absolute.path != kernel.absolute.path) {
    kernel.copySync(destination.path);
  }
  return sha256.convert(destination.readAsBytesSync()).toString();
}
