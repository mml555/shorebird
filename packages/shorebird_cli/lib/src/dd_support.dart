import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';

/// A reference to a [DdSupport] instance.
final ddSupportRef = create<DdSupport>(DdSupport.new);

/// The [DdSupport] instance available in the current zone.
DdSupport get ddSupport => read(ddSupportRef);

/// {@template dd_support}
/// Answers whether the engine currently in the cache can run Flutter's DD
/// two-pass build.
///
/// The pass needs `gen_snapshot --print_dd_function_identity_to` plus four
/// `analyze_snapshot --dd_*` modes. Those are specific to Shorebird's Dart
/// fork, so an engine built from vanilla Dart rejects them and the build dies
/// with `Setting VM flags failed: Unrecognized flags:
/// print_dd_function_identity_to` — a message that points at the wrong layer
/// entirely. Every failure inside the pass is fatal, so this has to be decided
/// before the build starts.
///
/// The check probes the *capability* rather than trying to recognize a
/// particular engine revision, so it keeps working for engines that do not
/// exist yet.
/// {@endtemplate}
class DdSupport {
  /// {@macro dd_support}
  DdSupport();

  final _cache = <ShorebirdArtifact, bool>{};

  /// Whether [genSnapshot] accepts the DD flags.
  ///
  /// `--version` makes the VM parse its flags, print, and exit before it
  /// compiles anything, so this costs one short-lived process and writes
  /// nothing. An unrecognized flag exits non-zero.
  bool isSupportedBy(ShorebirdArtifact genSnapshot) {
    return _cache.putIfAbsent(genSnapshot, () {
      final String executable;
      try {
        executable = shorebirdArtifacts.getArtifactPath(
          artifact: genSnapshot,
        );
      } on Exception {
        // No gen_snapshot to ask; let the build proceed and report its own
        // error rather than silently changing behavior here.
        return true;
      }

      try {
        final result = process.runSync(executable, const [
          '--print_dd_function_identity_to=/dev/null',
          '--version',
        ]);
        return result.exitCode == 0;
      } on Exception {
        return true;
      }
    });
  }
}
