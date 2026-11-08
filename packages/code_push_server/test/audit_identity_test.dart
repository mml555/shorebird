// cspell:words segs
// CONTROL-PLANE-AUDIT-2 qualification.
//
// Identity and tenancy mutations — who owns what, who may act on an app, which
// credential was issued — are first-class typed audit outcomes, not generic
// detail notes. This is the control-plane state that decides who is allowed to
// mutate releases and patches at all, so it is the weakest link if it is only
// recorded as free text.
//
// The patch-lifecycle half is qualified in `audit_test.dart`; the machinery
// (one row per request, outcome derived from the response, middleware outside
// auth) is shared and not re-proved here.
import 'dart:convert';
import 'dart:io';

import 'package:code_push_server/src/api.dart';
import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/audit.dart';
import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/observability.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support.dart';

const _bootstrapKey = 'sb_api_selfhost_dev';

/// Searched for, never expected. Shaped like a real API key so it also
/// exercises the credential-shape scrubber.
const _canary = 'sb_api_CANARY_IDENTITY_DO_NOT_LOG_4c71b0e9';

/// Shaped like a real INVITATION token, which is a capability in its own right
/// (whoever presents one gets the org role it carries, up to `owner`).
const _inviteCanary = 'sb_inv_CANARY_DO_NOT_LOG_2a5f8d3117';

