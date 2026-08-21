import 'dart:io';

import 'package:code_push_server/src/api.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Server-side acceptance of the non-terminal boot-lifecycle observation.
///
/// Step 1 of the telemetry path: the control plane must accept and correlate
/// these events BEFORE any client emits them, so the first production cohort to
/// receive C3 retry behaviour is measured rather than lost.
void main() {
  group('boot lifecycle events', () {
    late Directory tmp;
    late Repository repo;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('cps_lifecycle_test');
      repo = await Repository.open(sqliteConfig(tmp.path));
    });

    tearDown(() async {
      await repo.close();
      tmp.deleteSync(recursive: true);
    });

    Future<bool> put(
      String outcome, {
      String client = 'dev-1',
      int patch = 1,
      int? attempt,
      int ts = 1000,
    }) => repo.insertEvent(
      raw: '{"outcome":"$outcome"}',
      dedupeKey:
          '$client|app|1.0.0+1|$patch|__patch_boot_lifecycle__|$ts|$outcome',
      appId: 'app',
      clientId: client,
      type: '__patch_boot_lifecycle__',
      patchNumber: patch,
      releaseVersion: '1.0.0+1',
      ts: ts,
      outcome: outcome,
      ambiguousAttemptCount: attempt,
      bootFailureThreshold: 2,
      bootStartedAt: 999,
      updaterRevision: 'f729f958e9be',
    );

    test('a non-terminal lifecycle event is accepted and stored', () async {
      expect(await put('ambiguous_boot_retry', attempt: 1), isTrue);
      final m = await repo.bootLifecycleMetrics('app');
      expect(m, hasLength(1));
      expect(m.first['first_ambiguity'], 1);
      expect(m.first['recovered'], 0);
    });

    test('the ENDPOINT derives different keys for different outcomes', () {
      // THE ACTUAL REGRESSION, tested where it lives. Asserting this through
      // insertEvent would only prove the DB keeps two rows with two different
      // keys — it would pass even if the endpoint produced one key for both.
      base(String outcome) => {
        'client_id': 'dev-1',
        'app_id': 'app',
        'release_version': '1.0.0+1',
        'patch_number': 1,
        'type': '__patch_boot_lifecycle__',
        'timestamp': 1000,
        'outcome': outcome,
      };
      expect(
        eventDedupeKey(base('ambiguous_boot_retry')),
        isNot(eventDedupeKey(base('recovered_after_ambiguity'))),
        reason: 'same second, same patch, different outcome must not collide',
      );
    });

    test('keys for pre-existing event types are byte-identical', () {
      // Guards the upgrade: appending `outcome` must not perturb the key of any
      // event that has no outcome, or every device re-reports once on upgrade.
      expect(
        eventDedupeKey({
          'client_id': 'dev-1',
          'app_id': 'app',
          'release_version': '1.0.0+1',
          'patch_number': 1,
          'type': '__patch_install__',
          'timestamp': 1000,
        }),
        'dev-1|app|1.0.0+1|1|__patch_install__|1000',
      );
    });

    test(
      'retry and recovery in the SAME SECOND are both kept',
      () async {
        // THE REGRESSION THIS FILE EXISTS FOR. The dedupe key was
        // client|app|release|patch|type|timestamp, so an ambiguous retry at init
        // and the recovery from that same launch's success collided and the
        // RECOVERY was silently dropped — biasing P(recovery | first ambiguity)
        // downward, the exact number the threshold is judged on.
        expect(await put('ambiguous_boot_retry', attempt: 1), isTrue);
        expect(await put('recovered_after_ambiguity'), isTrue);

        final m = await repo.bootLifecycleMetrics('app');
        expect(m.first['first_ambiguity'], 1);
        expect(m.first['recovered'], 1, reason: 'recovery must not be deduped away');
      },
    );

    test('a genuine duplicate is still rejected', () async {
      expect(await put('ambiguous_boot_retry', attempt: 1), isTrue);
      expect(
        await put('ambiguous_boot_retry', attempt: 1),
        isFalse,
        reason: 'same outcome, same second, same patch is a real duplicate',
      );
    });

    test('recovery and retirement are separable populations', () async {
      await put('ambiguous_boot_retry', client: 'a', attempt: 1);
      await put('recovered_after_ambiguity', client: 'a');

      await put('ambiguous_boot_retry', client: 'b', attempt: 1);
      await put('ambiguous_boot_retry', client: 'b', attempt: 2, ts: 2000);
      await put('retired_after_ambiguity', client: 'b', ts: 2000);

      final m = (await repo.bootLifecycleMetrics('app')).first;
      expect(m['first_ambiguity'], 2, reason: 'two devices hit a first ambiguity');
      expect(m['recovered'], 1);
      expect(m['second_ambiguity'], 1);
      expect(m['retired'], 1);
      // P(recovery | first ambiguity) = 1/2 — computable, which is the point.
    });

    test('clients are counted once each, not per row', () async {
      await put('ambiguous_boot_retry', client: 'a', attempt: 1);
      await put('ambiguous_boot_retry', client: 'a', attempt: 1, ts: 2000);
      final m = (await repo.bootLifecycleMetrics('app')).first;
      expect(m['first_ambiguity'], 1, reason: 're-reporting must not inflate it');
    });

    test('an event with NO updater revision is ineligible', () async {
      // Strictness in the safe direction: an unknown client cannot be assumed to
      // carry the event-loss fixes, so it under-counts rather than fabricating.
      await repo.insertEvent(
        raw: '{}',
        dedupeKey: 'norev|app|1.7.0+1|1|__patch_boot_lifecycle__|5|ambiguous_boot_retry',
        appId: 'app',
        clientId: 'norev',
        type: '__patch_boot_lifecycle__',
        patchNumber: 1,
        releaseVersion: '1.7.0+1',
        ts: 5,
        outcome: 'ambiguous_boot_retry',
        ambiguousAttemptCount: 1,
      );
      expect(await repo.bootLifecycleMetrics('app'), isEmpty);
    });

    test('pre-epoch releases are excluded from the estimator', () async {
      // The pre-epoch bugs zeroed the recovery numerator while leaving the
      // denominator intact, so including these rows biases the estimate toward
      // zero rather than merely adding noise.
      await repo.insertEvent(
        raw: '{}',
        dedupeKey: 'old|app|1.5.0+1|1|__patch_boot_lifecycle__|1|ambiguous_boot_retry',
        appId: 'app',
        clientId: 'old',
        type: '__patch_boot_lifecycle__',
        patchNumber: 1,
        releaseVersion: '1.5.0+1',
        ts: 1,
        outcome: 'ambiguous_boot_retry',
        ambiguousAttemptCount: 1,
      );
      expect(
        await repo.bootLifecycleMetrics('app'),
        isEmpty,
        reason: 'a pre-epoch row must not reach the estimator',
      );

      // A post-epoch row is counted.
      await repo.insertEvent(
        raw: '{}',
        dedupeKey: 'new|app|1.7.0+1|1|__patch_boot_lifecycle__|1|ambiguous_boot_retry',
        appId: 'app',
        clientId: 'new',
        type: '__patch_boot_lifecycle__',
        patchNumber: 1,
        releaseVersion: '1.7.0+1',
        ts: 1,
        outcome: 'ambiguous_boot_retry',
        ambiguousAttemptCount: 1,
        updaterRevision: 'f729f958e9be',
      );
      final m = await repo.bootLifecycleMetrics('app');
      expect(m, hasLength(1));
      expect(m.first['release_version'], '1.7.0+1');
      expect(m.first['first_ambiguity'], 1);
    });

    test('pre-existing event types are unaffected', () async {
      // No outcome -> excluded from lifecycle metrics, dedupe key unchanged.
      expect(
        await repo.insertEvent(
          raw: '{}',
          dedupeKey: 'dev|app|1.0.0+1|1|__patch_install__|1000',
          appId: 'app',
          clientId: 'dev-1',
          type: '__patch_install__',
          patchNumber: 1,
          releaseVersion: '1.0.0+1',
          ts: 1000,
        ),
        isTrue,
      );
      expect(await repo.bootLifecycleMetrics('app'), isEmpty);
    });
  });
}
