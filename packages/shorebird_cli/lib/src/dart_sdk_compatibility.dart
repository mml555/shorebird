import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_origin.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

/// A reference to a [DartSdkCompatibility] instance.
final dartSdkCompatibilityRef = create<DartSdkCompatibility>(
  DartSdkCompatibility.new,
);

/// The [DartSdkCompatibility] instance available in the current zone.
DartSdkCompatibility get dartSdkCompatibility => read(dartSdkCompatibilityRef);

/// {@template dart_sdk_compatibility}
/// Refuses to build when the host Dart SDK in the Flutter cache was not built
/// from the same tree as the engine being built against.
///
/// The AOT pipeline spans two binaries from two different places:
/// `frontend_server` comes from `bin/cache/dart-sdk`, and `gen_snapshot` comes
/// from the engine artifacts named by `bin/internal/engine.version`. They agree
/// about `vm.table-selector.metadata` only if they were built from the same
/// Dart tree. Mixing them **compiles cleanly** and produces a snapshot whose
/// dispatch table is missing rows for selectors the frontend reported as
/// uncalled — the app then dies at startup with a `NoSuchMethodError` naming a
/// core-library member, pointing at nothing useful. See
/// `selfhost/TFA_ROOT_CAUSE.md`.
///
/// So this cannot be a capability probe the way `DdSupport` is: there is no
/// question to ask the frontend whose answer distinguishes the two cases. It
/// has to be an identity check against a recorded pairing.
///
/// The mismatch is easy to reach by accident, because nothing in Flutter's
/// bootstrap re-checks it. `bin/internal/shared.sh` calls `update_dart_sdk.sh`
/// only inside the branch that recompiles the flutter tool, and that branch is
/// gated on `bin/cache/flutter_tools.stamp` and the Flutter git revision —
/// never on `engine.version`. Rewriting `engine.version`, which is how an
/// experimental engine is selected, therefore swaps the backend and leaves the
/// frontend untouched.
/// {@endtemplate}
class DartSdkCompatibility {
  /// {@macro dart_sdk_compatibility}
  DartSdkCompatibility();

  /// Engine revisions that require a specific host Dart SDK, keyed and valued
  /// by revision prefix.
  ///
  /// Only engines listed here are checked. Shorebird's own engines pair their
  /// published `dart-sdk-<host>.zip` with the engine automatically and are
  /// absent by design, as is any engine we have not built — an unrecognized
  /// hash is not evidence of a mismatch.
  static const expectedDartSdkRevisions = <String, String>{
    // iOS, macOS host. selfhost/cdn/experimental_hashes.map.
    '70974f81': '6b58bb3a',
    // Android arm64, Linux host. selfhost/compatibility.yaml.
    '760e3fab': '4bd36869',
  };

  /// Throws [DartSdkMismatchException] when the cached Dart SDK does not match
  /// the engine currently selected by `bin/internal/engine.version`.
  ///
  /// A no-op for engines absent from [expectedDartSdkRevisions].
  void validate() {
    final engineRevision = shorebirdEnv.shorebirdEngineRevision;
    final expected = _expectedFor(engineRevision);
    if (expected == null) return;

    final revisionFile = File(
      p.join(
        shorebirdEnv.flutterDirectory.path,
        'bin',
        'cache',
        'dart-sdk',
        'revision',
      ),
    );

    String? actual;
    try {
      actual = revisionFile.readAsStringSync().trim();
    } on FileSystemException {
      // Unreadable is not "compatible". Fail closed: for a listed engine we
      // know a specific SDK is required, so being unable to confirm it is the
      // same risk as confirming it is wrong.
      actual = null;
    }

    if (actual != null && _matches(actual, expected)) return;

    throw DartSdkMismatchException(
      engineRevision: engineRevision,
      expectedDartSdkRevision: expected,
      actualDartSdkRevision: actual,
      flutterDirectory: shorebirdEnv.flutterDirectory.path,
      shorebirdRoot: shorebirdEnv.shorebirdRoot.path,
    );
  }

  String? _expectedFor(String engineRevision) {
    for (final entry in expectedDartSdkRevisions.entries) {
      if (_matches(engineRevision, entry.key)) return entry.value;
    }
    return null;
  }

  /// Compares revisions that may be recorded at different lengths — the map
  /// holds prefixes, the files hold full 40-character hashes.
  bool _matches(String a, String b) {
    final length = a.length < b.length ? a.length : b.length;
    return length > 0 && a.substring(0, length) == b.substring(0, length);
  }
}

/// {@template dart_sdk_mismatch_exception}
/// Thrown when the cached host Dart SDK was not built from the same tree as the
/// engine being built against.
/// {@endtemplate}
class DartSdkMismatchException implements Exception {
  /// {@macro dart_sdk_mismatch_exception}
  DartSdkMismatchException({
    required this.engineRevision,
    required this.expectedDartSdkRevision,
    required this.actualDartSdkRevision,
    required this.flutterDirectory,
    required this.shorebirdRoot,
  });

  /// The engine named by `bin/internal/engine.version`.
  final String engineRevision;

  /// The Dart SDK revision that engine requires.
  final String expectedDartSdkRevision;

  /// What is actually in the cache, or `null` if it could not be read.
  final String? actualDartSdkRevision;

  /// The vended Flutter checkout in use.
  final String flutterDirectory;

  /// The Shorebird install root.
  final String shorebirdRoot;

  /// The commands that install the right SDK.
  ///
  /// `update_dart_sdk.sh` runs only when the flutter tool is being recompiled,
  /// so removing `flutter_tools.stamp` is what makes it run at all;
  /// `engine-dart-sdk.stamp` is what makes it download rather than conclude it
  /// is current. `shorebird.stamp` goes too because the CLI's own snapshot is
  /// built against the outgoing SDK and would otherwise fail to load with
  /// `Wrong full snapshot version`.
  String get remediation =>
      '''
  echo $engineRevision > $flutterDirectory/bin/internal/engine.version
  rm -f $flutterDirectory/bin/cache/flutter_tools.stamp \\
        $flutterDirectory/bin/cache/engine-dart-sdk.stamp \\
        $shorebirdRoot/bin/cache/shorebird.stamp
  ${ArtifactOrigin.flutterStorageKey}=${ArtifactOrigin.flutterStorageBaseUrl()} $flutterDirectory/bin/flutter --version
  cat $flutterDirectory/bin/cache/dart-sdk/revision   # expect $expectedDartSdkRevision''';

  @override
  String toString() =>
      '''
The Dart SDK in the Flutter cache does not match the engine being built against.

  engine (bin/internal/engine.version): $engineRevision
  Dart SDK required by that engine:     $expectedDartSdkRevision
  Dart SDK actually in the cache:       ${actualDartSdkRevision ?? '<unreadable>'}

frontend_server comes from the cached Dart SDK and gen_snapshot comes from the
engine. When they are from different trees the build still SUCCEEDS and the app
dies at startup with a NoSuchMethodError on a core-library member, so this is
checked up front rather than discovered on a device.

To install the matching SDK:

$remediation''';
}
