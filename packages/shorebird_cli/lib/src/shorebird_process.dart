import 'dart:async';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_origin.dart';
import 'package:shorebird_cli/src/engine_config.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

/// A reference to a [ShorebirdProcess] instance.
final processRef = create(ShorebirdProcess.new);

/// The [ShorebirdProcess] instance available in the current zone.
ShorebirdProcess get process => read(processRef);

/// A wrapper around [Process] that replaces executables to Shorebird-vended
/// versions.
// This may need a better name, since it returns "Process" it's more a
// "ProcessFactory" than a "Process".
class ShorebirdProcess {
  /// Creates a ShorebirdProcess.
  ShorebirdProcess({
    ProcessWrapper? processWrapper, // For mocking ShorebirdProcess.
  }) : processWrapper = processWrapper ?? ProcessWrapper();

  /// The underlying process wrapper.
  final ProcessWrapper processWrapper;

  /// Starts a process, streams the output in real-time, and returns the exit
  /// code.
  ///
  /// Uses `ProcessStartMode.inheritStdio` so the child (flutter, gradlew,
  /// gen_snapshot) shares our terminal fds and can render its spinner + ANSI
  /// output the way users expect. The cost: the child's bytes never pass
  /// through the `LoggingStdout` `IOOverrides` installed in
  /// `bin/shorebird.dart`, so `flutter build` stderr is absent from the
  /// shorebird log file — on a build failure users see the real error on
  /// screen but the log only has `Failed to build AAB. Exited with code 1`
  /// (https://github.com/shorebirdtech/shorebird/issues/3703). Piping
  /// through Dart would capture stderr but turns `stdout.hasTerminal` false
  /// on the child side, regressing the interactive UX; a pty or per-fd
  /// shell tee would fix both but costs a dependency / POSIX-only path.
  /// Accepting the logging gap for now.
  Future<int> stream(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool? runInShell,
    String? workingDirectory,
    void Function(Process process)? onStart,
  }) async {
    final process = await start(
      executable,
      arguments,
      environment: environment,
      runInShell: runInShell,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.inheritStdio,
    );
    onStart?.call(process);
    return process.exitCode;
  }

  /// Runs the process and returns the result.
  Future<ShorebirdProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool? runInShell,
    String? workingDirectory,
    bool useVendedFlutter = true,
  }) async {
    final resolvedEnvironment = _resolveEnvironment(
      environment,
      executable: executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedExecutable = _resolveExecutable(
      executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedArguments = _resolveArguments(
      executable,
      arguments,
      useVendedFlutter: useVendedFlutter,
    );
    logger.detail(
      '''[Process.run] $resolvedExecutable ${resolvedArguments.join(' ')}${workingDirectory == null ? '' : ' (in $workingDirectory)'}''',
    );

    final result = await processWrapper.run(
      resolvedExecutable,
      resolvedArguments,
      workingDirectory: workingDirectory,
      environment: resolvedEnvironment,
      runInShell: runInShell,
    );

    _logResult(result);

    return result;
  }

  /// Runs the process synchronously and returns the result.
  ShorebirdProcessResult runSync(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
    bool useVendedFlutter = true,
  }) {
    final resolvedEnvironment = _resolveEnvironment(
      environment,
      executable: executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedExecutable = _resolveExecutable(
      executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedArguments = _resolveArguments(
      executable,
      arguments,
      useVendedFlutter: useVendedFlutter,
    );
    logger.detail(
      '''[Process.runSync] $resolvedExecutable ${resolvedArguments.join(' ')}${workingDirectory == null ? '' : ' (in $workingDirectory)'}''',
    );

    final result = processWrapper.runSync(
      resolvedExecutable,
      resolvedArguments,
      workingDirectory: workingDirectory,
      environment: resolvedEnvironment,
    );

    _logResult(result);

    return result;
  }

  /// Starts a new process running the executable with the specified arguments.
  Future<Process> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool useVendedFlutter = true,
    bool? runInShell,
    String? workingDirectory,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    final resolvedEnvironment = environment ?? {};
    if (_appliesStorageOrigin(useVendedFlutter: useVendedFlutter)) {
      // Note: this will overwrite existing environment values.
      resolvedEnvironment.addAll(_environmentOverrides(executable: executable));
    }
    final resolvedExecutable = _resolveExecutable(
      executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedArguments = _resolveArguments(
      executable,
      arguments,
      useVendedFlutter: useVendedFlutter,
    );
    logger.detail(
      '''[Process.start] $resolvedExecutable ${resolvedArguments.join(' ')}${workingDirectory == null ? '' : ' (in $workingDirectory)'}''',
    );

    return processWrapper.start(
      resolvedExecutable,
      resolvedArguments,
      environment: resolvedEnvironment,
      runInShell: runInShell,
      workingDirectory: workingDirectory,
      mode: mode,
    );
  }

  Map<String, String> _resolveEnvironment(
    Map<String, String>? baseEnvironment, {
    required String executable,
    required bool useVendedFlutter,
  }) {
    final resolvedEnvironment = baseEnvironment ?? {};
    if (_appliesStorageOrigin(useVendedFlutter: useVendedFlutter)) {
      // Note: this will overwrite existing environment values.
      resolvedEnvironment.addAll(_environmentOverrides(executable: executable));
    }

    return resolvedEnvironment;
  }

  /// Whether to hand the artifact origin to the child.
  ///
  /// `useVendedFlutter` is about WHICH flutter runs, not about where its
  /// artifacts come from — but upstream only injected the origin for the vended
  /// one, and `_precache` deliberately passes `useVendedFlutter: false` because
  /// it runs the TARGET revision's own binary. So a configured origin applies
  /// either way.
  ///
  /// When nothing is configured this reduces to the upstream condition exactly,
  /// which is what keeps default behaviour byte-identical.
  static bool _appliesStorageOrigin({required bool useVendedFlutter}) =>
      useVendedFlutter || ArtifactOrigin.isOverridden;

  String _resolveExecutable(
    String executable, {
    required bool useVendedFlutter,
  }) {
    if (useVendedFlutter && executable == 'flutter') {
      return _sanitizeExecutablePath(shorebirdEnv.flutterBinaryFile.path);
    }
    return _sanitizeExecutablePath(executable);
  }

  /// Sanitizes the executable path on Windows.
  /// https://github.com/dart-lang/sdk/issues/37751
  String _sanitizeExecutablePath(String executable) {
    if (executable.isEmpty) return executable;
    if (!platform.isWindows) return executable;
    if (executable.contains(' ') && !executable.contains('"')) {
      // Use quoted strings to indicate where the file name ends and the
      // arguments begin; otherwise, the file name is ambiguous.
      return '"$executable"';
    }
    return executable;
  }

  List<String> _resolveArguments(
    String executable,
    List<String> arguments, {
    required bool useVendedFlutter,
  }) {
    var resolvedArguments = arguments;
    if (executable == 'flutter') {
      if (logger.level == Level.verbose) {
        /// We explicitly add the `--verbose` flag to flutter commands when the
        /// shorebird command was run with `--verbose`
        /// (e.g. `shorebird release ios --verbose`).
        resolvedArguments = [...resolvedArguments, '--verbose'];
      }
      if (useVendedFlutter && engineConfig.localEngine != null) {
        resolvedArguments = [
          '--local-engine-src-path=${engineConfig.localEngineSrcPath}',
          '--local-engine=${engineConfig.localEngine}',
          '--local-engine-host=${engineConfig.localEngineHost}',
          ...resolvedArguments,
        ];
      }
    }

    return resolvedArguments;
  }

  void _logResult(ShorebirdProcessResult result) {
    logger.detail('Exited with code ${result.exitCode}');

    final stdout = result.stdout as String?;
    if (stdout != null && stdout.isNotEmpty) {
      logger.detail('''

stdout:
$stdout''');
    }

    final stderr = result.stderr as String?;
    if (stderr != null && stderr.isNotEmpty) {
      logger.detail('''

stderr:
$stderr''');
    }
  }

  /// Whether [executable] is a Flutter invocation, by BASENAME.
  ///
  /// Equality against the literal `'flutter'` was not enough, and this is the
  /// bug that made FLUTTER-STORAGE-AUTHORITY-1 more than a rename:
  /// `ShorebirdFlutter._precache` — the ONE call that downloads engine
  /// artifacts — passes the target revision's ABSOLUTE binary path, so the
  /// origin was never injected for it. It only appeared to work when the
  /// operator had set `FLUTTER_STORAGE_BASE_URL` in their own shell, because
  /// the child inherits that regardless.
  static bool _isFlutterExecutable(String executable) {
    final name = p.basename(executable);
    return name == 'flutter' || name == 'flutter.bat';
  }

  /// [_environmentOverrides] combined with the [_appliesStorageOrigin] gate,
  /// exposed so a test can assert on the environment a child would receive
  /// without standing up a real process.
  @visibleForTesting
  Map<String, String> testEnvironmentOverrides({
    required String executable,
    required bool useVendedFlutter,
  }) => _appliesStorageOrigin(useVendedFlutter: useVendedFlutter)
      ? _environmentOverrides(executable: executable)
      : const {};

  Map<String, String> _environmentOverrides({required String executable}) {
    if (_isFlutterExecutable(executable)) {
      // THE CHILD PROCESS IS WHERE THIS HAS TO LAND. Flutter fetches engine
      // artifacts itself, so an origin the parent merely knows about changes
      // nothing — it is handed over in the environment, under Flutter's own
      // standard variable name.
      //
      // Resolved through ArtifactOrigin rather than read here, so this is not a
      // fourth place that decides an origin. The `shorebird` shell wrapper
      // (third_party/flutter/bin/internal/shared.sh) resolves the same
      // authority for the first-run bootstrap, which happens before any Dart
      // code runs at all.
      return {
        ArtifactOrigin.flutterStorageKey:
            ArtifactOrigin.flutterStorageBaseUrl(),
      };
    }

    return {};
  }
}

/// Result from running a process.
class ShorebirdProcessResult {
  /// Creates a new [ShorebirdProcessResult].
  const ShorebirdProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// The exit code of the process.
  final int exitCode;

  /// The standard output of the process.
  final dynamic stdout;

  /// The standard error of the process.
  final dynamic stderr;
}

/// A wrapper around [Process] that can be mocked for testing.
// coverage:ignore-start
@visibleForTesting
class ProcessWrapper {
  /// Runs the process and returns the result.
  Future<ShorebirdProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
    bool? runInShell,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      environment: environment,
      // TODO(felangel): refactor to never runInShell
      runInShell: runInShell ?? Platform.isWindows,
      workingDirectory: workingDirectory,
    );
    return ShorebirdProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  /// Runs the process synchronously and returns the result.
  ShorebirdProcessResult runSync(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) {
    final result = Process.runSync(
      executable,
      arguments,
      environment: environment,
      runInShell: Platform.isWindows,
      workingDirectory: workingDirectory,
    );
    return ShorebirdProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  /// Starts a new process running the executable with the specified arguments.
  Future<Process> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool? runInShell,
    String? workingDirectory,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    return Process.start(
      executable,
      arguments,
      // TODO(felangel): refactor to never runInShell
      runInShell: runInShell ?? Platform.isWindows,
      environment: environment,
      workingDirectory: workingDirectory,
      mode: mode,
    );
  }
}

// coverage:ignore-end
