import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';

/// A reference to a [XcodeBuild] instance.
final xcodeBuildRef = create(XcodeBuild.new);

/// The [XcodeBuild] instance available in the current zone.
XcodeBuild get xcodeBuild => read(xcodeBuildRef);

/// A wrapper around the `xcodebuild` command.
class XcodeBuild {
  /// Name of the executable.
  static const executable = 'xcodebuild';

  /// Get the current Xcode version.
  Future<String> version() async {
    final result = await process.run(executable, ['-version']);
    if (result.exitCode != ExitCode.success.code) {
      throw ProcessException(executable, ['-version'], '${result.stderr}');
    }

    final lines = LineSplitter.split('${result.stdout}').map((e) => e.trim());
    return lines.join(' ');
  }

  /// The scheme whose name case-insensitively equals [flavor], **as spelled in
  /// the project**, or [flavor] unchanged when there is no match.
  ///
  /// WHY THIS EXISTS, and why the CLI token is not the answer. On iOS and macOS
  /// Flutter does NOT take `FLUTTER_APP_FLAVOR` from the flavor you typed. It
  /// parses it from the Xcode CONFIGURATION and returns the SCHEME's own
  /// casing:
  ///
  ///   common.dart, `_addFlavorToDartDefines`:
  ///     "For iOS and macOS projects, parse the flavor from the configuration,
  ///      do not get from the FLAVOR environment variable. This is because when
  ///      built from Xcode, the scheme/flavor can be changed through the UI and
  ///      is not reflected in the environment variable."
  ///
  ///   xcode_project.dart, `parseFlavorFromConfiguration`:
  ///     for (final String schemeName in info.schemes) {
  ///       if (schemeName.toLowerCase() == parsedScheme.toLowerCase()) {
  ///         return schemeName;
  ///       }
  ///     }
  ///
  /// So `--flavor foo` against a scheme named `Foo` ships a kernel compiled
  /// with `FLUTTER_APP_FLAVOR=Foo`. Measured on `selfhost/fixtures/flavored_app`:
  /// `ios/Flutter/Generated.xcconfig` carries `FLAVOR=foo` for the same build
  /// whose shipped `App` contains `V1/Foo`.
  ///
  /// Route B compiles its prepass and import kernels itself, so passing the CLI
  /// token there would describe a DIFFERENT Dart program than the one that
  /// ships — the exact defect the flavor work exists to close, with the
  /// define's key fixed and its value still divergent.
  ///
  /// FAILS SOFT, deliberately. If `xcodebuild` is unavailable, the project is
  /// missing, or the output cannot be parsed, this returns [flavor] unchanged —
  /// which is the behaviour that existed before this method and is exactly
  /// right whenever the scheme is spelled the same as the token. Failing
  /// loudly here would turn a cosmetic mismatch into a failed release.
  Future<String> flavorScheme({
    required String projectPath,
    required String flavor,
  }) async {
    if (flavor.isEmpty) return flavor;
    final args = ['-list', '-json', '-project', projectPath];
    try {
      final result = await process.run(executable, args);
      if (result.exitCode != ExitCode.success.code) return flavor;
      final decoded = jsonDecode('${result.stdout}');
      if (decoded is! Map) return flavor;
      final project = decoded['project'];
      if (project is! Map) return flavor;
      final schemes = project['schemes'];
      if (schemes is! List) return flavor;
      for (final scheme in schemes) {
        if (scheme is String && scheme.toLowerCase() == flavor.toLowerCase()) {
          return scheme;
        }
      }
    } on Exception {
      return flavor;
    }
    return flavor;
  }
}
