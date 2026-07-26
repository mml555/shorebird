import 'dart:io';

import 'package:code_push_server/src/domain.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('SQLite repository (single-container backend)', () {
    late Directory tmp;
    late Repository repo;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('cps_db_test');
      repo = await Repository.open(sqliteConfig(tmp.path));
    });

    tearDown(() async {
      await repo.close();
      tmp.deleteSync(recursive: true);
    });

    test(
      'seed created org 1 (the @ in owner@self-host.local survives)',
      () async {
        // Regression: the seed email must not be mangled by @param substitution.
        final u = await repo.userById(1);
        expect(u?.email, 'owner@self-host.local');
      },
    );

    test('full release -> patch -> promote -> rollback round-trip', () async {
      final app = await repo.createApp('demo', 1);
      expect(app.appId, isNotEmpty);

      final rel = await repo.createRelease(
        appId: app.appId,
        version: '1.0.0+1',
        flutterRevision: 'abc',
      );
      expect(rel.lifecycle, ReleaseLifecycle.draft);

      final art = await repo.createArtifact(
        ownerKind: 'release',
        ownerId: rel.id,
        arch: 'aarch64',
        platform: 'android',
        hash: 'h',
        size: 10,
      );
      expect(
        art.canSideload,
        isFalse,
      ); // boolean round-trips across the backend
      await repo.setArtifactStatus(art.id, ArtifactStatus.verified);
      expect(
        (await repo.artifactByToken(art.token))!.status,
        ArtifactStatus.verified,
      );

      final patch = await repo.createPatch(app.appId, rel.id);
      expect(patch.number, 1);

      final ch = await repo.createChannel(app.appId, 'stable');
      await repo.promote(ch.id, patch.id);
      final active = await repo.activeChannelPatch(ch.id);
      expect(active!.patchId, patch.id);
      expect(active.rolledBack, isFalse);

      await repo.withdraw(ch.id, patch.id, rollback: true);
      expect(await repo.rolledBackPatchNumbers(ch.id, rel.id), [1]);
    });

    test('events are idempotent and feed patch metrics', () async {
      final app = await repo.createApp('m', 1);
      final ins = await repo.insertEvent(
        raw: '{}',
        dedupeKey: 'k1',
        appId: app.appId,
        clientId: 'c1',
        type: '__patch_download__',
        patchNumber: 1,
      );
      final dup = await repo.insertEvent(
        raw: '{}',
        dedupeKey: 'k1',
        appId: app.appId,
        clientId: 'c1',
        type: '__patch_download__',
        patchNumber: 1,
      );
      expect(ins, isTrue);
      expect(dup, isFalse); // deduped

      final metrics = await repo.patchMetrics(app.appId);
      expect(metrics.single['downloads'], 1);
      expect(metrics.single['unique_clients'], 1);
    });

    test('data persists across a reopen', () async {
      await repo.createApp('persisted', 1);
      final k = await repo.getOrCreateSetting('sig', () => 'first');
      expect(k, 'first');
      expect(await repo.getOrCreateSetting('sig', () => 'second'), 'first');
      await repo.close();

      repo = await Repository.open(sqliteConfig(tmp.path));
      expect((await repo.apps()).length, 1);
      expect(await repo.getSetting('sig'), 'first');
    });
  });
}
