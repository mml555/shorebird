import 'dart:io';

import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_cli_command_runner.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_scope.dart';

Future<void> main(List<String> args) async {
  final commandStartedAt = DateTime.now();
  final loggingStdout = runScoped(
    () => LoggingStdout(baseStdOut: stdout, logFile: currentRunLogFile),
    values: {shorebirdEnvRef},
  );
  final loggingStderr = runScoped(
    () => LoggingStdout(baseStdOut: stderr, logFile: currentRunLogFile),
    values: {shorebirdEnvRef},
  );

  // Write the current command to the top of the log file.
  currentRunLogFile.writeAsStringSync('''
Command: shorebird ${args.join(' ')}

''', mode: FileMode.append);

  await IOOverrides.runZoned(
    () async => _flushThenExit(
      await runScoped(
        () async => ShorebirdCliCommandRunner().run(args),
        values: shorebirdScope(commandStartedAt: commandStartedAt),
      ),
    ),
    stdout: () => loggingStdout,
    stderr: () => loggingStderr,
  );
}

/// Flushes the stdout and stderr streams, then exits the program with the given
/// status code.
///
/// This returns a Future that will never complete, since the program will have
/// exited already. This is useful to prevent Future chains from proceeding
/// after you've decided to exit.
Future<void> _flushThenExit(int status) {
  return Future.wait<void>([
    stdout.close(),
    stderr.close(),
  ]).then<void>((_) => exit(status));
}
