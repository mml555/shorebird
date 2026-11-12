// cspell:words collab unlogged
// Request-level tests for the HTTP surface in `lib/src/api.dart`.
//
// Every group here corresponds to a defect found in the end-to-end security
// audit. The comments say what the behavior WAS, so a regression is obvious.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:code_push_server/src/api.dart';
import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/domain.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:code_push_server/src/signing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support.dart';

const _bootstrapKey = 'sb_api_selfhost_dev';

void main() {
  late Directory tmp;
  late Repository repo;
  late Config config;
  late Api api;

  Future<void> boot({Config? override}) async {
    tmp = Directory.systemTemp.createTempSync('cps_api');
    config = override ?? sqliteConfig(tmp.path);
    repo = await Repository.open(config);
    api = Api(repo, await ArtifactStore.open(config), config);
  }

  setUp(boot);

  tearDown(() async {
    await repo.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<Response> send(
    String method,
    String path, {
    String? bearer,
    Object? json,
    String? body,
    Stream<List<int>>? bodyStream,
    Map<String, String> headers = const {},
    String? peer,
  }) => Future.sync(
    () => api.handler(
      Request(
        method,
        Uri.parse('http://localhost:8080$path'),
        headers: {
          if (bearer != null) HttpHeaders.authorizationHeader: 'Bearer $bearer',
          ...headers,
        },
        // Shelf's io adapter puts the socket peer here; the rate limiter reads
        // it to decide whether X-Forwarded-For may be believed. Without it,
        // any test of the trusted-proxy path passes vacuously.
        context: peer == null
            ? const {}
            : {'shelf.io.connection_info': _FakeConnectionInfo(peer)},
        body: bodyStream ?? body ?? (json == null ? null : jsonEncode(json)),
      ),
    ),
  );

  Future<Map<String, dynamic>> jsonOf(Response r) async =>
      jsonDecode(await r.readAsString()) as Map<String, dynamic>;

  /// Creates an app owned by the bootstrap user, plus a release and channel.
  Future<({String appId, int releaseId, int channelId})> seedApp([
    String name = 'app',
  ]) async {
    final app = await jsonOf(
      await send(
        'POST',
        '/api/v1/apps',
        bearer: _bootstrapKey,
        json: {'display_name': name},
      ),
    );
    final appId = app['id'] as String;
    final rel = await jsonOf(
      await send(
        'POST',
        '/api/v1/apps/$appId/releases',
        bearer: _bootstrapKey,
        json: {'version': '1.0.0'},
      ),
    );
    final ch = await jsonOf(
      await send(
        'POST',
        '/api/v1/apps/$appId/channels',
        bearer: _bootstrapKey,
        json: {'channel': 'stable'},
      ),
    );
    return (
      appId: appId,
      releaseId: (rel['release'] as Map)['id'] as int,
      channelId: ch['id'] as int,
    );
  }

  /// Registers a patch artifact and uploads its bytes, leaving it verified.
  Future<void> uploadPatchArtifact(
    String appId,
    int patchId, {
    String arch = 'aarch64',
    String platform = 'android',
    String bearer = _bootstrapKey,
  }) async {
    const bd = 'BOUNDARY';
    String field(String n, String v) =>
        '--$bd\r\ncontent-disposition: form-data; name="$n"\r\n\r\n$v\r\n';
    final reg = await jsonOf(
      await send(
        'POST',
        '/api/v1/apps/$appId/patches/$patchId/artifacts',
        bearer: bearer,
        headers: {'content-type': 'multipart/form-data; boundary=$bd'},
        body:
            '${field('arch', arch)}${field('platform', platform)}'
            '${field('hash', 'unchecked-for-patches')}${field('size', '3')}'
            '--$bd--\r\n',
      ),
    );
    final token = (reg['url'] as String).split('/').last;
    final up = await send(
      'POST',
      '/api/v1/uploads/$token',
      bearer: bearer,
      headers: {'content-type': 'multipart/form-data; boundary=$bd'},
      body:
          '--$bd\r\ncontent-disposition: form-data; name="file"; '
          'filename="p"\r\n\r\nabc\r\n--$bd--\r\n',
    );
    expect(up.statusCode, HttpStatus.noContent);
  }

  /// A second, unrelated tenant: their own user, API key, org and app.
  Future<({int userId, String key, String appId})> otherTenant([
    String email = 'mallory@evil.test',
  ]) async {
    final user = await repo.upsertUser(email, 'Other');
    final key = await repo.createApiKey(user.id);
    final orgId = (await repo.memberships(user.id)).first.orgId;
    final app = await jsonOf(
      await send(
        'POST',
        '/api/v1/apps',
        bearer: key,
        json: {'display_name': 'theirs', 'organization_id': orgId},
      ),
    );
    return (userId: user.id, key: key, appId: app['id'] as String);
  }

  // -------------------------------------------------------------------------
  group('login (self-consent, no external IdP)', () {
    // WAS: `/login?email=<anyone>` handed out an auth code for an arbitrary
    // identity, and even without the parameter no credential was required at
    // all — so any unauthenticated caller could mint a session.
    test('GET returns a credential form, not a redirect with a code', () async {
      final r = await send('GET', '/login?continue=http://localhost:1234/cb');
      expect(r.statusCode, HttpStatus.ok);
      expect(r.headers[HttpHeaders.locationHeader], isNull);
      expect(await r.readAsString(), contains('name="api_key"'));
    });

    test('an email in the query string cannot choose the identity', () async {
      final r = await send(
        'GET',
        '/login?continue=http://localhost:1234/cb&email=attacker@evil.test',
      );
      expect(r.statusCode, HttpStatus.ok);
      expect(await r.readAsString(), isNot(contains('attacker@evil.test')));
    });

    test('POST without a valid API key issues no code', () async {
      final r = await send(
        'POST',
        '/login',
        body: 'continue=http%3A%2F%2Flocalhost%3A1234%2Fcb&api_key=wrong',
        headers: {'content-type': 'application/x-www-form-urlencoded'},
      );
      expect(r.statusCode, HttpStatus.unauthorized);
      expect(r.headers[HttpHeaders.locationHeader], isNull);
    });

    test('a failed login writes no audit row', () async {
      // WAS: `repo.audit('login.denied', ...)` on a PUBLIC route — an
      // unauthenticated write into the one table with no default retention.
      // Denials belong in the structured log.
      Future<int> auditRows() async =>
          (await repo.db.query('SELECT id FROM audit_log')).length;
      final before = await auditRows();
      for (var i = 0; i < 5; i++) {
        await send(
          'POST',
          '/login',
          body: 'continue=http%3A%2F%2Flocalhost%3A1234%2Fcb&api_key=wrong$i',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        );
      }
      expect(await auditRows(), before);
    });

    test('POST with a valid API key redirects with a code', () async {
      final r = await send(
        'POST',
        '/login',
        body:
            'continue=http%3A%2F%2Flocalhost%3A1234%2Fcb&api_key=$_bootstrapKey',
        headers: {'content-type': 'application/x-www-form-urlencoded'},
      );
      expect(r.statusCode, HttpStatus.found);
      final code = Uri.parse(
        r.headers[HttpHeaders.locationHeader]!,
      ).queryParameters['code'];
      expect(code, isNotNull);

      // And that code exchanges for a token bound to the configured identity.
      final tok = await jsonOf(
        await send(
          'POST',
          '/token',
          body: 'grant_type=authorization_code&code=$code',
        ),
      );
      final me = await jsonOf(
        await send(
          'GET',
          '/api/v1/users/me',
          bearer: tok['access_token'] as String,
        ),
      );
      expect(me['email'], config.loginEmail);
    });

    test("a user's own API key logs in as that user", () async {
      final other = await otherTenant('dev@example.test');
      final r = await send(
        'POST',
        '/login',
        body:
            'continue=http%3A%2F%2Flocalhost%3A1234%2Fcb&api_key=${other.key}',
        headers: {'content-type': 'application/x-www-form-urlencoded'},
      );
      final code = Uri.parse(
        r.headers[HttpHeaders.locationHeader]!,
      ).queryParameters['code'];
      final tok = await jsonOf(
        await send(
          'POST',
          '/token',
          body: 'grant_type=authorization_code&code=$code',
        ),
      );
      final me = await jsonOf(
        await send(
          'GET',
          '/api/v1/users/me',
          bearer: tok['access_token'] as String,
        ),
      );
      expect(me['email'], 'dev@example.test');
    });

    test('a non-loopback continue URL is refused', () async {
      // Otherwise the redirect could deliver a fresh auth code off-host.
      final r = await send('GET', '/login?continue=https://evil.test/steal');
      expect(r.statusCode, HttpStatus.badRequest);
    });

    test('a continue URL with a non-ASCII byte is refused', () async {
      // Same hang as CR/LF: dart:io's header validator rejects everything
      // outside printable ASCII, and it does so *while writing the response*.
      for (final bad in [
        'http://localhost:1234/é',
        'http://localhost:1234/\u202E',
        'http://localhost:1234/漢',
      ]) {
        final r = await send(
          'GET',
          '/login?continue=${Uri.encodeQueryComponent(bad)}',
        );
        expect(r.statusCode, HttpStatus.badRequest, reason: bad);
      }
    });

    test('a continue URL containing CR/LF is refused', () async {
      // WAS: only scheme+host were checked, and Uri.tryParse keeps a CRLF in
      // the path. That string went into a `Location:` header, which dart:io
      // then refuses to write *while emitting the response* — so the request
      // never completed and its socket stayed open. /login and /oauth/callback
      // are both public, making it an unauthenticated fd-exhaustion primitive.
      for (final bad in [
        'http://localhost:1234/cb\r\nX-Injected: pwned',
        'http://localhost:1234/cb\nSet-Cookie: a=b',
        'http://localhost:1234/cb\u0000',
      ]) {
        final r = await send(
          'GET',
          '/login?continue=${Uri.encodeQueryComponent(bad)}',
        );
        expect(r.statusCode, HttpStatus.badRequest, reason: bad);
      }
    });

    test('an absurdly long continue URL is refused', () async {
      final r = await send(
        'GET',
        '/login?continue=${Uri.encodeQueryComponent('http://localhost:1234/${'a' * 4096}')}',
      );
      expect(r.statusCode, HttpStatus.badRequest);
    });
  });

  // -------------------------------------------------------------------------
  group('POST /patches/events when an event cannot be stored', () {
    test('answers 422, a permanent refusal, not a retryable 500', () async {
      final failing = Api(
        _FailingEvents(repo.db),
        await ArtifactStore.open(config),
        config,
      );
      final r = await failing.handler(
        Request(
          'POST',
          Uri.parse('http://localhost:8080/api/v1/patches/events'),
          body: 'not json',
        ),
      );
      expect(r.statusCode, HttpStatus.unprocessableEntity);
      expect(await r.readAsString(), contains('do not retry'));
    });
  });

  group('request body limits', () {
    // WAS: every one of these read the body with an uncapped `readAsString`.
    // /patches/check, /patches/events, /login and /token are all public, so an
    // unauthenticated POST could pin arbitrary heap (UTF-8 decoding to a Dart
    // String roughly doubles the raw bytes on top of that).
    Stream<List<int>> big() => Stream<List<int>>.fromIterable(
      Iterable.generate(4, (_) => Uint8List(1 << 20)),
    );

    for (final path in [
      '/api/v1/patches/check',
      '/api/v1/patches/events',
      '/login',
      '/token',
    ]) {
      test('$path caps an oversized body', () async {
        final r = await send('POST', path, bodyStream: big());
        expect(r.statusCode, HttpStatus.requestEntityTooLarge);
      });
    }

    test('a body of invalid UTF-8 is a 400, not a 500', () async {
      // Strict decoding throws a FormatException on bytes the client chose —
      // the same client-triggerable 500 as the raw casts.
      final app = await seedApp();
      final r = await send(
        'POST',
        '/api/v1/apps/${app.appId}/patches',
        bearer: _bootstrapKey,
        bodyStream: Stream<List<int>>.value(
          Uint8List.fromList([0xC3, 0x28, 0xA0, 0xA1]),
        ),
      );
      expect(r.statusCode, HttpStatus.badRequest);
    });

    test('an authenticated JSON body is capped too', () async {
      final app = await seedApp();
      final r = await send(
        'POST',
        '/api/v1/apps/${app.appId}/patches',
        bearer: _bootstrapKey,
        bodyStream: big(),
      );
      expect(r.statusCode, HttpStatus.requestEntityTooLarge);
    });
  });

  // -------------------------------------------------------------------------
  group('bearer token handling', () {
    // WAS: with API_KEY="" a blank `Authorization: Bearer ` header compared
    // equal to the configured key and authenticated as the seeded owner.
    test('a blank bearer is rejected even when the API key is empty', () async {
      await repo.close();
      tmp.deleteSync(recursive: true);
      final base = sqliteConfig(
        Directory.systemTemp.createTempSync('cps_blank').path,
      );
      await boot(override: _withEmptyApiKey(base));

      final r = await send(
        'GET',
        '/api/v1/users/me',
        headers: {HttpHeaders.authorizationHeader: 'Bearer '},
      );
      expect(r.statusCode, HttpStatus.forbidden);
    });

    test('an unknown API key is rejected', () async {
      final r = await send('GET', '/api/v1/users/me', bearer: 'sb_api_nope');
      expect(r.statusCode, HttpStatus.forbidden);
    });
  });

  // -------------------------------------------------------------------------
  // -------------------------------------------------------------------------
  group('release artifact registration and activation', () {
    // WAS: re-registering an already-uploaded release artifact was always a 409,
    // and activating a platform only checked that the artifacts *present* were
    // verified. Together those stranded release 2.0.0+1785465879 (2026-07-30):
    // the run was killed with iOS `xcarchive` registered and `runner` +
    // `ios_supplement` missing, every retry died re-sending `xcarchive` before
    // reaching them, and no DELETE route exists to clear it.
    const bd = 'BOUNDARY';
    const abcSha =
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

    String field(String n, String v) =>
        '--$bd\r\ncontent-disposition: form-data; name="$n"\r\n\r\n$v\r\n';

    Future<Response> register(
      String appId,
      int releaseId, {
      required String arch,
      required String platform,
      String hash = abcSha,
    }) => send(
      'POST',
      '/api/v1/apps/$appId/releases/$releaseId/artifacts',
      bearer: _bootstrapKey,
      headers: {'content-type': 'multipart/form-data; boundary=$bd'},
      body:
          '${field('arch', arch)}${field('platform', platform)}'
          '${field('hash', hash)}${field('size', '3')}--$bd--\r\n',
    );

    /// Registers and uploads, leaving the artifact `verified`. Release artifacts
    /// have their hash checked (unlike patch artifacts), so the bytes must hash
    /// to [abcSha].
    Future<void> upload(
      String appId,
      int releaseId, {
      required String arch,
      required String platform,
    }) async {
      final reg = await jsonOf(
        await register(appId, releaseId, arch: arch, platform: platform),
      );
      final token = (reg['url'] as String).split('/').last;
      final up = await send(
        'POST',
        '/api/v1/uploads/$token',
        bearer: _bootstrapKey,
        headers: {'content-type': 'multipart/form-data; boundary=$bd'},
        body:
            '--$bd\r\ncontent-disposition: form-data; name="file"; '
            'filename="a"\r\n\r\nabc\r\n--$bd--\r\n',
      );
      expect(up.statusCode, HttpStatus.noContent);
    }

    Future<Response> activate(String appId, int releaseId, String platform) =>
        send(
          'PATCH',
          '/api/v1/apps/$appId/releases/$releaseId',
          bearer: _bootstrapKey,
          json: {'status': 'active', 'platform': platform},
        );

    test('a byte-identical re-upload is idempotent, not a conflict', () async {
      final app = await seedApp();
      final first = await jsonOf(
        await register(
          app.appId,
          app.releaseId,
          arch: 'xcarchive',
          platform: 'ios',
        ),
      );
      final again = await register(
        app.appId,
        app.releaseId,
        arch: 'xcarchive',
        platform: 'ios',
      );
      expect(again.statusCode, HttpStatus.ok);
      // Same registration, not a duplicate row — the retry can carry on to the
      // artifacts it still owes.
      expect((await jsonOf(again))['id'], first['id']);
    });

    test('a rebuilt artifact supersedes the stale one while incomplete', () async {
      // The real rescue path: `shorebird release` rebuilds on every retry, so the
      // retry's bytes differ from what landed before the interruption. Matching
      // on hash alone would 409 the exact case this exists to fix.
      final app = await seedApp();
      await upload(
        app.appId,
        app.releaseId,
        arch: 'xcarchive',
        platform: 'ios',
      );
      final rebuilt = await register(
        app.appId,
        app.releaseId,
        arch: 'xcarchive',
        platform: 'ios',
        hash: 'f' * 64,
      );
      expect(rebuilt.statusCode, HttpStatus.ok);
      // A fresh registration, not the superseded one.
      expect((await jsonOf(rebuilt))['hash'], 'f' * 64);
    });

    test('a differing hash is refused once the release is ready', () async {
      // From `ready` on, the release artifacts are what installed apps run and
      // what patches link against; swapping one would invalidate those patches.
      final app = await seedApp();
      for (final arch in ['xcarchive', 'runner', 'ios_supplement']) {
        await upload(app.appId, app.releaseId, arch: arch, platform: 'ios');
      }
      expect(
        (await activate(app.appId, app.releaseId, 'ios')).statusCode,
        HttpStatus.noContent,
      );
      final after = await register(
        app.appId,
        app.releaseId,
        arch: 'xcarchive',
        platform: 'ios',
        hash: 'f' * 64,
      );
      expect(after.statusCode, HttpStatus.conflict);
      expect(await after.readAsString(), contains('already registered'));
    });

    test('an unobfuscated single-ABI Android release activates', () async {
      // The set this check was built from was induced from a biased sample —
      // every Android release the server had seen was obfuscated and single-ABI
      // — so it demanded android_supplement (which only exists with
      // --obfuscate) plus arm and x86_64 (which only exist for a multi-ABI
      // build). That made this perfectly ordinary release impossible to
      // activate, and it is how a real release against our own engine failed.
      final app = await seedApp();
      for (final arch in ['aab', 'aarch64']) {
        await upload(app.appId, app.releaseId, arch: arch, platform: 'android');
      }
      final r = await activate(app.appId, app.releaseId, 'android');
      expect(r.statusCode, HttpStatus.noContent);
    });

    test('an Android release with no code artifact is refused', () async {
      // The "at least one of" half: an aab alone would activate a release no
      // patch could ever be built against.
      final app = await seedApp();
      await upload(app.appId, app.releaseId, arch: 'aab', platform: 'android');
      final r = await activate(app.appId, app.releaseId, 'android');
      expect(r.statusCode, HttpStatus.conflict);
      expect(await r.readAsString(), contains('no code artifact'));
    });

    test(
      'a platform cannot be activated with an incomplete artifact set',
      () async {
        final app = await seedApp();
        // Exactly the state the killed run left behind: one verified xcarchive.
        await upload(
          app.appId,
          app.releaseId,
          arch: 'xcarchive',
          platform: 'ios',
        );
        final r = await activate(app.appId, app.releaseId, 'ios');
        expect(r.statusCode, HttpStatus.conflict);
        final body = await r.readAsString();
        expect(body, contains('missing artifacts'));
        expect(body, contains('ios_supplement'));
        expect(body, contains('runner'));
      },
    );

    test(
      'a platform activates once its full artifact set is present',
      () async {
        final app = await seedApp();
        for (final arch in ['xcarchive', 'runner', 'ios_supplement']) {
          await upload(app.appId, app.releaseId, arch: arch, platform: 'ios');
        }
        expect(
          (await activate(app.appId, app.releaseId, 'ios')).statusCode,
          HttpStatus.noContent,
        );
      },
    );

    test('an unknown platform is not gated on an artifact list', () async {
      // macOS et al must not be blocked by a required set this server has never
      // learned; better a late-closed hole than a target that cannot ship.
      final app = await seedApp();
      await upload(app.appId, app.releaseId, arch: 'arm64', platform: 'macos');
      expect(
        (await activate(app.appId, app.releaseId, 'macos')).statusCode,
        HttpStatus.noContent,
      );
    });
  });

  // -------------------------------------------------------------------------
  group('cross-tenant isolation', () {
    // WAS: `_authorizeApp` checked the app in the PATH, but release_id,
    // patch_id and channel_id came from the body unchecked — so pairing your
    // own app id with another tenant's numeric id operated on their data.
    late ({String appId, int releaseId, int channelId}) victim;
    late ({int userId, String key, String appId}) attacker;

    setUp(() async {
      victim = await seedApp('victim');
      attacker = await otherTenant();
    });

    test('cannot create a patch on another app\'s release', () async {
      final r = await send(
        'POST',
        '/api/v1/apps/${attacker.appId}/patches',
        bearer: attacker.key,
        json: {'release_id': victim.releaseId},
      );
      expect(r.statusCode, HttpStatus.notFound);
    });

    test('cannot read another app\'s patches or artifacts', () async {
      for (final path in [
        '/api/v1/apps/${attacker.appId}/releases/${victim.releaseId}/patches',
        '/api/v1/apps/${attacker.appId}/releases/${victim.releaseId}/artifacts',
      ]) {
        expect(
          (await send('GET', path, bearer: attacker.key)).statusCode,
          HttpStatus.notFound,
          reason: path,
        );
      }
    });

    test('cannot mutate another app\'s release', () async {
      final r = await send(
        'PATCH',
        '/api/v1/apps/${attacker.appId}/releases/${victim.releaseId}',
        bearer: attacker.key,
        json: {'status': 'active', 'platform': 'android'},
      );
      expect(r.statusCode, HttpStatus.notFound);
    });

    test('cannot promote onto another app\'s channel', () async {
      // Build a legitimate, ready patch inside the attacker's OWN app, so the
      // only thing under test is the foreign channel id.
      final ownRelease = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${attacker.appId}/releases',
          bearer: attacker.key,
          json: {'version': '1.0.0'},
        ),
      );
      final ownPatch = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${attacker.appId}/patches',
          bearer: attacker.key,
          json: {'release_id': (ownRelease['release'] as Map)['id']},
        ),
      );
      await uploadPatchArtifact(
        attacker.appId,
        ownPatch['id'] as int,
        bearer: attacker.key,
      );

      final r = await send(
        'POST',
        '/api/v1/apps/${attacker.appId}/patches/promote',
        bearer: attacker.key,
        json: {'patch_id': ownPatch['id'], 'channel_id': victim.channelId},
      );
      expect(r.statusCode, HttpStatus.notFound);

      // And the victim's devices are still offered nothing.
      final check = await jsonOf(
        await send(
          'POST',
          '/api/v1/patches/check',
          json: {
            'app_id': victim.appId,
            'release_version': '1.0.0',
            'platform': 'android',
            'arch': 'aarch64',
            'channel': 'stable',
            'client_id': 'device-1',
          },
        ),
      );
      expect(check['patch_available'], isFalse);
    });

    test('cannot register an artifact on another app\'s patch', () async {
      final patch = await repo.createPatch(victim.appId, victim.releaseId);
      final r = await send(
        'POST',
        '/api/v1/apps/${attacker.appId}/patches/${patch.id}/artifacts',
        bearer: attacker.key,
        headers: {'content-type': 'multipart/form-data; boundary=X'},
        body: '--X--\r\n',
      );
      expect(r.statusCode, HttpStatus.notFound);
    });

    test(
      'cannot withdraw or re-roll another app\'s patch via /admin',
      () async {
        // /admin is dispatched outside the /api/v1/apps block, so it previously
        // received no app authorization at all.
        final patch = await repo.createPatch(victim.appId, victim.releaseId);
        for (final action in ['withdraw', 'rollout']) {
          final r = await send(
            'POST',
            '/admin/apps/${victim.appId}/patches/${patch.id}/$action',
            bearer: attacker.key,
          );
          expect(r.statusCode, HttpStatus.forbidden, reason: action);
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  group('collaborator roles', () {
    // WAS: any collaborator, including a plain developer, could add or remove
    // other collaborators — only app *access* was checked, never role.
    test('a developer collaborator cannot manage collaborators', () async {
      final app = await seedApp();
      final dev = await repo.upsertUser('dev@example.test', 'Dev');
      final devKey = await repo.createApiKey(dev.id);
      await repo.addCollaborator(app.appId, dev.id, 'developer');
      await repo.upsertUser('third@example.test', 'Third');

      final add = await send(
        'POST',
        '/admin/apps/${app.appId}/collaborators?email=third@example.test',
        bearer: devKey,
      );
      expect(add.statusCode, HttpStatus.forbidden);

      final remove = await send(
        'DELETE',
        '/admin/apps/${app.appId}/collaborators/1',
        bearer: devKey,
      );
      expect(remove.statusCode, HttpStatus.forbidden);
    });

    test('an org owner can manage collaborators', () async {
      final app = await seedApp();
      await repo.upsertUser('third@example.test', 'Third');
      final r = await send(
        'POST',
        '/admin/apps/${app.appId}/collaborators?email=third@example.test',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.ok);
    });

    test('an unknown collaborator role is rejected', () async {
      final app = await seedApp();
      await repo.upsertUser('third@example.test', 'Third');
      final r = await send(
        'POST',
        '/admin/apps/${app.appId}/collaborators'
            '?email=third@example.test&role=superuser',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.badRequest);
    });
  });

  // -------------------------------------------------------------------------
  group('promoted patches are immutable', () {
    // WAS: registering a further arch on a promoted patch flipped it back to
    // `uploading`; `patches/check` requires `ready`, so the whole fleet
    // silently stopped being offered the patch until the upload finished.
    test('a promoted patch refuses new artifacts', () async {
      final app = await seedApp();
      final patch = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${app.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': app.releaseId},
        ),
      );
      final patchId = patch['id'] as int;
      await uploadPatchArtifact(app.appId, patchId);
      expect(
        (await send(
          'POST',
          '/api/v1/apps/${app.appId}/patches/promote',
          bearer: _bootstrapKey,
          json: {'patch_id': patchId, 'channel_id': app.channelId},
        )).statusCode,
        HttpStatus.noContent,
      );

      final late = await send(
        'POST',
        '/api/v1/apps/${app.appId}/patches/$patchId/artifacts',
        bearer: _bootstrapKey,
        headers: {'content-type': 'multipart/form-data; boundary=X'},
        body: '--X--\r\n',
      );
      expect(late.statusCode, HttpStatus.conflict);

      // The patch is still ready, so devices keep being served.
      expect((await repo.patch(patchId))!.status, PatchStatus.ready);
    });

    test('a duplicate registration leaves a ready patch ready', () async {
      // WAS: the duplicate check ran AFTER setPatchStatus(uploading). The CLI
      // registers its last arch, the patch verifies to `ready`, the response is
      // lost, the CLI retries — `patchIsPromoted` is false so the retry gets
      // past that guard, flips `ready` -> `uploading` (a transition
      // `_patchNext` permits), and only THEN 409s. Nothing can move it forward
      // again: `patches/check` and promote both require `ready`. The patch was
      // stranded permanently by a retry of a request that had succeeded.
      final app = await seedApp();
      final patch = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${app.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': app.releaseId},
        ),
      );
      final patchId = patch['id'] as int;
      await uploadPatchArtifact(app.appId, patchId);
      expect((await repo.patch(patchId))!.status, PatchStatus.ready);

      const bd = 'BOUNDARY';
      String field(String n, String v) =>
          '--$bd\r\ncontent-disposition: form-data; name="$n"\r\n\r\n$v\r\n';
      final retry = await send(
        'POST',
        '/api/v1/apps/${app.appId}/patches/$patchId/artifacts',
        bearer: _bootstrapKey,
        headers: {'content-type': 'multipart/form-data; boundary=$bd'},
        body:
            '${field('arch', 'aarch64')}${field('platform', 'android')}'
            '${field('hash', 'unchecked-for-patches')}${field('size', '3')}'
            '--$bd--\r\n',
      );
      expect(retry.statusCode, HttpStatus.conflict);
      expect(
        (await repo.patch(patchId))!.status,
        PatchStatus.ready,
        reason: 'a rejected duplicate must not park the patch in uploading',
      );
      // Still promotable — the whole point.
      expect(
        (await send(
          'POST',
          '/api/v1/apps/${app.appId}/patches/promote',
          bearer: _bootstrapKey,
          json: {'patch_id': patchId, 'channel_id': app.channelId},
        )).statusCode,
        HttpStatus.noContent,
      );
    });

    test('multi-arch upload before promotion still works', () async {
      final app = await seedApp();
      final patch = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${app.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': app.releaseId},
        ),
      );
      final patchId = patch['id'] as int;
      await uploadPatchArtifact(app.appId, patchId, arch: 'aarch64');
      await uploadPatchArtifact(app.appId, patchId, arch: 'arm');
      expect((await repo.patch(patchId))!.status, PatchStatus.ready);
      expect(await repo.patchArtifacts(patchId), hasLength(2));
    });
  });

  // -------------------------------------------------------------------------
  group('malformed input', () {
    // WAS: int.parse on a path segment threw FormatException, surfacing as a
    // 500 plus a logged stack trace that a client could trigger at will.
    test('non-numeric path ids are a 400, not a 500', () async {
      final app = await seedApp();
      final paths = {
        '/api/v1/apps/${app.appId}/releases/abc/patches': 'GET',
        '/api/v1/apps/${app.appId}/releases/abc/artifacts': 'GET',
        '/admin/orgs/abc/members': 'GET',
        '/admin/orgs/1/members/xyz': 'DELETE',
      };
      for (final entry in paths.entries) {
        final r = await send(entry.value, entry.key, bearer: _bootstrapKey);
        expect(r.statusCode, HttpStatus.badRequest, reason: entry.key);
      }
    });

    test('wrong-typed body ids are a 400, not a 500', () async {
      // WAS: `body['release_id'] as int` threw a TypeError that escaped to the
      // generic handler as a 500 plus a logged stack trace — the same defect
      // as the path segments above, one line away from them.
      final app = await seedApp();
      final cases = <String, Object>{
        '/api/v1/apps/${app.appId}/patches': {'release_id': '1'},
        '/api/v1/apps/${app.appId}/patches/promote': {
          'patch_id': '1',
          'channel_id': app.channelId,
        },
        '/api/v1/apps/${app.appId}/releases': {'version': 7},
        '/api/v1/apps/${app.appId}/channels': {'channel': false},
        '/api/v1/apps': {'organization_id': 'one'},
      };
      for (final entry in cases.entries) {
        final r = await send(
          'POST',
          entry.key,
          bearer: _bootstrapKey,
          json: entry.value,
        );
        expect(r.statusCode, HttpStatus.badRequest, reason: entry.key);
      }
    });

    test('a missing required body id is a 400', () async {
      final app = await seedApp();
      final r = await send(
        'POST',
        '/api/v1/apps/${app.appId}/patches',
        bearer: _bootstrapKey,
        json: <String, Object>{},
      );
      expect(r.statusCode, HttpStatus.badRequest);
    });

    test('a non-object or unparseable JSON body is a 400', () async {
      final app = await seedApp();
      for (final body in ['[1,2,3]', '{not json']) {
        final r = await send(
          'POST',
          '/api/v1/apps/${app.appId}/patches',
          bearer: _bootstrapKey,
          body: body,
        );
        expect(r.statusCode, HttpStatus.badRequest, reason: body);
      }
    });

    test('a wrong-typed field on the device path never 500s', () async {
      // The updater's hot path stays tolerant: unusable input means "no patch
      // available", not an error the device has to interpret.
      final r = await send(
        'POST',
        '/api/v1/patches/check',
        json: {
          'app_id': 42,
          'release_version': '1.0.0',
          'platform': 'android',
          'arch': 'aarch64',
          'current_patch_number': 'three',
        },
      );
      expect(r.statusCode, HttpStatus.ok);
      expect((await jsonOf(r))['patch_available'], isFalse);
    });

    test('an out-of-range rollout is rejected', () async {
      final app = await seedApp();
      final r = await send(
        'POST',
        '/api/v1/apps/${app.appId}/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': 1, 'channel_id': app.channelId, 'rollout': 250},
      );
      expect(r.statusCode, HttpStatus.badRequest);
    });
  });

  // -------------------------------------------------------------------------
  group('assets-only patches', () {
    late String appId;
    late int patchId;
    late int channelId;

    /// Promotes a patch carrying [arch] artifacts and nothing else.
    Future<void> seedPatchWith(List<String> arches) async {
      final s = await seedApp();
      appId = s.appId;
      channelId = s.channelId;
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/$appId/patches',
          bearer: _bootstrapKey,
          json: {'release_id': s.releaseId},
        ),
      );
      patchId = p['id'] as int;
      for (final arch in arches) {
        await uploadPatchArtifact(appId, patchId, arch: arch);
      }
      await send(
        'POST',
        '/api/v1/apps/$appId/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': patchId, 'channel_id': channelId},
      );
    }

    Future<Map<String, dynamic>> check({List<String>? kinds}) async => jsonOf(
      await send(
        'POST',
        '/api/v1/patches/check',
        json: {
          'app_id': appId,
          'release_version': '1.0.0',
          'platform': 'android',
          'arch': 'aarch64',
          if (kinds != null) 'supported_patch_kinds': kinds,
        },
      ),
    );

    test('a code patch reports its kind', () async {
      await seedPatchWith(['aarch64']);
      final r = await check(kinds: [codePatchKind, assetsPatchKind]);
      expect(r['patch_available'], isTrue);
      expect((r['patch'] as Map)['kind'], equals(codePatchKind));
    });

    test('kind is present even for a client that asked for nothing', () async {
      // So a client never has to infer the kind from an absent field.
      await seedPatchWith(['aarch64']);
      final r = await check();
      expect((r['patch'] as Map)['kind'], equals(codePatchKind));
    });

    test(
      'an assets-only patch is served to a client that supports it',
      () async {
        await seedPatchWith([assetsArch]);
        final r = await check(kinds: [codePatchKind, assetsPatchKind]);
        expect(r['patch_available'], isTrue);
        final patch = r['patch'] as Map;
        expect(patch['kind'], equals(assetsPatchKind));
        expect(patch['download_url'], isA<String>());
      },
    );

    test('an assets-only patch is withheld from a stock updater', () async {
      // The compatibility gate, and the reason this is negotiated rather than
      // just announced. A stock updater would try to inflate the asset archive
      // as a binary diff, fail, and tombstone the patch as permanently bad for
      // the whole release — so it must never be offered one.
      await seedPatchWith([assetsArch]);
      expect((await check())['patch_available'], isFalse);
      expect((await check(kinds: [codePatchKind]))['patch_available'], isFalse);
    });

    test('code wins when a patch carries both', () async {
      await seedPatchWith(['aarch64', assetsArch]);
      final r = await check(kinds: [codePatchKind, assetsPatchKind]);
      // The code artifact is what the updater must apply; the bundle rides
      // alongside and is fetched separately via /patches/assets.
      expect((r['patch'] as Map)['kind'], equals(codePatchKind));
    });

    test(
      'an incapable client falls back to the superseded code patch',
      () async {
        // The hazard this exists to close: promoting an assets-only patch
        // withdraws the code patch, and a stock updater offered nothing would
        // silently lose a patch it was already entitled to.
        await seedPatchWith(['aarch64']);
        final codePatchId = patchId;

        // A second, assets-only patch supersedes it.
        final p = await jsonOf(
          await send(
            'POST',
            '/api/v1/apps/$appId/patches',
            bearer: _bootstrapKey,
            json: {'release_id': 1},
          ),
        );
        final assetsPatchId = p['id'] as int;
        await uploadPatchArtifact(appId, assetsPatchId, arch: assetsArch);
        await send(
          'POST',
          '/api/v1/apps/$appId/patches/promote',
          bearer: _bootstrapKey,
          json: {'patch_id': assetsPatchId, 'channel_id': channelId},
        );

        // Capable client: the new assets patch.
        final capable = await check(kinds: [codePatchKind, assetsPatchKind]);
        expect((capable['patch'] as Map)['kind'], equals(assetsPatchKind));

        // Stock client: the superseded code patch, not nothing.
        final stock = await check();
        expect(stock['patch_available'], isTrue);
        final patch = stock['patch'] as Map;
        expect(patch['kind'], equals(codePatchKind));
        expect(patch['number'], equals(1));
        expect(codePatchId, isNot(assetsPatchId));
      },
    );

    test('a rolled-back patch is never offered as a fallback', () async {
      // Superseded means "replaced"; rolled back means "pulled deliberately".
      // Conflating them would resurrect a patch someone withdrew for cause.
      await seedPatchWith(['aarch64']);
      final rb = await send(
        'POST',
        '/admin/apps/$appId/patches/$patchId/withdraw?rollback=true',
        bearer: _bootstrapKey,
      );
      expect(rb.statusCode, anyOf(HttpStatus.ok, HttpStatus.noContent));

      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/$appId/patches',
          bearer: _bootstrapKey,
          json: {'release_id': 1},
        ),
      );
      final assetsPatchId = p['id'] as int;
      await uploadPatchArtifact(appId, assetsPatchId, arch: assetsArch);
      await send(
        'POST',
        '/api/v1/apps/$appId/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': assetsPatchId, 'channel_id': channelId},
      );

      expect((await check())['patch_available'], isFalse);
    });

    test('the fallback still respects the client patch number', () async {
      // A client already on the code patch must not be handed it again.
      await seedPatchWith(['aarch64']);
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/$appId/patches',
          bearer: _bootstrapKey,
          json: {'release_id': 1},
        ),
      );
      final assetsPatchId = p['id'] as int;
      await uploadPatchArtifact(appId, assetsPatchId, arch: assetsArch);
      await send(
        'POST',
        '/api/v1/apps/$appId/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': assetsPatchId, 'channel_id': channelId},
      );

      final r = await jsonOf(
        await send(
          'POST',
          '/api/v1/patches/check',
          json: {
            'app_id': appId,
            'release_version': '1.0.0',
            'platform': 'android',
            'arch': 'aarch64',
            'current_patch_number': 1,
          },
        ),
      );
      expect(r['patch_available'], isFalse);
    });

    test('a malformed capability list is treated as no support', () async {
      await seedPatchWith([assetsArch]);
      final r = await jsonOf(
        await send(
          'POST',
          '/api/v1/patches/check',
          json: {
            'app_id': appId,
            'release_version': '1.0.0',
            'platform': 'android',
            'arch': 'aarch64',
            'supported_patch_kinds': 'assets',
          },
        ),
      );
      // Fails closed: a wrong-typed capability must not be read as consent.
      expect(r['patch_available'], isFalse);
    });
  });

  group('diagnostics speedtest', () {
    test('serves exactly the size the CLI verifies', () async {
      // NetworkChecker rejects any length other than 16000000.
      final urls = await jsonOf(
        await send(
          'GET',
          '/api/v1/diagnostics/gcp_download',
          bearer: _bootstrapKey,
        ),
      );
      final size = Uri.parse(
        urls['download_url'] as String,
      ).queryParameters['size'];
      expect(size, '16000000');

      final r = await send('GET', '/diagnostics/speedtest?size=$size');
      expect(r.headers[HttpHeaders.contentLengthHeader], '16000000');
    });

    test('a larger size cannot be requested (no amplification)', () async {
      final r = await send('GET', '/diagnostics/speedtest?size=999999999');
      expect(r.headers[HttpHeaders.contentLengthHeader], '16000000');
    });

    test('upload answers 204, which is what the CLI expects', () async {
      final r = await send('POST', '/diagnostics/speedtest', body: 'xxxx');
      expect(r.statusCode, HttpStatus.noContent);
    });

    test('is rate limited well below the general allowance', () async {
      var limited = false;
      for (var i = 0; i < 12; i++) {
        final r = await send('GET', '/diagnostics/speedtest?size=1');
        if (r.statusCode == HttpStatus.tooManyRequests) {
          limited = true;
          break;
        }
      }
      expect(limited, isTrue, reason: 'expected a 429 within 12 requests');
    });

    test('rotating the Authorization header does not evade the limit', () async {
      // WAS: the bucket key was the raw Authorization header, and speedtest
      // skips _auth() entirely — so a fresh random bearer per request bought a
      // fresh bucket every time and the cap never fired.
      var limited = false;
      for (var i = 0; i < 12; i++) {
        final r = await send(
          'GET',
          '/diagnostics/speedtest?size=1',
          bearer: 'sb_api_rotating_$i',
        );
        if (r.statusCode == HttpStatus.tooManyRequests) {
          limited = true;
          break;
        }
      }
      expect(limited, isTrue, reason: 'expected a 429 within 12 requests');
    });

    test(
      'rotating X-Forwarded-For from an untrusted peer is ignored',
      () async {
        // Same escape hatch via a header the client also controls. XFF is only
        // believed when the socket peer is a configured reverse proxy — here it
        // is 198.51.100.9, which is not, so all 12 land in one bucket.
        var limited = false;
        for (var i = 0; i < 12; i++) {
          final r = await send(
            'GET',
            '/diagnostics/speedtest?size=1',
            peer: '198.51.100.9',
            headers: {'x-forwarded-for': '203.0.113.$i'},
          );
          if (r.statusCode == HttpStatus.tooManyRequests) {
            limited = true;
            break;
          }
        }
        expect(limited, isTrue, reason: 'expected a 429 within 12 requests');
      },
    );

    test('its counter uses the configured backend, not a private one', () async {
      // WAS: a bare in-process `_RateLimiter`. With RATE_LIMIT_BACKEND=postgres
      // and N replicas that makes the real cap 6xN per IP — on the one
      // endpoint whose cap exists specifically to bound egress.
      await repo.close();
      await boot(
        override: sqliteConfig(
          Directory.systemTemp.createTempSync('cps_speed').path,
          rateLimitShared: true,
        ),
      );
      await send('GET', '/diagnostics/speedtest?size=1');
      final buckets = (await repo.db.query(
        'SELECT bucket FROM rate_limits',
      )).map((r) => r['bucket']).toList();
      expect(buckets, contains(startsWith('speed:')));
    });

    test('an oversized upload is refused at the speedtest size', () async {
      // WAS: the body was buffered via _collect up to MAX_UPLOAD_BYTES (512
      // MiB) before the cap was checked, on a public unauthenticated endpoint.
      // The CLI's probe is a fixed 5 MB, so nothing legitimate approaches this.
      var pulled = 0;
      final r = await send(
        'POST',
        '/diagnostics/speedtest',
        bodyStream:
            Stream<List<int>>.fromIterable(
              Iterable.generate(32, (_) => Uint8List(1 << 20)),
            ).map((c) {
              pulled += c.length;
              return c;
            }),
      );
      expect(r.statusCode, HttpStatus.requestEntityTooLarge);
      // And it stopped reading as soon as the cap was passed rather than
      // draining all 32 MiB into memory first.
      expect(pulled, lessThan(32 << 20));
    });
  });

  // -------------------------------------------------------------------------
  group('multipart limits', () {
    String part(String name, String value) =>
        '--B\r\ncontent-disposition: form-data; name="$name"\r\n\r\n$value\r\n';

    Future<Response> upload(String appId, int patchId, String body) => send(
      'POST',
      '/api/v1/apps/$appId/patches/$patchId/artifacts',
      bearer: _bootstrapKey,
      headers: {'content-type': 'multipart/form-data; boundary=B'},
      body: body,
    );

    Future<({String appId, int patchId})> patch() async {
      final app = await seedApp();
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${app.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': app.releaseId},
        ),
      );
      return (appId: app.appId, patchId: p['id'] as int);
    }

    test('a body with too many parts is refused', () async {
      // WAS: `_collect` capped each part but nothing bounded the part count or
      // the total, so a body of many small fields was unbounded in aggregate.
      final p = await patch();
      final body = [
        for (var i = 0; i < 64; i++) part('f$i', 'x'),
        '--B--\r\n',
      ].join();
      final r = await upload(p.appId, p.patchId, body);
      expect(r.statusCode, HttpStatus.badRequest);
      expect(await r.readAsString(), contains('multipart parts'));
    });

    test('the aggregate size is capped, not just each part', () async {
      await repo.close();
      final dir = Directory.systemTemp.createTempSync('cps_mp');
      await boot(override: _withMaxUpload(sqliteConfig(dir.path), 1000));
      final p = await patch();
      // Ten parts of 200 bytes: every part is under the cap, the body is not.
      final body = [
        for (var i = 0; i < 10; i++) part('f$i', 'y' * 200),
        '--B--\r\n',
      ].join();
      final r = await upload(p.appId, p.patchId, body);
      expect(r.statusCode, HttpStatus.requestEntityTooLarge);
    });

    test(
      'a missing required field is a 400 and leaves the patch alone',
      () async {
        // WAS: `fields['arch']!` threw a null-check error -> 500 + logged stack,
        // and the patch had already been moved to `uploading`, where
        // `patches/check` will not serve it and no request remains to finish it.
        final p = await patch();
        final before = (await repo.patch(p.patchId))!.status;
        final r = await upload(
          p.appId,
          p.patchId,
          '${part('platform', 'android')}--B--\r\n',
        );
        expect(r.statusCode, HttpStatus.badRequest);
        expect((await repo.patch(p.patchId))!.status, before);
      },
    );

    test('a normal registration still works', () async {
      final p = await patch();
      final r = await upload(
        p.appId,
        p.patchId,
        '${part('arch', 'aarch64')}${part('platform', 'android')}'
        '${part('hash', 'h')}${part('size', '3')}--B--\r\n',
      );
      expect(r.statusCode, HttpStatus.ok);
    });
  });

  // -------------------------------------------------------------------------
  group('rate limiting', () {
    /// Reboots with deliberately tiny limits so a bucket can be exhausted in a
    /// handful of requests.
    Future<void> bootWithLimits() async {
      await repo.close();
      await boot(
        override: sqliteConfig(
          Directory.systemTemp.createTempSync('cps_rl').path,
          rateLimitPerMinute: 2,
          rateLimitIpPerMinute: 4,
        ),
      );
    }

    test('a single principal is capped at the per-principal limit', () async {
      await bootWithLimits();
      expect(
        (await send(
          'GET',
          '/api/v1/users/me',
          bearer: _bootstrapKey,
        )).statusCode,
        HttpStatus.ok,
      );
      expect(
        (await send(
          'GET',
          '/api/v1/users/me',
          bearer: _bootstrapKey,
        )).statusCode,
        HttpStatus.ok,
      );
      expect(
        (await send(
          'GET',
          '/api/v1/users/me',
          bearer: _bootstrapKey,
        )).statusCode,
        HttpStatus.tooManyRequests,
      );
    });

    test('behind a TRUSTED proxy, each device gets its own bucket', () async {
      // The flip side of ignoring X-Forwarded-For: once TRUSTED_PROXIES names
      // the proxy, distinct devices must stop sharing one window — otherwise
      // the whole fleet throttles itself through the reverse proxy.
      await repo.close();
      await boot(
        override: sqliteConfig(
          Directory.systemTemp.createTempSync('cps_proxy').path,
          trustedProxies: const {'172.18.0.0/16'},
          rateLimitPerMinute: 2,
          rateLimitIpPerMinute: 2,
        ),
      );
      for (var i = 0; i < 6; i++) {
        final r = await send(
          'POST',
          '/api/v1/patches/check',
          peer: '172.18.0.5',
          headers: {'x-forwarded-for': '203.0.113.$i'},
          json: {'app_id': 'nope'},
        );
        expect(r.statusCode, HttpStatus.ok, reason: 'device $i');
      }
      // ...but one device that keeps hammering is still capped.
      for (var i = 0; i < 2; i++) {
        await send(
          'POST',
          '/api/v1/patches/check',
          peer: '172.18.0.5',
          headers: {'x-forwarded-for': '203.0.113.99'},
          json: {'app_id': 'nope'},
        );
      }
      final r = await send(
        'POST',
        '/api/v1/patches/check',
        peer: '172.18.0.5',
        headers: {'x-forwarded-for': '203.0.113.99'},
        json: {'app_id': 'nope'},
      );
      expect(r.statusCode, HttpStatus.tooManyRequests);
    });

    test('a client-prepended hop cannot displace the real one', () async {
      // nginx-style proxies APPEND, so the leftmost entry is client-written.
      // Rotating it must not create new buckets.
      await repo.close();
      await boot(
        override: sqliteConfig(
          Directory.systemTemp.createTempSync('cps_prepend').path,
          trustedProxies: const {'172.18.0.0/16'},
          rateLimitPerMinute: 2,
          rateLimitIpPerMinute: 2,
        ),
      );
      var limited = false;
      for (var i = 0; i < 8; i++) {
        final r = await send(
          'POST',
          '/api/v1/patches/check',
          peer: '172.18.0.5',
          // The client claims to be 1.2.3.$i; the proxy appended the truth.
          headers: {'x-forwarded-for': '1.2.3.$i, 203.0.113.7'},
          json: {'app_id': 'nope'},
        );
        if (r.statusCode == HttpStatus.tooManyRequests) {
          limited = true;
          break;
        }
      }
      expect(limited, isTrue, reason: 'all 8 should share 203.0.113.7');
    });

    test(
      'TRUSTED_PROXIES=* believes the header instead of collapsing',
      () async {
        // The wildcard is for a proxy whose address can't be pinned. It must
        // still separate devices — treating every hop as "trusted" and falling
        // back to the proxy's own address would put the whole fleet in one
        // bucket, which is the failure the setting exists to avoid.
        await repo.close();
        await boot(
          override: sqliteConfig(
            Directory.systemTemp.createTempSync('cps_star').path,
            trustedProxies: const {'*'},
            rateLimitPerMinute: 2,
            rateLimitIpPerMinute: 2,
          ),
        );
        for (var i = 0; i < 6; i++) {
          final r = await send(
            'POST',
            '/api/v1/patches/check',
            peer: '203.0.113.1',
            headers: {'x-forwarded-for': '198.51.100.$i'},
            json: {'app_id': 'nope'},
          );
          expect(r.statusCode, HttpStatus.ok, reason: 'device $i');
        }
      },
    );

    test('rotating the bearer still hits the per-IP ceiling', () async {
      // WAS: the only bucket was the bearer, which is client-supplied and not
      // validated until after this middleware — so a fresh one per request was
      // an unlimited supply of fresh windows.
      await bootWithLimits();
      for (var i = 0; i < 4; i++) {
        expect(
          (await send(
            'GET',
            '/api/v1/users/me',
            bearer: 'sb_api_rot_$i',
          )).statusCode,
          isNot(HttpStatus.tooManyRequests),
          reason: 'request $i',
        );
      }
      expect(
        (await send(
          'GET',
          '/api/v1/users/me',
          bearer: 'sb_api_rot_last',
        )).statusCode,
        HttpStatus.tooManyRequests,
      );
    });
  });

  // -------------------------------------------------------------------------
  group('issuing API keys (/admin/users)', () {
    // WAS: authenticated was the only requirement. `upsertUser` returns the
    // EXISTING row on an email conflict, so any tenant could name the seeded
    // owner and be handed a working owner API key — one request that undoes
    // every role and tenancy check elsewhere.
    test('a non-operator cannot mint a key for the seeded owner', () async {
      final attacker = await otherTenant();
      final r = await send(
        'POST',
        '/admin/users?email=${config.loginEmail}',
        bearer: attacker.key,
      );
      expect(r.statusCode, HttpStatus.forbidden);
      expect(await r.readAsString(), isNot(contains('sb_api_')));
    });

    test('a non-operator cannot create a new user either', () async {
      final attacker = await otherTenant();
      final r = await send(
        'POST',
        '/admin/users?email=fresh@example.test',
        bearer: attacker.key,
      );
      expect(r.statusCode, HttpStatus.forbidden);
      expect(await repo.userByEmail('fresh@example.test'), isNull);
    });

    test(
      'a developer collaborator on an app is still not an operator',
      () async {
        final app = await seedApp();
        final dev = await repo.upsertUser('dev@example.test', 'Dev');
        final devKey = await repo.createApiKey(dev.id);
        await repo.addCollaborator(app.appId, dev.id, 'admin');
        final r = await send(
          'POST',
          '/admin/users?email=${config.loginEmail}',
          bearer: devKey,
        );
        expect(r.statusCode, HttpStatus.forbidden);
      },
    );

    test('the bootstrap operator can still issue keys', () async {
      final r = await send(
        'POST',
        '/admin/users?email=teammate@example.test&name=Teammate',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.ok);
      final body = await jsonOf(r);
      expect(body['api_key'], startsWith('sb_api_'));
      expect(body['email'], 'teammate@example.test');
    });

    test('the operator can still issue keys AFTER shorebird login', () async {
      // The seeded root user is `owner@self-host.local`, but setup.sh writes a
      // LOGIN_EMAIL of its own — so the JWT minted by /login belonged to a
      // different user in a personal org, and the operator was refused by the
      // very route the login page points them at. `ensureRootOwner` makes the
      // configured LOGIN_EMAIL an owner of the root org at boot.
      await repo.close();
      await boot(
        override: _withLoginEmail(
          sqliteConfig(Directory.systemTemp.createTempSync('cps_login').path),
          'admin@example.test',
        ),
      );
      final redirect = await send(
        'POST',
        '/login',
        body:
            'continue=http%3A%2F%2Flocalhost%3A1234%2Fcb&api_key=$_bootstrapKey',
        headers: {'content-type': 'application/x-www-form-urlencoded'},
      );
      final code = Uri.parse(
        redirect.headers[HttpHeaders.locationHeader]!,
      ).queryParameters['code'];
      final tok = await jsonOf(
        await send(
          'POST',
          '/token',
          body: 'grant_type=authorization_code&code=$code',
        ),
      );
      final jwt = tok['access_token'] as String;
      expect(
        (await jsonOf(
          await send('GET', '/api/v1/users/me', bearer: jwt),
        ))['email'],
        'admin@example.test',
      );
      final issued = await send(
        'POST',
        '/admin/users?email=ci@example.test',
        bearer: jwt,
      );
      expect(issued.statusCode, HttpStatus.ok);
      expect((await jsonOf(issued))['api_key'], startsWith('sb_api_'));
    });
  });

  // -------------------------------------------------------------------------
  group('role validation', () {
    // WAS: only the collaborator route had an allowlist. Org roles were written
    // straight through, and authorization matches exact values — so `Admin`
    // (capital A) reads as no privileges at all.
    test('an unknown org invitation role is rejected', () async {
      final r = await send(
        'POST',
        '/admin/orgs/1/invitations?email=x@example.test&role=superuser',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.badRequest);
    });

    test('an unknown member role is rejected', () async {
      final user = await repo.upsertUser('member@example.test', null);
      final r = await send(
        'PATCH',
        '/admin/orgs/1/members/${user.id}?role=Admin',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.badRequest);
    });

    test(
      'a member role change with no role is rejected, not defaulted',
      () async {
        // `_validRole` defaults to `developer` where "unspecified" is meaningful
        // (create an invitation, add a collaborator). On an update it must not:
        // a mistyped parameter name would read as a silent demotion.
        final user = await repo.upsertUser('member@example.test', null);
        await repo.setMemberRole(1, user.id, 'admin');
        for (final query in ['', '?roles=admin', '?role=']) {
          final r = await send(
            'PATCH',
            '/admin/orgs/1/members/${user.id}$query',
            bearer: _bootstrapKey,
          );
          expect(r.statusCode, HttpStatus.badRequest, reason: query);
        }
      },
    );

    test('the last owner/admin of an org cannot be demoted', () async {
      // Otherwise nobody can invite, manage members, or (for the root org)
      // issue API keys, with no recovery short of the database.
      final r = await send(
        'PATCH',
        '/admin/orgs/1/members/1?role=developer',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.conflict);
      expect(await repo.orgAdminCount(1), greaterThanOrEqualTo(1));
    });
  });

  // -------------------------------------------------------------------------
  group('invitation expiry', () {
    // WAS: `_acceptInvitation` gated on `exp is DateTime`. `expires_at` is
    // TIMESTAMPTZ, which the SQLite translation rewrites to TEXT, so on the
    // DEFAULT backend the value is a String and the guard never fired — the
    // 7-day expiry was not enforced at all. A leaked accept link kept working
    // forever, and it grants whatever role the invite carries (up to `owner`).
    // These tests run on SQLite specifically, where the old code was dead.
    Future<String> inviteFor(String email, {required String role}) async {
      final r = await send(
        'POST',
        '/admin/orgs/1/invitations?email=$email&role=$role',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.ok);
      return (await jsonOf(r))['token'] as String;
    }

    /// A bearer for [email], via a per-user API key.
    Future<String> keyFor(String email) async =>
        repo.createApiKey((await repo.upsertUser(email, null)).id);

    test('a fresh invitation is still accepted', () async {
      const email = 'newhire@example.test';
      final token = await inviteFor(email, role: 'developer');
      final r = await send(
        'POST',
        '/api/v1/invitations/$token/accept',
        bearer: await keyFor(email),
      );
      expect(r.statusCode, HttpStatus.ok);
      expect((await jsonOf(r))['joined_org'], 1);
    });

    test('an expired invitation is refused on the SQLite backend', () async {
      const email = 'contractor@example.test';
      final token = await inviteFor(email, role: 'owner');
      // Backdate past the 7-day window. Written in the same ISO-8601 text form
      // the translation layer produces, so the SQL comparison is meaningful.
      final past = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 1))
          .toIso8601String();
      await repo.db.query(
        'UPDATE invitations SET expires_at = @x WHERE token = @t',
        {'x': past, 't': token},
      );

      final r = await send(
        'POST',
        '/api/v1/invitations/$token/accept',
        bearer: await keyFor(email),
      );
      expect(r.statusCode, HttpStatus.conflict);
      expect((await jsonOf(r))['message'], contains('expired'));
      // ...and it granted nothing: the invite named `owner` of the root org.
      final user = (await repo.userByEmail(email))!;
      expect(
        (await repo.memberships(user.id)).where((m) => m.orgId == 1),
        isEmpty,
        reason: 'an expired invite must not confer org membership',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('ranged downloads', () {
    late String url;

    setUp(() async {
      final app = await seedApp();
      final patch = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${app.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': app.releaseId},
        ),
      );
      await uploadPatchArtifact(app.appId, patch['id'] as int);
      // The artifact is the 3 bytes `abc` (see uploadPatchArtifact).
      url = _signedUrlFor(
        config,
        (await repo.patchArtifacts(patch['id'] as int)).single.token,
      );
    });

    Future<Response> ranged(String range) =>
        send('GET', url, headers: {HttpHeaders.rangeHeader: range});

    test('serves a valid range', () async {
      final r = await ranged('bytes=1-2');
      expect(r.statusCode, HttpStatus.partialContent);
      expect(r.headers[HttpHeaders.contentRangeHeader], 'bytes 1-2/3');
      expect(await r.readAsString(), 'bc');
    });

    test('an inverted range is a 416, not a 500', () async {
      // WAS: len = end - start + 1 = -49, so openRead threw and the client got
      // a 500 with a logged stack trace on demand.
      final r = await ranged('bytes=100-50');
      expect(r.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      expect(r.headers[HttpHeaders.contentRangeHeader], 'bytes */3');
    });

    test('an end past the file is clamped to the real length', () async {
      // WAS: Content-Length: 100000000000 with a 3-byte body, so the client
      // waited for bytes that never came until it timed out.
      final r = await ranged('bytes=0-99999999999');
      expect(r.statusCode, HttpStatus.partialContent);
      expect(r.headers[HttpHeaders.contentLengthHeader], '3');
      expect(r.headers[HttpHeaders.contentRangeHeader], 'bytes 0-2/3');
    });

    test('a start past the end of the file is a 416', () async {
      expect(
        (await ranged('bytes=9-')).statusCode,
        HttpStatus.requestedRangeNotSatisfiable,
      );
    });

    test('a suffix range serves the last bytes', () async {
      final r = await ranged('bytes=-2');
      expect(r.headers[HttpHeaders.contentRangeHeader], 'bytes 1-2/3');
      expect(await r.readAsString(), 'bc');
    });
  });

  // -------------------------------------------------------------------------
  group('download fault injection', () {
    test('fail_after is ignored in production', () async {
      final app = await seedApp();
      final patch = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${app.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': app.releaseId},
        ),
      );
      await uploadPatchArtifact(app.appId, patch['id'] as int);
      final artifact = (await repo.patchArtifacts(patch['id'] as int)).single;

      // Non-production honors it (the updater's resume tests rely on this).
      final devUrl = _signedUrlFor(config, artifact.token);
      final truncated = await send('GET', '$devUrl&fail_after=1');
      expect((await truncated.read().expand((c) => c).toList()), hasLength(1));

      // Production ignores it and serves the whole artifact.
      await repo.close();
      final prodDir = Directory.systemTemp.createTempSync('cps_prod');
      await boot(override: _asProduction(sqliteConfig(prodDir.path)));
      final app2 = await seedApp();
      final patch2 = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${app2.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': app2.releaseId},
        ),
      );
      await uploadPatchArtifact(app2.appId, patch2['id'] as int);
      final artifact2 = (await repo.patchArtifacts(patch2['id'] as int)).single;
      final prodUrl = _signedUrlFor(config, artifact2.token);
      final full = await send('GET', '$prodUrl&fail_after=1');
      expect((await full.read().expand((c) => c).toList()), hasLength(3));
    });
  });

  // -------------------------------------------------------------------------
  group('upload token reuse after a rejected body', () {
    // WAS: `_upload` moved the artifact to `uploading` BEFORE parsing the
    // multipart body, so any body that failed to parse burned the token for
    // good: the retry hit the `status != pending` conflict, and re-registering
    // the artifact hit the duplicate `(patch, arch, platform)` check. Nothing
    // could move it forward, so the patch never reached `ready`.
    Future<({String appId, int patchId, String token})> registered() async {
      const bd = 'BOUNDARY';
      String field(String n, String v) =>
          '--$bd\r\ncontent-disposition: form-data; name="$n"\r\n\r\n$v\r\n';
      final app = await seedApp();
      final patch = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${app.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': app.releaseId},
        ),
      );
      final patchId = patch['id'] as int;
      final reg = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${app.appId}/patches/$patchId/artifacts',
          bearer: _bootstrapKey,
          headers: {'content-type': 'multipart/form-data; boundary=$bd'},
          body:
              '${field('arch', 'aarch64')}${field('platform', 'android')}'
              '${field('hash', 'unchecked-for-patches')}${field('size', '3')}'
              '--$bd--\r\n',
        ),
      );
      return (
        appId: app.appId,
        patchId: patchId,
        token: (reg['url'] as String).split('/').last,
      );
    }

    Future<Response> uploadBody(String token, String body) => send(
      'POST',
      '/api/v1/uploads/$token',
      bearer: _bootstrapKey,
      headers: {'content-type': 'multipart/form-data; boundary=BOUNDARY'},
      body: body,
    );

    const goodBody =
        '--BOUNDARY\r\ncontent-disposition: form-data; name="file"; '
        'filename="p"\r\n\r\nabc\r\n--BOUNDARY--\r\n';

    test('a body with no file part leaves the token usable', () async {
      final r = await registered();

      final missing = await uploadBody(
        r.token,
        '--BOUNDARY\r\ncontent-disposition: form-data; name="notafile"'
        '\r\n\r\nx\r\n--BOUNDARY--\r\n',
      );
      expect(missing.statusCode, HttpStatus.badRequest);

      // The retry must succeed rather than 409 on a non-pending status.
      final retry = await uploadBody(r.token, goodBody);
      expect(retry.statusCode, HttpStatus.noContent);
      expect(
        (await repo.patch(r.patchId))!.status,
        PatchStatus.ready,
        reason: 'the patch must still be able to reach ready',
      );
    });

    test('a body that exceeds the part cap leaves the token usable', () async {
      final r = await registered();

      final tooMany = await uploadBody(
        r.token,
        [
          for (var i = 0; i < 64; i++)
            '--BOUNDARY\r\ncontent-disposition: form-data; name="f$i"'
                '\r\n\r\nx\r\n',
          '--BOUNDARY--\r\n',
        ].join(),
      );
      expect(tooMany.statusCode, HttpStatus.badRequest);

      final retry = await uploadBody(r.token, goodBody);
      expect(retry.statusCode, HttpStatus.noContent);
    });
  });

  group('a failed store write leaves the upload retryable', () {
    // WAS: `_upload` set the artifact to `uploading` and then called
    // `store.put`. A throw (object store down, disk full) left it `uploading`
    // for good: the retry hit `status != pending` (409) and re-registering hit
    // the duplicate check, so the patch could never reach `ready`.
    const bd = 'BOUNDARY';
    String field(String n, String v) =>
        '--$bd\r\ncontent-disposition: form-data; name="$n"\r\n\r\n$v\r\n';
    const goodBody =
        '--BOUNDARY\r\ncontent-disposition: form-data; name="file"; '
        'filename="p"\r\n\r\nabc\r\n--BOUNDARY--\r\n';

    Future<({String appId, int patchId, String token})> registered([
      int size = 3,
    ]) async {
      final app = await seedApp();
      final patch = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${app.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': app.releaseId},
        ),
      );
      final patchId = patch['id'] as int;
      final reg = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${app.appId}/patches/$patchId/artifacts',
          bearer: _bootstrapKey,
          headers: {'content-type': 'multipart/form-data; boundary=$bd'},
          body:
              '${field('arch', 'aarch64')}${field('platform', 'android')}'
              '${field('hash', 'unchecked-for-patches')}${field('size', '$size')}'
              '--$bd--\r\n',
        ),
      );
      return (
        appId: app.appId,
        patchId: patchId,
        token: (reg['url'] as String).split('/').last,
      );
    }

    /// Mirrors the CLI's resumable loop (`_resumableUpload` in
    /// code_push_client.dart): chunked PUTs, a 308 with progress resets the
    /// failure count, a 5xx backs off and asks `bytes */TOTAL`, five
    /// consecutive failures give up, and a non-200/308 answer to the query
    /// aborts. Gives up at [cap] requests so a loop shows as `looped`.
    Future<({String outcome, int requests})> cliUpload(
      String token,
      String data, {
      required int chunk,
      int cap = 100,
    }) async {
      final total = data.length;
      var offset = 0;
      var failures = 0;
      var requests = 0;
      int? rangeEnd(Response r) {
        final h = r.headers['range'];
        if (h == null) return null;
        return int.parse(h.substring(h.lastIndexOf('-') + 1)) + 1;
      }

      Future<Response> put(String range, String body) {
        requests++;
        return send(
          'PUT',
          '/api/v1/uploads/$token',
          bearer: _bootstrapKey,
          headers: {'content-range': range},
          body: body,
        );
      }

      while (offset < total) {
        if (requests >= cap) return (outcome: 'looped', requests: requests);
        final end = offset + chunk < total ? offset + chunk : total;
        final r = await put(
          'bytes $offset-${end - 1}/$total',
          data.substring(offset, end),
        );
        if (r.statusCode == HttpStatus.ok) {
          offset = total;
        } else if (r.statusCode == 308) {
          final next = rangeEnd(r) ?? 0;
          if (next > offset) {
            failures = 0;
          } else if (++failures > 5) {
            return (outcome: 'failed', requests: requests);
          }
          offset = next;
        } else if (r.statusCode >= 500) {
          if (++failures > 5) return (outcome: 'failed', requests: requests);
          final q = await put('bytes */$total', '');
          if (q.statusCode == HttpStatus.ok) {
            offset = total;
          } else if (q.statusCode == 308) {
            offset = rangeEnd(q) ?? 0;
          } else {
            return (outcome: 'failed', requests: requests);
          }
        } else {
          return (outcome: 'failed', requests: requests);
        }
      }
      return (outcome: 'ok', requests: requests);
    }

    _FlakyStore flakyApi() {
      final root = Directory('${tmp.path}/artifacts')
        ..createSync(recursive: true);
      final staging = Directory('${tmp.path}/staging')
        ..createSync(recursive: true);
      final store = _FlakyStore(root, staging);
      api = Api(repo, store, config);
      return store;
    }

    Future<Response> uploadBody(String token) => send(
      'POST',
      '/api/v1/uploads/$token',
      bearer: _bootstrapKey,
      headers: {'content-type': 'multipart/form-data; boundary=$bd'},
      body: goodBody,
    );

    test(
      'multipart: the token returns to pending and the retry works',
      () async {
        final store = flakyApi();
        final r = await registered();
        final art = (await repo.artifactByToken(r.token))!;

        store.failNextPut = true;
        final failed = await uploadBody(r.token);
        expect(failed.statusCode, greaterThanOrEqualTo(500));
        expect(
          (await repo.artifactByToken(r.token))!.status,
          ArtifactStatus.pending,
        );
        expect(
          await store.exists(art.storageKey),
          isFalse,
          reason: 'a partial object must not be left behind',
        );

        final retry = await uploadBody(r.token);
        expect(retry.statusCode, HttpStatus.noContent);
        expect(
          (await repo.artifactByToken(r.token))!.status,
          ArtifactStatus.verified,
        );
        expect((await repo.patch(r.patchId))!.status, PatchStatus.ready);
      },
    );

    test('resumable: a commit that fails once succeeds on the query', () async {
      final store = flakyApi();
      final r = await registered(6);
      store.failNextPut = true;

      final res = await cliUpload(r.token, 'abcdef', chunk: 2);

      expect(res.outcome, 'ok');
      expect(
        res.requests,
        4,
        reason:
            '3 chunks and one status query that re-runs the commit; '
            'dropping the staged bytes would re-send every chunk',
      );
      final art = (await repo.artifactByToken(r.token))!;
      expect(
        art.status,
        ArtifactStatus.verified,
        reason: 'a 200 is not enough',
      );
      expect(await store.exists(art.storageKey), isTrue);
      expect((await repo.patch(r.patchId))!.status, PatchStatus.ready);
    });

    test('resumable: a commit that always fails ends after a bounded number '
        'of requests', () async {
      final store = flakyApi();
      final r = await registered(6);
      store.alwaysFail = true;

      final res = await cliUpload(r.token, 'abcdef', chunk: 2);

      expect(res.outcome, 'failed', reason: 'it must not loop');
      expect(res.requests, lessThan(20));
      final art = (await repo.artifactByToken(r.token))!;
      expect(art.status, isNot(ArtifactStatus.verified));
      expect(await store.exists(art.storageKey), isFalse);
    });

    test('resumable: bad staged bytes fail verification and restart', () async {
      flakyApi();
      final r = await registered(6);
      // 5 bytes against a registered size of 6: verification rejects it.
      final res = await cliUpload(r.token, 'abcde', chunk: 2);
      expect(res.outcome, 'failed');
      expect(
        (await repo.artifactByToken(r.token))!.status,
        ArtifactStatus.failed,
      );
    });

    test('resumable: losing the claim is a conflict, not a takeover', () async {
      final store = flakyApi();
      api = Api(_RacingRepo(repo.db), store, config);
      final r = await registered();
      final art = (await repo.artifactByToken(r.token))!;
      final res = await send(
        'PUT',
        '/api/v1/uploads/${r.token}',
        bearer: _bootstrapKey,
        headers: {'content-range': 'bytes 0-2/3'},
        body: 'abc',
      );
      expect(res.statusCode, HttpStatus.conflict);
      expect(
        (await repo.artifactByToken(r.token))!.status,
        ArtifactStatus.uploading,
      );
      expect(await store.exists(art.storageKey), isFalse);
    });

    test('multipart: an artifact that became failed cannot verify', () async {
      final store = flakyApi();
      final r = await registered();
      final art = (await repo.artifactByToken(r.token))!;
      store.afterPut = () =>
          repo.setArtifactStatus(art.id, ArtifactStatus.failed);

      final res = await uploadBody(r.token);

      expect(res.statusCode, HttpStatus.conflict);
      expect(
        (await repo.artifactByToken(r.token))!.status,
        ArtifactStatus.failed,
      );
    });

    test(
      'multipart: losing the claim is a conflict, not a double write',
      () async {
        // Both requests read `pending` before either claims. The loser must
        // stop at the compare-and-set rather than write the shared key.
        final store = flakyApi();
        api = Api(_RacingRepo(repo.db), store, config);
        final r = await registered();
        final art = (await repo.artifactByToken(r.token))!;

        final res = await uploadBody(r.token);

        expect(res.statusCode, HttpStatus.conflict);
        expect(await res.readAsString(), contains('already in use'));
        expect(await store.exists(art.storageKey), isFalse);
      },
    );

    test(
      'multipart: a failure after another request verified is a no-op',
      () async {
        // Two requests share a token and a storage key. B verifies while A's put
        // is failing; A's cleanup must not demote the artifact or delete B's
        // object.
        final store = flakyApi();
        final r = await registered();
        final art = (await repo.artifactByToken(r.token))!;
        store.beforeFailure = () async {
          await store.put(art.storageKey, utf8.encode('abc'));
          await repo.setArtifactStatus(art.id, ArtifactStatus.verified);
        };
        store.failNextPut = true;

        final failed = await uploadBody(r.token);
        expect(failed.statusCode, greaterThanOrEqualTo(500));
        expect(
          (await repo.artifactByToken(r.token))!.status,
          ArtifactStatus.verified,
        );
        expect(await store.exists(art.storageKey), isTrue);
      },
    );

    test(
      'multipart: a second request with a claimed token conflicts',
      () async {
        flakyApi();
        final r = await registered();
        final art = (await repo.artifactByToken(r.token))!;
        await repo.transitionArtifactStatus(
          art.id,
          ArtifactStatus.pending,
          ArtifactStatus.uploading,
        );
        expect((await uploadBody(r.token)).statusCode, HttpStatus.conflict);
      },
    );

    test('a store failure answers 500 without the store\'s detail', () async {
      final store = flakyApi();
      final r = await registered();
      store.failNextPut = true;

      final res = await uploadBody(r.token);

      expect(res.statusCode, HttpStatus.internalServerError);
      final body = await res.readAsString();
      expect(body, contains('Internal server error (request id req_'));
      expect(body, isNot(contains('no space left')));
      expect(body, isNot(contains(tmp.path)));
    });

    // A zero timeout makes every claim stale at once, so these tests need no
    // sleeps; the default (15 minutes) keeps a fresh claim safe.
    Api staleApi(ArtifactStore store) => Api(
      repo,
      store,
      config,
      uploadClaimTimeout: Duration.zero,
      inFlightWait: const Duration(milliseconds: 300),
    );

    test('multipart: a claim older than the bound is reclaimed', () async {
      final store = flakyApi();
      final r = await registered();
      final art = (await repo.artifactByToken(r.token))!;
      // A process killed mid-write: claimed, never finished.
      expect(await repo.claimArtifact(art.id), isNotNull);

      expect(
        (await uploadBody(r.token)).statusCode,
        HttpStatus.conflict,
        reason: 'a claim inside the bound may still be running',
      );
      api = staleApi(store);
      expect((await uploadBody(r.token)).statusCode, HttpStatus.noContent);
      expect(
        (await repo.artifactByToken(r.token))!.status,
        ArtifactStatus.verified,
      );
      expect((await repo.patch(r.patchId))!.status, PatchStatus.ready);
    });

    test('a claim with no recorded start gets its clock started, not '
        'stolen', () async {
      // `uploading` as an old replica leaves it, with no `uploading_at`: a
      // rolling deploy must not let a new replica take its live claim.
      final store = flakyApi();
      final r = await registered();
      final art = (await repo.artifactByToken(r.token))!;
      await repo.setArtifactStatus(art.id, ArtifactStatus.uploading);
      expect((await repo.artifactByToken(r.token))!.uploadingAt, isNull);

      expect((await uploadBody(r.token)).statusCode, HttpStatus.conflict);
      final seen = (await repo.artifactByToken(r.token))!;
      expect(seen.status, ArtifactStatus.uploading);
      expect(seen.uploadingAt, isNotNull, reason: 'the clock started');

      api = staleApi(store);
      expect((await uploadBody(r.token)).statusCode, HttpStatus.noContent);
    });

    test('multipart: a holder reclaimed while alive cannot undo the new '
        'owner (fails the write)', () async {
      final store = flakyApi();
      final r = await registered();
      final art = (await repo.artifactByToken(r.token))!;
      String? claimB;
      store.beforeFailure = () async {
        // While A is still writing, its claim is reclaimed and B takes over
        // and writes the shared object.
        expect(await repo.reclaimStaleUpload(art.id, Duration.zero), isTrue);
        claimB = await repo.claimArtifact(art.id);
        await store.put(art.storageKey, utf8.encode('abc'));
      };
      store.failNextPut = true;

      final res = await uploadBody(r.token);

      expect(res.statusCode, greaterThanOrEqualTo(500));
      final now = (await repo.artifactByToken(r.token))!;
      expect(now.status, ArtifactStatus.uploading, reason: 'still B\'s');
      expect(await store.exists(art.storageKey), isTrue, reason: 'B\'s object');
      expect(
        await repo.settleClaim(art.id, claimB!, ArtifactStatus.verified),
        isTrue,
        reason: 'B still owns the claim',
      );
    });

    test('multipart: a stale holder cannot mark verified over the new '
        'owner', () async {
      final store = flakyApi();
      final r = await registered();
      final art = (await repo.artifactByToken(r.token))!;
      String? claimB;
      store.beforeVerify = () async {
        expect(await repo.reclaimStaleUpload(art.id, Duration.zero), isTrue);
        claimB = await repo.claimArtifact(art.id);
      };

      final res = await uploadBody(r.token);

      expect(res.statusCode, HttpStatus.conflict);
      expect(
        (await repo.artifactByToken(r.token))!.status,
        ArtifactStatus.uploading,
        reason: 'still B\'s, not verified by the stale holder',
      );
      expect(
        await repo.settleClaim(art.id, claimB!, ArtifactStatus.verified),
        isTrue,
        reason: 'B still owns the claim',
      );
    });

    test('resumable: a stale holder cannot fail the new owner or discard its '
        'staged bytes', () async {
      final store = flakyApi();
      final r = await registered(6);
      final art = (await repo.artifactByToken(r.token))!;
      // 5 bytes against a registered size of 6: the holder's verify fails.
      await store.stageChunk(r.token, 0, utf8.encode('abcde'));
      String? claimB;
      store.beforeVerify = () async {
        expect(await repo.reclaimStaleUpload(art.id, Duration.zero), isTrue);
        claimB = await repo.claimArtifact(art.id);
      };

      final res = await send(
        'PUT',
        '/api/v1/uploads/${r.token}',
        bearer: _bootstrapKey,
        headers: {'content-range': 'bytes */5'},
      );

      expect(res.statusCode, HttpStatus.conflict);
      expect(
        (await repo.artifactByToken(r.token))!.status,
        ArtifactStatus.uploading,
        reason: 'not failed by the stale holder',
      );
      expect(store.stagedSize(r.token), 5, reason: 'staged file kept');
      expect(
        await repo.settleClaim(art.id, claimB!, ArtifactStatus.verified),
        isTrue,
      );
    });

    test('resumable: a chunk is refused if a commit started while its body '
        'arrived', () async {
      final store = flakyApi();
      api = Api(_ClaimOnRecheckRepo(repo.db), store, config);
      final r = await registered();

      final res = await send(
        'PUT',
        '/api/v1/uploads/${r.token}',
        bearer: _bootstrapKey,
        headers: {'content-range': 'bytes 0-1/3'},
        body: 'ab',
      );

      expect(res.statusCode, HttpStatus.conflict);
      expect(store.stagedSize(r.token), 0);
    });

    test('resumable: a query during a running commit does not start a second '
        'commit', () async {
      final store = flakyApi();
      api = Api(
        repo,
        store,
        config,
        inFlightWait: const Duration(milliseconds: 300),
      );
      final r = await registered();
      final art = (await repo.artifactByToken(r.token))!;
      await store.stageChunk(r.token, 0, utf8.encode('abc'));
      // The first commit holds the claim; the client lost its response.
      await repo.transitionArtifactStatus(
        art.id,
        ArtifactStatus.pending,
        ArtifactStatus.uploading,
      );

      final res = await send(
        'PUT',
        '/api/v1/uploads/${r.token}',
        bearer: _bootstrapKey,
        headers: {'content-range': 'bytes */3'},
      );

      expect(
        res.statusCode,
        HttpStatus.serviceUnavailable,
        reason: 'a 5xx is what the client retries; 200/308 would be a lie',
      );
      expect(await store.exists(art.storageKey), isFalse);
      expect(store.stagedSize(r.token), 3, reason: 'staged bytes untouched');
    });

    test('resumable: a query waits for the running commit and reports its '
        'result', () async {
      final store = flakyApi();
      api = Api(repo, store, config, inFlightWait: const Duration(seconds: 3));
      final r = await registered();
      final art = (await repo.artifactByToken(r.token))!;
      await store.stageChunk(r.token, 0, utf8.encode('abc'));
      await repo.transitionArtifactStatus(
        art.id,
        ArtifactStatus.pending,
        ArtifactStatus.uploading,
      );
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 250), () async {
          await repo.transitionArtifactStatus(
            art.id,
            ArtifactStatus.uploading,
            ArtifactStatus.verified,
          );
        }),
      );

      final res = await send(
        'PUT',
        '/api/v1/uploads/${r.token}',
        bearer: _bootstrapKey,
        headers: {'content-range': 'bytes */3'},
      );

      expect(res.statusCode, HttpStatus.ok);
    });

    test('resumable: waiters per token are capped, and the count returns to '
        'zero', () async {
      final store = flakyApi();
      api = Api(
        repo,
        store,
        config,
        // Long enough that the four waiters are still waiting when the fifth
        // query is answered, however slow the runner.
        inFlightWait: const Duration(seconds: 5),
      );
      final r = await registered();
      final art = (await repo.artifactByToken(r.token))!;
      await store.stageChunk(r.token, 0, utf8.encode('abc'));
      expect(await repo.claimArtifact(art.id), isNotNull);

      Future<Response> query() => send(
        'PUT',
        '/api/v1/uploads/${r.token}',
        bearer: _bootstrapKey,
        headers: {'content-range': 'bytes */3'},
      );

      var finished = 0;
      final waiting = [
        for (var i = 0; i < 4; i++) query().whenComplete(() => finished++),
      ];
      // Let the four enter the wait.
      while (api.debugWaiters(r.token) < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final fifth = await query();
      expect(fifth.statusCode, HttpStatus.serviceUnavailable);
      expect(
        finished,
        0,
        reason: 'over the cap is refused at once, while the four still wait',
      );
      expect(
        api.debugWaiters(r.token),
        4,
        reason: 'the refused one is not counted',
      );

      for (final res in await Future.wait(waiting)) {
        expect(res.statusCode, HttpStatus.serviceUnavailable);
      }
      expect(api.debugWaiters(r.token), 0);
    });

    test(
      'resumable: the waiter count is released when a waiter errors',
      () async {
        final store = flakyApi();
        api = Api(
          repo,
          store,
          config,
          inFlightWait: const Duration(seconds: 5),
        );
        final r = await registered();
        final art = (await repo.artifactByToken(r.token))!;
        await store.stageChunk(r.token, 0, utf8.encode('abc'));
        expect(await repo.claimArtifact(art.id), isNotNull);

        final res = send(
          'PUT',
          '/api/v1/uploads/${r.token}',
          bearer: _bootstrapKey,
          headers: {'content-range': 'bytes */3'},
        );
        while (api.debugWaiters(r.token) < 1) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        // The artifact fails under the waiter: the query answers 409 (an error
        // path out of the wait), and the count must still drop.
        final cur = (await repo.artifactByToken(r.token))!;
        expect(cur.status, ArtifactStatus.uploading);
        await repo.setArtifactStatus(art.id, ArtifactStatus.failed);

        expect((await res).statusCode, HttpStatus.conflict);
        expect(api.debugWaiters(r.token), 0);
      },
    );

    test('resumable: more bytes are refused while a commit runs', () async {
      final store = flakyApi();
      final r = await registered();
      final art = (await repo.artifactByToken(r.token))!;
      await store.stageChunk(r.token, 0, utf8.encode('abc'));
      await repo.transitionArtifactStatus(
        art.id,
        ArtifactStatus.pending,
        ArtifactStatus.uploading,
      );

      final res = await send(
        'PUT',
        '/api/v1/uploads/${r.token}',
        bearer: _bootstrapKey,
        headers: {'content-range': 'bytes 0-2/3'},
        body: 'abc',
      );

      expect(res.statusCode, HttpStatus.conflict);
    });

    test('resumable: a commit whose holder died is reclaimed', () async {
      final store = flakyApi();
      api = staleApi(store);
      final r = await registered();
      final art = (await repo.artifactByToken(r.token))!;
      await store.stageChunk(r.token, 0, utf8.encode('abc'));
      await repo.transitionArtifactStatus(
        art.id,
        ArtifactStatus.pending,
        ArtifactStatus.uploading,
      );

      final res = await send(
        'PUT',
        '/api/v1/uploads/${r.token}',
        bearer: _bootstrapKey,
        headers: {'content-range': 'bytes */3'},
      );

      expect(res.statusCode, HttpStatus.ok);
      expect(
        (await repo.artifactByToken(r.token))!.status,
        ArtifactStatus.verified,
      );
      expect((await repo.patch(r.patchId))!.status, PatchStatus.ready);
    });
  });

  // -------------------------------------------------------------------------
  group('untrusted X-Forwarded-For is surfaced', () {
    // X-Forwarded-For used to be honored unconditionally. Ignoring it unless
    // the peer is in TRUSTED_PROXIES is correct, but silent on upgrade: behind
    // an operator's own nginx/Caddy the peer is the Docker bridge gateway, not
    // loopback, so the whole fleet collapses into one rate-limit bucket and
    // starts seeing 429s with nothing saying why.
    Future<Response> check({required String peer, String? forwardedFor}) =>
        send(
          'POST',
          '/api/v1/patches/check',
          peer: peer,
          headers: {if (forwardedFor != null) 'x-forwarded-for': forwardedFor},
          json: {'app_id': 'nope'},
        );

    test('counts requests whose header was ignored', () async {
      // 172.17.0.1 is the Docker bridge gateway — the exact peer an operator
      // running their own proxy in front of the container ends up with.
      for (var i = 0; i < 3; i++) {
        await check(peer: '172.17.0.1', forwardedFor: '203.0.113.$i');
      }
      expect(api.obs.metrics.untrustedForwardedFor, 3);

      final metrics = await send('GET', '/metrics');
      expect(
        await metrics.readAsString(),
        contains('code_push_untrusted_forwarded_for_total 3'),
      );
    });

    test('does not count a trusted proxy', () async {
      await repo.close();
      await boot(
        override: sqliteConfig(
          Directory.systemTemp.createTempSync('cps_trusted').path,
          trustedProxies: const {'172.18.0.0/16'},
        ),
      );
      await check(peer: '172.18.0.5', forwardedFor: '203.0.113.7');
      expect(api.obs.metrics.untrustedForwardedFor, 0);
    });

    test('does not count a request with no header', () async {
      await check(peer: '172.17.0.1');
      expect(api.obs.metrics.untrustedForwardedFor, 0);
    });
  });

  // -------------------------------------------------------------------------
  group('plan and CLI metrics routes', () {
    // WAS: `shorebird whoami` also calls GET /plan, which 404ed, so whoami
    // failed with "Failed to fetch account." on every self-hosted install.
    // `shorebird metrics *` calls apps/{app}/metrics/{name}, which only
    // existed as apps/{app}/analytics/{name}.
    Future<void> seedEvents(String appId) async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      var n = 0;
      for (final (client, type, version, platform) in [
        ('c1', '__patch_download__', '1.0.0', 'android'),
        ('c1', '__patch_install__', '1.0.0', 'android'),
        ('c2', '__patch_install__', '1.0.0', 'android'),
        ('c3', '__patch_install__', '2.0.0', 'android'),
        ('c4', '__patch_install__', '1.0.0', 'ios'),
      ]) {
        await repo.insertEvent(
          raw: '{}',
          dedupeKey: 'k${n++}',
          appId: appId,
          clientId: client,
          type: type,
          patchNumber: 1,
          platform: platform,
          releaseVersion: version,
          ts: now - 3600,
        );
      }
    }

    Future<Map<String, dynamic>> getJson(String path) async {
      final r = await send('GET', path, bearer: _bootstrapKey);
      expect(r.statusCode, HttpStatus.ok, reason: path);
      return jsonOf(r);
    }

    // Keys the client's response models read unconditionally (checkedKey
    // keys must be present even when null). This package cannot depend on
    // the protocol package, so the keys are asserted instead.
    void expectKeys(Map<String, dynamic> body, List<String> keys) {
      for (final k in keys) {
        expect(body.containsKey(k), isTrue, reason: 'missing "$k" in $body');
      }
    }

    test('GET /plan reports a level and needs authentication', () async {
      final ok = await jsonOf(
        await send('GET', '/api/v1/plan', bearer: _bootstrapKey),
      );
      expect(ok['level'], 'self_hosted');

      final anon = await send('GET', '/api/v1/plan');
      expect(anon.statusCode, isNot(HttpStatus.ok));
      final bad = await send('GET', '/api/v1/plan', bearer: 'sb_api_nope');
      expect(bad.statusCode, HttpStatus.forbidden);
    });

    test('patch-installs and patch-downloads', () async {
      final app = await seedApp();
      await seedEvents(app.appId);
      for (final (name, count) in [
        ('patch-installs', 4),
        ('patch-downloads', 1),
      ]) {
        final body = await getJson(
          '/api/v1/apps/${app.appId}/metrics/$name'
          '?granularity=day&group_by=release',
        );
        expectKeys(body, ['as_of', 'granularity', 'current', 'previous']);
        final cur = body['current'] as Map<String, dynamic>;
        expect(cur['count'], count);
        expectKeys(cur['range'] as Map<String, dynamic>, ['start', 'end']);
        expect(cur['time_series'], isA<List<Object?>>());
        expect(cur['breakdown'], isA<List<Object?>>());
      }
    });

    test('start and end bound the window', () async {
      final app = await seedApp();
      await seedEvents(app.appId);
      final now = DateTime.now().toUtc();
      String iso(DateTime d) => Uri.encodeQueryComponent(d.toIso8601String());
      final inWindow = await getJson(
        '/api/v1/apps/${app.appId}/metrics/patch-installs'
        '?start=${iso(now.subtract(const Duration(days: 2)))}&end=${iso(now)}',
      );
      expect((inWindow['current'] as Map)['count'], 4);
      final before = await getJson(
        '/api/v1/apps/${app.appId}/metrics/patch-installs'
        '?start=${iso(now.subtract(const Duration(days: 9)))}'
        '&end=${iso(now.subtract(const Duration(days: 5)))}',
      );
      expect((before['current'] as Map)['count'], 0);
      final r = await send(
        'GET',
        '/api/v1/apps/${app.appId}/metrics/patch-installs'
            '?start=${iso(now)}&end=${iso(now.subtract(const Duration(days: 1)))}',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.badRequest);
    });

    test('unique-users', () async {
      final app = await seedApp();
      await seedEvents(app.appId);
      final body = await getJson(
        '/api/v1/apps/${app.appId}/metrics/unique-users?group_by=platform',
      );
      expectKeys(body, ['as_of', 'granularity', 'current', 'previous']);
      final cur = body['current'] as Map<String, dynamic>;
      expect(cur['unique_users'], 4);
      expect(cur['breakdown'], isA<List<Object?>>());
    });

    test('version-distribution', () async {
      final app = await seedApp();
      await seedEvents(app.appId);
      final body = await getJson(
        '/api/v1/apps/${app.appId}/metrics/version-distribution',
      );
      expectKeys(body, [
        'entries',
        'total_devices',
        'active_window_days',
        'as_of',
      ]);
      expect(body['total_devices'], 4);
    });

    test('new-devices', () async {
      final app = await seedApp();
      await seedEvents(app.appId);
      final body = await getJson(
        '/api/v1/apps/${app.appId}/metrics/new-devices',
      );
      expectKeys(body, ['current', 'previous', 'window_days', 'as_of']);
      expect(body['current'], 4);
    });

    test('patch-adoption', () async {
      final app = await seedApp();
      await seedEvents(app.appId);
      final body = await getJson(
        '/api/v1/apps/${app.appId}/metrics/patch-adoption'
        '?release_version=1.0.0',
      );
      expectKeys(body, [
        'release_version',
        'is_latest',
        'granularity',
        'range',
        'as_of',
        'patches',
      ]);
      expect(body['release_version'], '1.0.0');
    });

    test('active-hours', () async {
      final app = await seedApp();
      final body = await getJson(
        '/api/v1/apps/${app.appId}/metrics/active-hours',
      );
      expectKeys(body, [
        'hourly',
        'recommended_window_start_utc',
        'recommended_window_length_hours',
        'busiest_hour_utc',
        'lookback_days',
        'as_of',
      ]);
      expect(body['hourly'], hasLength(24));
    });

    test('activity-heatmap', () async {
      final app = await seedApp();
      final body = await getJson(
        '/api/v1/apps/${app.appId}/metrics/activity-heatmap',
      );
      expectKeys(body, [
        'cells',
        'busiest_day_of_week_utc',
        'busiest_hour_utc',
        'lookback_days',
        'as_of',
      ]);
      expect(body['cells'], hasLength(168));
    });

    test('an unknown metric is a 404', () async {
      final app = await seedApp();
      final r = await send(
        'GET',
        '/api/v1/apps/${app.appId}/metrics/nope',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.notFound);
    });

    test('analytics/{name} still works for the console', () async {
      final app = await seedApp();
      await seedEvents(app.appId);
      final body = await getJson(
        '/api/v1/apps/${app.appId}/analytics/patch-installs',
      );
      expect((body['current'] as Map)['count'], 4);
    });

    test('release-scoped patch installs and downloads', () async {
      final app = await seedApp(); // release 1.0.0
      await seedEvents(app.appId);
      for (final (name, count) in [
        ('patch-installs', 3),
        ('patch-downloads', 1),
      ]) {
        final body = await getJson(
          '/api/v1/apps/${app.appId}/releases/${app.releaseId}/metrics/$name'
          '?group_by=patch',
        );
        expectKeys(body, ['as_of', 'granularity', 'current', 'previous']);
        final cur = body['current'] as Map<String, dynamic>;
        // iOS and Android events merge under one version; 2.0.0 is not counted.
        expect(cur['count'], count);
        expect(cur['breakdown'], isA<List<Object?>>());
      }
    });

    test(
      'start alone runs to now, end alone covers the 28 days before it',
      () async {
        final app = await seedApp();
        await seedEvents(app.appId);
        final now = DateTime.now().toUtc();
        String iso(DateTime d) => Uri.encodeQueryComponent(d.toIso8601String());
        final startOnly = await getJson(
          '/api/v1/apps/${app.appId}/metrics/patch-installs'
          '?start=${iso(now.subtract(const Duration(days: 2)))}',
        );
        expect((startOnly['current'] as Map)['count'], 4);
        final endOnly = await getJson(
          '/api/v1/apps/${app.appId}/metrics/patch-installs'
          '?end=${iso(now.add(const Duration(hours: 1)))}',
        );
        final range = (endOnly['current'] as Map)['range'] as Map;
        final span = DateTime.parse(
          range['end'] as String,
        ).difference(DateTime.parse(range['start'] as String));
        expect(span, const Duration(days: 28));
        expect((endOnly['current'] as Map)['count'], 4);
      },
    );

    test(
      'previous is the same length just before, null before the data',
      () async {
        final app = await seedApp();
        await seedEvents(app.appId);
        final now = DateTime.now().toUtc();
        String iso(DateTime d) => Uri.encodeQueryComponent(d.toIso8601String());
        // The events are an hour old, so a window from 2 days ago starts after
        // the data floor only if the previous window does too.
        final none = await getJson(
          '/api/v1/apps/${app.appId}/metrics/patch-installs'
          '?start=${iso(now.subtract(const Duration(days: 2)))}',
        );
        expect(none['previous'], isNull);
        expect(none.containsKey('previous'), isTrue);
        // A 10 minute window: the previous one (10 minutes before it) is after
        // the data floor (events are an hour old), so it is present, empty and
        // as long as the current one.
        final recent = await getJson(
          '/api/v1/apps/${app.appId}/metrics/patch-installs'
          '?start=${iso(now.subtract(const Duration(minutes: 10)))}',
        );
        final cur = recent['current'] as Map;
        final prev = recent['previous'] as Map;
        expect(cur['count'], 0);
        expect(prev['count'], 0);
        Duration len(Map w) => DateTime.parse(
          (w['range'] as Map)['end'] as String,
        ).difference(DateTime.parse((w['range'] as Map)['start'] as String));
        expect(len(prev), len(cur));
        expect((prev['range'] as Map)['end'], (cur['range'] as Map)['start']);
      },
    );

    test(
      'a future start, or a window that is not positive, is a 400',
      () async {
        final app = await seedApp();
        final now = DateTime.now().toUtc();
        String iso(DateTime d) => Uri.encodeQueryComponent(d.toIso8601String());
        for (final q in [
          'start=${iso(now.add(const Duration(days: 1)))}',
          'end=${iso(now.subtract(const Duration(days: 40)))}'
              '&start=${iso(now.subtract(const Duration(days: 40)))}',
        ]) {
          final r = await send(
            'GET',
            '/api/v1/apps/${app.appId}/metrics/unique-users?$q',
            bearer: _bootstrapKey,
          );
          expect(r.statusCode, HttpStatus.badRequest, reason: q);
        }
      },
    );

    test('a timestamp with no offset is UTC; an offset is honored', () async {
      final app = await seedApp();
      final now = DateTime.now().toUtc();
      String naive(DateTime d) =>
          d.toIso8601String().replaceFirst(RegExp(r'Z$'), '');
      Future<DateTime> rangeStart(String start) async {
        final body = await getJson(
          '/api/v1/apps/${app.appId}/metrics/patch-installs'
          '?start=${Uri.encodeQueryComponent(start)}',
        );
        final range = (body['current'] as Map)['range'] as Map;
        return DateTime.parse(range['start'] as String);
      }

      final from = now.subtract(const Duration(days: 3));
      final got = await rangeStart(naive(from));
      expect(got.difference(from).abs(), lessThan(const Duration(seconds: 1)));
      // The same instant written at +05:00.
      final plus5 = from.add(const Duration(hours: 5));
      final offset = '${naive(plus5)}+05:00';
      final got5 = await rangeStart(offset);
      expect(got5.difference(from).abs(), lessThan(const Duration(seconds: 1)));
    });

    test('the span and window_days are capped at 366 days', () async {
      final app = await seedApp();
      final now = DateTime.now().toUtc();
      String iso(DateTime d) => Uri.encodeQueryComponent(d.toIso8601String());
      for (final q in [
        'start=${iso(now.subtract(const Duration(days: 400)))}',
        'window_days=367',
        'window_days=99999999999',
        'window_days=0',
        'window_days=abc',
      ]) {
        final r = await send(
          'GET',
          '/api/v1/apps/${app.appId}/metrics/patch-downloads?$q',
          bearer: _bootstrapKey,
        );
        expect(r.statusCode, HttpStatus.badRequest, reason: q);
      }
      final ok = await send(
        'GET',
        '/api/v1/apps/${app.appId}/metrics/patch-downloads?window_days=366',
        bearer: _bootstrapKey,
      );
      expect(ok.statusCode, HttpStatus.ok);
    });

    test('the console analytics routes stay lenient', () async {
      final app = await seedApp();
      await seedEvents(app.appId);
      // unique-users and patch-installs ignored start/end here before, and
      // still do (a malformed or inverted window is not an error).
      for (final name in ['unique-users', 'patch-installs']) {
        final r = await send(
          'GET',
          '/api/v1/apps/${app.appId}/analytics/$name'
              '?start=oops&end=2000-01-01&window_days=99999',
          bearer: _bootstrapKey,
        );
        expect(r.statusCode, HttpStatus.ok, reason: name);
      }
    });

    test('a non-numeric release id is a 400', () async {
      final app = await seedApp();
      final r = await send(
        'GET',
        '/api/v1/apps/${app.appId}/releases/abc/metrics/patch-installs',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.badRequest);
    });

    test('a release of another app is a 404', () async {
      final a = await seedApp('a');
      final b = await seedApp('b');
      final r = await send(
        'GET',
        '/api/v1/apps/${a.appId}/releases/${b.releaseId}/metrics/'
            'patch-installs',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.notFound);
    });

    test('an unauthenticated caller or another tenant is refused', () async {
      final app = await seedApp();
      final other = await otherTenant();
      for (final path in [
        '/api/v1/apps/${app.appId}/metrics/patch-installs',
        '/api/v1/apps/${app.appId}/metrics/unique-users',
        '/api/v1/apps/${app.appId}/releases/${app.releaseId}/metrics/'
            'patch-installs',
      ]) {
        final anon = await send('GET', path);
        expect(anon.statusCode, isNot(HttpStatus.ok), reason: path);
        final r = await send('GET', path, bearer: other.key);
        expect(r.statusCode, HttpStatus.forbidden, reason: path);
      }
    });
  });

  // -------------------------------------------------------------------------
  group('analytics date parameters', () {
    // WAS: `DateTime.parse` on `start`/`end` threw a FormatException that
    // escaped the handler as a 500 plus a logged stack trace — a
    // client-triggerable 500, the same class `_pathId` exists to prevent.
    test('a malformed start is a 400, not a 500', () async {
      final app = await seedApp();
      final r = await send(
        'GET',
        '/api/v1/apps/${app.appId}/analytics/patch-adoption?start=oops',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.badRequest);
      expect(await r.readAsString(), contains('Invalid start'));
    });

    test('a malformed end is a 400, not a 500', () async {
      final app = await seedApp();
      final r = await send(
        'GET',
        '/api/v1/apps/${app.appId}/analytics/patch-adoption?end=not-a-date',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.badRequest);
      expect(await r.readAsString(), contains('Invalid end'));
    });

    test('an out-of-range date is normalized, not rejected', () async {
      // Dart's DateTime.parse rolls components over rather than failing
      // (`2024-13-45` is 2025-02-14), so this is a 200 by design. Pinned so a
      // future switch to stricter parsing is a deliberate change, not a
      // surprise 400 for callers already sending such values.
      final app = await seedApp();
      final r = await send(
        'GET',
        '/api/v1/apps/${app.appId}/analytics/patch-adoption?start=2024-13-45',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.ok);
    });

    test('well-formed dates are accepted', () async {
      final app = await seedApp();
      final r = await send(
        'GET',
        '/api/v1/apps/${app.appId}/analytics/patch-adoption'
            '?start=2024-01-01&end=2024-02-01',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.ok);
    });

    test('omitted dates are accepted', () async {
      final app = await seedApp();
      final r = await send(
        'GET',
        '/api/v1/apps/${app.appId}/analytics/patch-adoption',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.ok);
    });
  });

  // -------------------------------------------------------------------------
  // The CLI's `PatchArtifact.fromJson` does an unguarded
  // `DateTime.parse(json['created_at'] as String)`. The patch-artifact payload
  // omitted `created_at`, so every patch that HAS artifacts was unparseable and
  // `patches info`, `patches list` and `patches set-track` all died with a
  // FormatException. Only artifact-less patches — which no real patch is —
  // appeared to work, which is why unit tests never caught it.
  group('patch artifact wire contract', () {
    test('a patch artifact carries every field the CLI requires', () async {
      final s = await seedApp();
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': s.releaseId},
        ),
      );
      await uploadPatchArtifact(s.appId, p['id'] as int);

      final list = await jsonOf(
        await send(
          'GET',
          '/api/v1/apps/${s.appId}/releases/${s.releaseId}/patches',
          bearer: _bootstrapKey,
        ),
      );
      final artifacts =
          ((list['patches'] as List).single as Map)['artifacts'] as List;
      final artifact = artifacts.single as Map<String, dynamic>;

      // Exactly the keys PatchArtifact.fromJson reads, with the types it casts
      // to. `created_at` is the one that was missing.
      expect(artifact['id'], isA<int>());
      expect(artifact['patch_id'], isA<int>());
      expect(artifact['arch'], isA<String>());
      expect(artifact['platform'], isA<String>());
      expect(artifact['hash'], isA<String>());
      expect(artifact['size'], isA<int>());
      expect(artifact['created_at'], isA<String>());
      // Must be parseable, not merely present.
      expect(
        () => DateTime.parse(artifact['created_at'] as String),
        returnsNormally,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Zero-config crash reporting. Boot-crash rollback already exists; what was
  // missing is the stack trace that explains why. Intake must be as forgiving as
  // possible — the client posting it is, by definition, an app that just died.
  group('crash reporting', () {
    late String appId;

    Future<Response> report(Object? body, {String? rawBody}) => send(
      'POST',
      '/api/v1/crashes',
      json: rawBody == null ? body : null,
      body: rawBody,
    );

    Future<List<dynamic>> listCrashes({String query = ''}) async =>
        (await jsonOf(
              await send(
                'GET',
                '/api/v1/apps/$appId/crashes$query',
                bearer: _bootstrapKey,
              ),
            ))['crashes']
            as List<dynamic>;

    setUp(() async {
      appId = (await seedApp()).appId;
    });

    Map<String, Object?> crash({
      String? client = 'device-1',
      String version = '1.0.0',
      int patch = 1,
      String stack = 'main.dart:1\nfoo.dart:2',
      String kind = 'FlutterError',
    }) => {
      'app_id': appId,
      'client_id': client,
      'release_version': version,
      'patch_number': patch,
      'platform': 'android',
      'arch': 'aarch64',
      'kind': kind,
      'message': 'boom',
      'stack': stack,
      'timestamp': 1700000000,
    };

    test('stores a report and reads it back', () async {
      expect((await jsonOf(await report(crash())))['stored'], isTrue);
      final list = await listCrashes();
      expect(list, hasLength(1));
      final c = list.single as Map<String, dynamic>;
      expect(c['release_version'], '1.0.0');
      expect(c['patch_number'], 1);
      expect(c['arch'], 'aarch64');
      expect(c['kind'], 'FlutterError');
      expect(c['stack'], contains('foo.dart:2'));
      // Normalized regardless of backend, and parseable.
      expect(() => DateTime.parse(c['received_at'] as String), returnsNormally);
    });

    test('a crash loop collapses to one row', () async {
      for (var i = 0; i < 5; i++) {
        await report(crash());
      }
      expect(await listCrashes(), hasLength(1));
      // Second post reports stored:false rather than erroring.
      expect((await jsonOf(await report(crash())))['stored'], isFalse);
    });

    test('a genuinely different stack is kept', () async {
      await report(crash());
      await report(crash(stack: 'other.dart:9'));
      expect(await listCrashes(), hasLength(2));
    });

    test('narrows by release version and patch number', () async {
      await report(crash());
      await report(crash(version: '2.0.0', patch: 7, stack: 'a.dart:1'));
      expect(await listCrashes(query: '?release_version=2.0.0'), hasLength(1));
      expect(await listCrashes(query: '?patch_number=7'), hasLength(1));
      expect(await listCrashes(query: '?patch_number=999'), isEmpty);
    });

    test('accepts a nested {crash: {...}} envelope', () async {
      expect(
        (await jsonOf(await report({'crash': crash()})))['stored'],
        isTrue,
      );
      expect(await listCrashes(), hasLength(1));
    });

    test('garbage never fails the reporter', () async {
      // An app in a crash loop must not also be fighting 4xx/5xx.
      for (final r in [
        await report(null, rawBody: 'not json at all'),
        await report(<String, Object?>{}),
        await report({'app_id': 12345}),
        await report(null, rawBody: ''),
      ]) {
        expect(r.statusCode, HttpStatus.ok);
        expect((await jsonOf(r))['stored'], anyOf(isTrue, isFalse));
      }
    });

    test('needs no bearer token', () async {
      final r = await send('POST', '/api/v1/crashes', json: crash());
      expect(r.statusCode, HttpStatus.ok);
    });

    test('another tenant cannot read this app\'s crashes', () async {
      await report(crash());
      final other = await otherTenant();
      final r = await send(
        'GET',
        '/api/v1/apps/$appId/crashes',
        bearer: other.key,
      );
      expect(r.statusCode, anyOf(HttpStatus.notFound, HttpStatus.forbidden));
    });

    // Symbolication is read-time and opt-in. Ingest must never depend on it:
    // symbols are often uploaded after a crash has already arrived, and
    // resolving costs a fetch + unzip + DWARF parse per distinct patch.
    group('symbolication', () {
      test('is absent unless asked for', () async {
        await report(crash());

        final crashes = await listCrashes();

        // Default response shape must be unchanged for existing callers.
        expect(crashes.single, isNot(contains('stack_symbolicated')));
      });

      test('is present but null when no symbols were retained', () async {
        await report(crash());

        final crashes = await listCrashes(query: '?symbolicate=true');

        // The key appears so a caller can tell "not resolvable" from "not
        // requested", and the raw stack is always still there.
        final report0 = crashes.single as Map<String, dynamic>;
        expect(report0, contains('stack_symbolicated'));
        expect(report0['stack_symbolicated'], isNull);
        expect(report0['stack'], equals('main.dart:1\nfoo.dart:2'));
      });

      test('is null for a crash carrying no patch number', () async {
        // A crash against an unpatched release has no patch, so no retained
        // symbol set can exist for it.
        await report({...crash(), 'patch_number': null});

        final crashes = await listCrashes(query: '?symbolicate=true');

        expect(
          (crashes.single as Map<String, dynamic>)['stack_symbolicated'],
          isNull,
        );
      });

      test('does not fail the request when symbols are unusable', () async {
        await report(crash());

        final r = await send(
          'GET',
          '/api/v1/apps/$appId/crashes?symbolicate=true',
          bearer: _bootstrapKey,
        );

        // Unsymbolicated crashes are still worth reading; an unresolvable
        // symbol set must never turn the list endpoint into an error.
        expect(r.statusCode, HttpStatus.ok);
      });
    });
  });

  // -------------------------------------------------------------------------
  // Asset support in patches. The bundle rides along as an ordinary patch
  // artifact tagged `arch: assets`, and app-side Dart fetches it from
  // /patches/assets. The native updater is never involved, which is what keeps
  // the feature off the engine-build critical path (and working on iOS).
  group('patch asset bundles', () {
    late String appId;
    late int releaseId;
    late int patchNumber;
    late int patchId;

    /// A promoted patch, so the app under test is running it.
    Future<void> seedPromotedPatch({bool withAssets = true}) async {
      final s = await seedApp();
      appId = s.appId;
      releaseId = s.releaseId;
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/$appId/patches',
          bearer: _bootstrapKey,
          json: {'release_id': releaseId},
        ),
      );
      patchId = p['id'] as int;
      patchNumber = p['number'] as int;
      // The code artifact the updater consumes...
      await uploadPatchArtifact(appId, patchId);
      // ...and the asset bundle, which needs NO new upload path: `arch` is
      // free-form on artifact registration, so this is the existing endpoint.
      if (withAssets) {
        await uploadPatchArtifact(appId, patchId, arch: assetsArch);
      }
      await send(
        'POST',
        '/api/v1/apps/$appId/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': patchId, 'channel_id': s.channelId},
      );
    }

    Future<Map<String, dynamic>> ask({
      String? app,
      String version = '1.0.0',
      String platform = 'android',
      Object? number,
    }) async => jsonOf(
      await send(
        'POST',
        '/api/v1/patches/assets',
        json: {
          'app_id': app ?? appId,
          'release_version': version,
          'platform': platform,
          'patch_number': number ?? patchNumber,
        },
      ),
    );

    test('serves a signed url for the named patch', () async {
      await seedPromotedPatch();
      final r = await ask();
      expect(r['assets_available'], isTrue);
      final assets = r['assets'] as Map<String, dynamic>;
      expect(assets['url'], isA<String>());
      expect(assets['hash'], isA<String>());
      expect(assets['size'], isA<int>());
      // Signed and expiring, exactly like the patch download url.
      final u = Uri.parse(assets['url'] as String);
      expect(u.path, startsWith('/download/'));
      expect(u.queryParameters, contains('exp'));
      expect(u.queryParameters, contains('sig'));
    });

    test('the url actually downloads the bundle', () async {
      await seedPromotedPatch();
      final u = Uri.parse(((await ask())['assets'] as Map)['url'] as String);
      // The signature lives in the query, so the path alone is not enough.
      final got = await send('GET', '${u.path}?${u.query}');
      expect(got.statusCode, HttpStatus.ok);
      expect(await got.readAsString(), 'abc');
    });

    test('a patch without an asset bundle reports none', () async {
      await seedPromotedPatch(withAssets: false);
      expect((await ask())['assets_available'], isFalse);
    });

    test('will not hand a client another patch number\'s assets', () async {
      await seedPromotedPatch();
      // The app believes it is running a patch that does not exist here.
      expect((await ask(number: patchNumber + 1))['assets_available'], isFalse);
      expect((await ask(number: 0))['assets_available'], isFalse);
    });

    test('stops serving assets once the patch is rolled back', () async {
      await seedPromotedPatch();
      expect((await ask())['assets_available'], isTrue);
      final r = await send(
        'POST',
        '/admin/apps/$appId/patches/$patchId/withdraw?rollback=true',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, anyOf(HttpStatus.ok, HttpStatus.noContent));
      // A rollback reverts devices to the previous code. Continuing to serve
      // this patch's assets would pair new assets with old code.
      expect((await ask())['assets_available'], isFalse);
    });

    test(
      'a plain withdraw keeps serving, because devices still run it',
      () async {
        // Withdrawing without rollback only stops OFFERING the patch to new
        // devices; anything already running it stays on it. Those devices must
        // keep getting their assets, or a withdraw would silently strip assets
        // from a fleet that is still executing the patched code.
        await seedPromotedPatch();
        final r = await send(
          'POST',
          '/admin/apps/$appId/patches/$patchId/withdraw',
          bearer: _bootstrapKey,
        );
        expect(r.statusCode, anyOf(HttpStatus.ok, HttpStatus.noContent));
        expect((await ask())['assets_available'], isTrue);
      },
    );

    test('another app cannot fish for this app\'s bundle', () async {
      await seedPromotedPatch();
      final other = await otherTenant();
      expect((await ask(app: other.appId))['assets_available'], isFalse);
    });

    test('unknown release version reports none', () async {
      await seedPromotedPatch();
      expect((await ask(version: '9.9.9'))['assets_available'], isFalse);
    });

    test('a platform with no bundle reports none', () async {
      await seedPromotedPatch();
      expect((await ask(platform: 'ios'))['assets_available'], isFalse);
    });

    test('malformed bodies answer none rather than erroring', () async {
      await seedPromotedPatch();
      // App code polls this on launch; a 500 here would be a crash path for a
      // purely additive feature.
      for (final body in <Map<String, Object?>>[
        {},
        {'app_id': appId},
        {'app_id': appId, 'release_version': '1.0.0', 'platform': 'android'},
        {
          'app_id': appId,
          'release_version': '1.0.0',
          'platform': 'android',
          'patch_number': 'not-an-int',
        },
      ]) {
        final r = await send('POST', '/api/v1/patches/assets', json: body);
        expect(r.statusCode, HttpStatus.ok);
        expect((await jsonOf(r))['assets_available'], isFalse);
      }
    });

    test(
      'needs no bearer token, like the rest of the device surface',
      () async {
        await seedPromotedPatch();
        final r = await send(
          'POST',
          '/api/v1/patches/assets',
          json: {
            'app_id': appId,
            'release_version': '1.0.0',
            'platform': 'android',
            'patch_number': patchNumber,
          },
        );
        expect(r.statusCode, HttpStatus.ok);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Build provenance. The CLI attaches a `metadata` blob to every release
  // status update and patch creation; the server used to discard it entirely.
  group('build metadata capture', () {
    late String appId;
    late int releaseId;

    setUp(() async {
      final s = await seedApp();
      appId = s.appId;
      releaseId = s.releaseId;
    });

    Future<Map<String, dynamic>?> releaseMetadata() async {
      final r = await jsonOf(
        await send(
          'GET',
          '/api/v1/apps/$appId/releases',
          bearer: _bootstrapKey,
        ),
      );
      final rel = (r['releases'] as List).single as Map<String, dynamic>;
      return rel['metadata'] as Map<String, dynamic>?;
    }

    // Shaped like a real `UpdateReleaseMetadata`, including the nested
    // environment object that must survive the round trip intact.
    const releaseMeta = {
      'release_platform': 'android',
      'flutter_version_override': '3.27.0',
      'generated_apks': false,
      'environment': {
        'shorebird_version': '1.2.3',
        'operating_system': 'macos',
        'flutter_revision': 'abc123',
      },
    };

    test('metadata sent with a release update is stored', () async {
      expect(await releaseMetadata(), isNull);
      await send(
        'PATCH',
        '/api/v1/apps/$appId/releases/$releaseId',
        bearer: _bootstrapKey,
        json: {'metadata': releaseMeta},
      );
      final stored = await releaseMetadata();
      expect(stored, isNotNull);
      expect(stored!['flutter_version_override'], '3.27.0');
      // Nested structure, not flattened or stringified.
      expect((stored['environment'] as Map)['shorebird_version'], '1.2.3');
      expect(stored['generated_apks'], isFalse);
    });

    test('metadata sent with a patch is stored', () async {
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/$appId/patches',
          bearer: _bootstrapKey,
          json: {
            'release_id': releaseId,
            'metadata': {'used_ignore_asset_changes_flag': true},
          },
        ),
      );
      final list = await jsonOf(
        await send(
          'GET',
          '/api/v1/apps/$appId/releases/$releaseId/patches',
          bearer: _bootstrapKey,
        ),
      );
      final patch = (list['patches'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((x) => x['id'] == p['id']);
      expect(
        (patch['metadata'] as Map)['used_ignore_asset_changes_flag'],
        isTrue,
      );
    });

    // The opposite of the notes rule, on purpose: a release that fails the
    // fail-closed status gate is exactly when you want to know what built it.
    test('metadata is captured even when the request 409s on status', () async {
      final r = await send(
        'PATCH',
        '/api/v1/apps/$appId/releases/$releaseId',
        bearer: _bootstrapKey,
        // `active` with no verified artifacts is the 409 path.
        json: {
          'status': 'active',
          'platform': 'android',
          'metadata': releaseMeta,
        },
      );
      expect(r.statusCode, HttpStatus.conflict);
      expect((await releaseMetadata())!['flutter_version_override'], '3.27.0');
    });

    test('a later release update replaces the stored metadata', () async {
      await send(
        'PATCH',
        '/api/v1/apps/$appId/releases/$releaseId',
        bearer: _bootstrapKey,
        json: {'metadata': releaseMeta},
      );
      await send(
        'PATCH',
        '/api/v1/apps/$appId/releases/$releaseId',
        bearer: _bootstrapKey,
        json: {
          'metadata': {'flutter_version_override': '3.29.0'},
        },
      );
      final stored = await releaseMetadata();
      expect(stored!['flutter_version_override'], '3.29.0');
      expect(stored.containsKey('environment'), isFalse);
    });

    // Metadata is diagnostic data whose shape is upstream's to change, so a
    // surprising value must never fail the release it was attached to.
    test(
      'a non-object or absent metadata field is ignored, not an error',
      () async {
        for (final bad in <Object?>[null, 'a string', 42, <String>[], {}]) {
          final r = await send(
            'PATCH',
            '/api/v1/apps/$appId/releases/$releaseId',
            bearer: _bootstrapKey,
            json: {'metadata': bad},
          );
          expect(r.statusCode, HttpStatus.noContent, reason: 'metadata=$bad');
          expect(await releaseMetadata(), isNull, reason: 'metadata=$bad');
        }
      },
    );

    test(
      'an oversized blob is dropped, and the release still succeeds',
      () async {
        final r = await send(
          'PATCH',
          '/api/v1/apps/$appId/releases/$releaseId',
          bearer: _bootstrapKey,
          json: {
            'metadata': {'padding': 'x' * (64 * 1024 + 1)},
          },
        );
        expect(r.statusCode, HttpStatus.noContent);
        expect(await releaseMetadata(), isNull);
      },
    );

    // Notes and metadata are independent columns written by the same request.
    test('metadata and notes on one request both land', () async {
      await send(
        'PATCH',
        '/api/v1/apps/$appId/releases/$releaseId',
        bearer: _bootstrapKey,
        json: {'metadata': releaseMeta, 'notes': 'shipped from CI'},
      );
      final r = await jsonOf(
        await send(
          'GET',
          '/api/v1/apps/$appId/releases',
          bearer: _bootstrapKey,
        ),
      );
      final rel = (r['releases'] as List).single as Map<String, dynamic>;
      expect(rel['notes'], 'shipped from CI');
      expect((rel['metadata'] as Map)['release_platform'], 'android');
    });
  });

  // -------------------------------------------------------------------------
  // Restricting an org to one or more email domains, so a personal account
  // can't be added to a company org or onto one of its apps.
  group('org email-domain restriction', () {
    /// The bootstrap user's org (they are its owner).
    Future<int> rootOrg() async => (await repo.memberships(1)).first.orgId;

    Future<Response> setDomains(
      int orgId,
      String domains, {
      String? bearer,
    }) => send(
      'PUT',
      '/admin/orgs/$orgId/domains?domains=${Uri.encodeQueryComponent(domains)}',
      bearer: bearer ?? _bootstrapKey,
    );

    Future<Response> invite(int orgId, String email) => send(
      'POST',
      '/admin/orgs/$orgId/invitations?email=${Uri.encodeQueryComponent(email)}',
      bearer: _bootstrapKey,
    );

    test('an org is unrestricted by default', () async {
      final orgId = await rootOrg();
      final r = await jsonOf(
        await send('GET', '/admin/orgs/$orgId/domains', bearer: _bootstrapKey),
      );
      expect(r['domains'], isEmpty);
      expect(
        (await invite(orgId, 'anyone@gmail.com')).statusCode,
        HttpStatus.ok,
      );
    });

    test('setting a policy round-trips normalized domains', () async {
      final orgId = await rootOrg();
      final put = await jsonOf(
        await setDomains(orgId, '@Self-Host.local, example.COM'),
      );
      expect(put['domains'], ['self-host.local', 'example.com']);
      final get = await jsonOf(
        await send('GET', '/admin/orgs/$orgId/domains', bearer: _bootstrapKey),
      );
      expect(get['domains'], ['self-host.local', 'example.com']);
    });

    test(
      'an in-domain invitation is allowed, an out-of-domain one is not',
      () async {
        final orgId = await rootOrg();
        await setDomains(orgId, 'self-host.local,example.com');
        expect(
          (await invite(orgId, 'dev@example.com')).statusCode,
          HttpStatus.ok,
        );
        final bad = await invite(orgId, 'someone@gmail.com');
        expect(bad.statusCode, HttpStatus.forbidden);
        // The refusal names the policy so an admin can act on it.
        expect((await jsonOf(bad))['message'], contains('example.com'));
      },
    );

    // The case the upstream request is actually about: a personal account added
    // straight onto a company app, bypassing the org invitation flow.
    test(
      'an out-of-domain collaborator cannot be added to the org\'s app',
      () async {
        final orgId = await rootOrg();
        final s = await seedApp();
        await repo.upsertUser('personal@gmail.com', 'Personal');
        await repo.upsertUser('colleague@example.com', 'Colleague');
        await setDomains(orgId, 'example.com,self-host.local');

        final bad = await send(
          'POST',
          '/admin/apps/${s.appId}/collaborators?email=personal%40gmail.com',
          bearer: _bootstrapKey,
        );
        expect(bad.statusCode, HttpStatus.forbidden);

        final ok = await send(
          'POST',
          '/admin/apps/${s.appId}/collaborators?email=colleague%40example.com',
          bearer: _bootstrapKey,
        );
        expect(ok.statusCode, HttpStatus.ok);
      },
    );

    test('clearing the policy makes the org unrestricted again', () async {
      final orgId = await rootOrg();
      await setDomains(orgId, 'example.com,self-host.local');
      expect(
        (await invite(orgId, 'someone@gmail.com')).statusCode,
        HttpStatus.forbidden,
      );
      final cleared = await jsonOf(await setDomains(orgId, ''));
      expect(cleared['domains'], isEmpty);
      expect(
        (await invite(orgId, 'someone@gmail.com')).statusCode,
        HttpStatus.ok,
      );
    });

    // Existing members predate the policy and keep their access; the policy
    // governs additions only. Evicting on the next request would be far worse.
    test(
      'an existing member is not evicted by a policy that excludes them',
      () async {
        final orgId = await rootOrg();
        final before = await repo.orgMembers(orgId);
        await setDomains(orgId, 'example.com,self-host.local');
        expect(await repo.orgMembers(orgId), hasLength(before.length));
        expect(await repo.userCanAccessApp(1, (await seedApp()).appId), isTrue);
      },
    );

    test('a policy excluding every owner/admin is refused', () async {
      final orgId = await rootOrg();
      // The only owner is owner@self-host.local, so this would strand the org.
      final r = await setDomains(orgId, 'example.com');
      expect(r.statusCode, HttpStatus.conflict);
      expect(await repo.orgAllowedDomains(orgId), isEmpty);
    });

    test(
      'a non-empty but unparseable list is a 400, not a silent clear',
      () async {
        final orgId = await rootOrg();
        await setDomains(orgId, 'self-host.local');
        final r = await setDomains(orgId, 'localhost, nope');
        expect(r.statusCode, HttpStatus.badRequest);
        expect(await repo.orgAllowedDomains(orgId), ['self-host.local']);
      },
    );

    test('a non-admin can neither read nor set the policy', () async {
      final orgId = await rootOrg();
      final other = await otherTenant();
      expect(
        (await send(
          'GET',
          '/admin/orgs/$orgId/domains',
          bearer: other.key,
        )).statusCode,
        HttpStatus.forbidden,
      );
      expect(
        (await setDomains(orgId, 'evil.test', bearer: other.key)).statusCode,
        HttpStatus.forbidden,
      );
      expect(await repo.orgAllowedDomains(orgId), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Tracks are channels: `shorebird patches set-track --track=<name>` resolves
  // the channel and promotes onto it, so several patches can be live at once on
  // different tracks and each device follows only its own. This pins the
  // behavior upstream shorebirdtech/shorebird#1443 and #3776 ask for.
  group('independent live patches per track', () {
    test(
      'each track serves its own patch, and promotion is per track',
      () async {
        final s = await seedApp();
        final appId = s.appId;

        Future<int> readyPatch() async {
          final p = await jsonOf(
            await send(
              'POST',
              '/api/v1/apps/$appId/patches',
              bearer: _bootstrapKey,
              json: {'release_id': s.releaseId},
            ),
          );
          final id = p['id'] as int;
          await uploadPatchArtifact(appId, id);
          return id;
        }

        Future<int> channel(String name) async {
          final c = await jsonOf(
            await send(
              'POST',
              '/api/v1/apps/$appId/channels',
              bearer: _bootstrapKey,
              json: {'channel': name},
            ),
          );
          return c['id'] as int;
        }

        Future<void> promote(int patchId, int channelId) async {
          final r = await send(
            'POST',
            '/api/v1/apps/$appId/patches/promote',
            bearer: _bootstrapKey,
            json: {'patch_id': patchId, 'channel_id': channelId},
          );
          expect(r.statusCode, HttpStatus.noContent);
        }

        /// What a device on [track] is told to install.
        Future<int?> check(String track) async {
          final r = await jsonOf(
            await send(
              'POST',
              '/api/v1/patches/check',
              json: {
                'app_id': appId,
                'release_version': '1.0.0',
                'platform': 'android',
                'arch': 'aarch64',
                'channel': track,
                'client_id': 'device-on-$track',
                'patch_number': 0,
              },
            ),
          );
          final patch = r['patch'];
          return patch == null ? null : (patch as Map)['number'] as int?;
        }

        final internal = await channel('internal');
        final patch1 = await readyPatch();
        final patch2 = await readyPatch();

        // The high-volume internal track gets both patches in turn; stable, the
        // curated track, is still serving nothing.
        await promote(patch1, internal);
        expect(await check('internal'), 1);
        expect(await check('stable'), isNull);

        await promote(patch2, internal);
        expect(await check('internal'), 2);
        expect(await check('stable'), isNull);

        // Curated promotion: only the vetted patch #1 graduates to stable, while
        // internal stays ahead on #2. Both are live simultaneously.
        await promote(patch1, s.channelId);
        expect(await check('stable'), 1);
        expect(await check('internal'), 2);
      },
    );

    // The named tracks §6 lists by name. The code path is generic — channels are
    // get-or-create by name (`api.dart:1550` `_createChannel`) — and the test
    // above already drives one non-stable channel, so what this adds is COVERAGE
    // OF THE NAMED ROWS, not a new capability. Recorded that way deliberately:
    // §6 has twice retracted a claim in this area, once for reading a negative
    // grep as absent work and once for inferring "permanently stable-only" from
    // a real omission.
    //
    // The second half is the one worth having. Supersession is scoped by
    // `WHERE channel_id = @c AND status = @a AND patch_id <> @p`
    // (`repository.dart:1205`), so promoting onto one track must not disturb
    // another — and because a patch can be live on two tracks at once, the verb
    // is ADD, not move. If this half ever fails, stop and re-read the query
    // rather than editing the expectation.
    test(
      'named tracks are independent, and promotion adds rather than moves',
      () async {
        final s = await seedApp();
        final appId = s.appId;

        Future<int> readyPatch() async {
          final p = await jsonOf(
            await send(
              'POST',
              '/api/v1/apps/$appId/patches',
              bearer: _bootstrapKey,
              json: {'release_id': s.releaseId},
            ),
          );
          final id = p['id'] as int;
          await uploadPatchArtifact(appId, id);
          return id;
        }

        Future<int> channel(String name) async {
          final c = await jsonOf(
            await send(
              'POST',
              '/api/v1/apps/$appId/channels',
              bearer: _bootstrapKey,
              json: {'channel': name},
            ),
          );
          return c['id'] as int;
        }

        Future<void> promote(int patchId, int channelId) async {
          final r = await send(
            'POST',
            '/api/v1/apps/$appId/patches/promote',
            bearer: _bootstrapKey,
            json: {'patch_id': patchId, 'channel_id': channelId},
          );
          expect(r.statusCode, HttpStatus.noContent);
        }

        /// What a device on [track] is told to install. `client_id` varies per
        /// track because `eligibleForRollout` buckets on it (`rollout.dart:19`)
        /// and fails closed without one.
        Future<int?> check(String track) async {
          final r = await jsonOf(
            await send(
              'POST',
              '/api/v1/patches/check',
              json: {
                'app_id': appId,
                'release_version': '1.0.0',
                'platform': 'android',
                'arch': 'aarch64',
                'channel': track,
                'client_id': 'device-on-$track',
                'patch_number': 0,
              },
            ),
          );
          final patch = r['patch'];
          return patch == null ? null : (patch as Map)['number'] as int?;
        }

        final beta = await channel('beta');
        final staging = await channel('staging');
        final patch1 = await readyPatch();
        final patch2 = await readyPatch();
        final patch3 = await readyPatch();

        // Three named tracks, three different patches, all live at once.
        await promote(patch1, beta);
        await promote(patch2, staging);
        await promote(patch3, s.channelId);

        expect(await check('beta'), 1);
        expect(await check('staging'), 2);
        expect(await check('stable'), 3);

        // A device asking for a track nobody promoted onto gets nothing — not
        // stable's patch by accident, which is the failure that would make every
        // assertion above meaningless.
        expect(await check('canary'), isNull);

        // Promote staging's patch onto beta as well. Two things must hold: beta
        // supersedes its OWN previous patch, and staging keeps serving patch2
        // because the same patch is now live on two tracks simultaneously.
        await promote(patch2, beta);

        expect(await check('beta'), 2);
        expect(await check('staging'), 2);
        expect(await check('stable'), 3);
      },
    );

    // The `channel` field is what `shorebird patches list` prints as the track
    // and `patches info` shows as "Track:". It was hardcoded null, so a patch
    // promoted seconds earlier still displayed "[no track]".
    test('the CLI-visible track reflects promotion and withdrawal', () async {
      final s = await seedApp();
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': s.releaseId},
        ),
      );
      final patchId = p['id'] as int;
      await uploadPatchArtifact(s.appId, patchId);

      Future<Object?> track() async {
        final r = await jsonOf(
          await send(
            'GET',
            '/api/v1/apps/${s.appId}/releases/${s.releaseId}/patches',
            bearer: _bootstrapKey,
          ),
        );
        return ((r['patches'] as List).single as Map)['channel'];
      }

      // Never promoted: genuinely no track.
      expect(await track(), isNull);

      await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': patchId, 'channel_id': s.channelId},
      );
      expect(await track(), 'stable');

      // Withdrawn: no longer served, so it reports no track again rather than
      // continuing to claim the channel it was removed from.
      await send(
        'POST',
        '/admin/apps/${s.appId}/patches/$patchId/withdraw?channel=stable',
        bearer: _bootstrapKey,
      );
      expect(await track(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Upstream 1.6.123's release-scoped rollback, over the same withdrawal the
  // /admin route performs. Rollforward is deliberately refused.
  group('upstream rollback / rollforward', () {
    late ({String appId, int releaseId, int channelId}) s;
    late int patchId;

    setUp(() async {
      s = await seedApp();
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': s.releaseId},
        ),
      );
      patchId = p['id'] as int;
      await uploadPatchArtifact(s.appId, patchId);
    });

    Future<void> promote(int channelId) => send(
      'POST',
      '/api/v1/apps/${s.appId}/patches/promote',
      bearer: _bootstrapKey,
      json: {'patch_id': patchId, 'channel_id': channelId},
    );

    Future<Response> rollback({int? releaseId, String? bearer}) => send(
      'POST',
      '/api/v1/apps/${s.appId}/releases/${releaseId ?? s.releaseId}'
          '/patches/$patchId/rollback',
      bearer: bearer ?? _bootstrapKey,
    );

    Future<Map<String, dynamic>> check([String channel = 'stable']) async =>
        jsonOf(
          await send(
            'POST',
            '/api/v1/patches/check',
            json: {
              'app_id': s.appId,
              'release_version': '1.0.0',
              'platform': 'android',
              'arch': 'aarch64',
              'channel': channel,
            },
          ),
        );

    test('rolls back, and devices are told to revert', () async {
      await promote(s.channelId);
      expect((await check())['patch_available'], isTrue);

      final r = await rollback();
      expect(r.statusCode, HttpStatus.ok);
      expect((await jsonOf(r))['channels'], ['stable']);

      final c = await check();
      expect(c['patch_available'], isFalse);
      expect(c['rolled_back_patch_numbers'], [1]);
      final listed = await jsonOf(
        await send(
          'GET',
          '/api/v1/apps/${s.appId}/releases/${s.releaseId}/patches',
          bearer: _bootstrapKey,
        ),
      );
      expect(
        ((listed['patches'] as List).single as Map)['is_rolled_back'],
        isTrue,
      );
    });

    test('a repeat is 304, not a conflict', () async {
      await promote(s.channelId);
      expect((await rollback()).statusCode, HttpStatus.ok);
      final again = await rollback();
      expect(again.statusCode, HttpStatus.notModified);
      expect(await again.readAsString(), isEmpty);
    });

    test('names no channel, so it rolls back on every active one', () async {
      final beta = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/channels',
          bearer: _bootstrapKey,
          json: {'channel': 'beta'},
        ),
      );
      await promote(s.channelId);
      await promote(beta['id'] as int);

      final r = await rollback();
      expect(r.statusCode, HttpStatus.ok);
      expect(
        (await jsonOf(r))['channels'],
        unorderedEquals(['stable', 'beta']),
      );
      expect((await check('stable'))['rolled_back_patch_numbers'], [1]);
      expect((await check('beta'))['rolled_back_patch_numbers'], [1]);
    });

    test('a never-promoted patch is a conflict', () async {
      expect((await rollback()).statusCode, HttpStatus.conflict);
    });

    test(
      'a withdrawn patch is marked rolled back: withdrawal is terminal',
      () async {
        await promote(s.channelId);
        await send(
          'POST',
          '/admin/apps/${s.appId}/patches/$patchId/withdraw?channel=stable',
          bearer: _bootstrapKey,
        );
        expect((await check())['rolled_back_patch_numbers'], isEmpty);
        final r = await rollback();
        expect(r.statusCode, HttpStatus.ok);
        expect((await jsonOf(r))['channels'], ['stable']);
        expect((await check())['rolled_back_patch_numbers'], [1]);
        expect((await rollback()).statusCode, HttpStatus.notModified);
      },
    );

    test('the patch must belong to the release in the path', () async {
      await promote(s.channelId);
      final other = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/releases',
          bearer: _bootstrapKey,
          json: {'version': '2.0.0'},
        ),
      );
      final r = await rollback(releaseId: (other['release'] as Map)['id']);
      expect(r.statusCode, HttpStatus.notFound);
      expect((await check())['patch_available'], isTrue);
    });

    test('another tenant cannot roll it back', () async {
      await promote(s.channelId);
      final attacker = await otherTenant();
      expect(
        (await rollback(bearer: attacker.key)).statusCode,
        HttpStatus.forbidden,
      );
      // Their own app id paired with our patch id.
      final r = await send(
        'POST',
        '/api/v1/apps/${attacker.appId}/releases/${s.releaseId}'
            '/patches/$patchId/rollback',
        bearer: attacker.key,
      );
      expect(r.statusCode, HttpStatus.notFound);
      expect((await check())['patch_available'], isTrue);
    });

    test('rollforward fails clearly and changes nothing', () async {
      await promote(s.channelId);
      await rollback();
      final r = await send(
        'POST',
        '/api/v1/apps/${s.appId}/releases/${s.releaseId}'
            '/patches/$patchId/rollforward',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.notImplemented);
      final body = await jsonOf(r);
      expect(body['code'], 'unsupported');
      expect(body['message'], contains('not supported'));
      final c = await check();
      expect(c['patch_available'], isFalse);
      expect(c['rolled_back_patch_numbers'], [1]);
    });
  });

  // Rolling back the newest patch puts devices back on the previous one, as the
  // CLI help says and upstream does. Publishing a patch supersedes the earlier
  // one on its channel, and the device deletes it when the newer one boots, so
  // the server has to offer it again.
  group('rollback restores the prior patch', () {
    late ({String appId, int releaseId, int channelId}) s;

    setUp(() async {
      s = await seedApp();
    });

    /// Creates a patch with one artifact per entry of [platforms] and
    /// promotes it to a channel (default `stable`).
    Future<({int id, int number})> publish({
      List<String> platforms = const ['android'],
      int? channelId,
      int rollout = 100,
      int? releaseId,
    }) async {
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': releaseId ?? s.releaseId},
        ),
      );
      final id = p['id'] as int;
      for (final platform in platforms) {
        await uploadPatchArtifact(s.appId, id, platform: platform);
      }
      final r = await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches/promote',
        bearer: _bootstrapKey,
        json: {
          'patch_id': id,
          'channel_id': channelId ?? s.channelId,
          'rollout': rollout,
        },
      );
      expect(r.statusCode, HttpStatus.noContent);
      return (id: id, number: p['number'] as int);
    }

    Future<Response> rollback(int patchId, {int? releaseId}) => send(
      'POST',
      '/api/v1/apps/${s.appId}/releases/${releaseId ?? s.releaseId}'
          '/patches/$patchId/rollback',
      bearer: _bootstrapKey,
    );

    Future<Map<String, dynamic>> check({
      int current = 0,
      String channel = 'stable',
      String platform = 'android',
      String? clientId,
      String? appId,
    }) async => jsonOf(
      await send(
        'POST',
        '/api/v1/patches/check',
        json: {
          'app_id': appId ?? s.appId,
          'release_version': '1.0.0',
          'platform': platform,
          'arch': 'aarch64',
          'channel': channel,
          'current_patch_number': current,
          if (clientId != null) 'client_id': clientId,
        },
      ),
    );

    int? offered(Map<String, dynamic> c) =>
        (c['patch'] as Map<String, dynamic>?)?['number'] as int?;

    test('the check offers the previous patch and reports the rollback, '
        'even to a device that is on the rolled-back patch', () async {
      final p1 = await publish();
      final p2 = await publish();
      expect(offered(await check()), 2);

      final r = await rollback(p2.id);
      expect(r.statusCode, HttpStatus.ok);
      final body = await jsonOf(r);
      expect(body['channels'], ['stable']);
      expect(body['restored'], [
        {'patch_id': p1.id, 'number': 1, 'channel': 'stable', 'rollout': 100},
      ]);

      // A device on the base release (it lost patch 1 when 2 booted, then
      // dropped 2), and a device still running 2: the same answer.
      for (final current in [0, 2]) {
        final c = await check(current: current);
        expect(c['rolled_back_patch_numbers'], [2]);
        expect(c['patch_available'], isTrue);
        expect(offered(c), 1);
      }
      // A device that is on patch 1 already is not offered it again.
      expect(offered(await check(current: 1)), isNull);
    });

    test('rolling back again walks back to the base release', () async {
      final p1 = await publish();
      final p2 = await publish();
      final p3 = await publish();

      await rollback(p3.id);
      expect(offered(await check()), 2);
      await rollback(p2.id);
      // 3 stays rolled back: 1 comes back, never 3 or 2.
      var c = await check();
      expect(offered(c), 1);
      expect(c['rolled_back_patch_numbers'], [2, 3]);

      final last = await rollback(p1.id);
      expect(last.statusCode, HttpStatus.ok);
      expect((await jsonOf(last))['restored'], isEmpty);
      c = await check();
      expect(c['patch_available'], isFalse);
      expect(c['rolled_back_patch_numbers'], [1, 2, 3]);
    });

    test('a patch rolled back while superseded is never restored', () async {
      final p1 = await publish();
      final p2 = await publish();
      final p3 = await publish();

      // 1 is superseded (active nowhere): rolling it back is a 200 that marks
      // it, not a 409.
      final r = await rollback(p1.id);
      expect(r.statusCode, HttpStatus.ok);
      final body = await jsonOf(r);
      expect(body['channels'], ['stable']);
      expect(body['restored'], isEmpty);
      expect((await rollback(p1.id)).statusCode, HttpStatus.notModified);
      // Devices on 3 keep it; they are only told about 1.
      var c = await check();
      expect(offered(c), 3);
      expect(c['rolled_back_patch_numbers'], [1]);

      await rollback(p3.id);
      expect(offered(await check()), 2);
      await rollback(p2.id);
      c = await check();
      expect(c['patch_available'], isFalse);
      expect(c['rolled_back_patch_numbers'], [1, 2, 3]);
    });

    test('a never-promoted patch is still a conflict', () async {
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': s.releaseId},
        ),
      );
      expect((await rollback(p['id'] as int)).statusCode, HttpStatus.conflict);
    });

    test('the admin withdraw route restores too', () async {
      await publish();
      final p2 = await publish();
      final r = await send(
        'POST',
        '/admin/apps/${s.appId}/patches/${p2.id}/withdraw'
            '?channel=stable&rollback=true',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.ok);
      expect(((await jsonOf(r))['restored'] as List).single['number'], 1);
      expect(offered(await check()), 1);
    });

    test('withdrawing without a rollback restores nothing', () async {
      await publish();
      final p2 = await publish();
      final r = await send(
        'POST',
        '/admin/apps/${s.appId}/patches/${p2.id}/withdraw?channel=stable',
        bearer: _bootstrapKey,
      );
      expect((await jsonOf(r))['restored'], isEmpty);
      expect((await check())['patch_available'], isFalse);
    });

    group('rollout', () {
      test('the restored patch keeps the percentage it had', () async {
        await publish(rollout: 50);
        final p2 = await publish();
        await rollback(p2.id);

        var eligible = 0;
        for (var i = 0; i < 40; i++) {
          if (offered(await check(clientId: 'client-$i')) == 1) eligible++;
        }
        // Still a partial rollout: some devices get it, some do not.
        expect(eligible, greaterThan(0));
        expect(eligible, lessThan(40));
        // A device with no stable id fails closed, as for any partial rollout.
        expect(offered(await check()), isNull);
      });

      test('the rollback response says what rollout it restored at', () async {
        await publish(rollout: 25);
        final p2 = await publish();
        final body = await jsonOf(await rollback(p2.id));
        expect(((body['restored'] as List).single as Map)['rollout'], 25);
      });
    });

    group('platforms', () {
      test(
        'restores per platform, only what the rolled-back patch served',
        () async {
          // 1 is android-only, 2 is ios-only; 3 covers both and supersedes both.
          await publish();
          await publish(platforms: ['ios']);
          final p3 = await publish(platforms: ['android', 'ios']);
          final body = await jsonOf(await rollback(p3.id));
          expect(
            [for (final r in body['restored'] as List) (r as Map)['number']],
            [2, 1],
          );
          expect(offered(await check()), 1);
          expect(offered(await check(platform: 'ios')), 2);
        },
      );

      test('a patch is not restored for a platform still served', () async {
        // 1 (android+ios) is only partly covered by 2 (android), so it stays
        // active; rolling 2 back needs no restore.
        await publish(platforms: ['android', 'ios']);
        final p2 = await publish();
        final body = await jsonOf(await rollback(p2.id));
        expect(body['restored'], isEmpty);
        expect(offered(await check()), 1);
        expect(offered(await check(platform: 'ios')), 1);
      });

      test(
        'an earlier patch is restored only for the platforms it has',
        () async {
          // 1 is ios-only and was superseded by 2 (android+ios). Rolling back 2
          // restores 1 for ios; android has nothing to go back to.
          await publish(platforms: ['ios']);
          final p2 = await publish(platforms: ['android', 'ios']);
          await rollback(p2.id);
          expect(offered(await check()), isNull);
          expect(offered(await check(platform: 'ios')), 1);
        },
      );

      test('a patch for a different platform is not restored', () async {
        // 1 is ios-only, 2 is android-only: 2 never superseded 1, and rolling
        // 2 back brings nothing back.
        await publish(platforms: ['ios']);
        final p2 = await publish();
        final body = await jsonOf(await rollback(p2.id));
        expect(body['restored'], isEmpty);
        expect(offered(await check()), isNull);
        expect(offered(await check(platform: 'ios')), 1);
      });
    });

    test('other channels are untouched', () async {
      final beta = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/channels',
          bearer: _bootstrapKey,
          json: {'channel': 'beta'},
        ),
      );
      final betaId = beta['id'] as int;
      final p1 = await publish();
      final p2 = await publish();
      await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': p1.id, 'channel_id': betaId},
      );
      final p3 = await publish(channelId: betaId);
      expect(p3.number, 3);

      // Rolling back 2 (active on stable only) restores 1 on stable; beta,
      // where 3 is active, is unchanged.
      final body = await jsonOf(await rollback(p2.id));
      expect(body['channels'], ['stable']);
      expect(offered(await check()), 1);
      final c = await check(channel: 'beta');
      expect(offered(c), 3);
      expect(c['rolled_back_patch_numbers'], isEmpty);

      // Rolling back 3 on beta restores 1 there; stable is as it was.
      await rollback(p3.id);
      expect(offered(await check(channel: 'beta')), 1);
      expect(offered(await check()), 1);
    });

    test('a patch of another release is not restored', () async {
      await publish();
      final rel2 = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/releases',
          bearer: _bootstrapKey,
          json: {'version': '2.0.0'},
        ),
      );
      final r2 = (rel2['release'] as Map)['id'] as int;
      final other = await publish(releaseId: r2);
      final body = await jsonOf(await rollback(other.id, releaseId: r2));
      expect(body['restored'], isEmpty);
      // Release 1's patch was never touched by release 2's promote or rollback.
      expect(offered(await check()), 1);
    });

    test('tenants are isolated', () async {
      await publish();
      final p2 = await publish();
      final attacker = await otherTenant();
      final r = await send(
        'POST',
        '/api/v1/apps/${s.appId}/releases/${s.releaseId}'
            '/patches/${p2.id}/rollback',
        bearer: attacker.key,
      );
      expect(r.statusCode, HttpStatus.forbidden);
      // Their own app id paired with our release and patch ids.
      final viaOwn = await send(
        'POST',
        '/api/v1/apps/${attacker.appId}/releases/${s.releaseId}'
            '/patches/${p2.id}/rollback',
        bearer: attacker.key,
      );
      expect(viaOwn.statusCode, HttpStatus.notFound);
      final c = await check();
      expect(offered(c), 2);
      expect(c['rolled_back_patch_numbers'], isEmpty);
      // And our rollback does not reach their app's checks.
      await rollback(p2.id);
      expect(
        (await check(appId: attacker.appId))['rolled_back_patch_numbers'],
        isEmpty,
      );
    });

    test('a deleted channel keeps telling devices to revert and restores '
        'nothing', () async {
      final qa = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/channels',
          bearer: _bootstrapKey,
          json: {'channel': 'qa'},
        ),
      );
      final qaId = qa['id'] as int;
      await publish(channelId: qaId);
      final p2 = await publish(channelId: qaId);
      final del = await send(
        'DELETE',
        '/api/v1/apps/${s.appId}/channels/$qaId',
        bearer: _bootstrapKey,
      );
      expect(del.statusCode, HttpStatus.noContent);
      final body = await jsonOf(await rollback(p2.id));
      expect(body['restored'], isEmpty);
      final c = await check(channel: 'qa');
      expect(c['patch_available'], isFalse);
      expect(c['rolled_back_patch_numbers'], [2]);
    });

    test(
      'a patch an operator withdrew is not restored by a later rollback',
      () async {
        await publish();
        await publish();
        final p3 = await publish();
        // The operator pulls 3 without a rollback. 1 and 2 were superseded.
        final w = await send(
          'POST',
          '/admin/apps/${s.appId}/patches/${p3.id}/withdraw?channel=stable',
          bearer: _bootstrapKey,
        );
        expect(w.statusCode, HttpStatus.ok);
        final p4 = await publish();
        final body = await jsonOf(await rollback(p4.id));
        final numbers = [
          for (final r in body['restored'] as List) (r as Map)['number'],
        ];
        expect(numbers, [2]);
        expect(offered(await check()), 2);
      },
    );

    test('an operator-withdrawn patch stays withdrawn when the patch above it '
        'is rolled back', () async {
      await publish();
      final p2 = await publish();
      final p3 = await publish();
      // Put 2 back as the live patch, then have the operator pull it.
      await rollback(p3.id);
      expect(offered(await check()), 2);
      final w = await send(
        'POST',
        '/admin/apps/${s.appId}/patches/${p2.id}/withdraw?channel=stable',
        bearer: _bootstrapKey,
      );
      expect(w.statusCode, HttpStatus.ok);
      final p4 = await publish();
      final body = await jsonOf(await rollback(p4.id));
      // 2 was withdrawn by the operator (marker cleared), 1 was superseded.
      expect(
        [for (final r in body['restored'] as List) (r as Map)['number']],
        [1],
      );
      expect(offered(await check()), 1);
    });

    test('a candidate without a verified artifact is not restored', () async {
      final p1 = await publish();
      final p2 = await publish();
      await repo.db.query(
        "UPDATE artifacts SET status = 'failed' "
        "WHERE owner_kind = 'patch' AND owner_id = @p",
        {'p': p1.id},
      );
      final body = await jsonOf(await rollback(p2.id));
      expect(body['restored'], isEmpty);
      expect(offered(await check()), isNull);
    });

    test(
      'a device on the last rolled-back patch gets nothing and the list',
      () async {
        final p1 = await publish();
        await rollback(p1.id);
        final c = await check(current: 1);
        expect(c['patch_available'], isFalse);
        expect(c['rolled_back_patch_numbers'], [1]);
      },
    );

    test('a partial-rollout restore leaves a device outside the bucket on the '
        'base release', () async {
      await publish(rollout: 0);
      final p2 = await publish();
      await rollback(p2.id);
      final c = await check(current: 2, clientId: 'any-client');
      expect(c['patch_available'], isFalse);
      expect(c['rolled_back_patch_numbers'], [2]);
    });

    test('rolling back again restores nothing twice', () async {
      await publish();
      final p2 = await publish();
      expect(
        ((await jsonOf(await rollback(p2.id)))['restored'] as List),
        hasLength(1),
      );
      expect((await rollback(p2.id)).statusCode, HttpStatus.notModified);
      expect(offered(await check()), 1);
    });

    test('a repeated admin withdraw with rollback restores nothing', () async {
      await publish();
      final p2 = await publish();
      Future<Response> withdraw() => send(
        'POST',
        '/admin/apps/${s.appId}/patches/${p2.id}/withdraw'
            '?channel=stable&rollback=true',
        bearer: _bootstrapKey,
      );
      expect((await withdraw()).statusCode, HttpStatus.ok);
      expect((await withdraw()).statusCode, HttpStatus.conflict);
      expect(offered(await check()), 1);
    });

    test(
      'the admin withdraw with rollback marks every channel it was on',
      () async {
        final beta = await jsonOf(
          await send(
            'POST',
            '/api/v1/apps/${s.appId}/channels',
            bearer: _bootstrapKey,
            json: {'channel': 'beta'},
          ),
        );
        final betaId = beta['id'] as int;
        final p1 = await publish();
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/patches/promote',
          bearer: _bootstrapKey,
          json: {'patch_id': p1.id, 'channel_id': betaId},
        );
        await publish(channelId: betaId); // supersedes 1 on beta
        // 1 is active on stable; pull it there with the admin route.
        final r = await send(
          'POST',
          '/admin/apps/${s.appId}/patches/${p1.id}/withdraw'
              '?channel=stable&rollback=true',
          bearer: _bootstrapKey,
        );
        expect(r.statusCode, HttpStatus.ok);
        expect((await jsonOf(r))['channels'], ['stable', 'beta']);
        expect((await check())['rolled_back_patch_numbers'], [1]);
        expect((await check(channel: 'beta'))['rolled_back_patch_numbers'], [
          1,
        ]);
        final audit = await repo.db.query(
          "SELECT detail FROM audit_log WHERE action = 'patch.withdraw' "
          'ORDER BY id DESC LIMIT 1',
        );
        final detail = jsonDecode(audit.single['detail']! as String) as Map;
        expect(detail['channels'], ['stable', 'beta']);
      },
    );

    test('rollforward is still refused after a restore', () async {
      await publish();
      final p2 = await publish();
      await rollback(p2.id);
      final r = await send(
        'POST',
        '/api/v1/apps/${s.appId}/releases/${s.releaseId}'
            '/patches/${p2.id}/rollforward',
        bearer: _bootstrapKey,
      );
      expect(r.statusCode, HttpStatus.notImplemented);
      expect(offered(await check()), 1);
    });

    test('rolling back marks the patch on channels where it is only '
        'superseded', () async {
      final beta = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/channels',
          bearer: _bootstrapKey,
          json: {'channel': 'beta'},
        ),
      );
      final betaId = beta['id'] as int;
      final p1 = await publish();
      await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': p1.id, 'channel_id': betaId},
      );
      final p2 = await publish(channelId: betaId); // 2 supersedes 1 on beta
      await publish(); // 3 supersedes 1 on stable (1 is active there)
      // Roll 1 back: it is superseded on both channels.
      final r = await rollback(p1.id);
      expect(r.statusCode, HttpStatus.ok);
      expect(
        (await jsonOf(r))['channels'],
        unorderedEquals(['stable', 'beta']),
      );
      expect((await check())['rolled_back_patch_numbers'], [1]);
      expect((await check(channel: 'beta'))['rolled_back_patch_numbers'], [1]);
      // 2 is active on beta; rolling it back must not bring 1 back there.
      final body = await jsonOf(await rollback(p2.id));
      expect(body['restored'], isEmpty);
      final c = await check(channel: 'beta');
      expect(c['patch_available'], isFalse);
      expect(c['rolled_back_patch_numbers'], [1, 2]);
    });

    test('is audited: patch.withdraw for the rollback, patch.restore per '
        'restored patch', () async {
      final p1 = await publish();
      final p2 = await publish();
      await rollback(p2.id);
      final rows = await repo.db.query(
        "SELECT target, detail FROM audit_log WHERE action = 'patch.restore'",
      );
      expect(rows, hasLength(1));
      expect(rows.single['target'], '${p1.id}');
      expect(rows.single['detail'], contains('patch 1 active again'));
      expect(rows.single['detail'], contains('patch 2'));
      final wd = await repo.db.query(
        "SELECT patch_id FROM audit_log WHERE action = 'patch.withdraw'",
      );
      expect(wd.single['patch_id'], p2.id);
    });
  });

  // A channel can carry several live releases (1.0.0 and 2.0.0 both on
  // `stable`). Patch numbers and platforms are per release, so promoting a
  // patch must supersede only the same release's patches, and the check must
  // look for the device's own release's active patch.
  group('two releases on one channel', () {
    late ({String appId, int releaseId, int channelId}) s;
    late int release2;

    setUp(() async {
      s = await seedApp();
      final rel2 = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/releases',
          bearer: _bootstrapKey,
          json: {'version': '2.0.0'},
        ),
      );
      release2 = (rel2['release'] as Map)['id'] as int;
    });

    Future<int> publish(
      int releaseId, {
      List<String> platforms = const ['android'],
      int rollout = 100,
    }) async {
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': releaseId},
        ),
      );
      final id = p['id'] as int;
      for (final platform in platforms) {
        await uploadPatchArtifact(s.appId, id, platform: platform);
      }
      final r = await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': id, 'channel_id': s.channelId, 'rollout': rollout},
      );
      expect(r.statusCode, HttpStatus.noContent);
      return p['number'] as int;
    }

    Future<int?> offered(
      String version, {
      String platform = 'android',
      String? clientId,
    }) async {
      final c = await jsonOf(
        await send(
          'POST',
          '/api/v1/patches/check',
          json: {
            'app_id': s.appId,
            'release_version': version,
            'platform': platform,
            'arch': 'aarch64',
            'channel': 'stable',
            if (clientId != null) 'client_id': clientId,
          },
        ),
      );
      return (c['patch'] as Map<String, dynamic>?)?['number'] as int?;
    }

    test(
      'each release keeps its active patch across the other\'s promotes',
      () async {
        await publish(s.releaseId);
        expect(await offered('1.0.0'), 1);
        // Release 2's patches have higher numbers and a superset of platforms.
        await publish(release2, platforms: ['android', 'ios']);
        await publish(release2);
        expect(await offered('2.0.0'), 2);
        expect(await offered('1.0.0'), 1);
        // And back: another patch for release 1 leaves release 2 alone.
        await publish(s.releaseId);
        expect(await offered('1.0.0'), 2);
        expect(await offered('2.0.0'), 2);
      },
    );

    test(
      'promoting within a release still supersedes its older patch',
      () async {
        await publish(s.releaseId);
        await publish(release2);
        await publish(s.releaseId);
        expect(await offered('1.0.0'), 2);
        expect(await offered('2.0.0'), 1);
      },
    );

    test(
      'a release is not served another release\'s higher-numbered patch',
      () async {
        await publish(release2);
        await publish(release2);
        await publish(release2);
        await publish(s.releaseId);
        expect(await offered('1.0.0'), 1);
        expect(await offered('2.0.0'), 3);
      },
    );

    test('platform and rollout scoping are unchanged', () async {
      await publish(s.releaseId, platforms: ['ios']);
      await publish(s.releaseId);
      // Android-only 2 does not cover ios-only 1, so both stay active.
      expect(await offered('1.0.0'), 2);
      expect(await offered('1.0.0', platform: 'ios'), 1);
      await publish(release2, rollout: 0);
      expect(await offered('2.0.0', clientId: 'c'), isNull);
      expect(await offered('1.0.0'), 2);
    });
  });

  // -------------------------------------------------------------------------
  // Upstream 1.6.123 app rename, app transfer and channel delete, under the one
  // rule in selfhost/upstream/ADOPTION-1.6.123.md §5: admin at every scope the
  // mutation changes, and a collaborator grant never counts at org scope.
  group('app and channel management', () {
    late ({String appId, int releaseId, int channelId}) s;

    setUp(() async => s = await seedApp());

    /// A user holding [role] in org [orgId], via a real invitation.
    Future<({int id, String key})> member(
      String email,
      String role, {
      int orgId = 1,
    }) async {
      final u = await repo.upsertUser(email, email);
      final token = await repo.createInvitation(orgId, email, role);
      await repo.acceptInvitation(token, u.id, orgId, role);
      return (id: u.id, key: await repo.createApiKey(u.id));
    }

    /// A user who is only a collaborator on the seeded app.
    Future<({int id, String key})> collaborator(
      String email,
      String role,
    ) async {
      final u = await repo.upsertUser(email, email);
      await repo.addCollaborator(s.appId, u.id, role);
      return (id: u.id, key: await repo.createApiKey(u.id));
    }

    group('rename', () {
      Future<Response> rename(String name, {String bearer = _bootstrapKey}) =>
          send(
            'PATCH',
            '/api/v1/apps/${s.appId}',
            bearer: bearer,
            json: {'name': name},
          );

      Future<String> displayName() async {
        final r = await jsonOf(
          await send('GET', '/api/v1/apps', bearer: _bootstrapKey),
        );
        return ((r['apps'] as List).single as Map)['display_name'] as String;
      }

      test('an org owner can rename', () async {
        expect((await rename('Renamed')).statusCode, HttpStatus.noContent);
        expect(await displayName(), 'Renamed');
      });

      test('an admin collaborator can rename', () async {
        final c = await collaborator('admin@example.test', 'admin');
        expect(
          (await rename('Renamed', bearer: c.key)).statusCode,
          HttpStatus.noContent,
        );
      });

      test('a developer, member or collaborator, cannot', () async {
        final dev = await member('dev@example.test', 'developer');
        final collab = await collaborator('collab@example.test', 'developer');
        for (final key in [dev.key, collab.key]) {
          expect(
            (await rename('Nope', bearer: key)).statusCode,
            HttpStatus.forbidden,
          );
        }
        expect(await displayName(), 'app');
      });

      test('an empty name is rejected', () async {
        expect((await rename('  ')).statusCode, HttpStatus.badRequest);
      });
    });

    group('channel delete', () {
      late int patchId;
      late int qaId;

      setUp(() async {
        final p = await jsonOf(
          await send(
            'POST',
            '/api/v1/apps/${s.appId}/patches',
            bearer: _bootstrapKey,
            json: {'release_id': s.releaseId},
          ),
        );
        patchId = p['id'] as int;
        await uploadPatchArtifact(s.appId, patchId);
        qaId =
            (await jsonOf(
                  await send(
                    'POST',
                    '/api/v1/apps/${s.appId}/channels',
                    bearer: _bootstrapKey,
                    json: {'channel': 'qa'},
                  ),
                ))['id']
                as int;
      });

      Future<Response> promote(int channelId) => send(
        'POST',
        '/api/v1/apps/${s.appId}/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': patchId, 'channel_id': channelId},
      );

      Future<Response> delete(int channelId, {String bearer = _bootstrapKey}) =>
          send(
            'DELETE',
            '/api/v1/apps/${s.appId}/channels/$channelId',
            bearer: bearer,
          );

      Future<Map<String, dynamic>> check(String channel) async => jsonOf(
        await send(
          'POST',
          '/api/v1/patches/check',
          json: {
            'app_id': s.appId,
            'release_version': '1.0.0',
            'platform': 'android',
            'arch': 'aarch64',
            'channel': channel,
          },
        ),
      );

      Future<List<Object?>> channelNames() async {
        final r = await send(
          'GET',
          '/api/v1/apps/${s.appId}/channels',
          bearer: _bootstrapKey,
        );
        return [
          for (final c in jsonDecode(await r.readAsString()) as List)
            (c as Map)['name'],
        ];
      }

      test('stops serving and disappears from listings', () async {
        await promote(qaId);
        expect((await check('qa'))['patch_available'], isTrue);

        expect((await delete(qaId)).statusCode, HttpStatus.noContent);
        expect(await channelNames(), isNot(contains('qa')));
        expect((await check('qa'))['patch_available'], isFalse);
        expect((await promote(qaId)).statusCode, HttpStatus.notFound);
        expect((await delete(qaId)).statusCode, HttpStatus.notFound);

        final listed = await jsonOf(
          await send(
            'GET',
            '/api/v1/apps/${s.appId}/releases/${s.releaseId}/patches',
            bearer: _bootstrapKey,
          ),
        );
        expect(((listed['patches'] as List).single as Map)['channel'], isNull);
      });

      test('a later rollback still reaches its devices', () async {
        await promote(qaId);
        await delete(qaId);
        final rb = await send(
          'POST',
          '/api/v1/apps/${s.appId}/releases/${s.releaseId}'
              '/patches/$patchId/rollback',
          bearer: _bootstrapKey,
        );
        expect(rb.statusCode, HttpStatus.ok);
        expect((await jsonOf(rb))['channels'], ['qa']);
        final c = await check('qa');
        expect(c['patch_available'], isFalse);
        expect(c['rolled_back_patch_numbers'], [1]);
      });

      test('recreating the name restores it, serving nothing', () async {
        await promote(qaId);
        await delete(qaId);
        final again = await jsonOf(
          await send(
            'POST',
            '/api/v1/apps/${s.appId}/channels',
            bearer: _bootstrapKey,
            json: {'channel': 'qa'},
          ),
        );
        expect(again['id'], qaId);
        expect(await channelNames(), contains('qa'));
        expect((await check('qa'))['patch_available'], isFalse);
        expect((await promote(qaId)).statusCode, HttpStatus.noContent);
        expect((await check('qa'))['patch_available'], isTrue);
      });

      test('built-in tracks are permanent', () async {
        expect((await delete(s.channelId)).statusCode, HttpStatus.conflict);
        expect(await channelNames(), contains('stable'));
      });

      test('a developer cannot delete; an admin collaborator can', () async {
        final dev = await collaborator('dev@example.test', 'developer');
        expect(
          (await delete(qaId, bearer: dev.key)).statusCode,
          HttpStatus.forbidden,
        );
        final admin = await collaborator('admin@example.test', 'admin');
        expect(
          (await delete(qaId, bearer: admin.key)).statusCode,
          HttpStatus.noContent,
        );
      });

      test('another app\'s channel id is not found', () async {
        final other = await seedApp('other');
        final r = await send(
          'DELETE',
          '/api/v1/apps/${other.appId}/channels/$qaId',
          bearer: _bootstrapKey,
        );
        expect(r.statusCode, HttpStatus.notFound);
        expect(await channelNames(), contains('qa'));
      });
    });

    group('transfer', () {
      /// A second org, owned by someone else, with the bootstrap user added
      /// at [bootstrapRole] (or not at all).
      Future<int> otherOrg({String? bootstrapRole = 'admin'}) async {
        final owner = await repo.upsertUser('carol@corp.test', 'Carol');
        final orgId = (await repo.memberships(owner.id)).first.orgId;
        if (bootstrapRole != null) {
          final token = await repo.createInvitation(
            orgId,
            'owner@self-host.local',
            bootstrapRole,
          );
          await repo.acceptInvitation(token, 1, orgId, bootstrapRole);
        }
        return orgId;
      }

      Future<Response> transfer(int orgId, {String bearer = _bootstrapKey}) =>
          send(
            'POST',
            '/api/v1/organizations/$orgId/apps',
            bearer: bearer,
            json: {'app_id': s.appId},
          );

      test('an admin of both orgs can move the app', () async {
        final orgId = await otherOrg();
        expect((await transfer(orgId)).statusCode, HttpStatus.noContent);
        expect(await repo.appOrgId(s.appId), orgId);
      });

      test('admin of the source alone is not enough', () async {
        for (final role in [null, 'developer']) {
          final orgId = await otherOrg(bootstrapRole: role);
          expect(
            (await transfer(orgId)).statusCode,
            HttpStatus.forbidden,
            reason: '$role',
          );
          expect(await repo.appOrgId(s.appId), 1);
        }
      });

      test('an owner collaborator cannot move it into their own org', () async {
        // The escalation the rule exists to stop: an app-scoped grant turned
        // into ownership.
        final c = await collaborator('mallory@evil.test', 'owner');
        final theirOrg = (await repo.memberships(c.id)).first.orgId;
        expect(
          (await transfer(theirOrg, bearer: c.key)).statusCode,
          HttpStatus.forbidden,
        );
        expect(await repo.appOrgId(s.appId), 1);
      });

      test('no access to the app is forbidden', () async {
        final t = await otherTenant();
        final orgId = (await repo.memberships(t.userId)).first.orgId;
        expect(
          (await transfer(orgId, bearer: t.key)).statusCode,
          HttpStatus.forbidden,
        );
      });

      test('refused while collaborators fall outside the allowlist', () async {
        final orgId = await otherOrg();
        await repo.setOrgAllowedDomains(orgId, ['corp.test']);
        final c = await collaborator('dev@example.test', 'developer');

        final r = await transfer(orgId);
        expect(r.statusCode, HttpStatus.conflict);
        expect((await jsonOf(r))['message'], contains('dev@example.test'));
        expect(await repo.appOrgId(s.appId), 1);

        await repo.removeCollaborator(s.appId, c.id);
        expect((await transfer(orgId)).statusCode, HttpStatus.noContent);
      });

      test('into its own org is a no-op', () async {
        expect((await transfer(1)).statusCode, HttpStatus.noContent);
        expect(await repo.appOrgId(s.appId), 1);
      });
    });
  });

  // -------------------------------------------------------------------------
  // Release/patch notes. The wire contract always carried `notes` on both DTOs
  // and the CLI's `releases info` / `patches info` already print it, but the
  // server hardcoded null on every response, so the field could never be used.
  group('release and patch notes', () {
    late String appId;
    late int releaseId;

    setUp(() async {
      final s = await seedApp();
      appId = s.appId;
      releaseId = s.releaseId;
    });

    Future<Map<String, dynamic>> release() async {
      final r = await jsonOf(
        await send(
          'GET',
          '/api/v1/apps/$appId/releases',
          bearer: _bootstrapKey,
        ),
      );
      return (r['releases'] as List).single as Map<String, dynamic>;
    }

    Future<int> createPatch({String? notes}) async {
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/$appId/patches',
          bearer: _bootstrapKey,
          json: {'release_id': releaseId, if (notes != null) 'notes': notes},
        ),
      );
      return p['id'] as int;
    }

    Future<Map<String, dynamic>> patchFromList(int patchId) async {
      final r = await jsonOf(
        await send(
          'GET',
          '/api/v1/apps/$appId/releases/$releaseId/patches',
          bearer: _bootstrapKey,
        ),
      );
      return (r['patches'] as List).cast<Map<String, dynamic>>().firstWhere(
        (p) => p['id'] == patchId,
      );
    }

    test('a release round-trips notes set at creation', () async {
      final r = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/$appId/releases',
          bearer: _bootstrapKey,
          json: {'version': '2.0.0', 'notes': 'first ship'},
        ),
      );
      expect((r['release'] as Map)['notes'], 'first ship');
    });

    test('PATCH sets release notes and they survive a re-read', () async {
      final r = await send(
        'PATCH',
        '/api/v1/apps/$appId/releases/$releaseId',
        bearer: _bootstrapKey,
        json: {'notes': 'hotfix for the login crash'},
      );
      expect(r.statusCode, HttpStatus.noContent);
      expect((await release())['notes'], 'hotfix for the login crash');
    });

    // The CLI sends `UpdateReleaseRequest` with every key populated during a
    // normal release, so a null `notes` must not wipe notes already set --
    // upstream documents null as "the notes will not be updated".
    test('a null notes field leaves existing notes alone', () async {
      await send(
        'PATCH',
        '/api/v1/apps/$appId/releases/$releaseId',
        bearer: _bootstrapKey,
        json: {'notes': 'keep me'},
      );
      await send(
        'PATCH',
        '/api/v1/apps/$appId/releases/$releaseId',
        bearer: _bootstrapKey,
        json: {'status': 'active', 'platform': 'android', 'notes': null},
      );
      expect((await release())['notes'], 'keep me');
    });

    // Notes are validated up front but written last, so a request rejected by
    // the status gate doesn't leave the notes changed by a call that failed.
    test('a request that 409s on status does not apply its notes', () async {
      final r = await send(
        'PATCH',
        '/api/v1/apps/$appId/releases/$releaseId',
        bearer: _bootstrapKey,
        // `active` with no verified artifacts is the fail-closed 409 path.
        json: {'status': 'active', 'platform': 'android', 'notes': 'nope'},
      );
      expect(r.statusCode, HttpStatus.conflict);
      expect((await release())['notes'], isNull);
    });

    test('an empty notes string clears notes', () async {
      await send(
        'PATCH',
        '/api/v1/apps/$appId/releases/$releaseId',
        bearer: _bootstrapKey,
        json: {'notes': 'temporary'},
      );
      await send(
        'PATCH',
        '/api/v1/apps/$appId/releases/$releaseId',
        bearer: _bootstrapKey,
        json: {'notes': ''},
      );
      expect((await release())['notes'], isNull);
    });

    test('a patch round-trips notes set at creation', () async {
      final patchId = await createPatch(notes: 'raising the timeout');
      expect((await patchFromList(patchId))['notes'], 'raising the timeout');
    });

    test('PATCH sets patch notes and echoes what was stored', () async {
      final patchId = await createPatch();
      expect((await patchFromList(patchId))['notes'], isNull);
      final r = await jsonOf(
        await send(
          'PATCH',
          '/api/v1/apps/$appId/patches/$patchId',
          bearer: _bootstrapKey,
          json: {'notes': 'annotated after the fact'},
        ),
      );
      expect(r['notes'], 'annotated after the fact');
      expect(
        (await patchFromList(patchId))['notes'],
        'annotated after the fact',
      );
    });

    test('notes over the ceiling are a 400, not a silent truncation', () async {
      final r = await send(
        'PATCH',
        '/api/v1/apps/$appId/releases/$releaseId',
        bearer: _bootstrapKey,
        json: {'notes': 'x' * 4097},
      );
      expect(r.statusCode, HttpStatus.badRequest);
      expect((await release())['notes'], isNull);
    });

    test('a wrong-typed notes field is a 400, not a 500', () async {
      final r = await send(
        'PATCH',
        '/api/v1/apps/$appId/releases/$releaseId',
        bearer: _bootstrapKey,
        json: {'notes': 42},
      );
      expect(r.statusCode, HttpStatus.badRequest);
    });

    test('another tenant cannot write notes on this app\'s patch', () async {
      final patchId = await createPatch();
      final other = await otherTenant();
      final r = await send(
        'PATCH',
        '/api/v1/apps/$appId/patches/$patchId',
        bearer: other.key,
        json: {'notes': 'pwned'},
      );
      expect(r.statusCode, isIn([HttpStatus.forbidden, HttpStatus.notFound]));
      expect((await patchFromList(patchId))['notes'], isNull);
    });
  });

  // The request log used to record `req.url.path` only. That is right for every
  // path but one: the air-gap fixture's beacon carries its whole payload in the
  // query string, so a path-only line silently discarded the value the device
  // gates read back — `GET /selfhost-beacon/state -> 403` and nothing else.
  group('loggedRequestPath', () {
    test(
      'logs the query for the fixture beacon, whose query IS the payload',
      () {
        expect(
          loggedRequestPath(
            Uri.parse('selfhost-beacon/state?release=V1&param=PARAM-ARG'),
          ),
          'selfhost-beacon/state?release=V1&param=PARAM-ARG',
        );
      },
    );

    test(
      'does NOT log the query for any other path — it carries user data',
      () {
        // The admin surface really does take an email in the query. Logging
        // queries wholesale would put personal data in a shipped log.
        expect(
          loggedRequestPath(Uri.parse('api/v1/admin/users?email=a@b.example')),
          'api/v1/admin/users',
        );
        // Nor does a lookalike prefix opt in.
        expect(
          loggedRequestPath(Uri.parse('selfhost-beacons-evil?param=x')),
          'selfhost-beacons-evil',
        );
      },
    );

    test('leaves probe paths byte-identical, so they stay unlogged', () {
      // Observability._isProbe compares the WHOLE string; a suffix here would
      // start flooding the log at the scrape interval.
      for (final p in ['healthz', 'readyz', 'metrics']) {
        expect(loggedRequestPath(Uri.parse(p)), p);
      }
    });

    test('cannot be used to forge a second log line', () {
      // Uri percent-encodes the newline before we ever see it, so the encoding
      // is what actually holds here; the sanitizer inside loggedRequestPath is
      // a second line of defense for a query string that did not come from Uri.
      // Either way the property a log parser depends on is the same: one
      // request cannot produce two lines.
      final forged = loggedRequestPath(
        Uri.parse(
          'selfhost-beacon/state',
        ).replace(query: 'param=a\nGET /admin -> 200 (0ms)'),
      );
      expect(forged, isNot(contains('\n')));
      expect(forged, contains('%0A'));
    });

    test('clips an unbounded query', () {
      final long = loggedRequestPath(
        Uri.parse('selfhost-beacon/state?param=${'x' * 900}'),
      );
      expect(long.length, lessThan(600));
      expect(long, endsWith('(clipped)'));
    });
  });
}

