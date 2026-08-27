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
      String rev = 'f729f958e9be',
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
      updaterRevision: rev,
    );

    test('a non-terminal lifecycle event is accepted and stored', () async {
      expect(await put('ambiguous_boot_retry', attempt: 1), isTrue);
      final m = await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.a);
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

        final m = await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.a);
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

      final m = (await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.a)).first;
      expect(m['first_ambiguity'], 2, reason: 'two devices hit a first ambiguity');
      expect(m['recovered'], 1);
      expect(m['second_ambiguity'], 1);
      expect(m['retired'], 1);
      // P(recovery | first ambiguity) = 1/2 — computable, which is the point.
    });

    test('clients are counted once each, not per row', () async {
      await put('ambiguous_boot_retry', client: 'a', attempt: 1);
      await put('ambiguous_boot_retry', client: 'a', attempt: 1, ts: 2000);
      final m = (await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.a)).first;
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
      expect(await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.a), isEmpty);
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
        await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.a),
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
      final m = await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.a);
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
      expect(await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.a), isEmpty);
    });

    // ---- EPOCHS DO NOT POOL ----------------------------------------------
    // The flat allow-list this replaced had one fatal property: adding a
    // revision silently merged its clients with every earlier one. These pin
    // that it cannot happen again.

    test('the ACTIVE epoch is B, activated on af6e842ccf87 alone', () async {
      expect(Repository.activePolicyEpoch, PolicyEpoch.b);
      expect(PolicyEpoch.b.updaterRevisions, {'af6e842ccf87'});
      // Activation did NOT widen the predicate: an Epoch A row is still
      // invisible to the active epoch.
      await put('ambiguous_boot_retry', attempt: 1);
      expect(await repo.bootLifecycleMetrics('app'), isEmpty);
    });

    test('an af6e842ccf87 lifecycle row is visible to B, not to A', () async {
      // The other direction of the separation. Before activation this row
      // belonged to no epoch; now it belongs to exactly one.
      await put('ambiguous_boot_retry', attempt: 1, rev: 'af6e842ccf87');

      final b = await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.b);
      expect(b, hasLength(1));
      expect(b.first['first_ambiguity'], 1);

      final a = await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.a);
      expect(a, isEmpty, reason: 'a closed epoch must not absorb later clients');
    });

    test('the epochs PARTITION the rows rather than pooling them', () async {
      // One client per revision. Each epoch sees exactly its own, and neither
      // ever reports the sum.
      await put('ambiguous_boot_retry', attempt: 1, client: 'old-1');
      await put(
        'ambiguous_boot_retry',
        attempt: 1,
        client: 'new-1',
        ts: 2000,
        rev: 'af6e842ccf87',
      );
      final a = await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.a);
      final b = await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.b);
      expect(a, hasLength(1));
      expect(a.first['first_ambiguity'], 1);
      expect(b, hasLength(1));
      expect(b.first['first_ambiguity'], 1);
    });

    test("epoch A's clients never count toward epoch B", () async {
      // The load-bearing separation. Same app, same rows, two epochs: A sees
      // them, B does not. If someone later unions the revision sets, this fails.
      await put('ambiguous_boot_retry', attempt: 1);
      final a = await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.a);
      expect(a, hasLength(1));
      expect(a.first['first_ambiguity'], 1);

      final b = await repo.bootLifecycleMetrics('app', epoch: PolicyEpoch.b);
      expect(b, isEmpty, reason: 'epoch B must start from zero');
    });

    test('the empty-set guard is RETAINED and currently dormant', () async {
      // Every epoch is activated now, so the early return in
      // bootLifecycleMetrics is unreachable today. It stays because the NEXT
      // epoch will have a defined-but-unactivated window, and in that window
      // `IN ()` is a SQL syntax error rather than an empty match -- whose
      // tempting "fix" is dropping the predicate, which pools every revision.
      // Asserted so the guard is not deleted as dead code.
      expect(
        PolicyEpoch.values.every((e) => e.updaterRevisions.isNotEmpty),
        isTrue,
        reason: 'an unactivated epoch now exists, so the guard is live again -- '
            'test it directly rather than removing it',
      );
    });

    test('epoch A is closed and epoch B is not', () async {
      expect(PolicyEpoch.a.closed, isTrue);
      expect(PolicyEpoch.b.closed, isFalse);
      // Each epoch records the cell its lifecycle behaviour shipped in, so the
      // sample can always be tied back to the runtime that produced it.
      expect(PolicyEpoch.a.cell, startsWith('2c4443ce'));
      expect(PolicyEpoch.b.cell, startsWith('4792f0ec'));
    });
  });
}
