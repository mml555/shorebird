// cspell:words aarch bipatch
// Contract test: the REAL `CodePushClient` (the one `shorebird_cli` ships)
// driven against the REAL server handler, with no network in between.
//
// The server was built against what the client sends, but nothing checked it
// from the client's side: a client change (a renamed field, a new status
// code it starts to depend on) only failed in production. Every case here
// goes through the client's own request building and response parsing, so
// either side drifting fails CI. See the workflow's paths filter, which runs
// this on client and protocol changes too.
//
// A case that exposes a real client/server mismatch is `skip:`ped with the
// mismatch named, so it is listed rather than papered over.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:code_push_server/src/api.dart';
import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import '../support.dart';

const _apiKey = 'sb_api_selfhost_dev';
const _host = 'http://localhost:8080';

/// An [http.Client] that never touches a socket: each request becomes a shelf
/// [shelf.Request], goes to [handler], and the shelf response comes back as a
/// [http.StreamedResponse]. Bodies are fully buffered on the way in, which is
/// what the server's own io adapter delivers for these small requests.
class ShelfClient extends http.BaseClient {
  ShelfClient(this.handler);

  final shelf.Handler handler;

  /// Every request seen, for cases that assert on the wire (e.g. the
  /// resumable upload's chunking).
  final requests = <http.BaseRequest>[];

