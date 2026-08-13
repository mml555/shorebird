// Route B (selfhost), G4.1: the build configuration a release was compiled with,
// as something a patch can be checked against.
//
// WHY THIS IS ITS OWN CONCEPT AND NOT A STRING COMPARISON. A patch's replacement
// body is compiled long after the release, on a different invocation and possibly a
// different machine. `const String.fromEnvironment('X')` is resolved at COMPILE
// time, so a patch compiled with a different define set than its release does not
// fail — it bakes in a different constant and ships. That is the silent-behaviour-
// change shape this fork is organised against, and no runtime check can catch it,
// because by the time the code runs the wrong value is already a literal.
//
// TWO REPRESENTATIONS, DELIBERATELY SEPARATE.
//
//   * `rawArgs` — how the configuration was SUPPLIED. Kept for audit and for
//     debugging a disagreement, never for deciding compatibility.
//   * `effectiveDefines` — what the COMPILER received, canonicalised. This is the
//     only thing compatibility is decided on.
//
// Making textual command-line equality the rule would refuse two invocations that
// compile identically — `--dart-define=b=2 --dart-define=a=1` versus the same pair
// in the other order — and that is a refusal the user cannot act on, because there
// is nothing wrong with their patch.
//
// THE CANONICAL FORM IS MEASURED, NOT ASSUMED. Every rule below cites
// `selfhost/engine/route_b/probes/g41_define_semantics.sh`, which compiles through
// the release's own gen_kernel/gen_snapshot path and reports:
//
//   1. `-Dk=first -Dk=second` yields `k=second`. Duplicates collapse LAST-WINS, so
//      the effective configuration is a MAP, not a list. A list representation
//      would make a redundant re-specification look like a mismatch.
//   2. `-Da=1 -Db=2` and `-Db=2 -Da=1` produce BYTE-IDENTICAL kernels. Key order
//      carries no meaning, so the map is compared sorted.
//   3. `-Dk=` yields a defined EMPTY STRING, not an undefined key. So absent and
//      empty are different configurations and must never be normalised together —
//      the one rule a hand-rolled "drop empties" canonicaliser would have broken.
//
// If any of those three answers ever changes, that probe fails and this file is
// wrong. That is the intended coupling.
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The prefix Flutter uses to supply a define on a build invocation.
const _dartDefineFlag = '--dart-define=';

/// Options whose meaning cannot be reduced to an effective define set here.
///
/// `--dart-define-from-file` is parsed by Flutter with its own `.json`/`.env`
/// rules, and reimplementing that parsing to expand it into defines would be the
/// hand-reconstruction this design avoids. A release using it is a perfectly good
/// release; it simply cannot have its configuration fingerprinted, and the patch
/// side declines by name rather than comparing an incomplete set.
///
/// Kept in sync with `routeBUnforwardableOptions` in `route_b_release_kernels.dart`
/// by `route_b_build_config_test.dart`, so the two cannot drift into disagreeing
/// about what is carryable.
const routeBUnfingerprintableOptions = ['--dart-define-from-file'];

/// {@template route_b_build_config}
/// A release's build configuration, in the two forms that matter.
/// {@endtemplate}
class RouteBBuildConfig {
  /// {@macro route_b_build_config}
  const RouteBBuildConfig({
    required this.rawArgs,
    required this.effectiveDefines,
  });

  /// Derives the configuration from a build invocation's arguments.
  ///
  /// Returns null when an option is present whose effective set cannot be
  /// determined here — see [routeBUnfingerprintableOptions]. Null means "cannot
  /// be fingerprinted", which the caller must treat as its own state rather than
  /// as an empty configuration: an empty set is a real configuration that a patch
  /// can match, and "unknown" is not.
  static RouteBBuildConfig? fromBuildArgs(List<String> buildArgs) {
    final defines = <String, String>{};
    for (final arg in buildArgs) {
      final unfingerprintable = routeBUnfingerprintableOptions.any(
        (option) => arg == option || arg.startsWith('$option='),
      );
      if (unfingerprintable) return null;
      if (!arg.startsWith(_dartDefineFlag)) continue;
      final body = arg.substring(_dartDefineFlag.length);
      final eq = body.indexOf('=');
      // `--dart-define=K` with no `=` defines K as the empty string, which is the
      // same effective configuration as `--dart-define=K=`. Both are DEFINED, and
      // neither is the same as omitting K (probe rule 3).
      final key = eq < 0 ? body : body.substring(0, eq);
      final value = eq < 0 ? '' : body.substring(eq + 1);
      if (key.isEmpty) continue;
      // Last-wins, per probe rule 1.
      defines[key] = value;
    }
    return RouteBBuildConfig(
      rawArgs: List.unmodifiable(buildArgs),
      effectiveDefines: Map.unmodifiable(defines),
    );
  }

