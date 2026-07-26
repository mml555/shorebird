import 'dart:io';

import 'package:code_push_server/src/analytics.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  // Verifies the analytics date SQL (truncPeriod/extractDow/extractHour) runs on
  // the SQLite backend — i.e. the dashboard works in single-container mode.
  group('Analytics on SQLite', () {
    late Directory tmp;
    late Repository repo;
    late Analytics analytics;
    late String appId;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('cps_an_test');
      repo = await Repository.open(sqliteConfig(tmp.path));
      analytics = Analytics(repo.db);
      final app = await repo.createApp('demo', 1);
      appId = app.appId;
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      Future<void> ev(String client, String type, int agoHours) =>
          repo.insertEvent(
            raw: '{}',
            dedupeKey: '$client-$type-$agoHours',
            appId: appId,
            clientId: client,
            type: type,
            patchNumber: 1,
            platform: 'android',
            releaseVersion: '1.0.0+1',
            ts: now - agoHours * 3600,
          );
      await ev('c1', '__patch_download__', 1);
      await ev('c1', '__patch_install__', 1);
      await ev('c2', '__patch_download__', 2);
      await ev('c2', '__patch_install__', 25);
    });

    tearDown(() async {
      await repo.close();
      tmp.deleteSync(recursive: true);
    });

    test(
      'every analytics endpoint executes and returns its DTO shape',
      () async {
        final adoption = await analytics.patchAdoption(
          appId,
          granularity: 'day',
        );
        expect(adoption['patches'], isA<List<Object?>>());

        final uu = await analytics.uniqueUsers(appId, granularity: 'day');
        final cur = uu['current']! as Map<String, Object?>;
        expect(cur['unique_users'], 2); // c1 + c2
        expect(cur['time_series'], isA<List<Object?>>());

        final vd = await analytics.versionDistribution(appId);
        expect(vd['total_devices'], 2);
        expect(
          (vd['entries']! as List).single,
          containsPair('release_version', '1.0.0+1'),
        );

        final heat = await analytics.activityHeatmap(appId);
        expect((heat['cells']! as List).length, 168); // 7 x 24

        final hours = await analytics.activeHours(appId);
        expect((hours['hourly']! as List).length, 24);

        final nd = await analytics.newDevices(appId);
        expect(nd['current'], 2); // both first-seen in-window

        final installs = await analytics.patchMetric(
          appId,
          metric: 'installs',
          granularity: 'week',
        );
        expect((installs['current']! as Map)['count'], 2); // 2 install events
      },
    );

    test(
      'weekly bucketing groups events (Postgres-compatible Monday weeks)',
      () async {
        final m = await analytics.patchMetric(
          appId,
          metric: 'downloads',
          granularity: 'week',
        );
        final series = (m['current']! as Map)['time_series']! as List;
        // Both downloads fall in the trailing window; bucket periods are ISO UTC.
        expect(series, isNotEmpty);
        for (final b in series) {
          expect((b as Map)['period'], matches(r'^\d{4}-\d{2}-\d{2}T'));
        }
      },
    );
  });
}
