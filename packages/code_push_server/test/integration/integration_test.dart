@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

/// Opt-in HTTP integration flow. Skipped unless `INTEGRATION=1` and the
/// required env vars are set, so the default `dart test` (unit) run stays
/// green in CI without a live Postgres + S3 stack.
///
/// The canonical end-to-end sequence lives in `tool/smoke_test.sh`; see
/// `test/integration/README.md` for how to bring up the stack and run it.
///
/// To run:
///   INTEGRATION=1 \
///   DATABASE_URL=postgres://cps:cps@localhost:5432/cps \
///   S3_ENDPOINT=http://localhost:19000 \
///   BASE_URL=http://localhost:8080 \
///   API_KEY=sb_api_selfhost_dev \
///   dart test --tags integration
void main() {
  final env = Platform.environment;
  final enabled = env['INTEGRATION'] == '1';

  const requiredVars = ['DATABASE_URL', 'S3_ENDPOINT', 'BASE_URL', 'API_KEY'];
  final missing = requiredVars.where((v) => (env[v] ?? '').isEmpty).toList();

  final skipReason = !enabled
      ? 'integration tests are opt-in: set INTEGRATION=1 to run'
      : missing.isNotEmpty
      ? 'missing required env: ${missing.join(', ')}'
      : null;

  group('code_push_server HTTP integration flow', () {
    test('smoke_test.sh drives the full CLI + device wire sequence', () async {
      // Delegate to the canonical smoke test, which is the source of truth
      // for the integration flow (create app/release, verified upload,
      // fail-closed gating, promote, device check, ranged download,
      // rollback). It exits non-zero on any failed assertion.
      final scriptPath = _smokeTestPath();
      final result = await Process.run(
        'bash',
        [scriptPath],
        environment: {'BASE': env['BASE_URL']!, 'KEY': env['API_KEY']!},
      );
      printOnFailure(result.stdout.toString());
      printOnFailure(result.stderr.toString());
      expect(
        result.exitCode,
        0,
        reason: 'smoke_test.sh failed:\n${result.stdout}\n${result.stderr}',
      );
    });
  }, skip: skipReason);
}

/// Resolves `tool/smoke_test.sh` relative to the package root regardless of
/// the test's working directory.
String _smokeTestPath() {
  // Tests run with the package root as cwd under `dart test`.
  final candidates = <String>['tool/smoke_test.sh', '../../tool/smoke_test.sh'];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return 'tool/smoke_test.sh';
}
