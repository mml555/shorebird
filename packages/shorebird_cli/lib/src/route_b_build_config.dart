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

/// The define Flutter uses to carry the app flavor into Dart.
///
/// SEMANTIC, and it reaches the compiler as an ORDINARY DEFINE — which is why
/// flavor is represented here and NOT as a second compatibility field. Two inputs
/// describing one compiler fact could only drift apart.
///
/// It must be SYNTHESISED from the resolved flavor rather than looked for among the
/// dart-defines, because a legal invocation can never supply it directly:
/// `flutter_command.dart` exits if it appears in `--dart-define`,
/// `--dart-define-from-file`, or the environment. Measured in
/// `probes/g42_flavor_flow.sh`, which cites each of those lines.
const _appFlavorDefine = 'FLUTTER_APP_FLAVOR';

/// Flutter's obfuscation flag, as it appears in a build invocation.
///
/// SEMANTIC, measured: `probes/g43_obfuscation_semantics.sh` compiles one kernel
/// with and without it and the STRIPPED program bytes differ. So a release built
/// obfuscated and a patch built plain are different programs, and the patch must
/// be refused rather than warned about.
const _obfuscateFlag = '--obfuscate';

/// Flutter's symbol-output flag, as it appears in a build invocation.
///
/// NOT SEMANTIC, and this is the one worth being explicit about because it is the
/// tempting mistake. `probes/g43_obfuscation_semantics.sh` measures it two ways:
///
///   * adding the flag changes the emitted ELF but NOT the stripped program;
///   * pointing it at path A versus path B changes the emitted ELF but NOT the
///     stripped program.
///
/// Both differences live entirely in DWARF. So the path is an output DESTINATION,
/// and putting it in the fingerprint would make two machines that produce the
/// byte-identical program incompatible purely because their filesystem layouts
/// differ. It is recorded for audit and deliberately excluded from compatibility —
/// excluded on evidence, not overlooked.
const _splitDebugInfoFlag = '--split-debug-info';

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
    this.obfuscate = false,
    this.splitDebugInfoPath,
    this.flavor,
  });

  /// The flavor that actually reaches the compiler, by Flutter's own precedence.
  ///
  /// `flutter_command.dart`: `cliFlavor ?? defaultFlavor`. Deriving it from the
  /// command line alone would silently record "no flavor" for a release flavored
  /// entirely by `pubspec.yaml`'s `default-flavor` — a release with no
  /// command-line token to notice, which is the path most likely to regress.
  static String? resolveFlavor({
    String? cliFlavor,
    Map<String, dynamic>? pubspecFlutterSection,
  }) {
    if (cliFlavor != null && cliFlavor.isNotEmpty) return cliFlavor;
    final fromManifest = pubspecFlutterSection?['default-flavor'];
    return fromManifest is String && fromManifest.isNotEmpty
        ? fromManifest
        : null;
  }

  /// Derives the configuration from a build invocation's arguments.
  ///
  /// Returns null when an option is present whose effective set cannot be
  /// determined here — see [routeBUnfingerprintableOptions]. Null means "cannot
  /// be fingerprinted", which the caller must treat as its own state rather than
  /// as an empty configuration: an empty set is a real configuration that a patch
  /// can match, and "unknown" is not.
  static RouteBBuildConfig? fromBuildArgs(
    List<String> buildArgs, {
    String? flavor,
  }) {
    final defines = <String, String>{};
    var obfuscate = false;
    String? splitDebugInfoPath;
    for (var i = 0; i < buildArgs.length; i++) {
      final arg = buildArgs[i];
      if (arg == _obfuscateFlag) {
        obfuscate = true;
        continue;
      }
      // Both spellings, because a caller may pass either and the two mean the
      // same thing to Flutter.
      if (arg.startsWith('$_splitDebugInfoFlag=')) {
        splitDebugInfoPath = arg.substring(_splitDebugInfoFlag.length + 1);
        continue;
      }
      if (arg == _splitDebugInfoFlag && i + 1 < buildArgs.length) {
        splitDebugInfoPath = buildArgs[i + 1];
        i++;
        continue;
      }
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
    // THE FLAVOR WINS, mirroring Flutter's own last-write-wins: at xcodebuild time
    // it does `dartDefines.removeWhere(FLUTTER_APP_FLAVOR)` then re-adds its value
    // (`common.dart`, flutter/issues/169598). So the fingerprint represents the
    // FINAL value that reaches the compiler, not the first one written.
    if (flavor != null && flavor.isNotEmpty) {
      defines[_appFlavorDefine] = flavor;
    }
    return RouteBBuildConfig(
      rawArgs: List.unmodifiable(buildArgs),
      effectiveDefines: Map.unmodifiable(defines),
      obfuscate: obfuscate,
      splitDebugInfoPath: splitDebugInfoPath,
      flavor: flavor,
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
      obfuscate: json['obfuscate'] == true,
      splitDebugInfoPath: json['splitDebugInfoPath'] as String?,
      flavor: json['flavor'] as String?,
    );
  }

  /// How the configuration was supplied. Audit only.
  final List<String> rawArgs;

  /// What the compiler effectively received. Compatibility is decided on this.
  final Map<String, String> effectiveDefines;

  /// Whether the program was obfuscated. Part of the EFFECTIVE configuration:
  /// the stripped program bytes differ with and without it.
  final bool obfuscate;

  /// Where symbols were written, when they were. AUDIT ONLY — never part of
  /// compatibility, for the reason recorded at [_splitDebugInfoFlag].
  final String? splitDebugInfoPath;

  /// The resolved flavor. AUDIT ONLY: its compiler effect is already carried by
  /// `effectiveDefines['FLUTTER_APP_FLAVOR']`, and comparing it separately would
  /// be a second compatibility input for one compiler fact.
  ///
  /// Recorded because a reader debugging a release needs to know a flavor was in
  /// play, and because "flavored via the manifest" and "flavored via the flag" are
  /// worth telling apart when something goes wrong.
  final String? flavor;

  /// The canonical text the fingerprint is taken over.
  ///
  /// Sorted by key (probe rule 2), and each pair length-prefixed so that no
  /// combination of keys and values can be re-parsed into a different set —
  /// `a=b:c` and `a=b`,`c=` must not collide.
  /// Note what is NOT here: [splitDebugInfoPath]. Excluded on the evidence in
  /// [_splitDebugInfoFlag], not by omission.
  String get canonicalForm {
    final keys = effectiveDefines.keys.toList()..sort();
    final parts = keys.map((k) {
      final v = effectiveDefines[k]!;
      return '${k.length}:$k=${v.length}:$v';
    });
    return 'obfuscate=${obfuscate ? 1 : 0};${parts.join(';')}';
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
    if (obfuscate != other.obfuscate) {
      lines.add(
        '  --obfuscate: '
        '${obfuscate ? "on" : "off"} in the release, '
        '${other.obfuscate ? "on" : "off"} in this patch',
      );
    }
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
    'obfuscate': obfuscate,
    if (flavor != null) 'flavor': flavor,
    // Recorded so a reader can see WHERE the symbols went, and deliberately not
    // part of the fingerprint below.
    if (splitDebugInfoPath != null) 'splitDebugInfoPath': splitDebugInfoPath,
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
