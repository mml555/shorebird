// cspell:words spki rsassa aqab
// Upstream 1.6.138 compatibility: `platforms` on releases, `GET /apps/{app}`,
// and managed patch signing (`GET /apps/{app}/signing-key`, `signing` on
// release artifacts, server-signed patch hashes).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:code_push_server/src/api.dart';
import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/domain.dart';
import 'package:code_push_server/src/patch_signing.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:jose/jose.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support.dart';

const _key = 'sb_api_selfhost_dev';
const _bd = 'BOUNDARY';

/// Reads one DER TLV at [offset]; returns (tag, content start, content end).
(int, int, int) _tlv(Uint8List b, int offset) {
  final tag = b[offset];
  var len = b[offset + 1];
  var start = offset + 2;
  if (len & 0x80 != 0) {
    final n = len & 0x7f;
    len = 0;
    for (var i = 0; i < n; i++) {
      len = (len << 8) | b[start + i];
    }
    start += n;
  }
  return (tag, start, start + len);
}

/// Parses an SPKI PEM the way an independent verifier would, returning a JWK.
Map<String, dynamic> _jwkFromPem(String pem) {
  expect(pem, startsWith('-----BEGIN PUBLIC KEY-----\n'));
  expect(pem, endsWith('-----END PUBLIC KEY-----\n'));
  final body = pem
      .replaceAll('-----BEGIN PUBLIC KEY-----', '')
      .replaceAll('-----END PUBLIC KEY-----', '')
      .replaceAll('\n', '');
  final der = Uint8List.fromList(base64.decode(body));
  final (_, spkiStart, _) = _tlv(der, 0);
  final (_, _, algEnd) = _tlv(der, spkiStart); // AlgorithmIdentifier
  final (bitTag, bitStart, _) = _tlv(der, algEnd);
  expect(bitTag, 0x03);
  final (_, seqStart, _) = _tlv(der, bitStart + 1); // skip unused-bits byte
  final (nTag, nStart, nEnd) = _tlv(der, seqStart);
  expect(nTag, 0x02);
  final (_, eStart, eEnd) = _tlv(der, nEnd);
  String b64u(List<int> v) => base64Url.encode(v).replaceAll('=', '');
  var n = der.sublist(nStart, nEnd);
  if (n.first == 0) n = n.sublist(1);
  return {'kty': 'RSA', 'n': b64u(n), 'e': b64u(der.sublist(eStart, eEnd))};
}