/// Stands in for the socket peer that `shelf_io` would supply.
class _FakeConnectionInfo implements HttpConnectionInfo {
  const _FakeConnectionInfo(this._ip);

  final String _ip;

  @override
  InternetAddress get remoteAddress => InternetAddress(_ip);

  @override
  int get remotePort => 54321;

  @override
  int get localPort => 8080;
}

/// Rebuilds [base] with an empty bootstrap API key.
Config _withEmptyApiKey(Config base) => _copy(base, bootstrapApiKey: '');

/// Rebuilds [base] in production mode (keeping the dev-friendly backends).
Config _asProduction(Config base) => _copy(base, production: true);

/// Rebuilds [base] with a small artifact-upload ceiling.
Config _withMaxUpload(Config base, int bytes) =>
    _copy(base, maxUploadBytes: bytes);

/// Rebuilds [base] with the operator identity `setup.sh` would have written.
Config _withLoginEmail(Config base, String email) =>
    _copy(base, loginEmail: email);

Config _copy(
  Config b, {
  String? bootstrapApiKey,
  bool? production,
  String? loginEmail,
  int? maxUploadBytes,
}) => Config(
  port: b.port,
  publicBaseUrl: b.publicBaseUrl,
  bootstrapApiKey: bootstrapApiKey ?? b.bootstrapApiKey,
  dbHost: b.dbHost,
  dbPort: b.dbPort,
  dbName: b.dbName,
  dbUser: b.dbUser,
  dbPassword: b.dbPassword,
  s3Endpoint: b.s3Endpoint,
  s3Port: b.s3Port,
  s3AccessKey: b.s3AccessKey,
  s3SecretKey: b.s3SecretKey,
  s3Bucket: b.s3Bucket,
  s3UseSsl: b.s3UseSsl,
  urlSigningSecret: b.urlSigningSecret,
  jwtIssuer: b.jwtIssuer,
  downloadUrlTtl: b.downloadUrlTtl,
  rateLimitPerMinute: b.rateLimitPerMinute,
  rateLimitIpPerMinute: b.rateLimitIpPerMinute,
  trustedProxies: b.trustedProxies,
  rateLimitShared: b.rateLimitShared,
  uploadMethod: b.uploadMethod,
  idpClientId: b.idpClientId,
  idpClientSecret: b.idpClientSecret,
  idpAuthorizeUrl: b.idpAuthorizeUrl,
  idpTokenUrl: b.idpTokenUrl,
  idpScopes: b.idpScopes,
  production: production ?? b.production,
  dbBackend: b.dbBackend,
  storageBackend: b.storageBackend,
  dataDir: b.dataDir,
  maxUploadBytes: maxUploadBytes ?? b.maxUploadBytes,
  logFormat: b.logFormat,
  dbSslMode: b.dbSslMode,
  loginEmail: loginEmail ?? b.loginEmail,
);

