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

    return RouteBReleaseProvenance(
      engineRevision: engineRevision,
      flutterRevision: flutterRevision,
      artifacts: artifacts,
      // Evidence, not a gate: the patch side re-counts from the shipped bytes
      // rather than believing these. They are here so a later failure can be
      // attributed to a specific release rather than to "some release".
      patchableCallSites: (decoded['patchableCallSites'] as num?)?.toInt() ?? 0,
      patchableCallSitesPerMiB:
          (decoded['patchableCallSitesPerMiB'] as num?)?.toDouble() ?? 0,
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

  /// Renders the sidecar. Pretty-printed: it is small, it is read by people
  /// debugging a release, and it ships inside a zip either way.
  String toJson() => const JsonEncoder.withIndent('  ').convert({
    'engineRevision': engineRevision,
    'flutterRevision': flutterRevision,
    'patchableCallSites': patchableCallSites,
    'patchableCallSitesPerMiB': patchableCallSitesPerMiB,
    'artifacts': artifacts,
  });
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