void main() {
  late Directory tmp;
  late Repository repo;
  late Config config;
  late Api api;
  late List<String> logLines;
  late void Function(String) savedSink;

  setUp(() async {
    logLines = [];
    savedSink = logSink;
    logSink = logLines.add;
    tmp = Directory.systemTemp.createTempSync('cps_audit_id');
    config = sqliteConfig(tmp.path);
    repo = await Repository.open(config);
    api = Api(repo, await ArtifactStore.open(config), config);
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
    String? body,
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
        body: body ?? (json == null ? null : jsonEncode(json)),
      ),
    ),
  );

  Future<Map<String, dynamic>> jsonOf(Response r) async =>
      jsonDecode(await r.readAsString()) as Map<String, dynamic>;

  Future<List<Map<String, Object?>>> events({
    String? operation,
    int? orgId,
    String? appId,
    String? target,
    String? targetKind,
    String? result,
    int? after,
    int limit = 200,
  }) => repo.auditEvents(
    operations: operation == null ? const [] : [operation],
    orgId: orgId,
    appId: appId,
    target: target,
    targetKind: targetKind,
    result: result,
    after: after,
    limit: limit,
  );

  /// Request-outcome rows only. A `detail` row is a sub-fact of a request and
  /// must never be mistaken for its outcome.
  Future<List<Map<String, Object?>>> requestEvents(String operation) async =>
      (await events(
        operation: operation,
      )).where((e) => e['kind'] == 'request').toList();

  Map<String, Object?> detailOf(Map<String, Object?> e) =>
      jsonDecode((e['detail'] ?? '{}') as String) as Map<String, Object?>;

  /// Creates a user + API key through the operator route.
  Future<({int id, String email, String key})> makeUser(String email) async {
    final u = await jsonOf(
      await send('POST', '/admin/users?email=$email', bearer: _bootstrapKey),
    );
    return (
      id: u['user_id'] as int,
      email: u['email'] as String,
      key: u['api_key'] as String,
    );
  }

  /// Creates an app in the caller's OWN organization.
  ///
  /// `POST /api/v1/apps` defaults to the root org, which a freshly provisioned
  /// user is not a member of — so without the explicit `organization_id` this
  /// 403s and the app id comes back null.
  Future<String> makeApp(String bearer) async {
    final orgs = await jsonOf(
      await send('GET', '/api/v1/organizations', bearer: bearer),
    );
    final orgId =
        ((orgs['organizations'] as List).first as Map)['organization']['id'];
    final app = await jsonOf(
      await send(
        'POST',
        '/api/v1/apps',
        bearer: bearer,
        json: {'display_name': 'access', 'organization_id': orgId},
      ),
    );
    return app['id'] as String;
  }

  // -------------------------------------------------------------------------
  group('classification', () {
    List<String> segs(String p) => Uri.parse(p).pathSegments;

    test('identity and tenancy mutations are recognized', () {
      final cases = <(String, String, String)>[
        ('POST', '/admin/users', 'user.create'),
        ('POST', '/admin/orgs/1/invitations', 'org.invite'),
        ('DELETE', '/admin/orgs/1/invitations/sb_inv_abc', 'org.invite.revoke'),
        ('PATCH', '/admin/orgs/1/members/7', 'org.member.role'),
        ('DELETE', '/admin/orgs/1/members/7', 'org.member.remove'),
        ('PUT', '/admin/orgs/1/domains', 'org.domains'),
        ('POST', '/admin/apps/a1/collaborators', 'app.collaborator.add'),
        ('DELETE', '/admin/apps/a1/collaborators/7', 'app.collaborator.remove'),
        ('POST', '/api/v1/users', 'user.register'),
        ('POST', '/api/v1/invitations/sb_inv_abc/accept', 'org.invite.accept'),
      ];
      for (final (method, path, operation) in cases) {
        expect(
          classifyMutation(method, segs(path))?.operation,
          operation,
          reason: '$method $path',
        );
      }
    });

    test('the org and the target come from the path where they are there', () {
      final r = classifyMutation('PATCH', segs('/admin/orgs/4/members/9'))!;
      expect(r.orgId, 4);
      expect(r.targetKind, AuditTargetKind.user);
      expect(r.target, '9');
      final c = classifyMutation(
        'DELETE',
        segs('/admin/apps/app-1/collaborators/9'),
      )!;
      expect(c.appId, 'app-1');
      expect(c.target, '9');
    });

    test('an invitation token is fingerprinted, never carried', () {
      const token = 'sb_inv_0123456789abcdef';
      for (final r in [
        classifyMutation('DELETE', segs('/admin/orgs/1/invitations/$token'))!,
        classifyMutation('POST', segs('/api/v1/invitations/$token/accept'))!,
      ]) {
        expect(r.targetKind, AuditTargetKind.invitation);
        expect(r.target, credentialFingerprint(token));
        expect(r.target, isNot(contains(token)));
        expect(r.route, isNot(contains(token)));
        expect(r.route, contains('{token}'));
      }
      // The same token fingerprints identically on both routes, which is what
      // ties an invitation's issue / accept / revoke rows together.
      expect(
        classifyMutation(
          'DELETE',
          segs('/admin/orgs/1/invitations/$token'),
        )!.target,
        classifyMutation(
          'POST',
          segs('/api/v1/invitations/$token/accept'),
        )!.target,
      );
    });

    test('admin reads and login are not mutations', () {
      final notMutations = <(String, String)>[
        ('GET', '/admin/orgs/1/members'),
        ('GET', '/admin/orgs/1/invitations'),
        ('GET', '/admin/orgs/1/domains'),
        ('GET', '/admin/apps/a1/collaborators'),
        ('GET', '/admin/audit'),
        ('GET', '/api/v1/users/me'),
        ('GET', '/api/v1/organizations'),
        // PUBLIC routes. Classifying these would let an unauthenticated caller
        // write an audit row per request; a failed login writing one was a
        // real defect (see api_test.dart).
        ('POST', '/login'),
        ('GET', '/oauth/callback'),
        ('POST', '/token'),
        ('POST', '/api/v1/logout'),
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
  group('acceptance 1 — a successful identity mutation is typed exactly once', () {
    test('user.create records the account and a key FINGERPRINT', () async {
      final res = await send(
        'POST',
        '/admin/users?email=dev@example.com&name=Dev',
        bearer: _bootstrapKey,
      );
      expect(res.statusCode, 200);
      final body = await jsonOf(res);
      final key = body['api_key'] as String;

      final rows = await requestEvents('user.create');
      expect(rows, hasLength(1));
      final e = rows.single;
      expect(e['kind'], 'request');
      expect(e['result'], 'success');
      expect(e['http_status'], 200);
      expect(e['actor_id'], 1);
      expect(e['actor_credential'], startsWith('bootstrap:'));
      expect(e['target_kind'], 'user');
      expect(e['target'], 'dev@example.com');
      expect(e['request_id'], res.headers['x-request-id']);
      final d = detailOf(e);
      expect(d['user_id'], body['user_id']);
      expect(d['account_existed'], isFalse);
      // The issued credential is identified, and not stored.
      expect(d['api_key_issued'], credentialFingerprint(key));
      expect(jsonEncode(e), isNot(contains(key)));
    });

    test('a second key for an existing account says so', () async {
      await makeUser('dev@example.com');
      await send(
        'POST',
        '/admin/users?email=dev@example.com',
        bearer: _bootstrapKey,
      );
      final rows = await requestEvents('user.create');
      expect(rows, hasLength(2));
      expect(detailOf(rows.first)['account_existed'], isFalse);
      // The escalation shape this route has: it returns the EXISTING account on
      // an email conflict, so "a key was issued for an account that already
      // existed" is the thing an incident asks about first.
      expect(detailOf(rows.last)['account_existed'], isTrue);
      expect(
        detailOf(rows.first)['api_key_issued'],
        isNot(detailOf(rows.last)['api_key_issued']),
      );
    });

    test(
      'an app access grant names the app, the person and both roles',
      () async {
        final owner = await makeUser('owner@example.com');
        final appId = await makeApp(owner.key);
        final teammate = await makeUser('team@example.com');

        // Grant, then change the grant (addCollaborator upserts).
        await send(
          'POST',
          '/admin/apps/$appId/collaborators?email=${teammate.email}&role=developer',
          bearer: owner.key,
        );
        await send(
          'POST',
          '/admin/apps/$appId/collaborators?email=${teammate.email}&role=admin',
          bearer: owner.key,
        );

        final rows = await requestEvents('app.collaborator.add');
        expect(rows, hasLength(2));
        for (final e in rows) {
          expect(e['result'], 'success');
          expect(e['app_id'], appId);
          expect(e['target_kind'], 'user');
          expect(e['target'], teammate.email);
          expect(e['actor_id'], owner.id);
        }
        // The quiet privilege change is legible: developer -> admin.
        expect(detailOf(rows.first)['role_before'], isNull);
        expect(detailOf(rows.first)['role_after'], 'developer');
        expect(detailOf(rows.last)['role_before'], 'developer');
        expect(detailOf(rows.last)['role_after'], 'admin');
      },
    );

    test('an org role change banks the role it replaced', () async {
      final u = await makeUser('member@example.com');
      await send(
        'POST',
        '/admin/orgs/1/invitations?email=${u.email}&role=developer',
        bearer: _bootstrapKey,
      );
      // Join, so there is a membership to change.
      final inv = (await repo.orgInvitations(1)).single;
      await send(
        'POST',
        '/api/v1/invitations/${inv['token']}/accept',
        bearer: u.key,
      );
      final res = await send(
        'PATCH',
        '/admin/orgs/1/members/${u.id}?role=admin',
        bearer: _bootstrapKey,
      );
      expect(res.statusCode, 200);

      final e = (await requestEvents('org.member.role')).single;
      expect(e['result'], 'success');
      expect(e['org_id'], 1);
      expect(e['target_kind'], 'user');
      expect(e['target'], '${u.id}');
      expect(detailOf(e), containsPair('role_before', 'developer'));
      expect(detailOf(e), containsPair('role_after', 'admin'));
    });

    test('the domain policy records both sides', () async {
      await send(
        'PUT',
        '/admin/orgs/1/domains?domains=self-host.local',
        bearer: _bootstrapKey,
      );
      await send(
        'PUT',
        '/admin/orgs/1/domains?domains=',
        bearer: _bootstrapKey,
      );
      final rows = await requestEvents('org.domains');
      expect(rows, hasLength(2));
      expect(rows.every((e) => e['target_kind'] == 'org'), isTrue);
      expect(rows.every((e) => e['org_id'] == 1), isTrue);
      expect(detailOf(rows.first)['domains_before'], '');
      expect(detailOf(rows.first)['domains_after'], 'self-host.local');
      expect(detailOf(rows.last)['domains_before'], 'self-host.local');
      expect(detailOf(rows.last)['domains_after'], '');
    });

    test(
      'an invitation is correlated across issue, accept and revoke',
      () async {
        final u = await makeUser('joiner@example.com');
        await send(
          'POST',
          '/admin/orgs/1/invitations?email=${u.email}&role=developer',
          bearer: _bootstrapKey,
        );
        final issued = (await requestEvents('org.invite')).single;
        final fp = detailOf(issued)['invitation'] as String;
        expect(fp, hasLength(12));
        expect(issued['target'], u.email);
        expect(detailOf(issued)['role_after'], 'developer');

        final token = (await repo.orgInvitations(1)).single['token'] as String;
        expect(fp, credentialFingerprint(token));

        await send('POST', '/api/v1/invitations/$token/accept', bearer: u.key);
        final accepted = (await requestEvents('org.invite.accept')).single;
        expect(accepted['result'], 'success');
        expect(accepted['target_kind'], 'invitation');
        // The same fingerprint on both rows is what links them, and neither row
        // holds the token.
        expect(accepted['target'], fp);
        expect(detailOf(accepted)['role_after'], 'developer');
        expect(detailOf(accepted)['user_id'], u.id);

        // A revoke of a fresh invitation fingerprints the same way.
        await send(
          'POST',
          '/admin/orgs/1/invitations?email=other@example.com&role=developer',
          bearer: _bootstrapKey,
        );
        final live = (await repo.orgInvitations(
          1,
        )).firstWhere((i) => i['email'] == 'other@example.com');
        await send(
          'DELETE',
          '/admin/orgs/1/invitations/${live['token']}',
          bearer: _bootstrapKey,
        );
        final revoked = (await requestEvents('org.invite.revoke')).single;
        expect(revoked['result'], 'success');
        expect(
          revoked['target'],
          credentialFingerprint(live['token']! as String),
        );
        expect(detailOf(revoked)['email'], 'other@example.com');
        expect(detailOf(revoked)['role_before'], 'developer');
        expect(detailOf(revoked)['invitation_existed'], isTrue);
      },
    );

    test('a member removal names who was removed and their role', () async {
      final u = await makeUser('leaver@example.com');
      await send(
        'POST',
        '/admin/orgs/1/invitations?email=${u.email}&role=developer',
        bearer: _bootstrapKey,
      );
      final inv = (await repo.orgInvitations(1)).single;
      await send(
        'POST',
        '/api/v1/invitations/${inv['token']}/accept',
        bearer: u.key,
      );
      final res = await send(
        'DELETE',
        '/admin/orgs/1/members/${u.id}',
        bearer: _bootstrapKey,
      );
      expect(res.statusCode, 200);
      final e = (await requestEvents('org.member.remove')).single;
      expect(e['result'], 'success');
      expect(e['org_id'], 1);
      expect(e['target'], '${u.id}');
      expect(detailOf(e)['role_before'], 'developer');
      expect(detailOf(e)['email'], u.email);
    });

    test('an app access removal is typed too', () async {
      final owner = await makeUser('o2@example.com');
      final appId = await makeApp(owner.key);
      final teammate = await makeUser('t2@example.com');
      await send(
        'POST',
        '/admin/apps/$appId/collaborators?email=${teammate.email}&role=developer',
        bearer: owner.key,
      );
      await send(
        'DELETE',
        '/admin/apps/$appId/collaborators/${teammate.id}',
        bearer: owner.key,
      );
      final e = (await requestEvents('app.collaborator.remove')).single;
      expect(e['result'], 'success');
      expect(e['app_id'], appId);
      expect(e['target'], '${teammate.id}');
      expect(detailOf(e)['email'], teammate.email);
      expect(detailOf(e)['role_before'], 'developer');
    });
  });

  // -------------------------------------------------------------------------
  group('acceptance 2 — an unauthorized identity mutation is a typed refusal', () {
    test('a non-operator cannot issue credentials', () async {
      final tenant = await makeUser('tenant@example.com');
      final res = await send(
        'POST',
        '/admin/users?email=victim@example.com',
        bearer: tenant.key,
      );
      expect(res.statusCode, HttpStatus.forbidden);
      final e = (await requestEvents('user.create')).last;
      expect(e['result'], 'refused');
      expect(e['http_status'], 403);
      expect(e['actor_id'], tenant.id);
      expect(e['actor_credential'], startsWith('api_key:'));
      // No key was issued, so nothing claims one was.
      expect(detailOf(e)['api_key_issued'], isNull);
    });

    test('a non-admin cannot grant app access', () async {
      final owner = await makeUser('o3@example.com');
      final appId = await makeApp(owner.key);
      final teammate = await makeUser('t3@example.com');
      await send(
        'POST',
        '/admin/apps/$appId/collaborators?email=${teammate.email}&role=developer',
        bearer: owner.key,
      );
      // A `developer` collaborator may ship patches but must not add people.
      final res = await send(
        'POST',
        '/admin/apps/$appId/collaborators?email=outsider@example.com&role=owner',
        bearer: teammate.key,
      );
      expect(res.statusCode, HttpStatus.forbidden);
      final e = (await requestEvents('app.collaborator.add')).last;
      expect(e['result'], 'refused');
      expect(e['app_id'], appId);
      expect(e['actor_id'], teammate.id);
      // What they ASKED for survives the refusal — an attempt to grant `owner`
      // is the interesting fact here, not merely that a 403 happened.
      expect(e['target'], 'outsider@example.com');
      expect(detailOf(e)['role_after'], 'owner');
    });

    test('a non-member cannot change roles or the domain policy', () async {
      final tenant = await makeUser('tenant2@example.com');
      for (final (method, path, operation) in [
        ('PATCH', '/admin/orgs/1/members/1?role=developer', 'org.member.role'),
        ('DELETE', '/admin/orgs/1/members/1', 'org.member.remove'),
        ('PUT', '/admin/orgs/1/domains?domains=evil.test', 'org.domains'),
        (
          'POST',
          '/admin/orgs/1/invitations?email=x@evil.test&role=owner',
          'org.invite',
        ),
      ]) {
        final res = await send(method, path, bearer: tenant.key);
        expect(res.statusCode, HttpStatus.forbidden, reason: path);
        final e = (await requestEvents(operation)).last;
        expect(e['result'], 'refused', reason: operation);
        expect(e['org_id'], 1, reason: operation);
        expect(e['actor_id'], tenant.id, reason: operation);
      }
      // Nothing in that sweep reads as success.
      expect(
        (await events(orgId: 1)).where((e) => e['result'] == 'success'),
        isEmpty,
      );
    });

    test(
      'an unknown credential attempting an identity mutation is visible',
      () async {
        final res = await send(
          'POST',
          '/admin/users?email=victim@example.com',
          bearer: _canary,
        );
        expect(res.statusCode, HttpStatus.forbidden);
        final e = (await requestEvents('user.create')).single;
        expect(e['result'], 'refused');
        expect(e['actor_id'], isNull);
        expect(e['actor_credential'], startsWith('rejected:'));
        // Attributable to the credential that keeps presenting itself, without
        // the credential being stored.
        expect(e['actor_credential'], contains(credentialFingerprint(_canary)));
      },
    );
  });

  // -------------------------------------------------------------------------
  group('acceptance 3 — a failed or conflicting mutation is not success', () {
    test(
      'demoting the last owner conflicts and is recorded as refused',
      () async {
        final res = await send(
          'PATCH',
          '/admin/orgs/1/members/1?role=developer',
          bearer: _bootstrapKey,
        );
        expect(res.statusCode, HttpStatus.conflict);
        final e = (await requestEvents('org.member.role')).single;
        expect(e['result'], 'refused');
        expect(e['http_status'], 409);
        // Both sides of the change that did NOT happen.
        expect(detailOf(e)['role_before'], 'owner');
        expect(detailOf(e)['role_after'], 'developer');
        // And the membership really is untouched.
        expect(await repo.memberRole(1, 1), 'owner');
      },
    );

    test('removing the last owner conflicts', () async {
      final res = await send(
        'DELETE',
        '/admin/orgs/1/members/1',
        bearer: _bootstrapKey,
      );
      expect(res.statusCode, HttpStatus.conflict);
      final e = (await requestEvents('org.member.remove')).single;
      expect(e['result'], 'refused');
      expect(e['http_status'], 409);
    });

    test('a domain policy that would lock out every admin conflicts', () async {
      final res = await send(
        'PUT',
        '/admin/orgs/1/domains?domains=nobody.test',
        bearer: _bootstrapKey,
      );
      expect(res.statusCode, HttpStatus.conflict);
      final e = (await requestEvents('org.domains')).single;
      expect(e['result'], 'refused');
      expect(detailOf(e)['domains_after'], 'nobody.test');
      expect(await repo.orgAllowedDomains(1), isEmpty);
    });

    test(
      'an out-of-domain invitation is refused with its subject intact',
      () async {
        await send(
          'PUT',
          '/admin/orgs/1/domains?domains=self-host.local',
          bearer: _bootstrapKey,
        );
        final res = await send(
          'POST',
          '/admin/orgs/1/invitations?email=someone@gmail.com&role=developer',
          bearer: _bootstrapKey,
        );
        expect(res.statusCode, HttpStatus.forbidden);
        final e = (await requestEvents('org.invite')).single;
        expect(e['result'], 'refused');
        expect(e['target'], 'someone@gmail.com');
        expect(detailOf(e)['role_after'], 'developer');
        // No invitation was issued, so no fingerprint claims one was.
        expect(detailOf(e)['invitation'], isNull);
        expect(await repo.orgInvitations(1), isEmpty);
      },
    );

    test('an already-accepted invitation conflicts', () async {
      final u = await makeUser('twice@example.com');
      await send(
        'POST',
        '/admin/orgs/1/invitations?email=${u.email}&role=developer',
        bearer: _bootstrapKey,
      );
      final token = (await repo.orgInvitations(1)).single['token'] as String;
      await send('POST', '/api/v1/invitations/$token/accept', bearer: u.key);
      final res = await send(
        'POST',
        '/api/v1/invitations/$token/accept',
        bearer: u.key,
      );
      expect(res.statusCode, HttpStatus.conflict);
      final rows = await requestEvents('org.invite.accept');
      expect(rows, hasLength(2));
      expect(rows.first['result'], 'success');
      expect(rows.last['result'], 'refused');
      // Same invitation, so the same fingerprint on both.
      expect(rows.last['target'], rows.first['target']);
    });

    test(
      'no identity mutation in this history reads as success wrongly',
      () async {
        final tenant = await makeUser('sweep@example.com');
        final before = await repo.auditCeiling();
        await send('POST', '/admin/users?email=x@y.z', bearer: tenant.key);
        await send(
          'PATCH',
          '/admin/orgs/1/members/1?role=viewer',
          bearer: _bootstrapKey,
        );
        await send('DELETE', '/admin/orgs/1/members/1', bearer: _bootstrapKey);
        await send(
          'POST',
          '/admin/orgs/99/invitations?email=a@b.c',
          bearer: _bootstrapKey,
        );
        final rows = (await events(
          after: before,
        )).where((e) => e['kind'] == 'request').toList();
        expect(rows, isNotEmpty);
        expect(rows.every((e) => e['result'] != 'success'), isTrue);
        expect(rows.every((e) => (e['http_status']! as int) >= 400), isTrue);
      },
    );
  });

  // -------------------------------------------------------------------------
  group('acceptance 4 — request correlation', () {
    test('the response X-Request-Id names the identity audit row', () async {
      final res = await send(
        'POST',
        '/admin/users?email=corr@example.com',
        bearer: _bootstrapKey,
      );
      final rid = res.headers['x-request-id'];
      expect(rid, startsWith('req_'));
      final found = await jsonOf(
        await send(
          'GET',
          '/admin/audit?request_id=$rid',
          bearer: _bootstrapKey,
        ),
      );
      expect(found['count'], 1);
      final e = (found['events'] as List).single as Map;
      expect(e['operation'], 'user.create');
      expect(e['target'], 'corr@example.com');
    });

    test('a denied audit-log READ is still traceable', () async {
      // A read writes no mutation event by design, so the `admin.denied`
      // detail row is the only trace of someone probing the trail itself.
      final tenant = await makeUser('prober@example.com');
      final res = await send('GET', '/admin/audit', bearer: tenant.key);
      expect(res.statusCode, HttpStatus.forbidden);
      final rid = res.headers['x-request-id'];
      final denied = (await events(operation: 'admin.denied')).single;
      expect(denied['kind'], 'detail');
      expect(denied['request_id'], rid);
      expect(denied['target'], 'audit');
      expect(denied['actor_id'], tenant.id);
    });
  });

  // -------------------------------------------------------------------------
  group('acceptance 5 — secret canaries occur zero times', () {
    test(
      'neither an API-key nor an invitation-token canary is recorded',
      () async {
        final u = await makeUser('canary@example.com');
        logLines.clear();

        // Every place a caller controls, across the identity surface.
        await send(
          'POST',
          '/admin/users?email=new@example.com&name=$_canary',
          bearer: _bootstrapKey,
          headers: {'x-api-key': _canary},
        );
        await send(
          'POST',
          '/admin/orgs/1/invitations?email=${u.email}&role=developer&note=$_canary',
          bearer: _canary,
        );
        await send(
          'DELETE',
          '/admin/orgs/1/invitations/$_inviteCanary',
          bearer: _bootstrapKey,
        );
        await send(
          'POST',
          '/api/v1/invitations/$_inviteCanary/accept',
          bearer: u.key,
        );
        // A real invitation, so a REAL token is also in play and could leak.
        await send(
          'POST',
          '/admin/orgs/1/invitations?email=${u.email}&role=developer',
          bearer: _bootstrapKey,
        );
        final realToken =
            (await repo.orgInvitations(1)).single['token'] as String;
        await send(
          'POST',
          '/api/v1/invitations/$realToken/accept',
          bearer: u.key,
        );

        final auditLines = logLines
            .where((l) => l.startsWith('audit '))
            .toList();
        expect(auditLines, isNotEmpty, reason: 'the control must have output');
        final captured =
            '${auditLines.join('\n')}\n${jsonEncode(await events(limit: 1000))}';

        expect(_canary.allMatches(captured).length, 0);
        expect(_inviteCanary.allMatches(captured).length, 0);
        expect(captured, isNot(contains(realToken)));
        expect(captured, isNot(contains(u.key)));
        expect(captured, isNot(contains(_bootstrapKey)));
        // Not vacuous: the same capture holds the events and their subjects.
        expect(captured, contains('user.create'));
        expect(captured, contains('org.invite'));
        expect(captured, contains('canary@example.com'));
        // And the tokens ARE identified, by fingerprint.
        expect(captured, contains(credentialFingerprint(realToken)));
        expect(captured, contains(credentialFingerprint(_inviteCanary)));
      },
    );

    test('an invitation-token shape reaching free text is redacted', () async {
      expect(auditSafeText('token=$_inviteCanary'), 'token=[redacted]');
    });
  });

  // -------------------------------------------------------------------------
  group('acceptance 6 — admin reads write no mutation events', () {
    test('the whole read surface leaves the ceiling untouched', () async {
      final owner = await makeUser('reader@example.com');
      final appId = await makeApp(owner.key);
      final before = await repo.auditCeiling();
      for (final path in [
        '/admin/orgs/1/members',
        '/admin/orgs/1/invitations',
        '/admin/orgs/1/domains',
        '/admin/apps/$appId/collaborators',
        '/admin/audit',
        '/admin/audit?operation=user.create',
        '/api/v1/users/me',
        '/api/v1/organizations',
      ]) {
        await send('GET', path, bearer: _bootstrapKey);
      }
      expect(await repo.auditCeiling(), before);
    });

    test('a failed login still writes nothing', () async {
      // `/login` is PUBLIC. It stays unclassified so an unauthenticated caller
      // cannot pad the table, and the pre-existing guarantee holds.
      final before = await repo.auditCeiling();
      await send(
        'POST',
        '/login?continue=http://127.0.0.1:1234/',
        body: 'api_key=wrong',
        headers: {
          HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded',
        },
      );
      expect(await repo.auditCeiling(), before);
    });
  });

  // -------------------------------------------------------------------------
  group('acceptance 7 — detail is no longer the only evidence', () {
    test('every in-scope identity mutation writes a typed request row', () async {
      // The complete set of mutating identity/tenancy routes this server has.
      // If one is added later without a classifier entry, this fails.
      final owner = await makeUser('cover@example.com');
      final appId = await makeApp(owner.key);
      final joiner = await makeUser('cover2@example.com');

      await send(
        'POST',
        '/api/v1/users',
        bearer: owner.key,
        json: {'name': 'X'},
      );
      await send(
        'POST',
        '/admin/orgs/1/invitations?email=${joiner.email}&role=developer',
        bearer: _bootstrapKey,
      );
      final token = (await repo.orgInvitations(1)).single['token'] as String;
      await send(
        'POST',
        '/api/v1/invitations/$token/accept',
        bearer: joiner.key,
      );
      await send(
        'PATCH',
        '/admin/orgs/1/members/${joiner.id}?role=admin',
        bearer: _bootstrapKey,
      );
      await send(
        'DELETE',
        '/admin/orgs/1/members/${joiner.id}',
        bearer: _bootstrapKey,
      );
      await send(
        'PUT',
        '/admin/orgs/1/domains?domains=example.com',
        bearer: _bootstrapKey,
      );
      await send(
        'POST',
        '/admin/orgs/1/invitations?email=late@example.com&role=developer',
        bearer: _bootstrapKey,
      );
      final live = (await repo.orgInvitations(1)).single['token'] as String;
      await send(
        'DELETE',
        '/admin/orgs/1/invitations/$live',
        bearer: _bootstrapKey,
      );
      await send(
        'POST',
        '/admin/apps/$appId/collaborators?email=${joiner.email}&role=developer',
        bearer: owner.key,
      );
      await send(
        'DELETE',
        '/admin/apps/$appId/collaborators/${joiner.id}',
        bearer: owner.key,
      );

      for (final operation in [
        'user.create',
        'user.register',
        'org.invite',
        'org.invite.accept',
        'org.invite.revoke',
        'org.member.role',
        'org.member.remove',
        'org.domains',
        'app.collaborator.add',
        'app.collaborator.remove',
      ]) {
        final rows = await requestEvents(operation);
        expect(rows, isNotEmpty, reason: '$operation has no typed request row');
        expect(
          rows.every((e) => e['result'] != null && e['http_status'] != null),
          isTrue,
          reason: '$operation row is missing result/http_status',
        );
      }
    });

    test(
      'no identity operation writes BOTH a typed row and a duplicate note',
      () async {
        // The old free-text rows were replaced, not supplemented: a second row
        // under the same operation name would double-count every mutation.
        final u = await makeUser('dup@example.com');
        await send(
          'POST',
          '/admin/orgs/1/invitations?email=${u.email}&role=developer',
          bearer: _bootstrapKey,
        );
        for (final operation in ['user.create', 'org.invite']) {
          final all = await events(operation: operation);
          expect(
            all.where((e) => e['kind'] == 'detail'),
            isEmpty,
            reason: '$operation still writes a detail row too',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  group('acceptance 8 — "who changed access to app X?"', () {
    test('one call answers it, attempts included', () async {
      final owner = await makeUser('lead@example.com');
      final appId = await makeApp(owner.key);
      final other = await makeApp(owner.key);
      final teammate = await makeUser('mate@example.com');
      final outsider = await makeUser('outsider@example.com');

      // Granted, then removed.
      await send(
        'POST',
        '/admin/apps/$appId/collaborators?email=${teammate.email}&role=developer',
        bearer: owner.key,
      );
      await send(
        'DELETE',
        '/admin/apps/$appId/collaborators/${teammate.id}',
        bearer: owner.key,
      );
      // Attempted by someone with no business doing it.
      await send(
        'POST',
        '/admin/apps/$appId/collaborators?email=${outsider.email}&role=owner',
        bearer: outsider.key,
      );
      // Noise on another app, which must not appear.
      await send(
        'POST',
        '/admin/apps/$other/collaborators?email=${teammate.email}&role=developer',
        bearer: owner.key,
      );

      final body = await jsonOf(
        await send(
          'GET',
          '/admin/audit?app_id=$appId'
              '&operation=app.collaborator.add,app.collaborator.remove',
          bearer: _bootstrapKey,
        ),
      );
      final rows = (body['events'] as List).cast<Map<String, Object?>>();
      expect(rows, hasLength(3));
      expect(rows.every((e) => e['app_id'] == appId), isTrue);
      expect(rows.map((e) => '${e['operation']}:${e['result']}').toList(), [
        'app.collaborator.add:success',
        'app.collaborator.remove:success',
        'app.collaborator.add:refused',
      ]);
      // Who, to whom, and what they wanted.
      expect(rows[0]['actor'], owner.email);
      expect(rows[0]['target'], teammate.email);
      expect(rows[2]['actor'], outsider.email);
      expect(rows[2]['target'], outsider.email);
      expect(detailOf(rows[2])['role_after'], 'owner');
    });

    test(
      'and "what has been done to this person?" across both surfaces',
      () async {
        final u = await makeUser('subject@example.com');
        await send(
          'POST',
          '/admin/orgs/1/invitations?email=${u.email}&role=developer',
          bearer: _bootstrapKey,
        );
        final body = await jsonOf(
          await send(
            'GET',
            '/admin/audit?target_kind=user&target=${u.email}',
            bearer: _bootstrapKey,
          ),
        );
        final ops = [
          for (final e in body['events'] as List) (e as Map)['operation'],
        ];
        expect(ops, containsAll(['user.create', 'org.invite']));
      },
    );

    test(
      'an unknown target_kind is a 400, not a silently empty answer',
      () async {
        final res = await send(
          'GET',
          '/admin/audit?target_kind=principal',
          bearer: _bootstrapKey,
        );
        expect(res.statusCode, HttpStatus.badRequest);
      },
    );
  });
}
