@Tags(['integration'])
library;

import 'dart:io';

import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:test/test.dart';

/// Replicas that boot together must not race the same migration.
///
/// Needs an EMPTY Postgres database in `DATABASE_URL` (CI's `postgres` job runs
/// it before anything else migrates that database):
///
///   INTEGRATION=1 DATABASE_URL=postgres://cps:pw@localhost:5432/empty_db \
///   dart test --tags integration test/integration/migration_lock_pg_test.dart
void main() {
  final env = Platform.environment;
  final url = env['DATABASE_URL'] ?? '';
  final skip = env['INTEGRATION'] != '1' || url.isEmpty
      ? 'opt-in: set INTEGRATION=1 and DATABASE_URL (an empty database)'
      : null;

  test('concurrent first boots all migrate cleanly, once', () async {
    final cfg = Config.fromEnv({'DATABASE_URL': url});
    final repos = await Future.wait([
      for (var i = 0; i < 4; i++) Repository.open(cfg),
    ]);
    try {
      final rows = await repos.first.db.query(
        'SELECT count(*) AS n, count(DISTINCT version) AS d '
        'FROM schema_migrations',
      );
      expect(rows.single['n'], rows.single['d']);
      expect(rows.single['n'] as num, greaterThan(1));
    } finally {
      for (final r in repos) {
        await r.db.close();
      }
    }
  }, skip: skip);
}
