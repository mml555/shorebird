import 'package:code_push_server/src/api.dart';
import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/observability.dart';
import 'package:test/test.dart';

import 'support.dart';

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
      final a = rateLimitKey(auth: 'Bearer abc', ip: '1.1.1.1');
      // Same bearer from a different IP shares the same bucket.
      expect(rateLimitKey(auth: 'Bearer abc', ip: '2.2.2.2'), a);
      expect(rateLimitKey(auth: 'Bearer xyz', ip: '1.1.1.1'), isNot(a));
    });

    test('the bearer is hashed, not carried into the key verbatim', () {
      // WAS: 'auth:$auth'. The header is unbounded and unvalidated, and the
      // key is retained for the whole window (and written to an indexed
      // Postgres column), so a 256 KiB bearer pinned 256 KiB per bucket —
      // unauthenticated, since the key is built before _auth runs.
      final huge = 'Bearer ${'A' * 256 * 1024}';
      final key = rateLimitKey(auth: huge, ip: '1.1.1.1');
      expect(key.length, lessThan(64));
      expect(key, isNot(contains('AAAA')));
      expect(key, startsWith('auth:'));
    });

    test('unauthenticated device requests bucket by client IP', () {
      expect(rateLimitKey(ip: '10.0.0.7'), 'ip:10.0.0.7');
    });

    test(
      'different devices get different buckets (the fleet-throttle fix)',
      () {
        // Regression: previously all unauthenticated traffic shared one "anon"
        // bucket, so a fleet larger than the per-minute limit throttled itself.
        expect(
          rateLimitKey(ip: '10.0.0.7'),
          isNot(rateLimitKey(ip: '10.0.0.8')),
        );
      },
    );

    test('reads X-Forwarded-For behind a TRUSTED proxy', () {
      expect(
        clientIp(
          forwardedFor: '203.0.113.5',
          remoteIp: '10.0.0.1',
          isTrustedProxy: (ip) => ip == '10.0.0.1',
        ),
        '203.0.113.5',
      );
    });

    test('TRUSTED_PROXIES=* takes the header at face value', () {
      // Every hop looks trusted under the wildcard, so a right-to-left walk
      // would find nothing and silently fall back to the proxy's own address
      // -- putting the whole fleet in one bucket, the opposite of the intent.
      expect(
        clientIp(
          forwardedFor: '203.0.113.5, 10.0.0.1',
          remoteIp: '10.0.0.1',
          trustAllHops: true,
        ),
        '203.0.113.5',
      );
      // With no usable header it is still the peer.
      expect(clientIp(remoteIp: '10.0.0.1', trustAllHops: true), '10.0.0.1');
    });

    test('a hop that is not address-shaped is never used as a key', () {
      // The hop becomes part of a retained (and, on Postgres, indexed) bucket
      // key, so it is only taken when it is short and looks like an address.
      expect(
        clientIp(
          forwardedFor: 'unknown, ${'x' * 100}',
          remoteIp: '10.0.0.1',
          trustAllHops: true,
        ),
        '10.0.0.1',
      );
    });

    test('takes the rightmost hop the client could not have written', () {
      // nginx's $proxy_add_x_forwarded_for and most cloud load balancers
      // APPEND, so the leftmost entry is whatever the client sent. Only the
      // hops our own proxies added can be believed; walking from the right and
      // stopping at the first untrusted one is right for both proxy styles.
      const trusted = {'10.0.0.1', '10.0.0.2'};
      bool isTrusted(String ip) => trusted.contains(ip);
      expect(
        clientIp(
          forwardedFor: '1.2.3.4, 203.0.113.5, 10.0.0.2',
          remoteIp: '10.0.0.1',
          isTrustedProxy: isTrusted,
        ),
        // 1.2.3.4 is the client's own fabrication; 203.0.113.5 is the hop our
        // outermost proxy actually observed.
        '203.0.113.5',
      );
      // A spoofed header with no real hop falls back to the socket peer.
      expect(
        clientIp(
          forwardedFor: '10.0.0.1, 10.0.0.2',
          remoteIp: '10.0.0.1',
          isTrustedProxy: isTrusted,
        ),
        '10.0.0.1',
      );
    });

    test('ignores X-Forwarded-For from an untrusted peer', () {
      // WAS: the header was always believed. It is written by the client, so
      // a caller rotating it got a brand-new bucket on every request — the
      // limit counted to one, forever, and never fired.
      expect(
        clientIp(forwardedFor: '203.0.113.6', remoteIp: '10.0.0.1'),
        '10.0.0.1',
      );
    });

    test('empty auth / forwarded-for are ignored', () {
      expect(rateLimitKey(auth: '', ip: '9.9.9.9'), 'ip:9.9.9.9');
      expect(clientIp(forwardedFor: '', remoteIp: '9.9.9.9'), '9.9.9.9');
      expect(
        clientIp(
          forwardedFor: '  ,  , ',
          remoteIp: '9.9.9.9',
          trustAllHops: true,
        ),
        '9.9.9.9',
      );
    });

    test('falls back to unknown when no peer is known', () {
      expect(clientIp(), 'unknown');
      expect(rateLimitKey(ip: clientIp()), 'ip:unknown');
    });
  });

  group('Config.trustsProxy', () {
    Config cfg([Set<String> proxies = Config.defaultTrustedProxies]) =>
        sqliteConfig('./data', trustedProxies: proxies);

    test('loopback is trusted by default (a proxy on the same host)', () {
      final c = cfg();
      expect(c.trustsProxy('127.0.0.1'), isTrue);
      expect(c.trustsProxy('::1'), isTrue);
      expect(c.trustsProxy('10.0.0.1'), isFalse);
      expect(c.trustsProxy(null), isFalse);
    });

    test('an explicitly empty list trusts nothing', () {
      expect(cfg(const {}).trustsProxy('127.0.0.1'), isFalse);
    });

    test('matches IPv4 CIDR blocks (the Docker bridge range)', () {
      final c = cfg(const {'172.16.0.0/12'});
      expect(c.trustsProxy('172.17.0.5'), isTrue);
      expect(c.trustsProxy('172.31.255.254'), isTrue);
      expect(c.trustsProxy('172.15.0.1'), isFalse);
      expect(c.trustsProxy('192.168.1.1'), isFalse);
    });

    test('unwraps IPv4-mapped IPv6 peers', () {
      expect(cfg(const {'10.1.2.3'}).trustsProxy('::ffff:10.1.2.3'), isTrue);
    });

    test('a malformed entry never widens trust', () {
      // A bad TRUSTED_PROXIES value must fail closed, not match everything.
      for (final bad in ['not-an-ip/24', '10.0.0.0/99', '10.0.0.0/abc']) {
        expect(cfg({bad}).trustsProxy('10.0.0.1'), isFalse, reason: bad);
      }
    });

    test('"*" trusts any peer (explicit opt-in only)', () {
      expect(cfg(const {'*'}).trustsProxy('203.0.113.9'), isTrue);
    });
  });
}
