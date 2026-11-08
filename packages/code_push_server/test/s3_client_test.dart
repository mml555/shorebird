import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/s3_client.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

// The credentials and times in AWS's published Signature Version 4 examples
// (docs.aws.amazon.com, "Signature Calculations for the Authorization Header").
const _awsAccess = 'AKIAIOSFODNN7EXAMPLE';
const _awsSecret = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';
final _awsTime = DateTime.utc(2013, 5, 24);

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

    setUp(() async {
      objects.clear();
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((req) async {
          final auth = req.headers.value('authorization') ?? '';
          seen.add(
            '${req.method} ${req.uri.path} '
            '${auth.startsWith('AWS4-HMAC-SHA256') ? 'signed' : 'UNSIGNED'}',
          );
          final body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
          // The payload hash header must be the real hash of the body.
          expect(
            req.headers.value('x-amz-content-sha256'),
            sha256.convert(body).toString(),
          );
          final path = req.uri.path;
          final res = req.response;
          if (path == '/bkt' && req.method == 'HEAD') {
            res.statusCode = 404;
          } else if (path == '/bkt' && req.method == 'PUT') {
            res.statusCode = 200;
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
              if (range != null) {
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