/// Mirrors `Api._signedUrl` so tests can hit /download directly.
String _signedUrlFor(Config config, String token) {
  final signer = UrlSigner(config.urlSigningSecret);
  final s = signer.sign(token, DateTime.now().add(config.downloadUrlTtl));
  return '/download/$token?exp=${s.exp}&sig=${s.sig}';
}

/// A repository whose event inserts always fail, so both the main insert and
/// the verbatim fallback of `POST /patches/events` throw.
class _FailingEvents extends Repository {
  _FailingEvents(super.db);

  @override
  Future<bool> insertEvent({
    required String raw,
    String? dedupeKey,
    String? appId,
    String? clientId,
    String? type,
    int? patchNumber,
    String? platform,
    String? arch,
    String? releaseVersion,
    int? ts,
    String? outcome,
    int? ambiguousAttemptCount,
    int? bootFailureThreshold,
    int? bootStartedAt,
    String? updaterRevision,
  }) => throw StateError('injected event insert failure');
}

/// A filesystem store whose next `put` writes half the bytes and then throws,
/// like a disk filling up or a connection dropping mid-write.
class _FlakyStore extends FilesystemArtifactStore {
  _FlakyStore(super.root, super.staging);

  bool failNextPut = false;
  bool alwaysFail = false;

  /// Runs after a successful `put`, before the caller verifies.
  Future<void> Function()? afterPut;