void main() {
  late Directory tmp;
  late Repository repo;
  late Config config;
  late Api api;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('cps_signing');
    config = sqliteConfig(tmp.path);
    repo = await Repository.open(config);
    api = Api(repo, await ArtifactStore.open(config), config);
  });

  tearDown(() async {
    await repo.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<Response> send(
    String method,
    String path, {
    String? bearer = _key,
    Object? json,
    String? body,
  }) => Future.sync(
    () => api.handler(
      Request(
        method,
        Uri.parse('http://localhost:8080$path'),
        headers: {
          if (bearer != null) HttpHeaders.authorizationHeader: 'Bearer $bearer',
          if (body != null)
            'content-type': 'multipart/form-data; boundary=$_bd',
        },
        body: body ?? (json == null ? null : jsonEncode(json)),
      ),
    ),
  );

  Future<Map<String, dynamic>> jsonOf(Response r) async =>
      jsonDecode(await r.readAsString()) as Map<String, dynamic>;

  String multipart(Map<String, String> fields) =>
      '${fields.entries.map((e) => '--$_bd\r\ncontent-disposition: form-data; name="${e.key}"\r\n\r\n${e.value}\r\n').join()}--$_bd--\r\n';

  Future<String> newApp([String bearer = _key, int? orgId]) async =>
      (await jsonOf(
            await send(
              'POST',
              '/api/v1/apps',
              bearer: bearer,
              json: {'display_name': 'app', 'organization_id': ?orgId},
            ),
          ))['id']
          as String;

  Future<int> newRelease(String appId, [String version = '1.0.0']) async =>
      ((await jsonOf(
                await send(
                  'POST',
                  '/api/v1/apps/$appId/releases',
                  json: {'version': version},
                ),
              ))['release']
              as Map)['id']
          as int;

  Future<Response> registerReleaseArtifact(
    String appId,
    int releaseId, {
    String platform = 'android',
    String arch = 'aab',
    Object? signing,
  }) => send(
    'POST',
    '/api/v1/apps/$appId/releases/$releaseId/artifacts',
    body: multipart({
      'arch': arch,
      'platform': platform,
      'hash': 'abc',
      'size': '3',
      'can_sideload': 'true',
      'filename': 'app.aab',
      if (signing != null) 'signing': jsonEncode(signing),
    }),
  );

  Future<Map<String, dynamic>> signingKey(String appId) async {
    final r = await send('GET', '/api/v1/apps/$appId/signing-key');
    expect(r.statusCode, HttpStatus.ok);
    return (await jsonOf(r))['signing_key'] as Map<String, dynamic>;
  }

  Future<Response> registerPatchArtifact(
    String appId,
    int patchId, {
    String hash = 'deadbeef',
    String? hashSignature,
    String platform = 'android',
    String arch = 'aarch64',
  }) => send(
    'POST',
    '/api/v1/apps/$appId/patches/$patchId/artifacts',
    body: multipart({
      'arch': arch,
      'platform': platform,
      'hash': hash,
      'size': '3',
      'hash_signature': ?hashSignature,
    }),
  );

  Future<int> newPatch(String appId, int releaseId) async =>
      (await jsonOf(
            await send(
              'POST',
              '/api/v1/apps/$appId/patches',
              json: {'release_id': releaseId},
            ),
          ))['id']
          as int;

  group('release JSON', () {
    test('carries `platforms` and keeps `platform_statuses`', () async {
      final appId = await newApp();
      final id = await newRelease(appId);
      // No platform yet: upstream still requires the key, as a map.
      var rel =
          (await jsonOf(
                await send('GET', '/api/v1/apps/$appId/releases'),
              ))['releases'].single
              as Map<String, dynamic>;
      expect(rel['platforms'], <String, dynamic>{});

      await repo.setReleasePlatformStatus(id, 'android', 'active');
      await repo.setReleasePlatformStatus(id, 'ios', 'draft');
      await registerReleaseArtifact(appId, id, signing: {'mode': 'customer'});
      rel =
          (await jsonOf(
                await send('GET', '/api/v1/apps/$appId/releases'),
              ))['releases'].single
              as Map<String, dynamic>;
      expect(rel['platforms'], {
        'android': {'status': 'active', 'signing_mode': 'customer'},
        // No signing reported for this platform: the key is absent, as
        // ReleasePlatformDetails documents.
        'ios': {'status': 'draft'},
      });
      expect(rel['platform_statuses'], {'android': 'active', 'ios': 'draft'});
    });

    test('create response carries `platforms` too', () async {
      final appId = await newApp();
      final r = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/$appId/releases',
          json: {'version': '2.0.0'},
        ),
      );
      expect((r['release'] as Map)['platforms'], <String, dynamic>{});
    });

    test(
      'a legacy release (no signing reported) has no signing_mode',
      () async {
        final appId = await newApp();
        final id = await newRelease(appId);
        await registerReleaseArtifact(appId, id);
        await repo.setReleasePlatformStatus(id, 'android', 'active');
        final rel =
            (await jsonOf(
                  await send('GET', '/api/v1/apps/$appId/releases'),
                ))['releases'].single
                as Map<String, dynamic>;
        expect(rel['platforms'], {
          'android': {'status': 'active'},
        });
      },
    );
  });

  group('GET /apps/{app}', () {
    test('returns one AppMetadata', () async {
      final appId = await newApp();
      await newRelease(appId, '1.2.3');
      final r = await send('GET', '/api/v1/apps/$appId');
      expect(r.statusCode, HttpStatus.ok);
      final app = await jsonOf(r);
      expect(app['app_id'], appId);
      expect(app['organization_id'], 1);
      expect(app['display_name'], 'app');
      expect(app['latest_release_version'], '1.2.3');
      expect(DateTime.parse(app['created_at'] as String), isA<DateTime>());
      expect(DateTime.parse(app['updated_at'] as String), isA<DateTime>());
      // No enterprise policy here, so the field is absent (null upstream).
      expect(app.containsKey('patch_signing_required'), isFalse);
    });

    test('list entries carry organization_id', () async {
      await newApp();
      final apps = (await jsonOf(await send('GET', '/api/v1/apps')))['apps'];
      expect((apps as List).single['organization_id'], 1);
    });

    test(
      '404 (never 403) for another tenant\'s app and a missing app',
      () async {
        final victim = await newApp();
        final user = await repo.upsertUser('mallory@evil.test', 'M');
        final other = await repo.createApiKey(user.id);
        final foreign = await send(
          'GET',
          '/api/v1/apps/$victim',
          bearer: other,
        );
        final missing = await send(
          'GET',
          '/api/v1/apps/does-not-exist',
          bearer: other,
        );
        expect(foreign.statusCode, HttpStatus.notFound);
        expect(missing.statusCode, HttpStatus.notFound);
        // Indistinguishable, so an app id cannot be probed.
        expect(await jsonOf(foreign), await jsonOf(missing));
      },
    );

    test('requires authentication', () async {
      final appId = await newApp();
      final r = await send('GET', '/api/v1/apps/$appId', bearer: null);
      // The server's _auth middleware answers 403 to an unauthenticated call.
      expect(
        r.statusCode,
        isIn([HttpStatus.unauthorized, HttpStatus.forbidden]),
      );
    });
  });

  group('GET /apps/{app}/signing-key', () {
    test('creates a 2048-bit key on first fetch and then reuses it', () async {
      final appId = await newApp();
      final first = await signingKey(appId);
      expect(first['id'], isA<int>());
      final jwk = _jwkFromPem(first['public_key_pem'] as String);
      expect(
        base64Url.decode(base64Url.normalize(jwk['n'] as String)).length,
        256,
      );
      expect(jwk['e'], 'AQAB');
      expect(await signingKey(appId), first);
      // A second app of the same org shares the org's key.
      expect(await signingKey(await newApp()), first);
    });

    test(
      'exposes only the public key, and stores the private one encrypted',
      () async {
        final appId = await newApp();
        final r = await send('GET', '/api/v1/apps/$appId/signing-key');
        final raw = await r.readAsString();
        expect(jsonDecode(raw)['signing_key'].keys, ['id', 'public_key_pem']);
        expect(raw, isNot(contains('PRIVATE')));
        final rows = await repo.db.query('SELECT * FROM signing_keys');
        final enc = rows.single['private_key_enc'] as String;
        // A compact JWE: five dot-separated parts, no JWK members in the clear.
        expect(enc.split('.'), hasLength(5));
        expect(enc, isNot(contains('"d"')));
        expect(enc, isNot(contains('PRIVATE')));
      },
    );

    test('is per organization', () async {
      final a = await newApp();
      final user = await repo.upsertUser('bob@other.test', 'Bob');
      final bobKey = await repo.createApiKey(user.id);
      final bobOrg = (await repo.memberships(user.id)).first.orgId;
      final b = await newApp(bobKey, bobOrg);
      expect(
        (await signingKey(a))['id'],
        isNot(
          (await jsonOf(
            await send('GET', '/api/v1/apps/$b/signing-key', bearer: bobKey),
          ))['signing_key']['id'],
        ),
      );
    });

    test('404 for an app the caller cannot see', () async {
      final victim = await newApp();
      final user = await repo.upsertUser('mallory@evil.test', 'M');
      final other = await repo.createApiKey(user.id);
      final r = await send(
        'GET',
        '/api/v1/apps/$victim/signing-key',
        bearer: other,
      );
      expect(r.statusCode, HttpStatus.notFound);
      expect(await repo.db.query('SELECT 1 FROM signing_keys'), isEmpty);
    });
  });

  group('release artifact signing', () {
    test('managed: stored and returned with the public key', () async {
      final appId = await newApp();
      final key = await signingKey(appId);
      final id = await newRelease(appId);
      final r = await registerReleaseArtifact(
        appId,
        id,
        signing: {'mode': 'managed', 'key_id': key['id']},
      );
      expect(r.statusCode, HttpStatus.ok);
      final arts =
          (await jsonOf(
                await send('GET', '/api/v1/apps/$appId/releases/$id/artifacts'),
              ))['artifacts']
              as List;
      expect(arts.single['signing'], {
        'mode': 'managed',
        'key_id': key['id'],
        'public_key_pem': key['public_key_pem'],
      });
    });

    test(
      'customer and unsigned return just the mode; legacy returns none',
      () async {
        final appId = await newApp();
        final id = await newRelease(appId);
        await registerReleaseArtifact(appId, id, signing: {'mode': 'customer'});
        await registerReleaseArtifact(
          appId,
          id,
          arch: 'aarch64',
          signing: {'mode': 'unsigned'},
        );
        await registerReleaseArtifact(appId, id, arch: 'arm');
        final arts =
            (await jsonOf(
                  await send(
                    'GET',
                    '/api/v1/apps/$appId/releases/$id/artifacts',
                  ),
                ))['artifacts']
                as List;
        expect(arts[0]['signing'], {'mode': 'customer'});
        expect(arts[1]['signing'], {'mode': 'unsigned'});
        expect((arts[2] as Map).containsKey('signing'), isFalse);
      },
    );

    test(
      'rejects malformed signing, and keys that are not the org\'s',
      () async {
        final appId = await newApp();
        final id = await newRelease(appId);
        for (final bad in <Object>[
          'nope',
          {'mode': 'sideways'},
          {'mode': 'managed'},
          {'mode': 'managed', 'key_id': 999},
        ]) {
          final r = await registerReleaseArtifact(appId, id, signing: bad);
          expect(r.statusCode, HttpStatus.badRequest, reason: '$bad');
        }
        // Another org's key id cannot be named.
        final user = await repo.upsertUser('bob@other.test', 'Bob');
        final bobKey = await repo.createApiKey(user.id);
        final bobOrg = (await repo.memberships(user.id)).first.orgId;
        final bobApp = await newApp(bobKey, bobOrg);
        final theirs =
            (await jsonOf(
                  await send(
                    'GET',
                    '/api/v1/apps/$bobApp/signing-key',
                    bearer: bobKey,
                  ),
                ))['signing_key']['id']
                as int;
        final r = await registerReleaseArtifact(
          appId,
          id,
          signing: {'mode': 'managed', 'key_id': theirs},
        );
        expect(r.statusCode, HttpStatus.badRequest);
      },
    );
  });

  group('patch signing', () {
    test('managed: the server signs the hex hash, and the updater would '
        'verify it', () async {
      final appId = await newApp();
      final key = await signingKey(appId);
      final id = await newRelease(appId);
      await registerReleaseArtifact(
        appId,
        id,
        signing: {'mode': 'managed', 'key_id': key['id']},
      );
      final patchId = await newPatch(appId, id);
      const hash =
          '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
      final r = await registerPatchArtifact(appId, patchId, hash: hash);
      expect(r.statusCode, HttpStatus.ok);

      final stored = (await repo.patchArtifacts(patchId)).single.hashSignature;
      expect(stored, isNotNull);
      // RSASSA-PKCS1-v1_5 / SHA-256 over the UTF-8 bytes of the hex string,
      // checked with a verifier that shares no code with the signer.
      final pub = JsonWebKey.fromJson(
        _jwkFromPem(key['public_key_pem'] as String),
      );
      expect(
        pub.verify(
          utf8.encode(hash),
          base64.decode(stored!),
          algorithm: 'RS256',
        ),
        isTrue,
      );
      // ...and over nothing else.
      expect(
        pub.verify(
          utf8.encode('${hash}0'),
          base64.decode(stored),
          algorithm: 'RS256',
        ),
        isFalse,
      );
    });

    test('managed: a client-supplied hash_signature is refused', () async {
      final appId = await newApp();
      final key = await signingKey(appId);
      final id = await newRelease(appId);
      await registerReleaseArtifact(
        appId,
        id,
        signing: {'mode': 'managed', 'key_id': key['id']},
      );
      final patchId = await newPatch(appId, id);
      final r = await registerPatchArtifact(
        appId,
        patchId,
        hashSignature: 'c2ln',
      );
      expect(r.statusCode, HttpStatus.badRequest);
      expect(await repo.patchArtifacts(patchId), isEmpty);
      // The refusal did not strand the patch: a correct retry works.
      expect((await registerPatchArtifact(appId, patchId)).statusCode, 200);
    });

    test('managed signing is per platform of the release', () async {
      final appId = await newApp();
      final key = await signingKey(appId);
      final id = await newRelease(appId);
      await registerReleaseArtifact(
        appId,
        id,
        signing: {'mode': 'managed', 'key_id': key['id']},
      );
      final patchId = await newPatch(appId, id);
      // The release has no iOS build reporting signing, so an iOS patch
      // artifact is stored as the client sent it.
      await registerPatchArtifact(
        appId,
        patchId,
        platform: 'ios',
        hashSignature: 'c2ln',
      );
      expect((await repo.patchArtifacts(patchId)).single.hashSignature, 'c2ln');
    });

    test('customer: a signature is required, and stored untouched', () async {
      final appId = await newApp();
      final id = await newRelease(appId);
      await registerReleaseArtifact(appId, id, signing: {'mode': 'customer'});
      final patchId = await newPatch(appId, id);
      expect(
        (await registerPatchArtifact(appId, patchId)).statusCode,
        HttpStatus.badRequest,
      );
      final r = await registerPatchArtifact(
        appId,
        patchId,
        hashSignature: 'YWJj',
      );
      expect(r.statusCode, HttpStatus.ok);
      expect((await repo.patchArtifacts(patchId)).single.hashSignature, 'YWJj');
    });

    test(
      'customer: assets needs a signature like code, symbols does not',
      () async {
        final appId = await newApp();
        final id = await newRelease(appId);
        await registerReleaseArtifact(appId, id, signing: {'mode': 'customer'});
        final patchId = await newPatch(appId, id);
        // Devices verify dlc.assets in Strict mode, so an unsigned assets
        // artifact would become a patch that is tombstoned on the next boot.
        final unsigned = await registerPatchArtifact(
          appId,
          patchId,
          arch: 'assets',
        );
        expect(unsigned.statusCode, HttpStatus.badRequest);
        expect(await unsigned.readAsString(), contains('hash_signature'));
        expect(
          (await registerPatchArtifact(appId, patchId)).statusCode,
          HttpStatus.badRequest,
        );
        expect(
          (await registerPatchArtifact(
            appId,
            patchId,
            arch: 'assets',
            hashSignature: 'YXNzZXRz',
          )).statusCode,
          HttpStatus.ok,
        );
        expect(
          (await registerPatchArtifact(
            appId,
            patchId,
            arch: 'symbols',
          )).statusCode,
          HttpStatus.ok,
        );
        expect(
          (await registerPatchArtifact(
            appId,
            patchId,
            hashSignature: 'YWJj',
          )).statusCode,
          HttpStatus.ok,
        );
        final stored = {
          for (final a in await repo.patchArtifacts(patchId))
            a.arch: a.hashSignature,
        };
        expect(stored, {
          'assets': 'YXNzZXRz',
          'symbols': null,
          'aarch64': 'YWJj',
        });
      },
    );

    test(
      'managed: assets is server-signed like code, symbols is not',
      () async {
        final appId = await newApp();
        final key = await signingKey(appId);
        final id = await newRelease(appId);
        await registerReleaseArtifact(
          appId,
          id,
          signing: {'mode': 'managed', 'key_id': key['id']},
        );
        final patchId = await newPatch(appId, id);
        const assetsHash = 'ab12';
        for (final arch in ['assets', 'symbols']) {
          final r = await registerPatchArtifact(
            appId,
            patchId,
            arch: arch,
            hash: assetsHash,
          );
          expect(r.statusCode, HttpStatus.ok, reason: arch);
        }
        final stored = {
          for (final a in await repo.patchArtifacts(patchId))
            a.arch: a.hashSignature,
        };
        expect(stored['symbols'], isNull);
        expect(stored['assets'], isNotNull);
        final pub = JsonWebKey.fromJson(
          _jwkFromPem(key['public_key_pem'] as String),
        );
        expect(
          pub.verify(
            utf8.encode(assetsHash),
            base64.decode(stored['assets']!),
            algorithm: 'RS256',
          ),
          isTrue,
        );
      },
    );

    test(
      'a release made before managed signing is never server-signed',
      () async {
        final appId = await newApp();
        // Even with an org key in existence.
        await signingKey(appId);
        final id = await newRelease(appId);
        await registerReleaseArtifact(appId, id); // no `signing`: legacy CLI
        final patchId = await newPatch(appId, id);
        await registerPatchArtifact(appId, patchId);
        expect(
          (await repo.patchArtifacts(patchId)).single.hashSignature,
          isNull,
        );
      },
    );

    test(
      'unsigned releases pass a client signature through unchanged',
      () async {
        final appId = await newApp();
        final id = await newRelease(appId);
        await registerReleaseArtifact(appId, id, signing: {'mode': 'unsigned'});
        final patchId = await newPatch(appId, id);
        await registerPatchArtifact(appId, patchId);
        expect(
          (await repo.patchArtifacts(patchId)).single.hashSignature,
          isNull,
        );
      },
    );

    test('patches/check returns the server-made hash_signature', () async {
      final appId = await newApp();
      final key = await signingKey(appId);
      final id = await newRelease(appId);
      await registerReleaseArtifact(
        appId,
        id,
        signing: {'mode': 'managed', 'key_id': key['id']},
      );
      final channel = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/$appId/channels',
          json: {'channel': 'stable'},
        ),
      );
      final patchId = await newPatch(appId, id);
      await registerPatchArtifact(appId, patchId);
      final art = (await repo.patchArtifacts(patchId)).single;
      await repo.setArtifactStatus(art.id, ArtifactStatus.verified);
      await repo.setPatchStatus(patchId, PatchStatus.ready);
      await repo.setReleasePlatformStatus(id, 'android', 'active');
      final promote = await send(
        'POST',
        '/api/v1/apps/$appId/patches/promote',
        json: {'patch_id': patchId, 'channel_id': channel['id']},
      );
      expect(promote.statusCode, lessThan(300));
      final check = await jsonOf(
        await send(
          'POST',
          '/api/v1/patches/check',
          bearer: null,
          json: {
            'app_id': appId,
            'release_version': '1.0.0',
            'platform': 'android',
            'arch': 'aarch64',
            'channel': 'stable',
            'client_id': 'device-1',
          },
        ),
      );
      expect(check['patch_available'], isTrue);
      expect(
        (check['patch'] as Map)['hash_signature'],
        (await repo.patchArtifacts(patchId)).single.hashSignature,
      );
    });
  });

  group('release deletion', () {
    test(
      'DELETE release removes it, its patches and their artifacts',
      () async {
        final appId = await newApp();
        final keep = await newRelease(appId, '0.9.0');
        final id = await newRelease(appId);
        await registerReleaseArtifact(appId, id);
        final patchId = await newPatch(appId, id);
        await registerPatchArtifact(appId, patchId);
        final keys = [
          ...(await repo.releaseArtifacts(id)).map((a) => a.storageKey),
          ...(await repo.patchArtifacts(patchId)).map((a) => a.storageKey),
        ];
        final store = await ArtifactStore.open(config);
        for (final k in keys) {
          await store.put(k, [1, 2, 3]);
        }

        final r = await send('DELETE', '/api/v1/apps/$appId/releases/$id');
        expect(r.statusCode, HttpStatus.noContent);
        expect(await repo.release(id), isNull);
        expect(await repo.patch(patchId), isNull);
        expect(await repo.releaseArtifacts(id), isEmpty);
        expect(await repo.patchArtifacts(patchId), isEmpty);
        for (final k in keys) {
          expect(await store.exists(k), isFalse);
        }
        // Another release of the app is untouched.
        expect(await repo.release(keep), isNotNull);
        expect(
          (await send('DELETE', '/api/v1/apps/$appId/releases/$id')).statusCode,
          HttpStatus.notFound,
        );
      },
    );

    test('DELETE refuses a release with a live patch, unless forced', () async {
      final appId = await newApp();
      final id = await newRelease(appId);
      await registerReleaseArtifact(appId, id);
      final channel = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/$appId/channels',
          json: {'channel': 'stable'},
        ),
      );
      final patchId = await newPatch(appId, id);
      await registerPatchArtifact(appId, patchId);
      final art = (await repo.patchArtifacts(patchId)).single;
      await repo.setArtifactStatus(art.id, ArtifactStatus.verified);
      await repo.setPatchStatus(patchId, PatchStatus.ready);
      await repo.setReleasePlatformStatus(id, 'android', 'active');
      expect(
        (await send(
          'POST',
          '/api/v1/apps/$appId/patches/promote',
          json: {'patch_id': patchId, 'channel_id': channel['id']},
        )).statusCode,
        lessThan(300),
      );

      final refused = await send('DELETE', '/api/v1/apps/$appId/releases/$id');
      expect(refused.statusCode, HttpStatus.conflict);
      final message = await refused.readAsString();
      expect(message, contains('patches rollback'));
      expect(message, contains('force=true'));
      expect(await repo.release(id), isNotNull);
      expect(await repo.patch(patchId), isNotNull);

      // Only an explicit true forces it.
      for (final f in ['false', '0', '']) {
        expect(
          (await send(
            'DELETE',
            '/api/v1/apps/$appId/releases/$id?force=$f',
          )).statusCode,
          HttpStatus.conflict,
          reason: 'force=$f',
        );
      }

      final forced = await send(
        'DELETE',
        '/api/v1/apps/$appId/releases/$id?force=true',
      );
      expect(forced.statusCode, HttpStatus.noContent);
      expect(await repo.release(id), isNull);
      expect(await repo.patch(patchId), isNull);
    });

    test(
      'DELETE succeeds without force once the live patch is rolled back',
      () async {
        final appId = await newApp();
        final id = await newRelease(appId);
        await registerReleaseArtifact(appId, id);
        final channel = await jsonOf(
          await send(
            'POST',
            '/api/v1/apps/$appId/channels',
            json: {'channel': 'stable'},
          ),
        );
        final patchId = await newPatch(appId, id);
        await registerPatchArtifact(appId, patchId);
        final art = (await repo.patchArtifacts(patchId)).single;
        await repo.setArtifactStatus(art.id, ArtifactStatus.verified);
        await repo.setPatchStatus(patchId, PatchStatus.ready);
        await repo.setReleasePlatformStatus(id, 'android', 'active');
        await send(
          'POST',
          '/api/v1/apps/$appId/patches/promote',
          json: {'patch_id': patchId, 'channel_id': channel['id']},
        );
        expect(
          (await send('DELETE', '/api/v1/apps/$appId/releases/$id')).statusCode,
          HttpStatus.conflict,
        );

        expect(await repo.rollbackActive(patchId), [channel['id']]);

        expect(
          (await send('DELETE', '/api/v1/apps/$appId/releases/$id')).statusCode,
          HttpStatus.noContent,
        );
        expect(await repo.release(id), isNull);
      },
    );

    test('DELETE artifacts?platform= removes one platform only', () async {
      final appId = await newApp();
      final id = await newRelease(appId);
      await registerReleaseArtifact(appId, id);
      await registerReleaseArtifact(appId, id, platform: 'ios', arch: 'runner');
      await repo.setReleasePlatformStatus(id, 'android', 'active');
      await repo.setReleasePlatformStatus(id, 'ios', 'active');
      expect(
        (await send(
          'DELETE',
          '/api/v1/apps/$appId/releases/$id/artifacts',
        )).statusCode,
        HttpStatus.badRequest,
      );
      final r = await send(
        'DELETE',
        '/api/v1/apps/$appId/releases/$id/artifacts?platform=ios',
      );
      expect(r.statusCode, HttpStatus.noContent);
      expect((await repo.releaseArtifacts(id)).map((a) => a.platform), [
        'android',
      ]);
      expect((await repo.release(id))!.platformStatuses, {'android': 'active'});
    });

    test(
      'needs an app admin and cannot reach another tenant\'s release',
      () async {
        final appId = await newApp();
        final id = await newRelease(appId);
        final dev = await repo.upsertUser('dev@x.test', 'Dev');
        final devKey = await repo.createApiKey(dev.id);
        await repo.addCollaborator(appId, dev.id, 'developer');
        expect(
          (await send(
            'DELETE',
            '/api/v1/apps/$appId/releases/$id',
            bearer: devKey,
          )).statusCode,
          HttpStatus.forbidden,
        );
        final stranger = await repo.upsertUser('m@evil.test', 'M');
        final strangerKey = await repo.createApiKey(stranger.id);
        expect(
          (await send(
            'DELETE',
            '/api/v1/apps/$appId/releases/$id',
            bearer: strangerKey,
          )).statusCode,
          isIn([HttpStatus.forbidden, HttpStatus.notFound]),
        );
        expect(await repo.release(id), isNotNull);
      },
    );
  });

  group('PatchSigner', () {
    test('round-trips under its secret and not under another', () async {
      final signer = PatchSigner('a' * 40);
      final k = signer.generate();
      final sig = await signer.signHash(k.privateKeyEncrypted, 'abc123');
      final pub = JsonWebKey.fromJson(_jwkFromPem(k.publicKeyPem));
      expect(
        pub.verify(
          utf8.encode('abc123'),
          base64.decode(sig),
          algorithm: 'RS256',
        ),
        isTrue,
      );
      await expectLater(
        PatchSigner('b' * 40).signHash(k.privateKeyEncrypted, 'abc123'),
        throwsA(anything),
      );
    });
  });

  group('key-encryption secret', () {
    test('the JWE header carries a key version', () async {
      final k = PatchSigner('a' * 40).generate();
      final header =
          jsonDecode(
                utf8.decode(
                  base64Url.decode(
                    base64Url.normalize(k.privateKeyEncrypted.split('.').first),
                  ),
                ),
              )
              as Map<String, dynamic>;
      expect(header['kid'], PatchSigner.currentKeyVersion);
      expect(header['alg'], 'dir');
      expect(header['enc'], 'A256GCM');
    });

    test('signing-key answers 503 naming the variable when unset', () async {
      final bare = Api(
        repo,
        await ArtifactStore.open(config),
        sqliteConfig(tmp.path, patchSigningKeySecret: null),
      );
      final app = await newApp();
      final r = await bare.handler(
        Request(
          'GET',
          Uri.parse('http://localhost:8080/api/v1/apps/$app/signing-key'),
          headers: {HttpHeaders.authorizationHeader: 'Bearer $_key'},
        ),
      );
      expect(r.statusCode, HttpStatus.serviceUnavailable);
      expect(await r.readAsString(), contains('PATCH_SIGNING_KEY_SECRET'));
      // And nothing was stored under some fallback.
      expect(await repo.anySigningKey(), isNull);
    });

    test('boot check: ok with no key, ok with the right secret, refuses a '
        'wrong or missing one', () async {
      expect(await api.checkPatchSigningKeys(), isNull);
      await signingKey(await newApp());
      expect(await api.checkPatchSigningKeys(), isNull);

      Future<Api> withSecret(String? secret) async => Api(
        repo,
        await ArtifactStore.open(config),
        sqliteConfig(tmp.path, patchSigningKeySecret: secret),
      );
      final wrong = await (await withSecret('z' * 40)).checkPatchSigningKeys();
      expect(wrong, contains('PATCH_SIGNING_KEY_SECRET does not decrypt'));
      final missing = await (await withSecret(null)).checkPatchSigningKeys();
      expect(missing, contains('PATCH_SIGNING_KEY_SECRET is not set'));
    });

    test(
      'boot check: a later org\'s key that does not decrypt is found and named',
      () async {
        await signingKey(await newApp());
        // A second org whose key was wrapped under some other secret.
        final user = await repo.upsertUser('second@example.com', null);
        final orgId = (await repo.memberships(user.id)).single.orgId;
        final bad = await repo.insertSigningKeyIfAbsent(
          orgId,
          'pem',
          'garbage',
        );
        final problem = await api.checkPatchSigningKeys();
        expect(problem, contains('organization $orgId'));
        expect(problem, contains('key id ${bad.id}'));
      },
    );
  });

  group('Config', () {
    List<String> problems(String? secret) => sqliteConfig(
      tmp.path,
      patchSigningKeySecret: secret,
    ).validate().where((p) => p.contains('PATCH_SIGNING')).toList();

    test('unset never falls back to URL_SIGNING_SECRET', () async {
      // Optional outside production (managed signing is just unavailable)...
      expect(problems(null), isEmpty);
      // ...required in production, naming the variable.
      final prod = sqliteConfig(
        tmp.path,
        production: true,
        patchSigningKeySecret: null,
      ).validate().where((p) => p.contains('PATCH_SIGNING_KEY_SECRET'));
      expect(prod, hasLength(1));
      expect(prod.single, contains('required in production'));
    });

    test('a set secret must be long enough and not reused', () {
      expect(problems('a' * 40), isEmpty);
      expect(problems('short'), hasLength(1));
      expect(problems('x' * 40), isEmpty);
    });
  });
}
