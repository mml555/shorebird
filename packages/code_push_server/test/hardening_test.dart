import 'package:code_push_server/src/api.dart';
import 'package:code_push_server/src/observability.dart';
import 'package:test/test.dart';

void main() {
  group('Metrics.render (Prometheus exposition)', () {
    test('counts requests by method and status class', () {
      final m = Metrics()
        ..record('GET', 200, 5)
        ..record('GET', 204, 3)
        ..record('POST', 500, 12)
        ..record('GET', 404, 1);
      final out = m.render();
      expect(
        out,
        contains('code_push_requests_total{method="GET",status="2xx"} 2'),
      );
      expect(
        out,
        contains('code_push_requests_total{method="POST",status="5xx"} 1'),
      );
      expect(
        out,
        contains('code_push_requests_total{method="GET",status="4xx"} 1'),
      );
    });

    test('histogram buckets are cumulative and +Inf equals total count', () {
      final m = Metrics()
        ..record('GET', 200, 5) // 0.005s
        ..record('GET', 200, 30) // 0.030s
        ..record('GET', 200, 3000); // 3s
      final out = m.render();
      // le="0.01" covers only the 5ms request.
      expect(
        out,
        contains('code_push_request_duration_seconds_bucket{le="0.01"} 1'),
      );
      // le="0.05" covers the 5ms and 30ms requests.
      expect(
        out,
        contains('code_push_request_duration_seconds_bucket{le="0.05"} 2'),
      );
      // +Inf and the count line both equal the total.
      expect(
        out,
        contains('code_push_request_duration_seconds_bucket{le="+Inf"} 3'),
      );
      expect(out, contains('code_push_request_duration_seconds_count 3'));
    });

    test('exposes in-flight gauge and well-formed HELP/TYPE lines', () {
      final m = Metrics()..inFlight = 4;
      final out = m.render();
      expect(out, contains('code_push_requests_in_flight 4'));
      expect(out, contains('# TYPE code_push_requests_total counter'));
      expect(
        out,
        contains('# TYPE code_push_request_duration_seconds histogram'),
      );
    });
  });

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