  /// Runs at the start of `verify`, after the caller's heartbeat.
  Future<void> Function()? beforeVerify;

  @override
  Future<String?> verify(
    String key,
    String expectedHash,
    int expectedSize, {
    required bool checkHash,
  }) async {
    await beforeVerify?.call();
    return super.verify(key, expectedHash, expectedSize, checkHash: checkHash);
  }

  /// Runs inside the failing `put`, before it throws: what a concurrent
  /// request sharing the key might have done in the meantime.
  Future<void> Function()? beforeFailure;

  @override
  Future<void> put(String key, List<int> bytes) async {
    if (failNextPut || alwaysFail) {
      failNextPut = false;
      await super.put(key, bytes.sublist(0, bytes.length ~/ 2));
      await beforeFailure?.call();
      throw const FileSystemException('injected: no space left on device');
    }
    await super.put(key, bytes);
    await afterPut?.call();
  }
}

/// A repository where the first read of a `pending` artifact is followed by
/// another request claiming it, so the caller's `status == pending` check
/// passes on a stale read and only its compare-and-set can notice.
class _ClaimOnRecheckRepo extends Repository {
  _ClaimOnRecheckRepo(super.db);

  int _reads = 0;

  /// The second read of the artifact (the re-check after a chunk's body has
  /// arrived) finds a commit already claimed.
  @override
  Future<ArtifactRow?> artifactByToken(String token) async {
    final art = await super.artifactByToken(token);
    if (++_reads == 2 && art != null) await claimArtifact(art.id);
    return art == null ? null : await super.artifactByToken(token);
  }
}

class _RacingRepo extends Repository {
  _RacingRepo(super.db);

  bool _raced = false;

  @override
  Future<ArtifactRow?> artifactByToken(String token) async {
    final art = await super.artifactByToken(token);
    if (!_raced && art != null && art.status == ArtifactStatus.pending) {
      _raced = true;
      await setArtifactStatus(art.id, ArtifactStatus.uploading);
    }
    return art;
  }
}
