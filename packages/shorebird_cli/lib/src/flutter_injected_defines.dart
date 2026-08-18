// Route B (selfhost): the defines FLUTTER injects, which no user ever types.
//
// THE BUG THIS CLOSES. `flutter build` does not compile the program the user
// described on the command line. Before it calls the frontend it appends six
// defines of its own (`flutter_command.dart` `_addFlutterVersionToDartDefines`,
// plus `FLUTTER_ENABLED_FEATURE_FLAGS` from `_addFeatureFlagsToDartDefines`),
// and `String.fromEnvironment` can read every one of them. Route B's prepass and
// import kernels were compiled without them, so retention and binding were
// decided against a Dart program the release does not ship.
//
// It is not a flavored-app edge case. Measured on a CLEAN `flutter create` app
// with no flavor and no `--dart-define` at all, the release still receives six
// defines the prepass never saw, and Route B's own coverage analyzer reports the
// two kernels' `main` as CHANGED. See `probes/g41c_injected_defines.sh`.
//
// WHY THE VALUES ARE READ AND NOT RECONSTRUCTED
//
// Every one of the six is a trap for anyone who reconstructs it:
//
//   FLUTTER_ENGINE_REVISION      is NOT this release's engine. It comes from
//                                `bin/cache/engine_stamp.json` `git_revision`
//                                (`version.dart:681`), which on the pinned cell
//                                reads `11e5695710` while Shorebird's own
//                                `engine.version` reads `40eaa0ef`. Deriving it
//                                from `shorebirdEnv.shorebirdEngineRevision`
//                                produces a plausible, wrong answer.
//   FLUTTER_FRAMEWORK_REVISION   is truncated to 10 characters
//                                (`version.dart:959`), not the full SHA.
//   FLUTTER_GIT_URL              interpolates a NULLABLE getter, so a checkout
//                                with no tracking remote ships the literal
//                                string "null" — while `flutter --version
//                                --machine` reports `unknown source` for the
//                                same state (`version.dart:281` vs `:1576`).
//                                The two disagree by construction.
//   FLUTTER_ENABLED_FEATURE_FLAGS depends on `flutter config` state on THIS
//                                machine, and is omitted entirely when empty.
//
// So the values are taken from the one place that cannot be wrong about them:
// the `DART_DEFINES` line Flutter itself writes to
// `ios/Flutter/Generated.xcconfig` for this very build. That is the same source
// the `--dart-define-from-file` expansion is checked against, and it is read
// with the same decoder.
import 'dart:io';

import 'package:shorebird_cli/src/dart_define_from_file.dart';

/// The defines Flutter injects into every build, and which a user is forbidden
/// to set.
///
/// Flutter exits with an error if any of these arrives via `--dart-define`,
/// `--dart-define-from-file` or the environment
/// (`flutter_command.dart:1563-1571`, `:1584-1591`). That is why a collision
/// between this map and the user's own defines is not merely unlikely but
/// unreachable, and why their relative order in the forwarded argument list
/// cannot be observed.
const flutterInjectedDefineKeys = <String>[
  // `_addFlutterVersionToDartDefines`, in the order Flutter appends them.
  'FLUTTER_VERSION',
  'FLUTTER_CHANNEL',
  'FLUTTER_GIT_URL',
  'FLUTTER_FRAMEWORK_REVISION',
  'FLUTTER_ENGINE_REVISION',
  'FLUTTER_DART_VERSION',
  // `_addFeatureFlagsToDartDefines`. Absent from the build entirely when no
  // enabled feature has a `runtimeId`, which is the common case and which the
  // measurement on a clean app confirmed.
  'FLUTTER_ENABLED_FEATURE_FLAGS',
];

/// `FLUTTER_APP_FLAVOR` is injected by Flutter too, and is deliberately NOT in
/// [flutterInjectedDefineKeys].
///
/// It has its own threading and its own reason: Flutter REWRITES it at the
/// xcodebuild stage from the Xcode configuration, so the value in the xcconfig
/// is the CLI token (`foo`) while the value in the shipped kernel is the
/// scheme's casing (`Foo`) — measured on `selfhost/fixtures/flavored_app`.
/// Reading it from the xcconfig would therefore reintroduce the exact casing
/// divergence `f06fa056` closed. It is synthesised from the resolved flavor
/// instead, and appended last.
const flutterFlavorDefineKey = 'FLUTTER_APP_FLAVOR';

/// The defines Flutter injected into a build, read from Flutter's own answer.
abstract final class FlutterInjectedDefines {
  /// Selects the injected defines out of a decoded `DART_DEFINES` map.
  ///
  /// Keys absent from [resolved] are absent from the result rather than
  /// defaulted: a define Flutter did not emit must not be invented here, since
  /// `const String.fromEnvironment('K')` distinguishes "unset" from "empty" and
  /// a program may branch on that difference.
  static Map<String, String> selectFrom(Map<String, String> resolved) => {
    for (final key in flutterInjectedDefineKeys)
      if (resolved.containsKey(key)) key: resolved[key]!,
  };

  /// Reads the defines Flutter injected into the build that wrote [xcconfig],
  /// or null when that file cannot be read or carries no `DART_DEFINES`.
  ///
  /// Null is a REASON TO DECLINE, never a reason to substitute an empty map:
  /// compiling the prepass with no injected defines is precisely the bug this
  /// closes, and doing it silently would be worse than the bug.
  static Map<String, String>? fromGeneratedXcconfig(File xcconfig) {
    final resolved = DartDefineFromFileExpansion.decodeGeneratedXcconfig(
      xcconfig,
    );
    if (resolved == null) return null;
    return selectFrom(resolved);
  }
}
