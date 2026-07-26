import 'package:code_push_server/src/api.dart';
import 'package:test/test.dart';

void main() {
  group('rateLimitKey', () {
    test('authenticated requests bucket by bearer, regardless of IP', () {
      expect(
        rateLimitKey(auth: 'Bearer abc', remoteIp: '1.1.1.1'),
        'auth:Bearer abc',
      );
      // Same bearer from a different IP shares the same bucket.
      expect(
        rateLimitKey(auth: 'Bearer abc', remoteIp: '2.2.2.2'),
        'auth:Bearer abc',
      );
    });

    test('unauthenticated device requests bucket by client IP', () {
      expect(rateLimitKey(remoteIp: '10.0.0.7'), 'ip:10.0.0.7');
    });

    test(
      'different devices get different buckets (the fleet-throttle fix)',
      () {
        // Regression: previously all unauthenticated traffic shared one "anon"
        // bucket, so a fleet larger than the per-minute limit throttled itself.
        expect(
          rateLimitKey(remoteIp: '10.0.0.7'),
          isNot(rateLimitKey(remoteIp: '10.0.0.8')),
        );
      },
    );

    test('honors the first X-Forwarded-For hop behind a proxy', () {
      expect(
        rateLimitKey(
          forwardedFor: '203.0.113.5, 10.0.0.1',
          remoteIp: '10.0.0.1',
        ),
        'ip:203.0.113.5',
      );
    });

    test('empty auth / forwarded-for are ignored', () {
      expect(rateLimitKey(auth: '', remoteIp: '9.9.9.9'), 'ip:9.9.9.9');
      expect(rateLimitKey(forwardedFor: '', remoteIp: '9.9.9.9'), 'ip:9.9.9.9');
    });

    test('falls back to unknown when neither auth nor IP is present', () {
      expect(rateLimitKey(), 'ip:unknown');
    });
  });
}