  /// Parses the persisted form. Throws [FormatException] rather than returning
  /// null: "no configuration recorded" and "unreadable configuration" have
  /// different remediations.
  factory RouteBBuildConfig.fromJson(Map<String, dynamic> json) {
    final raw = json['rawArgs'];
    final defines = json['effectiveDefines'];
    if (raw is! List || defines is! Map) {
      throw const FormatException(
        'route B build config must carry rawArgs and effectiveDefines',
      );
    }
    return RouteBBuildConfig(
      rawArgs: List.unmodifiable(raw.map((e) => '$e')),
      effectiveDefines: Map.unmodifiable(<String, String>{
        for (final entry in defines.entries) '${entry.key}': '${entry.value}',
      }),
    );
  }

  /// How the configuration was supplied. Audit only.
  final List<String> rawArgs;

  /// What the compiler effectively received. Compatibility is decided on this.
  final Map<String, String> effectiveDefines;

  /// The canonical text the fingerprint is taken over.
  ///
  /// Sorted by key (probe rule 2), and each pair length-prefixed so that no
  /// combination of keys and values can be re-parsed into a different set —
  /// `a=b:c` and `a=b`,`c=` must not collide.
  String get canonicalForm {
    final keys = effectiveDefines.keys.toList()..sort();
    final parts = keys.map((k) {
      final v = effectiveDefines[k]!;
      return '${k.length}:$k=${v.length}:$v';
    });
    return parts.join(';');
  }

  /// A short, stable identifier for the effective configuration.
  String get fingerprint =>
      sha256.convert(utf8.encode(canonicalForm)).toString().substring(0, 16);

  /// Whether [other] would compile with the same effective configuration.
  bool agreesWith(RouteBBuildConfig other) =>
      canonicalForm == other.canonicalForm;

  /// A human-readable account of the difference, for a refusal message.
  ///
  /// Names the keys rather than dumping two command lines, because the actionable
  /// fact is which define disagrees — the command lines may differ in ways that do
  /// not matter at all.
  String describeDifference(RouteBBuildConfig other) {
    final lines = <String>[];
    final keys = {
      ...effectiveDefines.keys,
      ...other.effectiveDefines.keys,
    }.toList()..sort();
    for (final key in keys) {
      final mine = effectiveDefines[key];
      final theirs = other.effectiveDefines[key];
      if (mine == theirs) continue;
      if (mine == null) {
        lines.add('  $key: absent in the release, "$theirs" in this patch');
      } else if (theirs == null) {
        lines.add('  $key: "$mine" in the release, absent in this patch');
      } else {
        lines.add('  $key: "$mine" in the release, "$theirs" in this patch');
      }
    }
    return lines.join('\n');
  }

  /// The persisted form.
  Map<String, dynamic> toJson() => {
    'rawArgs': rawArgs,
    'effectiveDefines': {
      // Sorted on the way out so the sidecar is byte-stable for the same
      // configuration regardless of argument order.
      for (final key in effectiveDefines.keys.toList()..sort())
        key: effectiveDefines[key],
    },
    // Recorded rather than recomputed on read, so a future change to the
    // canonicalisation is detectable instead of silently re-deriving a different
    // answer from old data.
    'fingerprint': fingerprint,
  };

  /// The `-D` arguments that reproduce this configuration for `gen_kernel` and
  /// `dart2bytecode`.
  ///
  /// Emitted in sorted key order: order is not semantic (probe rule 2), and a
  /// deterministic order makes a compile command reproducible from the record.
  List<String> get compilerArgs => [
    for (final key in effectiveDefines.keys.toList()..sort())
      '-D$key=${effectiveDefines[key]}',
  ];
}
