import 'dart:io';

import 'package:code_push_server/src/repository.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  // A rollback moves the binary back. It does not move the schema back, so an
  // old server can meet a database a newer one has already migrated.
  //
  // The migration loop skips versions it does not recognise, which means that
  // WITHOUT this guard the old binary boots, answers /healthz and /readyz with
  // 200, serves every table the newer schema did not touch, and 500s the
  // device update path. Measured 2026-09-06 (UPGRADE-ROLLBACK-1): an
  // orchestrator sees a ready server while every device sees a broken one.
  group('schema version guard', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('cps_schema_guard'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('refuses a database migrated by a newer server', () async {
      // Bring a database up to this binary's own schema first, so the only
      // thing that changes below is the recorded version.
      final repo = await Repository.open(sqliteConfig(tmp.path));
      final rows = await repo.db.query(
        'SELECT max(version) AS v FROM schema_migrations',
      );
      final current = (rows.first['v']! as num).toInt();
      // A version this binary does not implement, as a newer release would
      // have left behind.
      await repo.db.query(
        'INSERT INTO schema_migrations(version) VALUES (@v)',
        {'v': current + 1},
      );
      await repo.close();

      await expectLater(
        Repository.open(sqliteConfig(tmp.path)),
        throwsA(
          isA<SchemaTooNewException>()
              .having((e) => e.applied, 'applied', current + 1)
              .having((e) => e.known, 'known', current),
        ),
      );
    });

    test(
      'opens normally when the database is at this binary\'s own version',
      () async {
        // The control that proves the guard did not simply break startup: the
        // ordinary case must still work, twice, because the second open is the
        // one that reads a fully-migrated database rather than creating it.
        final first = await Repository.open(sqliteConfig(tmp.path));
        await first.close();
        final second = await Repository.open(sqliteConfig(tmp.path));
        expect(second, isNotNull);
        await second.close();
      },
    );
  });
}
