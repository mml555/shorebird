import 'package:code_push_server/src/rollout.dart';
import 'package:test/test.dart';

void main() {
  group('rolloutBucket', () {
    test('is within [0, 10000)', () {
      for (var i = 0; i < 1000; i++) {
        final bucket = rolloutBucket('app', 1, 2, 'client-$i');
        expect(bucket, inInclusiveRange(0, 9999));
      }
    });

    test('is deterministic: same inputs produce the same bucket', () {
      final a = rolloutBucket('app-abc', 3, 7, 'client-xyz');
      final b = rolloutBucket('app-abc', 3, 7, 'client-xyz');
      expect(a, equals(b));
    });

    test('different clientId generally produces a different bucket', () {
      final buckets = <int>{};
      for (var i = 0; i < 200; i++) {
        buckets.add(rolloutBucket('app', 1, 1, 'client-$i'));
      }
      // With 200 distinct client ids the hash should spread widely; require a
      // large number of distinct buckets (collisions are possible but rare).
      expect(buckets.length, greaterThan(190));
    });

    test('varying any promotion component changes the bucket space', () {
      final base = rolloutBucket('app', 1, 1, 'client');
      final diffApp = rolloutBucket('app2', 1, 1, 'client');
      final diffChannel = rolloutBucket('app', 2, 1, 'client');
      final diffPatch = rolloutBucket('app', 1, 2, 'client');
      expect({base, diffApp, diffChannel, diffPatch}.length, greaterThan(1));
    });
  });

  group('eligibleForRollout', () {
    bool eligible(int rollout, String? clientId) => eligibleForRollout(
      appId: 'app',
      channelId: 1,
      patchId: 1,
      rollout: rollout,
      clientId: clientId,
    );

    test('rollout >= 100 is always eligible, even with a null clientId', () {
      expect(eligible(100, null), isTrue);
      expect(eligible(150, null), isTrue);
      expect(eligible(100, 'client'), isTrue);
    });

    test('rollout <= 0 is never eligible', () {
      expect(eligible(0, 'client'), isFalse);
      expect(eligible(-10, 'client'), isFalse);
    });

    test('partial rollout fails closed with null or empty clientId', () {
      expect(eligible(50, null), isFalse);
      expect(eligible(50, ''), isFalse);
    });

    test('partial rollout at 25% distributes roughly proportionally', () {
      var eligibleCount = 0;
      const total = 1000;
      for (var i = 0; i < total; i++) {
        if (eligible(25, 'client-$i')) eligibleCount++;
      }
      final fraction = eligibleCount / total;
      expect(fraction, inInclusiveRange(0.18, 0.32));
    });

    test('partial rollout at 50% distributes roughly proportionally', () {
      var eligibleCount = 0;
      const total = 1000;
      for (var i = 0; i < total; i++) {
        if (eligible(50, 'client-$i')) eligibleCount++;
      }
      final fraction = eligibleCount / total;
      expect(fraction, inInclusiveRange(0.42, 0.58));
    });

    test('thresholds are nested: eligible at 25% implies eligible at 50%', () {
      for (var i = 0; i < 1000; i++) {
        final clientId = 'client-$i';
        if (eligible(25, clientId)) {
          expect(
            eligible(50, clientId),
            isTrue,
            reason: '$clientId eligible at 25% must also be eligible at 50%',
          );
        }
      }
    });
  });
}
