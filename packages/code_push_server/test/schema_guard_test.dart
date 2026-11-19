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

  group('migration 19 (rollout in hundredths of a percent)', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('cps_mig19'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('backfills existing rows from rollout, so none changes', () async {
      var repo = await Repository.open(sqliteConfig(tmp.path));
      final org = (await repo.db.query('SELECT id FROM organizations')).first;
      final app = await repo.createApp('a', (org['id']! as num).toInt());
      final rel = await repo.createRelease(appId: app.appId, version: '1.0.0');
      final ch = await repo.createChannel(app.appId, 'stable');
      final ids = <int>[];
      for (final percent in [0, 25, 100]) {
        final p = await repo.createPatch(app.appId, rel.id);
        await repo.promote(ch.id, p.id, rolloutBps: percent * 100);
        ids.add(p.id);
      }
      // Put the database back as a server before migration 19 left it: no
      // `rollout_bps` column, and the migration not recorded.
      await repo.db.query(
        'ALTER TABLE channel_patches DROP COLUMN rollout_bps',
      );
      await repo.db.query('DELETE FROM schema_migrations WHERE version >= 19');
      await repo.db.query('DROP TABLE build_runs');
      await repo.db.query(
        'ALTER TABLE channel_patches DROP COLUMN rollout_schedule',
      );
      await repo.close();

      repo = await Repository.open(sqliteConfig(tmp.path));
      final rows = await repo.db.query(
        'SELECT patch_id, rollout, rollout_bps FROM channel_patches '
        'ORDER BY patch_id',
      );
      expect(
        [for (final r in rows) (r['rollout'], r['rollout_bps'])],
        [(0, 0), (25, 2500), (100, 10000)],
      );
      final deployments = await repo.patchDeployments(ids[1]);
      expect(deployments.single['rollout_percentage'], 25);
      await repo.close();
    });
  });

  group('migration 22 (one live artifact per patch architecture)', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('cps_mig22'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test(
      'a duplicate pair keeps the lower id live and gets the index',
      () async {
        var repo = await Repository.open(sqliteConfig(tmp.path));
        final org = (await repo.db.query('SELECT id FROM organizations')).first;
        final app = await repo.createApp('a', (org['id']! as num).toInt());
        final rel = await repo.createRelease(
          appId: app.appId,
          version: '1.0.0',
        );
        final p = await repo.createPatch(app.appId, rel.id);
        // The database as version 21 left it: no index, migration unrecorded.
        await repo.db.query('DROP INDEX artifacts_one_live');
        await repo.db.query(
          'DELETE FROM schema_migrations WHERE version >= 22',
        );
        Future<int> add(String arch) async => (await repo.createArtifact(
          ownerKind: 'patch',
          ownerId: p.id,
          arch: arch,
          platform: 'windows',
          hash: 'h',
          size: 1,
        )).id;
        final low = await add('aarch64');
        final high = await add('aarch64');
        final other = await add('x86_64');
        await repo.close();

        repo = await Repository.open(sqliteConfig(tmp.path));
        final rows = await repo.db.query(
          'SELECT id, status FROM artifacts ORDER BY id',
        );
        final status = {
          for (final r in rows) (r['id']! as num).toInt(): r['status'],
        };
        expect(status[low], isNot('failed'));
        expect(status[high], 'failed');
        expect(status[other], isNot('failed'));
        expect(
          await repo.db.query(
            "SELECT name FROM sqlite_master WHERE name = 'artifacts_one_live'",
          ),
          isNotEmpty,
        );
        await repo.close();
      },
    );
  });
}
