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

  group('rollout in basis points', () {
    bool eligible(int bps, String? clientId) => eligibleForRolloutBps(
      appId: 'app',
      channelId: 1,
      patchId: 1,
      rolloutBps: bps,
      clientId: clientId,
    );

    test('a whole percent is the same decision as the percent function', () {
      for (var i = 0; i < 500; i++) {
        for (final percent in [1, 10, 50, 99]) {
          expect(
            eligible(percent * 100, 'client-$i'),
            eligibleForRollout(
              appId: 'app',
              channelId: 1,
              patchId: 1,
              rollout: percent,
              clientId: 'client-$i',
            ),
          );
        }
      }
    });

    test('0.01% is one bucket in ten thousand and 100% is everyone', () {
      var one = 0;
      for (var i = 0; i < 20000; i++) {
        if (eligible(1, 'client-$i')) one++;
        expect(eligible(10000, 'client-$i'), isTrue);
      }
      expect(one, lessThan(20));
    });

    test('12.5% reaches about an eighth of the clients', () {
      var n = 0;
      for (var i = 0; i < 4000; i++) {
        if (eligible(1250, 'client-$i')) n++;
      }
      expect(n / 4000, inInclusiveRange(0.10, 0.15));
    });

    test('raising a rollout never removes a client', () {
      for (var i = 0; i < 1000; i++) {
        if (eligible(1250, 'client-$i')) {
          expect(eligible(1251, 'client-$i'), isTrue);
          expect(eligible(5000, 'client-$i'), isTrue);
        }
      }
    });

    test('a partial rollout fails closed without a client id', () {
      expect(eligible(9999, null), isFalse);
      expect(eligible(9999, ''), isFalse);
      expect(eligible(10000, null), isTrue);
      expect(eligible(0, 'client'), isFalse);
    });
  });

  group('parseRolloutPercentage', () {
    int parse(Object? v) => parseRolloutPercentage(v, field: 'p');

    test('accepts multiples of 0.01 from 0.01 to 100', () {
      expect(parse(100), 10000);
      expect(parse(100.0), 10000);
      expect(parse(0.01), 1);
      expect(parse(12.5), 1250);
      expect(parse(33.33), 3333);
      expect(parse(0.29), 29);
    });

    test('refuses everything else', () {
      for (final v in [0, 0.0, -1, 100.01, 101, 0.001, 12.345, '10', null]) {
        expect(() => parse(v), throwsFormatException, reason: '$v');
      }
      expect(() => parse(double.nan), throwsFormatException);
      expect(() => parse(double.infinity), throwsFormatException);
    });
  });

  group('effectiveRolloutBps', () {
    test('uses rollout_bps when it agrees with rollout', () {
      expect(effectiveRolloutBps({'rollout': 12, 'rollout_bps': 1250}), 1250);
    });

    test('falls back to rollout for a row an older server wrote', () {
      expect(effectiveRolloutBps({'rollout': 50, 'rollout_bps': null}), 5000);
      // An older server raised `rollout` and left a stale `rollout_bps`.
      expect(effectiveRolloutBps({'rollout': 80, 'rollout_bps': 1250}), 8000);
    });
  });

  test('percentageOf keeps whole percentages integers', () {
    expect(percentageOf(5000), 50);
    expect(percentageOf(5000), isA<int>());
    expect(percentageOf(1250), 12.5);
  });
}
