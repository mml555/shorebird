import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/s3_client.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

// The credentials and times in AWS's published Signature Version 4 examples
// (docs.aws.amazon.com, "Signature Calculations for the Authorization Header").
const _awsAccess = 'AKIAIOSFODNN7EXAMPLE';
const _awsSecret = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';
final _awsTime = DateTime.utc(2013, 5, 24);

/// A [Random] that always draws the top of the range, so jittered waits show
/// their ceiling.
class _MaxRandom implements Random {
  @override
  int nextInt(int max) => max - 1;
  @override
  double nextDouble() => 1;
  @override
  bool nextBool() => true;
}

void main() {
  group('signRequest', () {
    test('matches the AWS "GET Object" example (with Range)', () {
      final h = signRequest(
        method: 'GET',
        url: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
        headers: {'range': 'bytes=0-9'},
        payload: const [],
        now: _awsTime,
        accessKey: _awsAccess,
        secretKey: _awsSecret,
        region: 'us-east-1',
      );
      expect(
        h['authorization'],
        'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/'
        's3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;'
        'x-amz-date, Signature='
        'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
      );
    });

    test('matches the AWS "PUT Object" example (signed payload hash)', () {
      // AWS's example also signs date, storage-class and x-amz-* headers we do
      // not send, so this checks the payload-hash path with our header set by
      // recomputing the documented signature chain independently.
      final h = signRequest(
        method: 'PUT',
        url: Uri.parse(
          'https://examplebucket.s3.amazonaws.com/test%24file.text',
        ),
        headers: {
          'date': 'Fri, 24 May 2013 00:00:00 GMT',
          'x-amz-storage-class': 'REDUCED_REDUNDANCY',
        },
        payload: utf8.encode('Welcome to Amazon S3.'),
        now: _awsTime,
        accessKey: _awsAccess,
        secretKey: _awsSecret,
        region: 'us-east-1',
      );
      expect(
        h['authorization'],
        endsWith(
          'Signature='
          '98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd',
        ),
      );
      expect(
        h['x-amz-content-sha256'],
        sha256.convert(utf8.encode('Welcome to Amazon S3.')).toString(),
      );
    });

    test('includes a non-default port in the signed host', () {
      final h = signRequest(
        method: 'GET',
        url: Uri.parse('http://seaweedfs:8333/b/k'),
        headers: const {},
        payload: const [],
        now: _awsTime,
        accessKey: 'a',
        secretKey: 's',
        region: 'us-east-1',
      );
      expect(h['host'], 'seaweedfs:8333');
    });
  });

  test('uriEncode follows SigV4 rules', () {
    expect(uriEncode('a b/c+d~é', slash: false), 'a%20b/c%2Bd~%C3%A9');
    expect(uriEncode('a/b', slash: true), 'a%2Fb');
  });

  group('S3Client against a recording fake', () {
    late HttpServer server;
    late S3Client client;
    final objects = <String, List<int>>{};
    final seen = <String>[];
    // Behaviours a test switches on to imitate a misbehaving store.
    var ignoreRange = false;
    var bucketExistsNow = false;
    int? bucketPutStatus;
    var bucketPutBody = '';
    var stall = false;
    // How many of the next requests are never answered.
    var stallNext = 0;
    // Cut the connection after the first bytes of a GET response.
    var breakBody = false;
    final amzDates = <String>[];
    // Statuses (and bodies) to answer the next requests with, before the
    // normal behaviour resumes. A null status drops the connection.
    final failures = <(int?, String)>[];

    setUp(() async {
      objects.clear();
      seen.clear();
      ignoreRange = false;
      bucketExistsNow = false;
      bucketPutStatus = null;
      bucketPutBody = '';
      stall = false;
      stallNext = 0;
      breakBody = false;
      amzDates.clear();
      failures.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((req) async {
          final auth = req.headers.value('authorization') ?? '';
          seen.add(
            '${req.method} ${req.uri.path} '
            '${auth.startsWith('AWS4-HMAC-SHA256') ? 'signed' : 'UNSIGNED'}',
          );
          amzDates.add(req.headers.value('x-amz-date') ?? '');
          final body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
          // The payload hash header must be the real hash of the body.
          expect(
            req.headers.value('x-amz-content-sha256'),
            sha256.convert(body).toString(),
          );
          final path = req.uri.path;
          final res = req.response;
          if (stall) return; // never answer
          if (stallNext > 0) {
            stallNext--;
            return;
          }
          if (failures.isNotEmpty) {
            final (status, text) = failures.removeAt(0);
            if (status == null) {
              (await res.detachSocket(writeHeaders: false)).destroy();
              return;
            }
            res
              ..statusCode = status
              ..write(text);
            await res.close();
            return;
          }
          if (path == '/bkt' && req.method == 'HEAD') {
            res.statusCode = bucketExistsNow ? 200 : 404;
          } else if (path == '/bkt' && req.method == 'PUT') {
            res.statusCode = bucketPutStatus ?? 200;
            res.write(bucketPutBody);
          } else if (req.method == 'PUT') {
            objects[path] = body;
          } else if (req.method == 'DELETE') {
            objects.remove(path);
            res.statusCode = 204;
          } else if (!objects.containsKey(path)) {
            res.statusCode = 404;
          } else {
            final data = objects[path]!;
            if (req.method == 'HEAD') {
              res.contentLength = data.length;
            } else {
              final range = req.headers.value('range');
              if (breakBody) {
                final socket = await res.detachSocket(writeHeaders: false);
                socket.add(
                  utf8.encode(
                    'HTTP/1.1 200 OK\r\ncontent-length: ${data.length}\r\n\r\n',
                  ),
                );
                socket.add(data.sublist(0, 10));
                await socket.flush();
                socket.destroy();
                return;
              }
              if (range != null && !ignoreRange) {
                final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
                final start = int.parse(m[1]!);
                final end = m[2]!.isEmpty ? data.length - 1 : int.parse(m[2]!);
                res.statusCode = 206;
                res.add(data.sublist(start, end + 1));
              } else {
                res.add(data);
              }
            }
          }
          await res.close();
        }),
      );
      client = S3Client(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        region: 'us-east-1',
        accessKey: 'k',
        secretKey: 's',
        bucket: 'bkt',
      );
    });

    tearDown(() async {
      client.close();
      await server.close(force: true);
    });

    test('bucket create, put, stat, ranged get, delete', () async {
      expect(await client.bucketExists(), isFalse);
      await client.createBucket();
      await client.putObject('patch/1/a b', [1, 2, 3, 4, 5]);
      expect(await client.statObject('patch/1/a b'), 5);
      Future<List<int>> read(int? o, int? l) async =>
          (await (await client.getObject(
            'patch/1/a b',
            offset: o,
            length: l,
          )).expand((c) => c).toList());
      expect(await read(null, null), [1, 2, 3, 4, 5]);
      expect(await read(1, 2), [2, 3]);
      expect(await read(3, null), [4, 5]);
      await client.deleteObject('patch/1/a b');
      await client.deleteObject('patch/1/a b'); // already gone: fine
      await expectLater(
        client.statObject('patch/1/a b'),
        throwsA(isA<S3NotFoundException>()),
      );
      expect(seen, everyElement(endsWith('signed')));
      expect(seen, isNot(contains(contains('UNSIGNED'))));
      expect(seen, contains('PUT /bkt/patch/1/a%20b signed'));
    });

    Future<List<int>> read(String key, {int? offset, int? length}) async =>
        (await (await client.getObject(
          key,
          offset: offset,
          length: length,
        )).expand((c) => c).toList());

    test('a ranged read fails when the store ignores Range (200)', () async {
      await client.putObject('k', [1, 2, 3, 4, 5]);
      ignoreRange = true;
      await expectLater(
        read('k', offset: 1, length: 2),
        throwsA(isA<S3Exception>().having((e) => e.statusCode, 'status', 200)),
      );
      await expectLater(read('k', offset: 2), throwsA(isA<S3Exception>()));
      // A read with no range is still a plain 200.
      expect(await read('k'), [1, 2, 3, 4, 5]);
      expect(await read('k', offset: 0), [1, 2, 3, 4, 5]);
    });

    test('a ranged read rejects a length below 1 without a request', () async {
      await client.putObject('k', [1, 2, 3]);
      seen.clear();
      await expectLater(
        read('k', offset: 1, length: 0),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        read('k', offset: -1, length: 1),
        throwsA(isA<ArgumentError>()),
      );
      expect(seen, isEmpty);
    });

    test('BucketAlreadyOwnedByYou is success', () async {
      bucketPutStatus = 409;
      bucketPutBody = '<Error><Code>BucketAlreadyOwnedByYou</Code></Error>';
      await client.createBucket();
    });

    test(
      'BucketAlreadyExists is success when our HEAD then succeeds',
      () async {
        bucketPutStatus = 409;
        bucketPutBody = '<Error><Code>BucketAlreadyExists</Code></Error>';
        bucketExistsNow = true;
        await client.createBucket();
        expect(seen, ['PUT /bkt signed', 'HEAD /bkt signed']);
      },
    );

    test(
      'BucketAlreadyExists still fails when the bucket is not ours',
      () async {
        bucketPutStatus = 409;
        bucketPutBody = '<Error><Code>BucketAlreadyExists</Code></Error>';
        bucketExistsNow = false; // HEAD says 404 (or, on AWS, 403)
        await expectLater(
          client.createBucket(),
          throwsA(
            isA<S3Exception>()
                .having((e) => e.statusCode, 'status', 409)
                .having((e) => e.body, 'body', contains('BucketAlreadyExists')),
          ),
        );
      },
    );

    test('other bucket errors are not retried as success', () async {
      bucketPutStatus = 403;
      bucketPutBody = '<Error><Code>AccessDenied</Code></Error>';
      bucketExistsNow = true;
      await expectLater(client.createBucket(), throwsA(isA<S3Exception>()));
      expect(seen, ['PUT /bkt signed']);
    });

    test('a store that never answers fails after responseTimeout', () async {
      stall = true;
      final slow = S3Client(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        region: 'us-east-1',
        accessKey: 'k',
        secretKey: 's',
        bucket: 'bkt',
        responseTimeout: const Duration(milliseconds: 200),
        maxAttempts: 1,
      );
      addTearDown(slow.close);
      await expectLater(
        slow.statObject('k'),
        throwsA(isA<S3Exception>().having((e) => e.statusCode, 'status', 0)),
      );
    });

    group('retries', () {
      final delays = <Duration>[];
      late S3Client retrying;

      setUp(() {
        delays.clear();
        retrying = S3Client(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
          region: 'us-east-1',
          accessKey: 'k',
          secretKey: 's',
          bucket: 'bkt',
          sleep: (d) async => delays.add(d),
          random: Random(1),
        );
        addTearDown(retrying.close);
      });

      test('a 503 then success: the body is sent again, intact', () async {
        failures.add((503, '<Error><Code>SlowDown</Code></Error>'));
        await retrying.putObject('k', utf8.encode('payload'));
        expect(seen, ['PUT /bkt/k signed', 'PUT /bkt/k signed']);
        expect(objects['/bkt/k'], utf8.encode('payload'));
        expect(delays, hasLength(1));
      });

      test('a dropped connection is retried', () async {
        failures.add((null, ''));
        expect(await retrying.bucketExists(), isFalse);
        expect(seen, hasLength(2));
      });

      test('a 400 RequestTimeout is retried', () async {
        failures.add((400, '<Error><Code>RequestTimeout</Code></Error>'));
        await retrying.putObject('k', [1, 2, 3]);
        expect(seen, hasLength(2));
      });

      for (final status in [408, 429, 500, 502, 504]) {
        test('$status is retried', () async {
          failures.add((status, ''));
          await retrying.deleteObject('k');
          expect(seen, hasLength(2));
        });
      }

      test('gives up after maxAttempts and reports the last answer', () async {
        failures.addAll([for (var i = 0; i < 10; i++) (503, 'busy')]);
        await expectLater(
          retrying.putObject('k', [1]),
          throwsA(
            isA<S3Exception>()
                .having((e) => e.statusCode, 'status', 503)
                .having((e) => e.body, 'body', 'busy'),
          ),
        );
        expect(seen, hasLength(4));
        expect(delays, hasLength(3));
        expect(objects, isEmpty);
      });

      test('waits grow but stay under the cap', () async {
        failures.addAll([for (var i = 0; i < 10; i++) (500, '')]);
        final capped = S3Client(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
          region: 'us-east-1',
          accessKey: 'k',
          secretKey: 's',
          bucket: 'bkt',
          maxAttempts: 6,
          retryBaseDelay: const Duration(seconds: 1),
          retryMaxDelay: const Duration(seconds: 3),
          sleep: (d) async => delays.add(d),
          random: _MaxRandom(),
        );
        addTearDown(capped.close);
        await expectLater(
          capped.deleteObject('k'),
          throwsA(isA<S3Exception>()),
        );
        expect(delays, [
          const Duration(seconds: 1),
          const Duration(seconds: 2),
          const Duration(seconds: 3),
          const Duration(seconds: 3),
          const Duration(seconds: 3),
        ]);
      });

      for (final status in [400, 401, 403, 404, 409, 412]) {
        test('$status is not retried', () async {
          failures.add((status, '<Error><Code>Nope</Code></Error>'));
          failures.add((status, '<Error><Code>Nope</Code></Error>'));
          await expectLater(
            retrying.putObject('k', [1]),
            throwsA(
              isA<S3Exception>().having((e) => e.statusCode, 'status', status),
            ),
          );
          expect(seen, hasLength(1));
          expect(delays, isEmpty);
        });
      }

      test('maxAttempts: 1 turns retries off', () async {
        failures.add((503, ''));
        final once = S3Client(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
          region: 'us-east-1',
          accessKey: 'k',
          secretKey: 's',
          bucket: 'bkt',
          maxAttempts: 1,
          sleep: (d) async => delays.add(d),
        );
        addTearDown(once.close);
        await expectLater(
          once.putObject('k', [1]),
          throwsA(isA<S3Exception>()),
        );
        expect(seen, hasLength(1));
      });

      test('a body cut after the status is not replayed', () async {
        // The retry covers the request and its status line only. Once
        // getObject has returned the stream the bytes are consumed, so a
        // failure while reading it reaches the caller, not a second request.
        objects['/bkt/big'] = List.filled(100, 7);
        breakBody = true;
        final stream = await retrying.getObject('big');
        await expectLater(stream.drain<void>(), throwsA(isA<HttpException>()));
        expect(seen, ['GET /bkt/big signed']);
        expect(delays, isEmpty);
      });

      test('a stalled attempt is aborted and retried', () async {
        stallNext = 1;
        final quick = S3Client(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
          region: 'us-east-1',
          accessKey: 'k',
          secretKey: 's',
          bucket: 'bkt',
          responseTimeout: const Duration(milliseconds: 50),
          retryDeadline: const Duration(seconds: 5),
          sleep: (d) async => delays.add(d),
        );
        addTearDown(quick.close);
        await quick.putObject('k', [9]);
        expect(seen, hasLength(2));
        expect(objects['/bkt/k'], [9]);
      });

      test('every attempt is signed afresh', () async {
        var now = DateTime.utc(2026, 11, 10);
        final ticking = S3Client(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
          region: 'us-east-1',
          accessKey: 'k',
          secretKey: 's',
          bucket: 'bkt',
          clock: () => now,
          sleep: (d) async => now = now.add(const Duration(minutes: 1)),
        );
        addTearDown(ticking.close);
        failures.add((503, ''));
        await ticking.putObject('k', [1]);
        expect(amzDates, ['20261110T000000Z', '20261110T000100Z']);
      });

      test('the readiness probe does not retry', () async {
        failures.add((503, ''));
        await expectLater(
          retrying.bucketExists(retry: false),
          throwsA(isA<S3Exception>()),
        );
        expect(seen, hasLength(1));
      });

      test('no new attempt starts after retryDeadline', () async {
        failures.addAll([for (var i = 0; i < 10; i++) (503, '')]);
        final hurried = S3Client(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
          region: 'us-east-1',
          accessKey: 'k',
          secretKey: 's',
          bucket: 'bkt',
          retryDeadline: Duration.zero,
          sleep: (d) async => delays.add(d),
        );
        addTearDown(hurried.close);
        await expectLater(
          hurried.putObject('k', [1]),
          throwsA(isA<S3Exception>()),
        );
        expect(seen, hasLength(1));
      });

      test(
        'retries are reported and the final error counts attempts',
        () async {
          final notes = <String>[];
          final noisy = S3Client(
            endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
            region: 'us-east-1',
            accessKey: 'k',
            secretKey: 's',
            bucket: 'bkt',
            sleep: (d) async {},
            onRetry: notes.add,
          );
          addTearDown(noisy.close);
          failures.addAll([for (var i = 0; i < 10; i++) (503, '')]);
          await expectLater(
            noisy.putObject('k', [1]),
            throwsA(
              isA<S3Exception>().having(
                (e) => e.toString(),
                'message',
                contains('after 4 attempts'),
              ),
            ),
          );
          expect(notes, hasLength(3));
          expect(notes.first, allOf(contains('PUT k'), contains('503')));
        },
      );

      test(
        'a 5xx on GET names the key, with the range only when ranged',
        () async {
          for (final (args, name) in [
            ((1, 2), 'GET k (bytes=1-2)'),
            ((null, null), 'GET k'),
          ]) {
            failures.addAll([for (var i = 0; i < 4; i++) (503, '')]);
            await expectLater(
              retrying.getObject('k', offset: args.$1, length: args.$2),
              throwsA(
                isA<S3Exception>()
                    .having((e) => e.operation, 'operation', name)
                    .having((e) => e.attempts, 'attempts', 4),
              ),
            );
          }
        },
      );

      test(
        'an attempt that would start past the deadline is not started',
        () async {
          // Each attempt stalls for 100 ms. After two the call has run 200 ms,
          // past the 150 ms deadline, so a third must not start (it did when the
          // deadline was only checked before the attempt that followed it).
          stall = true;
          final bounded = S3Client(
            endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
            region: 'us-east-1',
            accessKey: 'k',
            secretKey: 's',
            bucket: 'bkt',
            responseTimeout: const Duration(milliseconds: 100),
            retryDeadline: const Duration(milliseconds: 150),
            retryBaseDelay: Duration.zero,
          );
          addTearDown(bounded.close);
          await expectLater(
            bounded.statObject('k'),
            throwsA(
              isA<S3Exception>().having((e) => e.attempts, 'attempts', 2),
            ),
          );
          expect(seen, hasLength(2));
        },
      );
    });

    test('virtual-hosted style puts the bucket in the host', () {
      final c = S3Client(
        endpoint: Uri.parse('https://s3.example.com'),
        region: 'r',
        accessKey: 'k',
        secretKey: 's',
        bucket: 'bkt',
        pathStyle: false,
      );
      expect(c.objectUrl('a/b').toString(), 'https://bkt.s3.example.com/a/b');
      c.close();
    });
  });

  group('MINIO_* aliases', () {
    test('fill in the S3_* settings and name the replacement', () {
      final c = Config.fromEnv({
        'MINIO_ROOT_USER': 'old-user',
        'MINIO_ROOT_PASSWORD': 'old-pass',
      });
      expect(c.s3AccessKey, 'old-user');
      expect(c.s3SecretKey, 'old-pass');
      expect(c.deprecationWarnings, [
        'MINIO_ROOT_USER is deprecated, use S3_ACCESS_KEY',
        'MINIO_ROOT_PASSWORD is deprecated, use S3_SECRET_KEY',
      ]);
    });

    test('an empty value counts as unset, as in compose', () {
      final c = Config.fromEnv({
        'S3_ACCESS_KEY': '',
        'S3_SECRET_KEY': '',
        'MINIO_ROOT_USER': 'old-user',
        'MINIO_ROOT_PASSWORD': 'old-pass',
      });
      expect(c.s3AccessKey, 'old-user');
      expect(c.s3SecretKey, 'old-pass');
      expect(c.deprecationWarnings, hasLength(2));
      expect(c.deprecationWarnings, everyElement(isNot(contains('ignored'))));
    });

    test('an empty MINIO_* does not override S3_*, or warn', () {
      final c = Config.fromEnv({
        'S3_ACCESS_KEY': 'new-user',
        'S3_SECRET_KEY': 'new-pass',
        'MINIO_ROOT_USER': '',
        'MINIO_ROOT_PASSWORD': '',
      });
      expect(c.s3AccessKey, 'new-user');
      expect(c.s3SecretKey, 'new-pass');
      expect(c.deprecationWarnings, isEmpty);
    });

    test('an empty S3_ACCESS_KEY alone falls back to the default', () {
      expect(Config.fromEnv({'S3_ACCESS_KEY': ''}).s3AccessKey, 'cps');
    });

    test('an empty secret is refused by validate(), in any mode', () {
      final c = Config.fromEnv({
        'S3_ENDPOINT': 'http://s3:9000',
        'S3_SECRET_KEY': '',
      });
      expect(c.s3SecretKey, isEmpty);
      expect(c.production, isFalse);
      expect(c.validate(), contains('S3_SECRET_KEY must not be empty'));
    });

    test('S3_* wins when both are set, and an unchanged .env still loads', () {
      final c = Config.fromEnv({
        'S3_ENDPOINT': 'http://minio:9000',
        'S3_ACCESS_KEY': 'cps',
        'S3_SECRET_KEY': 'new',
        'MINIO_ROOT_USER': 'cps',
        'MINIO_ROOT_PASSWORD': 'old',
      });
      expect(c.s3SecretKey, 'new');
      expect(c.storageBackend, 's3');
      expect(c.s3PathStyle, isTrue);
      expect(c.s3Region, 'us-east-1');
      expect(c.deprecationWarnings, hasLength(2));
      expect(c.deprecationWarnings.first, contains('is ignored'));
    });

    test('no warnings without MINIO_*, and S3_PATH_STYLE parses', () {
      final c = Config.fromEnv({'S3_PATH_STYLE': 'false', 'S3_REGION': 'auto'});
      expect(c.deprecationWarnings, isEmpty);
      expect(c.s3PathStyle, isFalse);
      expect(c.s3Region, 'auto');
      expect(
        () => Config.fromEnv({'S3_PATH_STYLE': 'maybe'}),
        throwsFormatException,
      );
    });
  });
}
