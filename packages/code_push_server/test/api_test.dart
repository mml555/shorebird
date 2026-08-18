// Request-level tests for the HTTP surface in `lib/src/api.dart`.
//
// Every group here corresponds to a defect found in the end-to-end security
// audit. The comments say what the behavior WAS, so a regression is obvious.
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