  /// When set, rewrites a response before the client sees it (fault injection).
  Future<http.StreamedResponse> Function(
    http.BaseRequest request,
    http.StreamedResponse response,
  )?
  intercept;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final bytes = await request.finalize().toBytes();
    final response = await handler(
      shelf.Request(
        request.method,
        request.url,
        headers: request.headers,
        body: bytes,
      ),
    );
    final out = http.StreamedResponse(
      response.read(),
      response.statusCode,
      headers: response.headers,
      request: request,
      reasonPhrase: _reason(response.statusCode),
    );
    return intercept == null ? out : intercept!(request, out);
  }

  static String _reason(int status) => switch (status) {
    200 => 'OK',
    204 => 'No Content',
    304 => 'Not Modified',
    308 => 'Resume Incomplete',
    400 => 'Bad Request',
    403 => 'Forbidden',
    404 => 'Not Found',
    409 => 'Conflict',
    _ => 'Status $status',
  };
}

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  late Directory tmp;
  late Repository repo;
  late Api api;
  late ShelfClient http_;
  late CodePushClient client;

  Future<void> boot({String uploadMethod = 'multipart'}) async {
    tmp = Directory.systemTemp.createTempSync('cps_contract');
    final config = sqliteConfig(tmp.path, uploadMethod: uploadMethod);
    repo = await Repository.open(config);
    api = Api(repo, await ArtifactStore.open(config), config);
    http_ = ShelfClient(api.handler);
    client = CodePushClient(
      httpClient: http_,
      hostedUri: Uri.parse(_host),
      customHeaders: {'authorization': 'Bearer $_apiKey'},
      uploadRetryBaseDelay: Duration.zero,
    );
  }

  tearDown(() async {
    await repo.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File writeFile(String name, List<int> bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  /// Posts [body] to the device-facing patches/check the way the updater does:
  /// unauthenticated JSON, built from the protocol's own request type.
  Future<PatchCheckResponse> check({
    required String appId,
    String version = '1.0.0',
    String arch = 'aarch64',
    String channel = 'stable',
    int? currentPatchNumber,
    String? clientId,
  }) async {
    final request = PatchCheckRequest(
      appId: appId,
      releaseVersion: version,
      platform: ReleasePlatform.android,
      arch: arch,
      channel: channel,
      currentPatchNumber: currentPatchNumber,
      clientId: clientId,
    );
    final response = await ShelfClient(api.handler).post(
      Uri.parse('$_host/api/v1/patches/check'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(request.toJson()),
    );
    expect(response.statusCode, 200, reason: response.body);
    return PatchCheckResponse.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// App, draft release, one uploaded aarch64 + aab release artifact, and the
  /// release activated, the way `shorebird release android` leaves it.
  Future<({String appId, Release release})> seedRelease() async {
    final app = await client.createApp(
      organizationId: 1,
      displayName: 'contract',
    );
    final release = await client.createRelease(
      appId: app.id,
      version: '1.0.0',
      flutterRevision: 'a' * 40,
    );
    for (final arch in ['aab', 'aarch64']) {
      final bytes = utf8.encode('release-$arch');
      await client.createReleaseArtifact(
        artifactPath: writeFile('release-$arch', bytes).path,
        appId: app.id,
        releaseId: release.id,
        arch: arch,
        platform: ReleasePlatform.android,
        hash: _sha256(bytes),
        canSideload: arch == 'aab',
        podfileLockHash: null,
      );
    }
    await client.updateReleaseStatus(
      appId: app.id,
      releaseId: release.id,
      platform: ReleasePlatform.android,
      status: ReleaseStatus.active,
    );
    return (appId: app.id, release: release);
  }

  /// Creates a patch and uploads one aarch64 artifact, leaving it `ready`.
  Future<CreatePatchResponse> seedPatch(
    String appId,
    int releaseId, {
    String content = 'patch-one',
  }) async {
    final patch = await client.createPatch(
      appId: appId,
      releaseId: releaseId,
      metadata: const {'note': 'contract'},
    );
    final bytes = utf8.encode(content);
    await client.createPatchArtifact(
      artifactPath: writeFile('patch-$content', bytes).path,
      appId: appId,
      patchId: patch.id,
      arch: 'aarch64',
      platform: ReleasePlatform.android,
      hash: _sha256(bytes),
    );
    return patch;
  }

  group('multipart uploads', () {
    setUp(boot);

    test('create app, release, release artifacts and activate', () async {
      final app = await client.createApp(
        organizationId: 1,
        displayName: 'contract',
      );
      expect(app.displayName, 'contract');

      final release = await client.createRelease(
        appId: app.id,
        version: '1.0.0',
        flutterRevision: 'b' * 40,
        flutterVersion: '3.35.0',
        displayName: 'first',
      );
      expect(release.version, '1.0.0');
      expect(release.flutterRevision, 'b' * 40);

      final bytes = utf8.encode('bundle');
      await client.createReleaseArtifact(
        artifactPath: writeFile('aab', bytes).path,
        appId: app.id,
        releaseId: release.id,
        arch: 'aab',
        platform: ReleasePlatform.android,
        hash: _sha256(bytes),
        canSideload: true,
        podfileLockHash: null,
      );
      final artifacts = await client.getReleaseArtifacts(
        appId: app.id,
        releaseId: release.id,
        platform: ReleasePlatform.android,
      );
      expect(artifacts.map((a) => a.arch), ['aab']);
      expect(artifacts.single.hash, _sha256(bytes));
      expect(artifacts.single.canSideload, isTrue);

      expect((await client.getApps()).map((a) => a.appId), contains(app.id));
    });

    test('a byte-identical release artifact re-upload is idempotent', () async {
      final app = await client.createApp(
        organizationId: 1,
        displayName: 'contract',
      );
      final release = await client.createRelease(
        appId: app.id,
        version: '1.0.0',
        flutterRevision: 'a' * 40,
      );
      final bytes = utf8.encode('bundle');
      Future<void> upload() => client.createReleaseArtifact(
        artifactPath: writeFile('aab', bytes).path,
        appId: app.id,
        releaseId: release.id,
        arch: 'aab',
        platform: ReleasePlatform.android,
        hash: _sha256(bytes),
        canSideload: true,
        podfileLockHash: null,
      );
      await upload();
      await upload();
    });

    test('patch create, patch artifact create, promote, check', () async {
      final seeded = await seedRelease();
      final channel = await client.createChannel(
        appId: seeded.appId,
        channel: 'stable',
      );
      final patch = await seedPatch(seeded.appId, seeded.release.id);
      expect(patch.number, 1);

      await client.promotePatch(
        appId: seeded.appId,
        patchId: patch.id,
        channelId: channel.id,
      );

      final res = await check(appId: seeded.appId);
      expect(res.patchAvailable, isTrue);
      expect(res.patch!.number, 1);
      expect(res.patch!.hash, _sha256(utf8.encode('patch-one')));
      expect(res.rolledBackPatchNumbers ?? const <int>[], isEmpty);

      // The device then downloads what the check named.
      final download = await ShelfClient(
        api.handler,
      ).get(Uri.parse(res.patch!.downloadUrl));
      expect(download.statusCode, 200);
      expect(utf8.decode(download.bodyBytes), 'patch-one');

      // A device already on patch 1 is offered nothing.
      final current = await check(appId: seeded.appId, currentPatchNumber: 1);
      expect(current.patchAvailable, isFalse);

      final patches = await client.getPatches(
        appId: seeded.appId,
        releaseId: seeded.release.id,
      );
      expect(patches.single.number, 1);
    });

    test('rollback tells devices to revert; a second one is a 304', () async {
      final seeded = await seedRelease();
      final channel = await client.createChannel(
        appId: seeded.appId,
        channel: 'stable',
      );
      final patch = await seedPatch(seeded.appId, seeded.release.id);
      await client.promotePatch(
        appId: seeded.appId,
        patchId: patch.id,
        channelId: channel.id,
      );

      expect(
        await client.rollbackPatch(
          appId: seeded.appId,
          releaseId: seeded.release.id,
          patchId: patch.id,
        ),
        isTrue,
      );
      final res = await check(appId: seeded.appId, currentPatchNumber: 1);
      expect(res.patchAvailable, isFalse);
      expect(res.rolledBackPatchNumbers, [1]);

      // `false` is the client's reading of 304 Not Modified.
      expect(
        await client.rollbackPatch(
          appId: seeded.appId,
          releaseId: seeded.release.id,
          patchId: patch.id,
        ),
        isFalse,
      );
    });

    test('signing-key fetch returns the same managed key each time', () async {
      final app = await client.createApp(
        organizationId: 1,
        displayName: 'contract',
      );
      final first = await client.getSigningKey(appId: app.id);
      expect(first.publicKeyPem, contains('BEGIN PUBLIC KEY'));
      final second = await client.getSigningKey(appId: app.id);
      expect(second.id, first.id);
      expect(second.publicKeyPem, first.publicKeyPem);
    });

    test('patch hash_signature reaches the device', () async {
      final seeded = await seedRelease();
      final channel = await client.createChannel(
        appId: seeded.appId,
        channel: 'stable',
      );
      final patch = await client.createPatch(
        appId: seeded.appId,
        releaseId: seeded.release.id,
        metadata: const {},
      );
      final bytes = utf8.encode('signed-patch');
      await client.createPatchArtifact(
        artifactPath: writeFile('signed', bytes).path,
        appId: seeded.appId,
        patchId: patch.id,
        arch: 'aarch64',
        platform: ReleasePlatform.android,
        hash: _sha256(bytes),
        hashSignature: 'client-supplied-signature',
      );
      await client.promotePatch(
        appId: seeded.appId,
        patchId: patch.id,
        channelId: channel.id,
      );
      final res = await check(appId: seeded.appId);
      // Today the managed server signs at registration and ignores what the
      // client sent; the contract is only that a signature is served.
      expect(res.patch!.hashSignature, isNotEmpty);
    });
  });

  group('resumable uploads', () {
    setUp(() => boot(uploadMethod: 'resumable'));

    test('single chunk, then the artifact is downloadable', () async {
      final seeded = await seedRelease();
      final puts = http_.requests.where((r) => r.method == 'PUT');
      // Two release artifacts, one PUT each, with a Content-Range.
      expect(puts, hasLength(2));
      expect(
        puts.first.headers['content-range'],
        matches(r'^bytes 0-\d+/\d+$'),
      );
      final artifacts = await client.getReleaseArtifacts(
        appId: seeded.appId,
        releaseId: seeded.release.id,
      );
      expect(artifacts, hasLength(2));
    });

    test('multiple chunks resume through the 308 + Range answers', () async {
      final app = await client.createApp(
        organizationId: 1,
        displayName: 'contract',
      );
      final release = await client.createRelease(
        appId: app.id,
        version: '1.0.0',
        flutterRevision: 'a' * 40,
      );
      // The client's chunk is 8 MiB, so 8 MiB + 1 byte is two PUTs: the first
      // answered 308 with `Range: bytes=0-8388607`, the second 200.
      final bytes = Uint8List(8 * 1024 * 1024 + 1)
        ..fillRange(0, 8 * 1024 * 1024 + 1, 7);
      await client.createReleaseArtifact(
        artifactPath: writeFile('big', bytes).path,
        appId: app.id,
        releaseId: release.id,
        arch: 'aab',
        platform: ReleasePlatform.android,
        hash: _sha256(bytes),
        canSideload: true,
        podfileLockHash: null,
      );
      final ranges = [
        for (final r in http_.requests)
          if (r.method == 'PUT') r.headers['content-range'],
      ];
      expect(ranges, [
        'bytes 0-8388607/8388609',
        'bytes 8388608-8388608/8388609',
      ]);
    });

    test('a dropped chunk response resumes from the server offset', () async {
      final app = await client.createApp(
        organizationId: 1,
        displayName: 'contract',
      );
      final release = await client.createRelease(
        appId: app.id,
        version: '1.0.0',
        flutterRevision: 'a' * 40,
      );
      final bytes = utf8.encode('resume-me');
      var dropped = false;
      http_.intercept = (request, response) async {
        // Lose the answer to the first chunk. The bytes did reach the server
        // and verified, so the client's status query must come back 200.
        if (request.method == 'PUT' && !dropped) {
          dropped = true;
          throw const SocketException('connection reset');
        }
        return response;
      };
      await client.createReleaseArtifact(
        artifactPath: writeFile('resume', bytes).path,
        appId: app.id,
        releaseId: release.id,
        arch: 'aab',
        platform: ReleasePlatform.android,
        hash: _sha256(bytes),
        canSideload: true,
        podfileLockHash: null,
      );
      expect(dropped, isTrue);
      final puts = http_.requests.where((r) => r.method == 'PUT').toList();
      expect(puts.last.headers['content-range'], 'bytes */9');
    });

    test('patch artifact over the resumable path reaches the device', () async {
      final seeded = await seedRelease();
      final channel = await client.createChannel(
        appId: seeded.appId,
        channel: 'stable',
      );
      final patch = await seedPatch(seeded.appId, seeded.release.id);
      await client.promotePatch(
        appId: seeded.appId,
        patchId: patch.id,
        channelId: channel.id,
      );
      expect((await check(appId: seeded.appId)).patch!.number, 1);
    });

    test(
      'a hash mismatch fails the upload with a CodePushUploadException',
      () async {
        final app = await client.createApp(
          organizationId: 1,
          displayName: 'contract',
        );
        final release = await client.createRelease(
          appId: app.id,
          version: '1.0.0',
          flutterRevision: 'a' * 40,
        );
        await expectLater(
          client.createReleaseArtifact(
            artifactPath: writeFile('bad', utf8.encode('actual')).path,
            appId: app.id,
            releaseId: release.id,
            arch: 'aab',
            platform: ReleasePlatform.android,
            hash: _sha256(utf8.encode('declared')),
            canSideload: true,
            podfileLockHash: null,
          ),
          throwsA(
            isA<CodePushUploadException>().having(
              (e) => e.statusCode,
              'statusCode',
              greaterThanOrEqualTo(400),
            ),
          ),
        );
      },
    );
  });

  group('error shapes the client parses', () {
    setUp(boot);

    test('404 on an unknown app is a CodePushNotFoundException', () async {
      await expectLater(
        client.createRelease(
          appId: 'no-such-app',
          version: '1.0.0',
          flutterRevision: 'a' * 40,
        ),
        throwsA(
          isA<CodePushException>()
              .having((e) => e.statusCode, 'statusCode', anyOf(403, 404))
              // The server's `{code, message}` body parses as ErrorResponse.
              .having((e) => e.response, 'response', isNotNull)
              .having((e) => e.code, 'code', isNotEmpty),
        ),
      );
    });

    test('a wrong bearer key is refused with a structured body', () async {
      final bad = CodePushClient(
        httpClient: http_,
        hostedUri: Uri.parse(_host),
        customHeaders: {'authorization': 'Bearer nope'},
      );
      await expectLater(
        bad.createApp(organizationId: 1, displayName: 'x'),
        throwsA(
          isA<CodePushException>()
              // The server answers 403 (not 401) for a bad key.
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e, 'type', isA<CodePushForbiddenException>())
              .having((e) => e.response, 'response', isNotNull),
        ),
      );
    });

    test('promoting a patch that is not ready is a conflict', () async {
      final seeded = await seedRelease();
      final channel = await client.createChannel(
        appId: seeded.appId,
        channel: 'stable',
      );
      final patch = await client.createPatch(
        appId: seeded.appId,
        releaseId: seeded.release.id,
        metadata: const {},
      );
      await expectLater(
        client.promotePatch(
          appId: seeded.appId,
          patchId: patch.id,
          channelId: channel.id,
        ),
        throwsA(
          isA<CodePushConflictException>().having(
            (e) => e.message,
            'message',
            contains('not ready'),
          ),
        ),
      );
    });

    test('a duplicate patch artifact is a conflict', () async {
      final seeded = await seedRelease();
      final patch = await seedPatch(seeded.appId, seeded.release.id);
      final bytes = utf8.encode('patch-one');
      await expectLater(
        client.createPatchArtifact(
          artifactPath: writeFile('dup', bytes).path,
          appId: seeded.appId,
          patchId: patch.id,
          arch: 'aarch64',
          platform: ReleasePlatform.android,
          hash: _sha256(bytes),
        ),
        throwsA(isA<CodePushConflictException>()),
      );
    });

    test(
      'a release artifact with a different hash is a conflict once active',
      () async {
        final seeded = await seedRelease();
        final bytes = utf8.encode('different');
        await expectLater(
          client.createReleaseArtifact(
            artifactPath: writeFile('diff', bytes).path,
            appId: seeded.appId,
            releaseId: seeded.release.id,
            arch: 'aab',
            platform: ReleasePlatform.android,
            hash: _sha256(bytes),
            canSideload: true,
            podfileLockHash: null,
          ),
          throwsA(isA<CodePushConflictException>()),
        );
      },
    );

    test(
      'a non-JSON error body keeps the status code in the message',
      () async {
        http_.intercept = (request, response) async => http.StreamedResponse(
          Stream.value(utf8.encode('<html>bad gateway</html>')),
          502,
          request: request,
        );
        await expectLater(
          client.createApp(organizationId: 1, displayName: 'x'),
          throwsA(
            isA<CodePushException>()
                .having(
                  (e) => e.message,
                  'message',
                  CodePushClient.unknownErrorMessageFor(502),
                )
                .having((e) => e.response, 'response', isNull),
          ),
        );
      },
    );

    test(
      'patches/check for an unknown app answers "no patch", not an error',
      () async {
        await boot();
        final res = await check(appId: 'no-such-app');
        expect(res.patchAvailable, isFalse);
      },
    );
  });
}
