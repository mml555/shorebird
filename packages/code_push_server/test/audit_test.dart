// cspell:words segs unrouted
// CONTROL-PLANE-AUDIT-1 qualification.
//
// Every mutating patch-lifecycle request must leave exactly one attributable,
// mechanically queryable audit event saying what was attempted and what
// happened. These tests are the positive and negative controls for that claim.
//
// The load-bearing one is `the audit ceiling control` at the bottom: it proves
// the probe used to show "nothing was created" can actually FAIL. A probe that
// cannot fail certifies nothing, which is precisely how gate 6E's
// "no patch-creation request in the log" check turned out to be vacuous.
import 'dart:convert';
import 'dart:io';

import 'package:code_push_server/src/api.dart';
import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/audit.dart';
import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/db.dart';
import 'package:code_push_server/src/observability.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support.dart';

const _bootstrapKey = 'sb_api_selfhost_dev';

/// A token that exists ONLY to be searched for. Deliberately shaped like this
/// server's own API keys so it also exercises the credential-shape scrubber,
/// and deliberately unique so a single occurrence anywhere in captured audit
/// output is unambiguous.
const _canary = 'sb_api_CANARY_DO_NOT_LOG_8f31c0aa4d5e';

void main() {
  late Directory tmp;
  late Repository repo;
  late Config config;
  late Api api;

  /// Every line the log sink received during a test.
  late List<String> logLines;
  late void Function(String) savedSink;

  Future<void> boot({
    Repository Function(Db db)? wrap,
    String? logFormat,
  }) async {
    tmp = Directory.systemTemp.createTempSync('cps_audit');
    config = sqliteConfig(tmp.path);
    repo = await Repository.open(config);
    if (wrap != null) repo = wrap(repo.db);
    api = Api(repo, await ArtifactStore.open(config), config);
  }

  setUp(() async {
    logLines = [];
    savedSink = logSink;
    logSink = logLines.add;
    await boot();
  });

  tearDown(() async {
    logSink = savedSink;
    await repo.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<Response> send(
    String method,
    String path, {
    String? bearer,
    Object? json,
    Map<String, String> headers = const {},
  }) => Future.sync(
    () => api.handler(
      Request(
        method,
        Uri.parse('http://localhost:8080$path'),
        headers: {
          if (bearer != null) HttpHeaders.authorizationHeader: 'Bearer $bearer',
          ...headers,
        },
        body: json == null ? null : jsonEncode(json),
      ),
    ),
  );

  Future<Map<String, dynamic>> jsonOf(Response r) async =>
      jsonDecode(await r.readAsString()) as Map<String, dynamic>;

  // ---- direct reads of the trail, so a test never infers it from a side
  // effect (which is the failure mode this whole lane exists to remove) ----

  Future<List<Map<String, Object?>>> events({
    String? operation,
    int? after,
    int? releaseId,
    String? result,
    int limit = 100,
  }) => repo.auditEvents(
    operations: operation == null ? const [] : [operation],
    after: after,
    releaseId: releaseId,
    result: result,
    limit: limit,
  );

  Future<int> ceiling() => repo.auditCeiling();

  /// Request-outcome rows only. Detail rows (`result IS NULL`) are sub-facts of
  /// a request, not its outcome, and must never be counted as one.
  Future<List<Map<String, Object?>>> requestEvents(String operation) async =>
      (await events(
        operation: operation,
      )).where((e) => e['kind'] == 'request').toList();

  Future<({String appId, int releaseId, int channelId})> seedApp() async {
    final app = await jsonOf(
      await send(
        'POST',
        '/api/v1/apps',
        bearer: _bootstrapKey,
        json: {'display_name': 'audit'},
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

  /// Registers a patch artifact and uploads its bytes, leaving the patch ready.
  Future<void> uploadPatchArtifact(String appId, int patchId) async {
    const bd = 'BOUNDARY';
    String field(String n, String v) =>
        '--$bd\r\ncontent-disposition: form-data; name="$n"\r\n\r\n$v\r\n';
    final bytes = [1, 2, 3, 4];
    final reg = await Future.sync(
      () => api.handler(
        Request(
          'POST',
          Uri.parse(
            'http://localhost:8080/api/v1/apps/$appId/patches/$patchId/artifacts',
          ),
          headers: {
            HttpHeaders.authorizationHeader: 'Bearer $_bootstrapKey',
            HttpHeaders.contentTypeHeader: 'multipart/form-data; boundary=$bd',
          },
          body:
              '${field('arch', 'aarch64')}'
              '${field('platform', 'android')}'
              '${field('hash', 'deadbeef')}'
              '${field('size', '${bytes.length}')}'
              '--$bd--\r\n',
        ),
      ),
    );
    final url = (await jsonOf(reg))['url'] as String;
    final token = Uri.parse(url).pathSegments.last;
    final filePart =
        '--$bd\r\ncontent-disposition: form-data; name="file"; '
        'filename="a.bin"\r\n\r\n${String.fromCharCodes(bytes)}\r\n--$bd--\r\n';
    await Future.sync(
      () => api.handler(
        Request(
          'POST',
          Uri.parse('http://localhost:8080/api/v1/uploads/$token'),
          headers: {
            HttpHeaders.authorizationHeader: 'Bearer $_bootstrapKey',
            HttpHeaders.contentTypeHeader: 'multipart/form-data; boundary=$bd',
          },
          body: filePart,
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  group('route classification', () {
    // The classifier is the ONLY thing that decides whether a request can
    // produce a mutation event, so it is tested directly rather than only
    // through the HTTP surface.
    List<String> segs(String p) => Uri.parse(p).pathSegments;

    test('mutating patch-lifecycle routes are recognized', () {
      final cases = <(String, String, String)>[
        ('POST', '/api/v1/apps', 'app.create'),
        ('POST', '/api/v1/apps/a1/releases', 'release.create'),
        ('PATCH', '/api/v1/apps/a1/releases/7', 'release.update'),
        (
          'POST',
          '/api/v1/apps/a1/releases/7/artifacts',
          'release.artifact.create',
        ),
        ('POST', '/api/v1/apps/a1/patches', 'patch.create'),
        ('PATCH', '/api/v1/apps/a1/patches/3', 'patch.update'),
        ('POST', '/api/v1/apps/a1/patches/promote', 'patch.promote'),
        (
          'POST',
          '/api/v1/apps/a1/patches/3/artifacts',
          'patch.artifact.create',
        ),
        ('POST', '/api/v1/apps/a1/channels', 'channel.create'),
        ('POST', '/api/v1/uploads/tok', 'artifact.upload'),
        ('PUT', '/api/v1/uploads/tok', 'artifact.upload'),
        ('POST', '/admin/apps/a1/patches/3/withdraw', 'patch.withdraw'),
        ('POST', '/admin/apps/a1/patches/3/rollout', 'patch.rollout'),
      ];
      for (final (method, path, operation) in cases) {
        expect(
          classifyMutation(method, segs(path))?.operation,
          operation,
          reason: '$method $path',
        );
      }
    });

    test('the path supplies the ids it carries', () {
      final r = classifyMutation(
        'POST',
        segs('/api/v1/apps/a1/patches/3/artifacts'),
      )!;
      expect(r.appId, 'a1');
      expect(r.patchId, 3);
      final w = classifyMutation(
        'POST',
        segs('/admin/apps/a1/patches/9/withdraw'),
      )!;
      expect(w.appId, 'a1');
      expect(w.patchId, 9);
    });

    test('the upload route template never carries the token', () {
      final r = classifyMutation('PUT', segs('/api/v1/uploads/s3cr3t-token'))!;
      expect(r.route, isNot(contains('s3cr3t-token')));
      expect(r.route, 'PUT /api/v1/uploads/{token}');
    });

    test('reads and device POSTs are not mutations', () {
      final notMutations = <(String, String)>[
        ('GET', '/api/v1/apps'),
        ('GET', '/api/v1/apps/a1/releases'),
        ('GET', '/api/v1/apps/a1/releases/7/patches'),
        ('GET', '/api/v1/apps/a1/channels'),
        ('GET', '/api/v1/apps/a1/metrics'),
        ('GET', '/api/v1/apps/a1/analytics/patch-adoption'),
        ('GET', '/metrics'),
        ('GET', '/healthz'),
        ('GET', '/admin/audit'),
        ('GET', '/admin/apps/a1/collaborators'),
        // Device surface: POSTs, but telemetry and lookups, not operator acts.
        ('POST', '/api/v1/patches/check'),
        ('POST', '/api/v1/patches/events'),
        ('POST', '/api/v1/patches/assets'),
        ('POST', '/api/v1/crashes'),
        ('POST', '/patches/check'),
        // Unrouted.
        ('POST', '/api/v1/apps/a1/patches/3/nonsense'),
        ('DELETE', '/api/v1/apps/a1/patches/3'),
      ];
      for (final (method, path) in notMutations) {
        expect(
          classifyMutation(method, segs(path)),
          isNull,
          reason: '$method $path',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  group('control 1 — successful create', () {
    test('leaves exactly one attributable patch.create event', () async {
      final s = await seedApp();
      final before = await ceiling();
      final res = await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches',
        bearer: _bootstrapKey,
        json: {'release_id': s.releaseId},
      );
      expect(res.statusCode, 200);
      final created = await jsonOf(res);

      final rows = await requestEvents('patch.create');
      expect(rows, hasLength(1), reason: 'exactly one create event');
      final e = rows.single;
      expect(e['result'], 'success');
      expect(e['http_status'], 200);
      // WHEN / WHO / WHAT / WHICH / WHAT RESULT / WHAT REQUEST — every question
      // the event has to answer, answered from the row alone.
      expect(DateTime.parse(e['timestamp']! as String), isNotNull);
      expect(e['actor_id'], 1);
      expect(e['actor'], 'owner@self-host.local');
      expect(e['actor_credential'], startsWith('bootstrap:'));
      expect(e['operation'], 'patch.create');
      expect(e['route'], 'POST /api/v1/apps/{app}/patches');
      expect(e['method'], 'POST');
      expect(e['app_id'], s.appId);
      expect(e['release_id'], s.releaseId);
      expect(e['patch_id'], created['id']);
      expect(e['patch_number'], created['number']);
      expect(e['request_id'], startsWith('req_'));
      expect((e['id']! as int) > before, isTrue);
    });

    test('two credentials on one account are distinguishable actors', () async {
      // Operationally these are different actors even though `actor_id` is the
      // same, which is why the credential fingerprint is its own field.
      final key = await repo.createApiKey(1);
      final s = await seedApp();
      await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches',
        bearer: _bootstrapKey,
        json: {'release_id': s.releaseId},
      );
      await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches',
        bearer: key,
        json: {'release_id': s.releaseId},
      );
      final creds = (await requestEvents(
        'patch.create',
      )).map((e) => e['actor_credential']).toList();
      expect(creds, hasLength(2));
      expect(creds.toSet(), hasLength(2));
      expect(creds.first, startsWith('bootstrap:'));
      expect(creds.last, startsWith('api_key:'));
      // And neither is the credential itself.
      expect(creds.join(), isNot(contains(key)));
      expect(creds.join(), isNot(contains(_bootstrapKey)));
    });
  });

  // -------------------------------------------------------------------------
  group('control 2 — successful promote', () {
    test('leaves an attributable promotion event with its track', () async {
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
      final res = await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': p['id'], 'channel_id': s.channelId, 'rollout': 25},
      );
      expect(res.statusCode, HttpStatus.noContent);

      final rows = await requestEvents('patch.promote');
      expect(rows, hasLength(1));
      final e = rows.single;
      expect(e['result'], 'success');
      expect(e['http_status'], 204);
      expect(e['app_id'], s.appId);
      // Both ids arrive in the BODY on this route, so this also proves handler
      // enrichment reaches the event.
      expect(e['patch_id'], p['id']);
      expect(e['patch_number'], p['number']);
      expect(e['release_id'], s.releaseId);
      expect(e['track'], 'stable');
      final detail = jsonDecode(e['detail']! as String) as Map;
      expect(detail['rollout'], 25);
      expect(detail['channel_id'], s.channelId);
    });

    test('a channel change is attributable', () async {
      final s = await seedApp();
      await send(
        'POST',
        '/api/v1/apps/${s.appId}/channels',
        bearer: _bootstrapKey,
        json: {'channel': 'beta'},
      );
      final rows = await requestEvents('channel.create');
      expect(rows.map((e) => e['track']), containsAll(['stable', 'beta']));
      expect(rows.every((e) => e['result'] == 'success'), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('control 3 — removal', () {
    test('withdraw with rollback leaves an attributable event', () async {
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
      await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': p['id'], 'channel_id': s.channelId},
      );
      final res = await send(
        'POST',
        '/admin/apps/${s.appId}/patches/${p['id']}/withdraw?rollback=true',
        bearer: _bootstrapKey,
      );
      expect(res.statusCode, 200);

      final rows = await requestEvents('patch.withdraw');
      expect(rows, hasLength(1));
      final e = rows.single;
      expect(e['result'], 'success');
      expect(e['app_id'], s.appId);
      expect(e['patch_id'], p['id']);
      expect(e['patch_number'], p['number']);
      expect(e['release_id'], s.releaseId);
      expect(e['track'], 'stable');
      expect((jsonDecode(e['detail']! as String) as Map)['rollback'], isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('control 4 — a refused mutation never reads as success', () {
    test('conflict: promoting a patch that is not ready', () async {
      final s = await seedApp();
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': s.releaseId},
        ),
      );
      final res = await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': p['id'], 'channel_id': s.channelId},
      );
      expect(res.statusCode, HttpStatus.conflict);
      final e = (await requestEvents('patch.promote')).single;
      expect(e['result'], 'refused');
      expect(e['http_status'], 409);
      // Attributable even though the mutation never happened.
      expect(e['patch_id'], p['id']);
      expect(e['app_id'], s.appId);
    });

    test('bad request: a create with no release_id', () async {
      final s = await seedApp();
      final res = await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches',
        bearer: _bootstrapKey,
        json: <String, Object?>{},
      );
      expect(res.statusCode, HttpStatus.badRequest);
      final e = (await requestEvents('patch.create')).single;
      expect(e['result'], 'refused');
      expect(e['http_status'], 400);
    });

    test('not found: a create against another app\'s release', () async {
      final mine = await seedApp();
      final theirs = await seedApp();
      final res = await send(
        'POST',
        '/api/v1/apps/${mine.appId}/patches',
        bearer: _bootstrapKey,
        json: {'release_id': theirs.releaseId},
      );
      expect(res.statusCode, HttpStatus.notFound);
      final e = (await requestEvents('patch.create')).single;
      expect(e['result'], 'refused');
      expect(e['http_status'], 404);
      // The release someone REACHED FOR is what makes this findable.
      expect(e['release_id'], theirs.releaseId);
      expect(e['app_id'], mine.appId);
    });

    test('forbidden: a create with an unknown credential', () async {
      // Refused by `_auth`, so the handler never runs. The attempt still has
      // to appear, or "nobody tried" and "nobody got through" are the same
      // observation.
      final s = await seedApp();
      final res = await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches',
        bearer: 'sb_api_not_a_real_key_at_all',
        json: {'release_id': s.releaseId},
      );
      expect(res.statusCode, HttpStatus.forbidden);
      final e = (await requestEvents('patch.create')).single;
      expect(e['result'], 'refused');
      expect(e['http_status'], 403);
      expect(e['actor_id'], isNull);
      expect(e['actor_credential'], startsWith('rejected:'));
      expect(e['app_id'], s.appId);
    });

    test('forbidden: a create with no credential at all', () async {
      final s = await seedApp();
      final res = await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches',
        json: {'release_id': s.releaseId},
      );
      expect(res.statusCode, HttpStatus.forbidden);
      final e = (await requestEvents('patch.create')).single;
      expect(e['result'], 'refused');
      expect(e['actor_credential'], 'anonymous');
    });

    test('no refused mutation is ever recorded as a success', () async {
      final s = await seedApp();
      // A spread of refusal shapes in one server's history.
      await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches',
        bearer: 'nope',
        json: {'release_id': s.releaseId},
      );
      await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches',
        bearer: _bootstrapKey,
        json: {'release_id': 999999},
      );
      await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': 1, 'channel_id': s.channelId, 'rollout': 500},
      );
      final refusals = await events(result: 'refused');
      expect(refusals, hasLength(3));
      expect(refusals.every((e) => e['http_status']! as int >= 400), isTrue);
      // And nothing in this window claims otherwise.
      final creates = await requestEvents('patch.create');
      expect(creates.every((e) => e['result'] != 'success'), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('control 5 — a read never masquerades as a mutation', () {
    test('read-only traffic writes no audit rows', () async {
      final s = await seedApp();
      final before = await ceiling();
      final reads = <(String, String, Object?)>[
        ('GET', '/api/v1/apps', null),
        ('GET', '/api/v1/apps/${s.appId}/releases', null),
        (
          'GET',
          '/api/v1/apps/${s.appId}/releases/${s.releaseId}/patches',
          null,
        ),
        ('GET', '/api/v1/apps/${s.appId}/channels', null),
        ('GET', '/api/v1/apps/${s.appId}/metrics', null),
        ('GET', '/api/v1/users/me', null),
        ('GET', '/api/v1/organizations', null),
        ('GET', '/metrics', null),
        ('GET', '/healthz', null),
        ('GET', '/admin/audit', null),
      ];
      for (final (method, path, body) in reads) {
        await send(method, path, bearer: _bootstrapKey, json: body);
      }
      // Device POSTs: mutate telemetry tables, but are not operator actions and
      // must not appear in the operator's mutation trail.
      await send(
        'POST',
        '/api/v1/patches/check',
        json: {
          'app_id': s.appId,
          'release_version': '1.0.0',
          'patch_number': 0,
          'platform': 'android',
          'arch': 'aarch64',
        },
      );
      await send(
        'POST',
        '/api/v1/patches/events',
        json: {
          'event': {
            'app_id': s.appId,
            'type': '__patch_install__',
            'client_id': 'c1',
            'platform': 'android',
            'arch': 'aarch64',
            'release_version': '1.0.0',
            'patch_number': 1,
            'timestamp': 1,
          },
        },
      );
      expect(await ceiling(), before, reason: 'no audit row for any read');
    });
  });

  // -------------------------------------------------------------------------
  group('control 6 — secret redaction', () {
    test('a canary credential occurs zero times in audit output', () async {
      final s = await seedApp();
      logLines.clear();
      // The canary is presented in every place a caller controls: the bearer,
      // an extra header, and a query string.
      await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches?trace=$_canary',
        bearer: _canary,
        json: {'release_id': s.releaseId, 'notes': 'note $_canary'},
      );
      // ... and once more with a valid credential, so the request that DID
      // succeed also had the canary in reach.
      await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches?trace=$_canary',
        bearer: _bootstrapKey,
        headers: {'x-api-key': _canary},
        json: {'release_id': s.releaseId},
      );

      // Captured audit output: the log-sink copy...
      final auditLines = logLines.where((l) => l.startsWith('audit ')).toList();
      expect(
        auditLines,
        isNotEmpty,
        reason: 'the control must have output to search',
      );
      // ...and the durable rows, serialized whole.
      final rows = jsonEncode(await events(limit: 1000));
      final captured = '${auditLines.join('\n')}\n$rows';

      expect(_canary.allMatches(captured).length, 0);
      expect(captured, isNot(contains(_canary)));
      // Nor the real bootstrap key, which is a secret in exactly the same way.
      expect(captured, isNot(contains(_bootstrapKey)));
      // Not vacuous: the same capture DOES contain the events and their ids.
      expect(captured, contains('patch.create'));
      expect(captured, contains(s.appId));
    });

    test('a credential that reaches a detail field is redacted', () async {
      // Backstop for the allowlist: if a future field ever carried a bearer,
      // the failure mode is a redacted string, not a leaked secret.
      expect(auditSafeText('key=$_canary tail'), 'key=[redacted] tail');
      expect(
        auditSafeText('Authorization: Bearer abc.def.ghi'),
        'Authorization: [redacted]',
      );
      expect(
        auditSafeText('eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln'),
        '[redacted]',
      );
    });

    test('free text cannot forge a second log line', () async {
      expect(auditSafeText('a\nb=c'), 'a?b=c');
      expect(
        auditSafeText('x' * 900).length,
        auditTextLimit + '(clipped)'.length,
      );
    });

    test('a request id is a correlation key, never a capability', () async {
      // Not adopted from an untrusted peer: it becomes a stored, indexed key,
      // and a caller who could choose it could forge collisions.
      expect(adoptedRequestId('abc', peerIsTrustedProxy: false), isNull);
      expect(adoptedRequestId('abc', peerIsTrustedProxy: true), 'abc');
      expect(adoptedRequestId('a b', peerIsTrustedProxy: true), isNull);
      expect(adoptedRequestId('x' * 65, peerIsTrustedProxy: true), isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('control 7 — a failed mutation cannot leave a success', () {
    test('a throwing create is recorded as an error, not a success', () async {
      await repo.close();
      await boot(wrap: _ThrowingCreatePatch.new);
      final s = await seedApp();
      final res = await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches',
        bearer: _bootstrapKey,
        json: {'release_id': s.releaseId},
      );
      expect(res.statusCode, HttpStatus.internalServerError);
      final e = (await requestEvents('patch.create')).single;
      expect(e['result'], 'error');
      expect(e['http_status'], 500);
      expect(e['release_id'], s.releaseId);
      // The point of the control: nothing anywhere says this worked.
      expect(
        await events(result: 'success', operation: 'patch.create'),
        isEmpty,
      );
    });

    test('a failed audit WRITE is loud, not silent', () async {
      // The mutation has already happened by the time the row is written, so a
      // failure here cannot be undone — but it must never pass unnoticed, or
      // "nothing was logged" stops meaning anything.
      await repo.close();
      await boot(wrap: _ThrowingAudit.new);
      final app = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps',
          bearer: _bootstrapKey,
          json: {'display_name': 'x'},
        ),
      );
      expect(app['id'], isNotNull, reason: 'the request itself still succeeds');
      expect(api.obs.metrics.auditWriteFailures, greaterThan(0));
      final failed = logLines.where((l) => l.contains('AUDIT WRITE FAILED'));
      expect(failed, isNotEmpty);
      expect(
        logLines.where((l) => l.contains('audit_persisted=false')),
        isNotEmpty,
      );
    });
  });

  // -------------------------------------------------------------------------
  group('control 8 — request correlation', () {
    test('the response X-Request-Id names the audit event', () async {
      final s = await seedApp();
      final res = await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches',
        bearer: _bootstrapKey,
        json: {'release_id': s.releaseId},
      );
      final rid = res.headers['x-request-id'];
      expect(rid, startsWith('req_'));
      final e = (await requestEvents('patch.create')).single;
      expect(e['request_id'], rid);

      // And an operator can go from the id the client saw to the trail.
      final found = await jsonOf(
        await send(
          'GET',
          '/admin/audit?request_id=$rid',
          bearer: _bootstrapKey,
        ),
      );
      expect(found['count'], 1);
      expect((found['events'] as List).single, containsPair('request_id', rid));
    });

    test('every response carries a request id, audited or not', () async {
      final read = await send('GET', '/api/v1/apps', bearer: _bootstrapKey);
      expect(read.headers['x-request-id'], startsWith('req_'));
      final probe = await send('GET', '/healthz');
      expect(probe.headers['x-request-id'], startsWith('req_'));
    });

    test('detail rows correlate to the request that wrote them', () async {
      // `release.ready` is a sub-fact with its own name (older evidence counts
      // rows by that name), so it stays a distinct row — tied to its request.
      final s = await seedApp();
      await _readyRelease(api, s.appId, s.releaseId);
      final rows = await events();
      final ready = rows.firstWhere((e) => e['operation'] == 'release.ready');
      expect(ready['kind'], 'detail');
      expect(ready['result'], isNull, reason: 'a sub-fact is not an outcome');
      final update = rows.firstWhere(
        (e) => e['operation'] == 'release.update' && e['kind'] == 'request',
      );
      expect(ready['request_id'], update['request_id']);
      expect(ready['release_id'], s.releaseId);
    });
  });

  // -------------------------------------------------------------------------
  group('the audit ceiling control', () {
    // This is the control gate 6E was missing. The claim under test is not
    // "no patch was created" — it is "the PROBE that says no patch was created
    // is capable of saying otherwise".
    test('the ceiling probe can fail', () async {
      final s = await seedApp();
      Future<List<Map<String, Object?>>> createsAbove(int c) =>
          events(operation: 'patch.create', after: c);

      // 1. Snapshot.
      final ceilingA = await ceiling();

      // 2. An interval in which the producer sends no patch-create request at
      //    all — the shape of a locally-refused `shorebird patch`. Real traffic
      //    still flows, so the interval is not simply empty.
      await send('GET', '/api/v1/apps', bearer: _bootstrapKey);
      await send(
        'GET',
        '/api/v1/apps/${s.appId}/releases/${s.releaseId}/patches',
        bearer: _bootstrapKey,
      );

      // 3. The negative reading.
      expect(await createsAbove(ceilingA), isEmpty);

      // 4. THE ANTI-VACUITY HALF. Send a create the logger should record, and
      //    prove the same probe now reports it. Without this, step 3 would pass
      //    identically against a logger that records nothing.
      final res = await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches',
        bearer: _bootstrapKey,
        json: {'release_id': s.releaseId},
      );
      expect(res.statusCode, 200);
      final after = await createsAbove(ceilingA);
      expect(after, hasLength(1));
      expect(after.single['result'], 'success');
      expect(after.single['release_id'], s.releaseId);

      // 5. And a fresh ceiling is once again clean, so the probe is not simply
      //    stuck returning rows.
      expect(await createsAbove(await ceiling()), isEmpty);
    });

    test('a refused create is above the ceiling too', () async {
      // The negative reading must mean "no request arrived", NOT "no patch was
      // created". A producer that reached the server and was refused there is a
      // different fact, and it must be visible as one.
      final s = await seedApp();
      final c = await ceiling();
      await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches',
        bearer: _bootstrapKey,
        json: {'release_id': 999999},
      );
      final rows = await events(operation: 'patch.create', after: c);
      expect(rows, hasLength(1));
      expect(rows.single['result'], 'refused');
    });
  });

  // -------------------------------------------------------------------------
  group('the operator query', () {
    test('answers "what happened to release N" in one call', () async {
      final s = await seedApp();
      final other = await seedApp();
      final p = await jsonOf(
        await send(
          'POST',
          '/api/v1/apps/${s.appId}/patches',
          bearer: _bootstrapKey,
          json: {'release_id': s.releaseId},
        ),
      );
      await uploadPatchArtifact(s.appId, p['id'] as int);
      await send(
        'POST',
        '/api/v1/apps/${s.appId}/patches/promote',
        bearer: _bootstrapKey,
        json: {'patch_id': p['id'], 'channel_id': s.channelId},
      );
      await send(
        'POST',
        '/admin/apps/${s.appId}/patches/${p['id']}/withdraw',
        bearer: _bootstrapKey,
      );
      // Noise on a different release, which must not appear.
      await send(
        'POST',
        '/api/v1/apps/${other.appId}/patches',
        bearer: _bootstrapKey,
        json: {'release_id': other.releaseId},
      );

      final body = await jsonOf(
        await send(
          'GET',
          '/admin/audit?release_id=${s.releaseId}'
              '&operation=patch.create,patch.promote,patch.withdraw',
          bearer: _bootstrapKey,
        ),
      );
      final ops = [
        for (final e in body['events'] as List) (e as Map)['operation'],
      ];
      expect(ops, ['patch.create', 'patch.promote', 'patch.withdraw']);
      expect(
        (body['events'] as List).every(
          (e) => (e as Map)['release_id'] == s.releaseId,
        ),
        isTrue,
      );
      expect(body['ceiling'], greaterThanOrEqualTo(await ceiling()));
    });

    test('is server-admin only', () async {
      // A tenant with their own app must not be able to read the deployment's
      // whole mutation history.
      final user = await jsonOf(
        await send(
          'POST',
          '/admin/users?email=tenant@example.com',
          bearer: _bootstrapKey,
        ),
      );
      final res = await send(
        'GET',
        '/admin/audit',
        bearer: user['api_key'] as String,
      );
      expect(res.statusCode, HttpStatus.forbidden);
      // The refusal itself is recorded, with the right subject.
      final denied = (await events(
        operation: 'admin.denied',
      )).where((e) => e['target'] == 'audit');
      expect(denied, isNotEmpty);
    });

    test('rejects a malformed result filter rather than ignoring it', () async {
      final res = await send(
        'GET',
        '/admin/audit?result=succeeded',
        bearer: _bootstrapKey,
      );
      expect(res.statusCode, HttpStatus.badRequest);
    });
  });
}

/// Drives a release to `ready`, which is what makes `release.ready` fire.
Future<void> _readyRelease(Api api, String appId, int releaseId) async {
  const bd = 'BOUNDARY';
  String field(String n, String v) =>
      '--$bd\r\ncontent-disposition: form-data; name="$n"\r\n\r\n$v\r\n';
  Future<Response> post(String path, String body, String contentType) =>
      Future.sync(
        () => api.handler(
          Request(
            'POST',
            Uri.parse('http://localhost:8080$path'),
            headers: {
              HttpHeaders.authorizationHeader: 'Bearer $_bootstrapKey',
              HttpHeaders.contentTypeHeader: contentType,
            },
            body: body,
          ),
        ),
      );

  const bytes = 'abcd';
  // Release artifacts are hash-verified on upload, so this must be the real
  // sha256 of the bytes below — otherwise the release never reaches `ready`
  // and the test would silently assert nothing.
  final hash = sha256.convert(utf8.encode(bytes)).toString();
  for (final arch in ['aab', 'aarch64']) {
    final reg = await post(
      '/api/v1/apps/$appId/releases/$releaseId/artifacts',
      '${field('arch', arch)}'
          '${field('platform', 'android')}'
          '${field('hash', hash)}'
          '${field('size', '${bytes.length}')}'
          '--$bd--\r\n',
      'multipart/form-data; boundary=$bd',
    );
    final url = (jsonDecode(await reg.readAsString()) as Map)['url'] as String;
    final token = Uri.parse(url).pathSegments.last;
    await post(
      '/api/v1/uploads/$token',
      '--$bd\r\ncontent-disposition: form-data; name="file"; '
          'filename="a.bin"\r\n\r\n$bytes\r\n--$bd--\r\n',
      'multipart/form-data; boundary=$bd',
    );
  }
  await Future.sync(
    () => api.handler(
      Request(
        'PATCH',
        Uri.parse(
          'http://localhost:8080/api/v1/apps/$appId/releases/$releaseId',
        ),
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer $_bootstrapKey',
          HttpHeaders.contentTypeHeader: 'application/json',
        },
        body: jsonEncode({'status': 'active', 'platform': 'android'}),
      ),
    ),
  );
}

/// A repository whose `createPatch` fails after the request is well-formed and
/// authorized — the "failed transaction" arm of control 7.
class _ThrowingCreatePatch extends Repository {
  _ThrowingCreatePatch(super.db);

  @override
  Future<PatchRow> createPatch(
    String appId,
    int releaseId, {
    String? notes,
    Map<String, Object?>? metadata,
  }) => throw StateError('injected failure after authorization');
}

/// A repository whose audit writes fail, for the "a missing row must be loud"
/// arm of control 7.
class _ThrowingAudit extends Repository {
  _ThrowingAudit(super.db);

  @override
  Future<int> audit(
    String action, {
    String? actor,
    String? target,
    String? detail,
    String? requestId,
    String? route,
    String? method,
    int? actorId,
    String? actorCredential,
    String? appId,
    int? releaseId,
    int? patchId,
    int? patchNumber,
    String? track,
    int? orgId,
    String? targetKind,
    String? result,
    int? httpStatus,
  }) => throw StateError('injected audit write failure');
}
