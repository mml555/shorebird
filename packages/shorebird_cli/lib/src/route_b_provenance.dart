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

import 'package:path/path.dart' as p;

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

    return RouteBReleaseProvenance(
      engineRevision: engineRevision,
      flutterRevision: flutterRevision,
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

  /// Renders the sidecar. Pretty-printed: it is small, it is read by people
  /// debugging a release, and it ships inside a zip either way.
  String toJson() => const JsonEncoder.withIndent('  ').convert({
    'engineRevision': engineRevision,
    'flutterRevision': flutterRevision,
    'patchableCallSites': patchableCallSites,
    'patchableCallSitesPerMiB': patchableCallSitesPerMiB,
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
