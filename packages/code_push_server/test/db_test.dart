import 'dart:io';

import 'package:code_push_server/src/config.dart';
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

    test('an ios patch does not evict an active android patch (per-platform '
        'supersession)', () async {
      // Regression: `shorebird patch --platforms=android,ios` publishes TWO
      // patches, one per platform. Promotion used to withdraw every other
      // active patch on the channel, so the ios patch evicted the android one
      // and Android devices got `patch_available: false`.
      final app = await repo.createApp('multi', 1);
      final rel = await repo.createRelease(
        appId: app.appId,
        version: '1.0.0+1',
        flutterRevision: 'abc',
      );
      final ch = await repo.createChannel(app.appId, 'stable');

      Future<int> publish(String platform) async {
        final p = await repo.createPatch(app.appId, rel.id);
        final a = await repo.createArtifact(
          ownerKind: 'patch',
          ownerId: p.id,
          arch: 'aarch64',
          platform: platform,
          hash: 'h-$platform-${p.id}',
          size: 10,
        );
        await repo.setArtifactStatus(a.id, ArtifactStatus.verified);
        await repo.promote(ch.id, p.id);
        return p.id;
      }

      final androidPatch = await publish('android');
      final iosPatch = await publish('ios');

      // Both stay active — they cover different platforms.
      expect(
        (await repo.activeChannelPatch(ch.id, platform: 'android'))?.patchId,
        androidPatch,
        reason: 'android must still be served after ios is promoted',
      );
      expect(
        (await repo.activeChannelPatch(ch.id, platform: 'ios'))?.patchId,
        iosPatch,
      );

      // A NEWER android patch supersedes only the older android one.
      final androidPatch2 = await publish('android');
      expect(
        (await repo.activeChannelPatch(ch.id, platform: 'android'))?.patchId,
        androidPatch2,
      );
      expect(
        (await repo.activeChannelPatch(ch.id, platform: 'ios'))?.patchId,
        iosPatch,
        reason: 'ios must survive an android re-promote',
      );
    });

    test('a single-platform patch does not evict a multi-platform one', () async {
      // The mirror of the test above. Supersession scoped to *any* platform
      // overlap withdrew the whole channel_patches row, so promoting an
      // android-only patch over an active android+ios patch unserved the iOS
      // devices — the same silent fallback, in the other direction. A patch is
      // superseded only when the incoming one covers every platform it carries.
      final app = await repo.createApp('cover', 1);
      final rel = await repo.createRelease(
        appId: app.appId,
        version: '1.0.0+1',
        flutterRevision: 'abc',
      );
      final ch = await repo.createChannel(app.appId, 'stable');

      Future<int> publish(List<String> platforms) async {
        final p = await repo.createPatch(app.appId, rel.id);
        for (final platform in platforms) {
          final a = await repo.createArtifact(
            ownerKind: 'patch',
            ownerId: p.id,
            arch: 'aarch64',
            platform: platform,
            hash: 'h-$platform-${p.id}',
            size: 10,
          );
          await repo.setArtifactStatus(a.id, ArtifactStatus.verified);
        }
        await repo.promote(ch.id, p.id);
        return p.id;
      }

      final both = await publish(['android', 'ios']);
      final androidOnly = await publish(['android']);

      // android moves to the newcomer; ios keeps the incumbent, which stays
      // active because the android-only patch does not cover it.
      expect(
        (await repo.activeChannelPatch(ch.id, platform: 'android'))?.patchId,
        androidOnly,
      );
      expect(
        (await repo.activeChannelPatch(ch.id, platform: 'ios'))?.patchId,
        both,
        reason: 'ios must survive an android-only promote',
      );

      // A patch covering BOTH platforms does supersede the pair.
      final bothAgain = await publish(['android', 'ios']);
      for (final platform in ['android', 'ios']) {
        expect(
          (await repo.activeChannelPatch(ch.id, platform: platform))?.patchId,
          bothAgain,
          reason: platform,
        );
      }
    });

    test('concurrent transactions do not corrupt each other', () async {
      // Regression: SQLite has one connection and no nested transactions, but
      // tx() awaits an async body. Two overlapping promotes used to interleave
      // — the second's BEGIN failed, and its error path issued a ROLLBACK that
      // discarded the FIRST transaction's work. One promote reported success
      // while its row was gone, leaving the stale patch active.
      final app = await repo.createApp('concurrent', 1);
      final rel = await repo.createRelease(
        appId: app.appId,
        version: '1.0.0+1',
        flutterRevision: 'abc',
      );
      final ch = await repo.createChannel(app.appId, 'stable');

      Future<int> patchWithArtifact() async {
        final p = await repo.createPatch(app.appId, rel.id);
        final a = await repo.createArtifact(
          ownerKind: 'patch',
          ownerId: p.id,
          arch: 'aarch64',
          platform: 'android',
          hash: 'h${p.id}',
          size: 10,
        );
        await repo.setArtifactStatus(a.id, ArtifactStatus.verified);
        return p.id;
      }

      final first = await patchWithArtifact();
      final second = await patchWithArtifact();

      // Both promotes are started before either is awaited.
      await Future.wait([
        repo.promote(ch.id, first),
        repo.promote(ch.id, second),
      ]);

      final rows = await repo.db.query(
        'SELECT patch_id, status FROM channel_patches ORDER BY id',
      );
      expect(rows, hasLength(2), reason: 'neither promote may be lost');
      // The later promote supersedes the earlier one on the same platform.
      expect(
        (await repo.activeChannelPatch(ch.id, platform: 'android'))?.patchId,
        second,
      );
    });

    test('housekeeping purges only what has expired', () async {
      await repo.insertAuthCode(
        'live',
        'a@b.c',
        DateTime.now().add(const Duration(minutes: 5)),
      );
      await repo.insertAuthCode(
        'stale',
        'a@b.c',
        DateTime.now().subtract(const Duration(minutes: 5)),
      );
      await repo.insertIdpState(
        'live-state',
        'http://localhost:1/cb',
        DateTime.now().add(const Duration(minutes: 5)),
      );
      await repo.insertIdpState(
        'stale-state',
        'http://localhost:1/cb',
        DateTime.now().subtract(const Duration(minutes: 5)),
      );
      final nowWindow = DateTime.now().millisecondsSinceEpoch ~/ 60000;
      await repo.incrementRateWindow('recent', nowWindow);
      await repo.incrementRateWindow('ancient', nowWindow - 120);

      await repo.purgeExpiredAuthCodes();
      await repo.purgeExpiredIdpStates();
      await repo.purgeOldRateWindows();

      // Query the tables directly. `consumeAuthCode`/`consumeIdpState` filter
      // on `expires_at` themselves, so asserting through them returns null for
      // an expired row whether or not the purge ran — the point here is that
      // the row is *gone*, not merely unusable.
      Future<List<Object?>> col(String sql, String c) async =>
          (await repo.db.query(sql)).map((r) => r[c]).toList();

      expect(await col('SELECT code FROM auth_codes', 'code'), ['live']);
      expect(await col('SELECT state FROM idp_states', 'state'), [
        'live-state',
      ]);
      expect(await col('SELECT bucket FROM rate_limits', 'bucket'), ['recent']);

      // And the live rows are still usable.
      expect(await repo.consumeAuthCode('live'), 'a@b.c');
      expect(await repo.consumeIdpState('live-state'), 'http://localhost:1/cb');
    });

    test('ensureRootOwner grants once and never re-grants', () async {
      // It runs on EVERY boot. Re-asserting the role would silently undo a
      // deliberate demotion, and re-inserting the row would re-admit an
      // operator who had been removed from the org — offboarding by removal
      // would last exactly until the next restart.
      Future<Object?> roleOf(int userId) async {
        for (final m in await repo.orgMembers(1)) {
          if (m['user_id'] == userId) return m['role'];
        }
        return null;
      }

      await repo.ensureRootOwner('ops@example.test');
      final user = (await repo.userByEmail('ops@example.test'))!;
      expect(await roleOf(user.id), 'owner');

      // Demote, then "reboot".
      await repo.setMemberRole(1, user.id, 'developer');
      await repo.ensureRootOwner('ops@example.test');
      expect(await roleOf(user.id), 'developer');

      // Remove, then "reboot".
      await repo.removeMember(1, user.id);
      await repo.ensureRootOwner('ops@example.test');
      expect(await roleOf(user.id), isNull);

      // And no duplicate rows accumulated for the seeded owner.
      expect(await repo.orgMembers(1), hasLength(1));
    });

    test('retention sweeps drop only rows past the cutoff', () async {
      // Both are opt-in (0 = keep forever) and run inside housekeeping()'s
      // catch-all, so a broken statement would be a silent permanent no-op.
      Future<void> event(String key, int daysAgo) => repo.db.query(
        'INSERT INTO events(dedupe_key, raw, received_at) '
        "VALUES (@k, '{}', @t)",
        {
          'k': key,
          't': DateTime.now()
              .toUtc()
              .subtract(Duration(days: daysAgo))
              .toIso8601String(),
        },
      );
      await event('old', 40);
      await event('new', 1);
      await repo.audit('a.old');
      await repo.db.query(
        "UPDATE audit_log SET created_at = @t WHERE action = 'a.old'",
        {
          't': DateTime.now()
              .toUtc()
              .subtract(const Duration(days: 40))
              .toIso8601String(),
        },
      );
      await repo.audit('a.new');

      // 0 keeps everything — the default, so this must not delete.
      await repo.purgeOldEvents(0);
      await repo.purgeOldAuditLog(0);
      expect(await repo.db.query('SELECT id FROM events'), hasLength(2));
      expect(await repo.db.query('SELECT id FROM audit_log'), hasLength(2));

      await repo.purgeOldEvents(30);
      await repo.purgeOldAuditLog(30);
      expect(
        (await repo.db.query(
          'SELECT dedupe_key FROM events',
        )).map((r) => r['dedupe_key']),
        ['new'],
      );
      expect(
        (await repo.db.query(
          'SELECT action FROM audit_log',
        )).map((r) => r['action']),
        ['a.new'],
      );
    });

    test('an IdP state is single-use', () async {
      await repo.insertIdpState(
        's1',
        'http://localhost:1/cb',
        DateTime.now().add(const Duration(minutes: 5)),
      );
      expect(await repo.consumeIdpState('s1'), 'http://localhost:1/cb');
      expect(await repo.consumeIdpState('s1'), isNull);
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

    group('root owner seeding across an IdP change', () {
      // WAS: skipping `ensureRootOwner` when the IdP is enabled only helped a
      // stack that had the IdP configured on its FIRST boot. A stack that ran
      // in self-consent mode first already had the placeholder in org_members,
      // and that row outlived the config change — so once the broker was turned
      // on, anyone who could present `you@example.com` to it landed on a
      // root-org owner (and with it `POST /admin/users`).
      const placeholder = Config.placeholderLoginEmail;

      Future<bool> ownsRootOrg(String email) async {
        final user = await repo.userByEmail(email);
        if (user == null) return false;
        return (await repo.memberships(
          user.id,
        )).any((m) => m.orgId == 1 && m.role == 'owner');
      }

      test('self-consent grants the placeholder root ownership', () async {
        await repo.close();
        repo = await Repository.open(
          sqliteConfig(tmp.path, loginEmail: placeholder),
        );
        expect(await ownsRootOrg(placeholder), isTrue);
      });

      test('enabling the IdP later revokes it', () async {
        await repo.close();
        repo = await Repository.open(
          sqliteConfig(tmp.path, loginEmail: placeholder),
        );
        expect(await ownsRootOrg(placeholder), isTrue);

        // Same database, IdP now configured.
        await repo.close();
        repo = await Repository.open(
          sqliteConfig(tmp.path, loginEmail: placeholder, idpEnabled: true),
        );
        expect(await ownsRootOrg(placeholder), isFalse);
        expect(
          await repo.getSetting('root_owner_seeded:$placeholder'),
          isNull,
          reason: 'the marker must go too, or the grant can never be remade',
        );
      });

      test('a real operator address is left alone', () async {
        const operator = 'admin@example.test';
        await repo.close();
        repo = await Repository.open(
          sqliteConfig(tmp.path, loginEmail: operator),
        );
        expect(await ownsRootOrg(operator), isTrue);

        await repo.close();
        repo = await Repository.open(
          sqliteConfig(tmp.path, loginEmail: operator, idpEnabled: true),
        );
        expect(
          await ownsRootOrg(operator),
          isTrue,
          reason: 'revoking this would lock out the operator who set it up',
        );
      });

      test('an ownership granted through the API survives', () async {
        // No seed marker, so the revoke must not touch it even though the
        // address happens to be the placeholder.
        await repo.close();
        repo = await Repository.open(sqliteConfig(tmp.path, idpEnabled: true));
        final user = await repo.upsertUser(placeholder, null);
        await repo.db.query(
          "INSERT INTO org_members(org_id, user_id, role) "
          "VALUES (1, @u, 'owner')",
          {'u': user.id},
        );
        expect(await ownsRootOrg(placeholder), isTrue);

        await repo.close();
        repo = await Repository.open(sqliteConfig(tmp.path, idpEnabled: true));
        expect(await ownsRootOrg(placeholder), isTrue);
      });
    });
  });
}
