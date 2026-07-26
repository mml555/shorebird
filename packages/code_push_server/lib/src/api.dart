import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:code_push_server/src/analytics.dart';
import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/content_range.dart';
import 'package:code_push_server/src/domain.dart';
import 'package:code_push_server/src/oauth.dart';
import 'package:code_push_server/src/observability.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:code_push_server/src/rollout.dart';
import 'package:code_push_server/src/signing.dart';
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';

/// The rate-limit bucket key. Authenticated requests bucket by their bearer;
/// unauthenticated (device) requests bucket by client IP — so one device (or
/// one spoofed request) can't exhaust a single shared window for the whole
/// fleet. Behind a proxy, [forwardedFor] (the first X-Forwarded-For hop) wins;
/// otherwise the socket [remoteIp] is used.
String rateLimitKey({String? auth, String? forwardedFor, String? remoteIp}) {
  if (auth != null && auth.isNotEmpty) return 'auth:$auth';
  if (forwardedFor != null && forwardedFor.isNotEmpty) {
    return 'ip:${forwardedFor.split(',').first.trim()}';
  }
  return 'ip:${remoteIp ?? 'unknown'}';
}

/// The HTTP surface: the Shorebird CLI/updater wire contract (translated to the
/// internal domain here), an OAuth auth service (`shorebird login`), and an
/// authenticated /admin surface (rollout, withdraw/rollback, provisioning).
class Api {
  Api(this.repo, this.store, this.config, {String? signingKeyJson})
    : oauth = OAuthService(config.jwtIssuer, keyJson: signingKeyJson),
      _signer = UrlSigner(config.urlSigningSecret),
      _analytics = Analytics(repo.db),
      obs = Observability(json: config.logFormat == 'json');

  final Repository repo;
  final ArtifactStore store;
  final Config config;
  final OAuthService oauth;
  final UrlSigner _signer;
  final Analytics _analytics;

  /// Structured logging + Prometheus metrics (exposed at `GET /metrics`).
  final Observability obs;

  final _RateLimiter _rateLimiter = _RateLimiter();
  // Short-lived CSRF state -> loopback `continue` URL for the IdP broker flow.
  final Map<String, String> _idpState = {};

  Handler get handler => const Pipeline()
      .addMiddleware(_logRequests())
      .addMiddleware(_rateLimit())
      .addMiddleware(_auth())
      .addHandler(_route);

  // ---- middleware ----

  Middleware _logRequests() =>
      (inner) => (req) async {
        final sw = Stopwatch()..start();
        obs.metrics.inFlight++;
        try {
          final res = await inner(req);
          sw.stop();
          obs.request(
            req.method,
            req.url.path,
            res.statusCode,
            sw.elapsedMilliseconds,
          );
          return res;
        } finally {
          obs.metrics.inFlight--;
        }
      };

  Middleware _rateLimit() =>
      (inner) => (req) async {
        final conn = req.context['shelf.io.connection_info'];
        final key = rateLimitKey(
          auth: req.headers['authorization'],
          forwardedFor: req.headers['x-forwarded-for'],
          remoteIp: conn is HttpConnectionInfo
              ? conn.remoteAddress.address
              : null,
        );
        final bool ok;
        if (config.rateLimitShared) {
          // Shared fixed window in Postgres — correct across restarts + nodes.
          final window = DateTime.now().millisecondsSinceEpoch ~/ 60000;
          final count = await repo.incrementRateWindow(key, window);
          ok = count <= config.rateLimitPerMinute;
        } else {
          ok = _rateLimiter.allow(key, config.rateLimitPerMinute);
        }
        if (!ok) return _err(429, 'rate_limited', 'Too many requests');
        return inner(req);
      };

  bool _isPublic(List<String> seg) {
    if (seg.isEmpty) return true; // health
    if (seg.length == 1 &&
        (seg[0] == 'healthz' || seg[0] == 'readyz' || seg[0] == 'metrics')) {
      return true;
    }
    if (seg.length == 2 && seg[0] == 'admin' && seg[1] == 'ui') {
      return true; // static page
    }
    if (seg.length == 2 && seg[0] == 'diagnostics' && seg[1] == 'speedtest') {
      return true;
    }
    if (seg.isNotEmpty && seg[0] == 'console') return true; // static UI
    if (seg.first == 'download') return true;
    // Auth-service endpoints (no bearer yet at login time).
    if (seg.length == 1 && (seg[0] == 'login' || seg[0] == 'token')) {
      return true;
    }
    if (seg.length == 2 && seg[0] == 'oauth' && seg[1] == 'callback') {
      return true;
    }
    if (seg.length == 2 && seg[0] == 'api' && seg[1] == 'logout') return true;
    if (seg.length == 2 && seg[0] == '.well-known' && seg[1] == 'jwks.json') {
      return true;
    }
    final tail = seg.first == 'api' && seg.length > 2 ? seg.sublist(2) : seg;
    return tail.length == 2 &&
        tail[0] == 'patches' &&
        (tail[1] == 'check' || tail[1] == 'events');
  }

  Middleware _auth() =>
      (inner) => (req) async {
        if (_isPublic(req.url.pathSegments)) return inner(req);
        final auth = req.headers['authorization'];
        final key = (auth != null && auth.startsWith('Bearer '))
            ? auth.substring('Bearer '.length)
            : null;
        if (key == null) {
          return _err(
            HttpStatus.forbidden,
            'forbidden',
            'Missing bearer token',
          );
        }
        int? userId;
        if (key.split('.').length == 3) {
          // Looks like a JWT (OAuth login credential): verify and map to a user.
          final email = await oauth.emailFromToken(key);
          if (email != null) {
            final user =
                await repo.userByEmail(email) ??
                await repo.upsertUser(email, null);
            userId = user.id;
          }
        } else if (key == config.bootstrapApiKey) {
          userId = 1;
        } else {
          userId = await repo.userIdForApiKey(key);
        }
        if (userId == null) {
          return _err(HttpStatus.forbidden, 'forbidden', 'Invalid credentials');
        }
        return inner(req.change(context: {'userId': userId}));
      };

  // ---- routing ----

  Future<Response> _route(Request req) async {
    try {
      return await _dispatch(req);
    } on DomainException catch (e) {
      return _err(e.statusCode, e.code, e.message);
    } catch (e, st) {
      obs.error('unhandled request error', e, st);
      return _err(HttpStatus.internalServerError, 'internal', '$e');
    }
  }

  int _uid(Request req) => (req.context['userId'] as int?) ?? 1;

  Future<Response> _dispatch(Request req) async {
    var seg = req.url.pathSegments;
    final m = req.method;
    if (seg.isEmpty) return Response.ok('code_push_server ok');

    if (seg.length == 1 && seg[0] == 'healthz' && m == 'GET') {
      return Response.ok('ok');
    }
    if (seg.length == 2 && seg[0] == 'admin' && seg[1] == 'ui' && m == 'GET') {
      return Response.ok(
        _adminHtml,
        headers: {HttpHeaders.contentTypeHeader: 'text/html'},
      );
    }
    if (seg.length == 1 && seg[0] == 'metrics' && m == 'GET') {
      return Response.ok(
        obs.metrics.render(),
        headers: {
          HttpHeaders.contentTypeHeader:
              'text/plain; version=0.0.4; charset=utf-8',
        },
      );
    }
    if (seg.length == 1 && seg[0] == 'readyz' && m == 'GET') {
      final db = await repo.ping();
      final objectStore = await store.ping();
      return Response(
        db && objectStore ? HttpStatus.ok : HttpStatus.serviceUnavailable,
        body: jsonEncode({'db': db, 'object_store': objectStore}),
        headers: {HttpHeaders.contentTypeHeader: 'application/json'},
      );
    }

    if (seg.length == 2 && seg[0] == 'download' && m == 'GET') {
      return _download(req, seg[1]);
    }

    // `shorebird doctor` network check: a public byte source/sink.
    if (seg.length == 2 && seg[0] == 'diagnostics' && seg[1] == 'speedtest') {
      return _speedtest(req);
    }
    // Web console (static single-page app).
    if (seg.isNotEmpty && seg[0] == 'console' && m == 'GET') return _console();

    // OAuth auth service (shorebird login).
    if (seg.length == 1 && seg[0] == 'login' && m == 'GET') return _login(req);
    if (seg.length == 2 &&
        seg[0] == 'oauth' &&
        seg[1] == 'callback' &&
        m == 'GET') {
      return _oauthCallback(req);
    }
    if (seg.length == 1 && seg[0] == 'token' && m == 'POST') return _token(req);
    if (seg.length == 2 &&
        seg[0] == 'api' &&
        seg[1] == 'logout' &&
        m == 'POST') {
      return _logout(req);
    }
    if (seg.length == 2 && seg[0] == '.well-known' && seg[1] == 'jwks.json') {
      return _json(oauth.jwks());
    }

    final devTail = seg.first == 'api' && seg.length > 2 ? seg.sublist(2) : seg;
    if (devTail.length == 2 && devTail[0] == 'patches' && m == 'POST') {
      if (devTail[1] == 'check') return _patchesCheck(req);
      if (devTail[1] == 'events') return _patchesEvents(req);
    }

    if (seg.isNotEmpty && seg[0] == 'admin') return _admin(req, seg.sublist(1));

    if (seg.length < 2 || seg[0] != 'api' || seg[1] != 'v1') {
      return _err(
        HttpStatus.notFound,
        'not_found',
        'No route /${req.url.path}',
      );
    }
    seg = seg.sublist(2);

    if (seg.length == 1 && seg[0] == 'organizations' && m == 'GET') {
      return _organizations(req);
    }
    if (seg.length == 2 && seg[0] == 'users' && seg[1] == 'me' && m == 'GET') {
      return _usersMe(req);
    }
    if (seg.length == 1 && seg[0] == 'users' && m == 'POST') {
      return _createUser(req);
    }
    if (seg.length == 3 &&
        seg[0] == 'invitations' &&
        seg[2] == 'accept' &&
        m == 'POST') {
      return _acceptInvitation(req, seg[1]);
    }
    if (seg.length == 2 && seg[0] == 'diagnostics' && m == 'GET') {
      if (seg[1] == 'gcp_upload') {
        return _json({
          'upload_url': '${config.publicBaseUrl}/diagnostics/speedtest',
        });
      }
      if (seg[1] == 'gcp_download') {
        return _json({
          'download_url':
              '${config.publicBaseUrl}/diagnostics/speedtest?size=1048576',
        });
      }
    }
    if (seg.length == 1 && seg[0] == 'apps') {
      if (m == 'POST') return _createApp(req);
      if (m == 'GET') return _getApps(req);
    }
    if (seg.length == 2 && seg[0] == 'uploads' && m == 'POST') {
      return _upload(req, seg[1]);
    }
    if (seg.length == 2 && seg[0] == 'uploads' && m == 'PUT') {
      return _resumableUpload(req, seg[1]);
    }

    if (seg.length >= 2 && seg[0] == 'apps') {
      final appId = seg[1];
      await _authorizeApp(req, appId);
      final rest = seg.sublist(2);
      if (rest.length == 1 && rest[0] == 'channels') {
        if (m == 'GET') return _getChannels(appId);
        if (m == 'POST') return _createChannel(req, appId);
      }
      if (rest.length == 1 && rest[0] == 'metrics' && m == 'GET') {
        return _metrics(appId);
      }
      if (rest.length == 2 && rest[0] == 'analytics' && m == 'GET') {
        final q = req.url.queryParameters;
        final gran = q['granularity'];
        switch (rest[1]) {
          case 'patch-adoption':
            return _json(
              await _analytics.patchAdoption(
                appId,
                releaseVersion: q['release_version'],
                granularity: gran,
                start: q['start'] != null ? DateTime.parse(q['start']!) : null,
                end: q['end'] != null ? DateTime.parse(q['end']!) : null,
              ),
            );
          case 'unique-users':
            return _json(
              await _analytics.uniqueUsers(
                appId,
                windowDays: int.tryParse(q['window_days'] ?? '') ?? 30,
                granularity: gran,
                groupBy: q['group_by'],
              ),
            );
          case 'version-distribution':
            return _json(
              await _analytics.versionDistribution(
                appId,
                activeWindowDays:
                    int.tryParse(q['active_window_days'] ?? '') ?? 30,
              ),
            );
          case 'activity-heatmap':
            return _json(
              await _analytics.activityHeatmap(
                appId,
                lookbackDays: int.tryParse(q['lookback_days'] ?? '') ?? 28,
              ),
            );
          case 'active-hours':
            return _json(
              await _analytics.activeHours(
                appId,
                lookbackDays: int.tryParse(q['lookback_days'] ?? '') ?? 28,
              ),
            );
          case 'new-devices':
            return _json(
              await _analytics.newDevices(
                appId,
                windowDays: int.tryParse(q['window_days'] ?? '') ?? 30,
              ),
            );
          case 'patch-installs':
          case 'patch-downloads':
            return _json(
              await _analytics.patchMetric(
                appId,
                metric: rest[1] == 'patch-downloads' ? 'downloads' : 'installs',
                windowDays: int.tryParse(q['window_days'] ?? '') ?? 30,
                granularity: gran,
                groupBy: q['group_by'],
                releaseVersion: q['release_version'],
                patchNumber: int.tryParse(q['patch_number'] ?? ''),
              ),
            );
        }
      }
      if (rest.length == 1 && rest[0] == 'patches' && m == 'POST') {
        return _createPatch(req, appId);
      }
      if (rest.length == 2 &&
          rest[0] == 'patches' &&
          rest[1] == 'promote' &&
          m == 'POST') {
        return _promotePatch(req, appId);
      }
      if (rest.length == 3 &&
          rest[0] == 'patches' &&
          rest[2] == 'artifacts' &&
          m == 'POST') {
        return _createPatchArtifact(req, appId, int.parse(rest[1]));
      }
      if (rest.length == 1 && rest[0] == 'releases') {
        if (m == 'POST') return _createRelease(req, appId);
        if (m == 'GET') return _getReleases(appId);
      }
      if (rest.length == 2 && rest[0] == 'releases' && m == 'PATCH') {
        return _updateRelease(req, appId, int.parse(rest[1]));
      }
      if (rest.length == 3 && rest[0] == 'releases' && rest[2] == 'artifacts') {
        final releaseId = int.parse(rest[1]);
        if (m == 'POST') return _createReleaseArtifact(req, appId, releaseId);
        if (m == 'GET') return _getReleaseArtifacts(req, releaseId);
      }
      if (rest.length == 3 &&
          rest[0] == 'releases' &&
          rest[2] == 'patches' &&
          m == 'GET') {
        return _getReleasePatches(int.parse(rest[1]));
      }
    }

    return _err(
      HttpStatus.notFound,
      'not_found',
      'No route $m /${req.url.path}',
    );
  }

  // ---- OAuth auth service ----

  /// GET `/login?continue=<loopback>`: auto-consents as the configured identity
  /// (self-host has no external IdP) and redirects to the loopback with a code.
  Future<Response> _login(Request req) async {
    final cont = req.url.queryParameters['continue'];
    if (cont == null) {
      return _err(HttpStatus.badRequest, 'bad_request', 'continue required');
    }

    // Broker mode: bounce to the external IdP; the real email arrives at
    // /oauth/callback, which then issues our own code back to `continue`.
    if (config.idpEnabled) {
      final state = OAuthService.randomToken('sb_state_');
      _idpState[state] = cont;
      final authUri = Uri.parse(config.idpAuthorizeUrl).replace(
        queryParameters: {
          'response_type': 'code',
          'client_id': config.idpClientId,
          'redirect_uri': '${config.publicBaseUrl}/oauth/callback',
          'scope': config.idpScopes,
          'state': state,
        },
      );
      return Response.found(authUri.toString());
    }

    // Self-consent (single-tenant / dev): no external IdP.
    final email =
        req.url.queryParameters['email'] ??
        Platform.environment['LOGIN_EMAIL'] ??
        'owner@self-host.local';
    final code = OAuthService.randomToken('sb_code_');
    await repo.insertAuthCode(
      code,
      email,
      DateTime.now().add(const Duration(minutes: 5)),
    );
    final sep = cont.contains('?') ? '&' : '?';
    return Response.found('$cont${sep}code=$code');
  }

  /// External-IdP redirect target: exchange the IdP code for the user's email,
  /// then hand our own code back to the CLI's loopback (`continue`).
  Future<Response> _oauthCallback(Request req) async {
    final q = req.url.queryParameters;
    final cont = _idpState.remove(q['state']);
    if (cont == null) {
      return _err(HttpStatus.badRequest, 'bad_request', 'Invalid state');
    }
    if (q['error'] != null) return Response.found('$cont?error=${q['error']}');
    final idpCode = q['code'];
    if (idpCode == null) return Response.found('$cont?error=missing_code');

    final tokenResp = await _idpTokenExchange(idpCode);
    final email = OAuthService.emailFromIdToken(tokenResp);
    if (email == null) return Response.found('$cont?error=no_email');

    final code = OAuthService.randomToken('sb_code_');
    await repo.insertAuthCode(
      code,
      email,
      DateTime.now().add(const Duration(minutes: 5)),
    );
    final sep = cont.contains('?') ? '&' : '?';
    return Response.found('$cont${sep}code=$code');
  }

  /// POSTs the authorization code to the IdP token endpoint (form-encoded).
  Future<Map<String, dynamic>> _idpTokenExchange(String code) async {
    final body =
        {
              'grant_type': 'authorization_code',
              'code': code,
              'redirect_uri': '${config.publicBaseUrl}/oauth/callback',
              'client_id': config.idpClientId,
              'client_secret': config.idpClientSecret,
            }.entries
            .map(
              (e) =>
                  '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
            )
            .join('&');
    final client = HttpClient();
    try {
      final r = await client.postUrl(Uri.parse(config.idpTokenUrl));
      r.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/x-www-form-urlencoded',
      );
      r.headers.set(HttpHeaders.acceptHeader, 'application/json');
      r.write(body);
      final resp = await r.close();
      final text = await resp.transform(utf8.decoder).join();
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// POST /token (form-encoded): authorization_code or refresh_token grant.
  /// Codes and refresh tokens are single-use and persisted in Postgres, so
  /// sessions survive restarts and a code/refresh cannot be replayed.
  Future<Response> _token(Request req) async {
    final form = Uri.splitQueryString(await req.readAsString());
    final grant = form['grant_type'];
    String? email;
    if (grant == 'authorization_code') {
      email = await repo.consumeAuthCode(form['code'] ?? '');
    } else if (grant == 'refresh_token') {
      email = await repo.consumeRefreshToken(form['refresh_token'] ?? '');
    } else {
      return _err(
        HttpStatus.badRequest,
        'unsupported_grant_type',
        'grant_type',
      );
    }
    if (email == null) {
      return _err(
        HttpStatus.badRequest,
        'invalid_grant',
        'Invalid code/refresh token',
      );
    }
    final refresh = OAuthService.randomToken('sb_rt_');
    await repo.insertRefreshToken(refresh, email);
    return _json({
      'access_token': oauth.mintAccessToken(email),
      'refresh_token': refresh,
      'token_type': 'Bearer',
      'expires_in': 900,
    });
  }

  /// POST /api/logout: bearer is the refresh token; revoke and 200.
  Future<Response> _logout(Request req) async {
    final auth = req.headers['authorization'];
    if (auth != null && auth.startsWith('Bearer ')) {
      await repo.revokeRefreshToken(auth.substring('Bearer '.length));
    }
    return Response.ok(
      '{}',
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
    );
  }

  Future<Response> _acceptInvitation(Request req, String token) async {
    final inv = await repo.invitation(token);
    if (inv == null) throw notFound('Unknown invitation');
    if (inv['accepted_at'] != null) {
      throw conflict('Invitation already accepted');
    }
    final exp = inv['expires_at'];
    if (exp is DateTime && DateTime.now().toUtc().isAfter(exp.toUtc())) {
      throw conflict('Invitation expired');
    }
    final user = await repo.userById(_uid(req));
    if (user == null) throw notFound('No user');
    if (user.email.toLowerCase() != (inv['email'] as String).toLowerCase()) {
      throw DomainException(
        HttpStatus.forbidden,
        'forbidden',
        'Invitation is for a different email',
      );
    }
    await repo.acceptInvitation(
      token,
      user.id,
      inv['org_id'] as int,
      inv['role'] as String,
    );
    await repo.audit(
      'org.invite.accept',
      actor: '${user.id}',
      target: '${inv['org_id']}',
    );
    return _json({'joined_org': inv['org_id'], 'role': inv['role']});
  }

  Future<Response> _usersMe(Request req) async {
    final user = await repo.userById(_uid(req));
    if (user == null) return _err(HttpStatus.notFound, 'not_found', 'No user');
    return _json(_privateUser(user));
  }

  Future<Response> _createUser(Request req) async {
    // The CLI posts {name}; identity (email) comes from the authed JWT/user.
    final body = await _jsonBody(req);
    final current = await repo.userById(_uid(req));
    final user = await repo.upsertUser(
      current?.email ?? 'owner@self-host.local',
      body['name'] as String?,
    );
    return _json(_privateUser(user));
  }

  Map<String, Object?> _privateUser(UserRow u) => {
    'id': u.id,
    'email': u.email,
    'display_name': u.displayName,
    'has_active_subscription': true,
    'jwt_issuer': config.jwtIssuer,
    'stripe_customer_id': null,
    'patch_overage_limit': null,
  };

  // ---- CLI contract ----

  Future<Response> _organizations(Request req) async {
    final ms = await repo.memberships(_uid(req));
    return _json({
      'organizations': [
        for (final m in ms)
          {
            'organization': {
              'id': m.orgId,
              'name': m.orgName,
              'organization_type': m.orgType,
              'created_at': m.createdAt,
              'updated_at': m.updatedAt,
            },
            'role': m.role,
          },
      ],
    });
  }

  Future<Response> _createApp(Request req) async {
    final body = await _jsonBody(req);
    final orgId = (body['organization_id'] as int?) ?? 1;
    if (!await repo.userInOrg(_uid(req), orgId)) {
      throw DomainException(
        HttpStatus.forbidden,
        'forbidden',
        'Not a member of org $orgId',
      );
    }
    final app = await repo.createApp(
      body['display_name'] as String? ?? 'app',
      orgId,
    );
    await repo.audit('app.create', actor: '${_uid(req)}', target: app.appId);
    return _json({'id': app.appId, 'display_name': app.displayName});
  }

  /// Authorizes the caller for [appId] via org membership or collaboration.
  Future<void> _authorizeApp(Request req, String appId) async {
    if (!await repo.userCanAccessApp(_uid(req), appId)) {
      throw DomainException(
        HttpStatus.forbidden,
        'forbidden',
        'No access to app $appId',
      );
    }
  }

  Future<Response> _getApps(Request req) async {
    final orgIds = (await repo.memberships(
      _uid(req),
    )).map((m) => m.orgId).toList();
    final apps = await repo.apps(orgIds: orgIds);
    final out = <Map<String, Object?>>[];
    for (final a in apps) {
      final rels = await repo.releases(a.appId);
      final platforms = <String>{};
      for (final r in rels) {
        platforms.addAll(r.platformStatuses.keys);
      }
      out.add({
        'app_id': a.appId,
        'display_name': a.displayName,
        'latest_release_version': rels.isEmpty ? null : rels.last.version,
        'latest_patch_number': await repo.latestPatchNumberForApp(a.appId),
        'created_at': a.createdAt,
        'updated_at': a.updatedAt,
        if (platforms.isNotEmpty) 'platforms': platforms.toList(),
      });
    }
    return _json({'apps': out});
  }

  Future<Response> _createRelease(Request req, String appId) async {
    final body = await _jsonBody(req);
    final r = await repo.createRelease(
      appId: appId,
      version: body['version'] as String,
      flutterRevision: body['flutter_revision'] as String?,
      flutterVersion: body['flutter_version'] as String?,
      displayName: body['display_name'] as String?,
    );
    return _json({'release': _releaseJson(r)});
  }

  Future<Response> _getReleases(String appId) async {
    final rels = await repo.releases(appId);
    return _json({'releases': rels.map(_releaseJson).toList()});
  }

  Future<Response> _updateRelease(
    Request req,
    String appId,
    int releaseId,
  ) async {
    final body = await _jsonBody(req);
    final release = await repo.release(releaseId);
    if (release == null) throw notFound('No release $releaseId');
    final status = body['status'] as String?;
    final platform = body['platform'] as String?;
    if (status != null && platform != null) {
      await repo.setReleasePlatformStatus(releaseId, platform, status);
      if (status == 'active') {
        // Scope the "all verified" gate to the platform being activated, so a
        // multi-platform release (or add-to-app sharing a platform) isn't gated
        // on other platforms' artifacts at the same version.
        final live = (await repo.releaseArtifacts(
          releaseId,
          platform: platform,
        )).where((a) => a.status != ArtifactStatus.failed).toList();
        final allVerified =
            live.isNotEmpty &&
            live.every((a) => a.status == ArtifactStatus.verified);
        if (!allVerified) {
          throw conflict(
            'Release $releaseId ($platform) has unverified artifacts',
          );
        }
        if (release.lifecycle != ReleaseLifecycle.ready) {
          await repo.setReleaseLifecycle(releaseId, ReleaseLifecycle.ready);
          await repo.audit(
            'release.ready',
            actor: '${_uid(req)}',
            target: '$releaseId',
          );
        }
      }
    }
    return Response(HttpStatus.noContent);
  }

  Future<Response> _createPatch(Request req, String appId) async {
    final body = await _jsonBody(req);
    final releaseId = body['release_id'] as int;
    if (await repo.release(releaseId) == null) {
      throw notFound('No release $releaseId');
    }
    final p = await repo.createPatch(appId, releaseId);
    return _json({'id': p.id, 'number': p.number, 'notes': null});
  }

  Future<Response> _createReleaseArtifact(
    Request req,
    String appId,
    int releaseId,
  ) async {
    final release = await repo.release(releaseId);
    if (release == null) throw notFound('No release $releaseId');
    if (release.lifecycle == ReleaseLifecycle.draft) {
      await repo.setReleaseLifecycle(releaseId, ReleaseLifecycle.uploading);
    }
    final (fields, _) = await _parseMultipart(req);
    if (await repo.existingArtifact(
          'release',
          releaseId,
          fields['arch']!,
          fields['platform']!,
        ) !=
        null) {
      throw conflict(
        'Artifact already registered for ${fields['arch']}/${fields['platform']}',
      );
    }
    final art = await repo.createArtifact(
      ownerKind: 'release',
      ownerId: releaseId,
      arch: fields['arch']!,
      platform: fields['platform']!,
      hash: fields['hash']!,
      size: int.tryParse(fields['size'] ?? '0') ?? 0,
      podfileLockHash: fields['podfile_lock_hash'],
      canSideload: fields['can_sideload'] == 'true',
    );
    return _json(_registerJson(art, releaseKey: true));
  }

  Future<Response> _createPatchArtifact(
    Request req,
    String appId,
    int patchId,
  ) async {
    final patch = await repo.patch(patchId);
    if (patch == null) throw notFound('No patch $patchId');
    requirePatchTransition(patch.status, PatchStatus.uploading);
    await repo.setPatchStatus(patchId, PatchStatus.uploading);
    final (fields, _) = await _parseMultipart(req);
    if (await repo.existingArtifact(
          'patch',
          patchId,
          fields['arch']!,
          fields['platform']!,
        ) !=
        null) {
      throw conflict(
        'Artifact already registered for ${fields['arch']}/${fields['platform']}',
      );
    }
    final art = await repo.createArtifact(
      ownerKind: 'patch',
      ownerId: patchId,
      arch: fields['arch']!,
      platform: fields['platform']!,
      hash: fields['hash']!,
      size: int.tryParse(fields['size'] ?? '0') ?? 0,
      hashSignature: fields['hash_signature'],
      podfileLockHash: fields['podfile_lock_hash'],
    );
    return _json(_registerJson(art, releaseKey: false));
  }

  Future<Response> _getReleaseArtifacts(Request req, int releaseId) async {
    final arch = req.url.queryParameters['arch'];
    final platform = req.url.queryParameters['platform'];
    final arts = await repo.releaseArtifacts(
      releaseId,
      arch: arch,
      platform: platform,
    );
    return _json({
      'artifacts': [
        for (final a in arts)
          {
            'id': a.id,
            'release_id': a.ownerId,
            'arch': a.arch,
            'platform': a.platform,
            'hash': a.hash,
            'size': a.size,
            'url': _signedUrl(a.token),
            'podfile_lock_hash': a.podfileLockHash,
            'can_sideload': a.canSideload,
          },
      ],
    });
  }

  Future<Response> _createChannel(Request req, String appId) async {
    final body = await _jsonBody(req);
    final name = body['channel'] as String;
    final channel =
        await repo.channel(appId, name) ??
        await repo.createChannel(appId, name);
    return _json({'id': channel.id, 'app_id': appId, 'name': channel.name});
  }

  Future<Response> _metrics(String appId) async {
    final app = await repo.appMetrics(appId);
    final patches = await repo.patchMetrics(appId);
    return _json({...app, 'patches': patches});
  }

  Future<Response> _getReleasePatches(int releaseId) async {
    final patches = await repo.patchesForRelease(releaseId);
    final out = <Map<String, Object?>>[];
    for (final p in patches) {
      final arts = await repo.patchArtifacts(p.id);
      out.add({
        'id': p.id,
        'number': p.number,
        'status': p.status.name,
        'channel': null,
        'deployments': await repo.patchDeployments(p.id),
        'artifacts': [
          for (final a in arts)
            {
              'id': a.id,
              'patch_id': a.ownerId,
              'arch': a.arch,
              'platform': a.platform,
              'hash': a.hash,
              'size': a.size,
            },
        ],
        'is_rolled_back': await repo.patchRolledBack(p.id),
        'notes': null,
      });
    }
    return _json({'patches': out});
  }

  /// Byte source/sink for `shorebird doctor`'s network speed check.
  Future<Response> _speedtest(Request req) async {
    if (req.method == 'GET') {
      final size =
          (int.tryParse(req.url.queryParameters['size'] ?? '') ?? 1048576)
              .clamp(0, 50 * 1024 * 1024);
      return Response.ok(
        Stream<List<int>>.value(Uint8List(size)),
        headers: {
          HttpHeaders.contentTypeHeader: 'application/octet-stream',
          HttpHeaders.contentLengthHeader: '$size',
        },
      );
    }
    await req.read().drain<void>(); // upload: accept + discard
    return _json({'ok': true});
  }

  /// Serves the self-contained web console (single-page app).
  Response _console() {
    final dir = Platform.environment['CONSOLE_DIR'] ?? 'console';
    final f = File('$dir/index.html');
    if (!f.existsSync()) {
      return _err(HttpStatus.notFound, 'not_found', 'console not available');
    }
    return Response.ok(
      f.readAsStringSync(),
      headers: {HttpHeaders.contentTypeHeader: 'text/html; charset=utf-8'},
    );
  }

  Future<Response> _getChannels(String appId) async {
    final chs = await repo.channels(appId);
    return _jsonRaw(
      jsonEncode([
        for (final c in chs) {'id': c.id, 'app_id': c.appId, 'name': c.name},
      ]),
    );
  }

  Future<Response> _promotePatch(Request req, String appId) async {
    final body = await _jsonBody(req);
    final patchId = body['patch_id'] as int;
    final channelId = body['channel_id'] as int;
    final rollout = (body['rollout'] as int?) ?? 100;
    final patch = await repo.patch(patchId);
    if (patch == null) throw notFound('No patch $patchId');
    if (await repo.channelById(channelId) == null) {
      throw notFound('No channel $channelId');
    }
    if (patch.status != PatchStatus.ready) {
      throw conflict('Patch $patchId is ${patch.status.name}, not ready');
    }
    await repo.promote(channelId, patchId, rollout: rollout);
    await repo.audit(
      'patch.promote',
      actor: '${_uid(req)}',
      target: '$patchId',
      detail: 'channel=$channelId rollout=$rollout',
    );
    return Response(HttpStatus.noContent);
  }

  // ---- uploads / downloads ----

  Future<Response> _upload(Request req, String token) async {
    final art = await repo.artifactByToken(token);
    if (art == null) throw notFound('Unknown upload token');
    final appId = art.ownerKind == 'release'
        ? (await repo.release(art.ownerId))?.appId
        : (await repo.patch(art.ownerId))?.appId;
    if (appId == null || !await repo.userCanAccessApp(_uid(req), appId)) {
      throw DomainException(
        HttpStatus.forbidden,
        'forbidden',
        'No access to this artifact',
      );
    }
    if (art.status != ArtifactStatus.pending) {
      throw conflict('Upload token not reusable (status ${art.status.name})');
    }
    await repo.setArtifactStatus(art.id, ArtifactStatus.uploading);
    final (_, file) = await _parseMultipart(req);
    if (file == null) throw badRequest('Missing file part');
    await store.put(art.storageKey, file.bytes);

    final reason = await store.verify(
      art.storageKey,
      art.hash,
      art.size,
      checkHash: art.ownerKind == 'release',
    );
    if (reason != null) {
      await repo.setArtifactStatus(art.id, ArtifactStatus.failed);
      await repo.audit('artifact.failed', target: '${art.id}', detail: reason);
      obs.info('artifact verify failed', {
        'artifact': art.id,
        'reason': reason,
      });
      throw badRequest('Artifact verification failed: $reason');
    }
    await repo.setArtifactStatus(art.id, ArtifactStatus.verified);
    obs.info('artifact verified', {
      'artifact': art.id,
      'owner': art.ownerKind,
      'arch': art.arch,
      'bytes': file.bytes.length,
    });
    await _maybeMarkPatchReady(art);
    return Response(HttpStatus.noContent);
  }

  /// GCS-style resumable upload: chunked PUTs with `Content-Range`, `308` +
  /// `Range` on incomplete, `200` on complete. Mirrors the CLI's contract.
  Future<Response> _resumableUpload(Request req, String token) async {
    final art = await repo.artifactByToken(token);
    if (art == null) throw notFound('Unknown upload token');
    final appId = art.ownerKind == 'release'
        ? (await repo.release(art.ownerId))?.appId
        : (await repo.patch(art.ownerId))?.appId;
    if (appId == null || !await repo.userCanAccessApp(_uid(req), appId)) {
      throw DomainException(
        HttpStatus.forbidden,
        'forbidden',
        'No access to this artifact',
      );
    }

    final cr = parseContentRange(req.headers[HttpHeaders.contentRangeHeader]);
    if (cr == null) throw badRequest('Missing/invalid Content-Range');
    if (cr.total > config.maxUploadBytes) {
      throw DomainException(
        HttpStatus.requestEntityTooLarge,
        'payload_too_large',
        'Upload exceeds the maximum size of ${config.maxUploadBytes} bytes',
      );
    }

    // Query the current offset: `Content-Range: bytes */TOTAL`.
    if (cr.isQuery) {
      await req.read().drain<void>();
      final size = store.stagedSize(token);
      if (art.status == ArtifactStatus.verified || size >= cr.total) {
        return Response(HttpStatus.ok);
      }
      return _resumeIncomplete(size);
    }

    if (art.status == ArtifactStatus.verified) return Response(HttpStatus.ok);
    if (art.status == ArtifactStatus.pending) {
      await repo.setArtifactStatus(art.id, ArtifactStatus.uploading);
    }
    final chunk = await _collect(req.read(), max: config.maxUploadBytes);
    await store.stageChunk(token, cr.start, chunk);
    final received = store.stagedSize(token);
    if (received < cr.total) return _resumeIncomplete(received);

    // Complete: commit to the object store + verify.
    await store.commitStaged(token, art.storageKey);
    final reason = await store.verify(
      art.storageKey,
      art.hash,
      art.size,
      checkHash: art.ownerKind == 'release',
    );
    if (reason != null) {
      await repo.setArtifactStatus(art.id, ArtifactStatus.failed);
      await repo.audit('artifact.failed', target: '${art.id}', detail: reason);
      throw badRequest('Artifact verification failed: $reason');
    }
    await repo.setArtifactStatus(art.id, ArtifactStatus.verified);
    obs.info('artifact verified', {
      'artifact': art.id,
      'owner': art.ownerKind,
      'arch': art.arch,
      'bytes': received,
      'resumable': true,
    });
    await _maybeMarkPatchReady(art);
    return Response(HttpStatus.ok);
  }

  Response _resumeIncomplete(int received) => Response(
    308, // Resume Incomplete
    headers: {
      if (received > 0) HttpHeaders.rangeHeader: 'bytes=0-${received - 1}',
    },
  );

  Future<void> _maybeMarkPatchReady(ArtifactRow art) async {
    if (art.ownerKind != 'patch') return;
    final arts = await repo.patchArtifacts(art.ownerId);
    final allVerified =
        arts.isNotEmpty &&
        arts.every((a) => a.status == ArtifactStatus.verified);
    if (allVerified) {
      final p = (await repo.patch(art.ownerId))!;
      requirePatchTransition(p.status, PatchStatus.ready);
      await repo.setPatchStatus(p.id, PatchStatus.ready);
    }
  }

  Future<Response> _download(Request req, String token) async {
    final q = req.url.queryParameters;
    if (!_validSignedUrl(token, q['exp'], q['sig'])) {
      return _err(HttpStatus.forbidden, 'forbidden', 'Invalid or expired URL');
    }
    final art = await repo.artifactByToken(token);
    if (art == null || !await store.exists(art.storageKey)) {
      throw notFound('No artifact for token');
    }
    final total = await store.size(art.storageKey);
    final failAfter = int.tryParse(q['fail_after'] ?? '');

    final range = req.headers[HttpHeaders.rangeHeader];
    if (range != null && range.startsWith('bytes=')) {
      final spec = range.substring('bytes='.length).split('-');
      final start = int.tryParse(spec[0]) ?? 0;
      final end = (spec.length > 1 && spec[1].isNotEmpty)
          ? int.parse(spec[1])
          : total - 1;
      final len = end - start + 1;
      final body = await store.openRead(
        art.storageKey,
        offset: start,
        length: len,
      );
      return Response(
        HttpStatus.partialContent,
        body: _maybeTruncate(body, failAfter),
        headers: {
          HttpHeaders.contentTypeHeader: 'application/octet-stream',
          HttpHeaders.acceptRangesHeader: 'bytes',
          HttpHeaders.contentRangeHeader: 'bytes $start-$end/$total',
          HttpHeaders.contentLengthHeader: '$len',
        },
      );
    }

    final body = await store.openRead(art.storageKey);
    return Response.ok(
      _maybeTruncate(body, failAfter),
      headers: {
        HttpHeaders.contentTypeHeader: 'application/octet-stream',
        HttpHeaders.acceptRangesHeader: 'bytes',
        HttpHeaders.contentLengthHeader: '$total',
      },
    );
  }

  Stream<List<int>> _maybeTruncate(
    Stream<List<int>> src,
    int? failAfter,
  ) async* {
    if (failAfter == null) {
      yield* src;
      return;
    }
    var sent = 0;
    await for (final chunk in src) {
      if (sent + chunk.length >= failAfter) {
        yield chunk.sublist(0, failAfter - sent);
        obs.info('fault: truncated download', {'after_bytes': failAfter});
        return;
      }
      sent += chunk.length;
      yield chunk;
    }
  }

  // ---- device ----

  Future<Response> _patchesCheck(Request req) async {
    final body = await _jsonBody(req);
    final appId = body['app_id'] as String?;
    final version = body['release_version'] as String?;
    final platform = body['platform'] as String?;
    final arch = body['arch'] as String?;
    final channelName = (body['channel'] as String?) ?? 'stable';
    final clientId = body['client_id'] as String?;
    final clientPatch =
        (body['current_patch_number'] as int?) ??
        (body['patch_number'] as int?) ??
        0;

    Map<String, Object?> resp({
      Map<String, Object?>? patch,
      List<int> rolledBack = const [],
    }) => {
      'patch_available': patch != null,
      'patch': patch,
      'rolled_back_patch_numbers': rolledBack,
    };

    if (appId == null || version == null || platform == null || arch == null) {
      return _json(resp());
    }
    final release = await repo.releaseByVersion(appId, version);
    if (release == null) return _json(resp());
    final channel = await repo.channel(appId, channelName);
    if (channel == null) return _json(resp());

    final rolledBack = await repo.rolledBackPatchNumbers(
      channel.id,
      release.id,
    );

    final active = await repo.activeChannelPatch(channel.id);
    if (active == null) return _json(resp(rolledBack: rolledBack));
    final patch = await repo.patch(active.patchId);
    if (patch == null || patch.releaseId != release.id) {
      return _json(resp(rolledBack: rolledBack));
    }
    if (patch.status != PatchStatus.ready) {
      return _json(resp(rolledBack: rolledBack));
    }
    if (patch.number <= clientPatch) return _json(resp(rolledBack: rolledBack));

    // Partial rollout: deterministic per-client bucketing. Fail closed when a
    // partial rollout has no stable client id.
    if (!eligibleForRollout(
      appId: appId,
      channelId: channel.id,
      patchId: patch.id,
      rollout: active.rollout,
      clientId: clientId,
    )) {
      return _json(resp(rolledBack: rolledBack));
    }

    final artifact = await repo.patchArtifact(patch.id, arch, platform);
    if (artifact == null || artifact.status != ArtifactStatus.verified) {
      return _json(resp(rolledBack: rolledBack));
    }
    return _json(
      resp(
        patch: {
          'number': patch.number,
          'download_url': _signedUrl(artifact.token),
          'hash': artifact.hash,
          'hash_signature': artifact.hashSignature,
        },
        rolledBack: rolledBack,
      ),
    );
  }

  Future<Response> _patchesEvents(Request req) async {
    final raw = await req.readAsString();
    obs.info('patches/events', {'body': raw});
    try {
      final decoded = jsonDecode(raw);
      final e = (decoded is Map && decoded['event'] is Map)
          ? decoded['event'] as Map
          : (decoded as Map);
      final dedupe = [
        e['client_id'],
        e['app_id'],
        e['release_version'],
        e['patch_number'],
        e['type'],
        e['timestamp'],
      ].join('|');
      final inserted = await repo.insertEvent(
        raw: raw,
        dedupeKey: dedupe,
        appId: e['app_id'] as String?,
        clientId: e['client_id'] as String?,
        type: e['type'] as String?,
        patchNumber: e['patch_number'] as int?,
        platform: e['platform'] as String?,
        arch: e['arch'] as String?,
        releaseVersion: e['release_version'] as String?,
        ts: e['timestamp'] as int?,
      );
      if (!inserted) obs.info('duplicate event ignored');
    } catch (_) {
      await repo.insertEvent(raw: raw);
    }
    return Response(HttpStatus.noContent);
  }

  // ---- admin ----

  Future<Response> _admin(Request req, List<String> seg) async {
    // POST /admin/orgs/{orgId}/invitations?email=&role=  -> invite to an org
    if (req.method == 'POST' &&
        seg.length == 3 &&
        seg[0] == 'orgs' &&
        seg[2] == 'invitations') {
      final orgId = int.parse(seg[1]);
      if (!await repo.userIsOrgAdmin(_uid(req), orgId)) {
        throw DomainException(
          HttpStatus.forbidden,
          'forbidden',
          'Not an org admin',
        );
      }
      final email = req.url.queryParameters['email'];
      final role = req.url.queryParameters['role'] ?? 'developer';
      if (email == null) throw badRequest('email required');
      final token = await repo.createInvitation(orgId, email, role);
      await repo.audit(
        'org.invite',
        actor: '${_uid(req)}',
        target: '$orgId',
        detail: '$email as $role',
      );
      // SMTP is optional in a self-host; return the accept link for delivery.
      return _json({
        'token': token,
        'email': email,
        'role': role,
        'accept_url':
            '${config.publicBaseUrl}/api/v1/invitations/$token/accept',
      });
    }
    // POST /admin/users?email=&name=  -> create user + issue an API key
    if (req.method == 'POST' && seg.length == 1 && seg[0] == 'users') {
      final email = req.url.queryParameters['email'];
      if (email == null || email.isEmpty) throw badRequest('email required');
      final user = await repo.upsertUser(
        email,
        req.url.queryParameters['name'],
      );
      final key = await repo.createApiKey(user.id);
      await repo.audit('user.create', actor: '${_uid(req)}', target: email);
      return _json({'user_id': user.id, 'email': user.email, 'api_key': key});
    }
    // POST /admin/apps/{appId}/collaborators?email=&role=
    if (req.method == 'POST' &&
        seg.length == 3 &&
        seg[0] == 'apps' &&
        seg[2] == 'collaborators') {
      final appId = seg[1];
      await _authorizeApp(req, appId);
      final email = req.url.queryParameters['email'];
      final role = req.url.queryParameters['role'] ?? 'developer';
      if (email == null) throw badRequest('email required');
      final user = await repo.userByEmail(email);
      if (user == null) throw notFound('No user $email');
      await repo.addCollaborator(appId, user.id, role);
      await repo.audit(
        'app.collaborator.add',
        actor: '${_uid(req)}',
        target: appId,
        detail: '$email as $role',
      );
      return _json({'app_id': appId, 'user_id': user.id, 'role': role});
    }
    // POST /admin/apps/{appId}/patches/{patchId}/withdraw?channel=&rollback=
    // POST /admin/apps/{appId}/patches/{patchId}/rollout?channel=&percent=
    if (req.method == 'POST' &&
        seg.length == 5 &&
        seg[0] == 'apps' &&
        seg[2] == 'patches') {
      final appId = seg[1];
      final patchId = int.parse(seg[3]);
      final action = seg[4];
      final channelName = req.url.queryParameters['channel'] ?? 'stable';
      final channel = await repo.channel(appId, channelName);
      if (channel == null) throw notFound('No channel $channelName');

      if (action == 'withdraw') {
        final rollback = req.url.queryParameters['rollback'] == 'true';
        final cp = await repo.activeChannelPatchForPatch(channel.id, patchId);
        if (cp == null) {
          throw conflict('Patch $patchId is not active on $channelName');
        }
        requireChannelPatchTransition(cp.status, ChannelPatchStatus.withdrawn);
        await repo.withdraw(channel.id, patchId, rollback: rollback);
        await repo.audit(
          'patch.withdraw',
          actor: '${_uid(req)}',
          target: '$patchId',
          detail: 'rollback=$rollback',
        );
        return _json({
          'withdrawn': true,
          'patch_id': patchId,
          'rolled_back': rollback,
        });
      }
      if (action == 'rollout') {
        final percent = int.parse(req.url.queryParameters['percent'] ?? '100');
        final cp = await repo.activeChannelPatchForPatch(channel.id, patchId);
        if (cp == null) {
          throw conflict('Patch $patchId is not active on $channelName');
        }
        await repo.setRollout(channel.id, patchId, percent);
        await repo.audit(
          'patch.rollout',
          actor: '${_uid(req)}',
          target: '$patchId',
          detail: 'percent=$percent',
        );
        return _json({'patch_id': patchId, 'rollout': percent});
      }
    }
    // ---- team read / manage ----

    // GET /admin/orgs/{orgId}/members
    if (req.method == 'GET' &&
        seg.length == 3 &&
        seg[0] == 'orgs' &&
        seg[2] == 'members') {
      final orgId = int.parse(seg[1]);
      if (!await repo.userInOrg(_uid(req), orgId)) {
        throw DomainException(
          HttpStatus.forbidden,
          'forbidden',
          'Not an org member',
        );
      }
      return _json({'members': await repo.orgMembers(orgId)});
    }
    // PATCH /admin/orgs/{orgId}/members/{userId}?role=
    if (req.method == 'PATCH' &&
        seg.length == 4 &&
        seg[0] == 'orgs' &&
        seg[2] == 'members') {
      final orgId = int.parse(seg[1]);
      final userId = int.parse(seg[3]);
      if (!await repo.userIsOrgAdmin(_uid(req), orgId)) {
        throw DomainException(
          HttpStatus.forbidden,
          'forbidden',
          'Not an org admin',
        );
      }
      final role = req.url.queryParameters['role'];
      if (role == null || role.isEmpty) throw badRequest('role required');
      await repo.setMemberRole(orgId, userId, role);
      await repo.audit(
        'org.member.role',
        actor: '${_uid(req)}',
        target: '$orgId',
        detail: 'user $userId -> $role',
      );
      return _json({'org_id': orgId, 'user_id': userId, 'role': role});
    }
    // DELETE /admin/orgs/{orgId}/members/{userId}
    if (req.method == 'DELETE' &&
        seg.length == 4 &&
        seg[0] == 'orgs' &&
        seg[2] == 'members') {
      final orgId = int.parse(seg[1]);
      final userId = int.parse(seg[3]);
      if (!await repo.userIsOrgAdmin(_uid(req), orgId)) {
        throw DomainException(
          HttpStatus.forbidden,
          'forbidden',
          'Not an org admin',
        );
      }
      // Don't strand the org: refuse to remove its last owner/admin.
      Map<String, Object?>? target;
      for (final x in await repo.orgMembers(orgId)) {
        if (x['user_id'] == userId) {
          target = x;
          break;
        }
      }
      final r = target?['role'];
      if ((r == 'owner' || r == 'admin') &&
          await repo.orgAdminCount(orgId) <= 1) {
        throw conflict('Cannot remove the last owner/admin of the org');
      }
      await repo.removeMember(orgId, userId);
      await repo.audit(
        'org.member.remove',
        actor: '${_uid(req)}',
        target: '$orgId',
        detail: 'user $userId',
      );
      return _json({'removed': true, 'org_id': orgId, 'user_id': userId});
    }
    // GET /admin/orgs/{orgId}/invitations
    if (req.method == 'GET' &&
        seg.length == 3 &&
        seg[0] == 'orgs' &&
        seg[2] == 'invitations') {
      final orgId = int.parse(seg[1]);
      if (!await repo.userIsOrgAdmin(_uid(req), orgId)) {
        throw DomainException(
          HttpStatus.forbidden,
          'forbidden',
          'Not an org admin',
        );
      }
      return _json({'invitations': await repo.orgInvitations(orgId)});
    }
    // DELETE /admin/orgs/{orgId}/invitations/{token}
    if (req.method == 'DELETE' &&
        seg.length == 4 &&
        seg[0] == 'orgs' &&
        seg[2] == 'invitations') {
      final orgId = int.parse(seg[1]);
      if (!await repo.userIsOrgAdmin(_uid(req), orgId)) {
        throw DomainException(
          HttpStatus.forbidden,
          'forbidden',
          'Not an org admin',
        );
      }
      await repo.revokeInvitation(orgId, seg[3]);
      await repo.audit(
        'org.invite.revoke',
        actor: '${_uid(req)}',
        target: '$orgId',
        detail: seg[3],
      );
      return _json({'revoked': true});
    }
    // GET /admin/apps/{appId}/collaborators
    if (req.method == 'GET' &&
        seg.length == 3 &&
        seg[0] == 'apps' &&
        seg[2] == 'collaborators') {
      final appId = seg[1];
      await _authorizeApp(req, appId);
      return _json({'collaborators': await repo.appCollaborators(appId)});
    }
    // DELETE /admin/apps/{appId}/collaborators/{userId}
    if (req.method == 'DELETE' &&
        seg.length == 4 &&
        seg[0] == 'apps' &&
        seg[2] == 'collaborators') {
      final appId = seg[1];
      await _authorizeApp(req, appId);
      final userId = int.parse(seg[3]);
      await repo.removeCollaborator(appId, userId);
      await repo.audit(
        'app.collaborator.remove',
        actor: '${_uid(req)}',
        target: appId,
        detail: 'user $userId',
      );
      return _json({'removed': true, 'user_id': userId});
    }

    return _err(
      HttpStatus.notFound,
      'not_found',
      'No admin route /${req.url.path}',
    );
  }

  // ---- signed URLs ----

  String _signedUrl(String token) {
    final s = _signer.sign(token, DateTime.now().add(config.downloadUrlTtl));
    return '${config.publicBaseUrl}/download/$token?exp=${s.exp}&sig=${s.sig}';
  }

  bool _validSignedUrl(String token, String? exp, String? sig) =>
      _signer.valid(token, exp, sig);

  // ---- helpers ----

  Map<String, Object?> _registerJson(
    ArtifactRow art, {
    required bool releaseKey,
  }) => {
    'id': art.id,
    if (releaseKey) 'release_id': art.ownerId else 'patch_id': art.ownerId,
    'arch': art.arch,
    'platform': art.platform,
    'hash': art.hash,
    'size': art.size,
    'url': '${config.publicBaseUrl}/api/v1/uploads/${art.token}',
    'upload_method': config.uploadMethod,
  };

  Map<String, Object?> _releaseJson(ReleaseRow r) => {
    'id': r.id,
    'app_id': r.appId,
    'version': r.version,
    'flutter_revision': r.flutterRevision,
    'flutter_version': r.flutterVersion,
    'display_name': r.displayName,
    'platform_statuses': r.platformStatuses,
    'created_at': r.createdAt,
    'updated_at': r.updatedAt,
    'notes': null,
  };

  Future<Map<String, dynamic>> _jsonBody(Request req) async {
    final s = await req.readAsString();
    if (s.isEmpty) return {};
    return jsonDecode(s) as Map<String, dynamic>;
  }

  Response _json(Object data) => _jsonRaw(jsonEncode(data));

  Response _jsonRaw(String body) => Response.ok(
    body,
    headers: {HttpHeaders.contentTypeHeader: 'application/json'},
  );

  Response _err(int status, String code, String message) => Response(
    status,
    body: jsonEncode({'code': code, 'message': message}),
    headers: {HttpHeaders.contentTypeHeader: 'application/json'},
  );

  Future<(Map<String, String>, ({String name, List<int> bytes})?)>
  _parseMultipart(Request req) async {
    final contentType = req.headers['content-type'] ?? '';
    final boundary = _boundary(contentType);
    final fields = <String, String>{};
    ({String name, List<int> bytes})? file;
    if (boundary == null) return (fields, file);
    await for (final part in MimeMultipartTransformer(
      boundary,
    ).bind(req.read())) {
      final disposition = part.headers['content-disposition'] ?? '';
      final name = _dispositionParam(disposition, 'name');
      final filename = _dispositionParam(disposition, 'filename');
      final bytes = await _collect(part, max: config.maxUploadBytes);
      if (filename != null) {
        file = (name: name ?? 'file', bytes: bytes);
      } else if (name != null) {
        fields[name] = utf8.decode(bytes);
      }
    }
    return (fields, file);
  }

  String? _boundary(String contentType) {
    final idx = contentType.indexOf('boundary=');
    if (idx == -1) return null;
    var b = contentType.substring(idx + 'boundary='.length);
    final semi = b.indexOf(';');
    if (semi != -1) b = b.substring(0, semi);
    if (b.length >= 2 && b.startsWith('"') && b.endsWith('"')) {
      b = b.substring(1, b.length - 1);
    }
    return b;
  }

  String? _dispositionParam(String disposition, String key) =>
      RegExp('$key="([^"]*)"').firstMatch(disposition)?.group(1);

  Future<List<int>> _collect(Stream<List<int>> s, {int? max}) async {
    final b = BytesBuilder();
    await for (final chunk in s) {
      b.add(chunk);
      // Cap mid-stream so an oversized (or dishonestly-sized) upload can't
      // exhaust memory before a Content-Length check would catch it.
      if (max != null && b.length > max) {
        throw DomainException(
          HttpStatus.requestEntityTooLarge,
          'payload_too_large',
          'Upload exceeds the maximum size of $max bytes',
        );
      }
    }
    return b.takeBytes();
  }
}

/// A thin, self-contained admin page. Public HTML (no secrets embedded); the
/// operator pastes an API key which the page sends as a bearer to the JSON API.
const _adminHtml = r'''
<!doctype html><html><head><meta charset="utf-8"><title>code_push_server admin</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
 body{font:14px/1.5 system-ui,sans-serif;margin:2rem;max-width:900px;color:#222}
 h1{font-size:1.3rem} input{padding:.4rem;font:inherit} button{padding:.4rem .8rem;font:inherit;cursor:pointer}
 table{border-collapse:collapse;width:100%;margin:.5rem 0} th,td{border:1px solid #ddd;padding:.3rem .5rem;text-align:left}
 .app{border:1px solid #ccc;border-radius:8px;padding:1rem;margin:1rem 0} .muted{color:#888} code{background:#f4f4f4;padding:.1rem .3rem;border-radius:4px}
</style></head><body>
<h1>code_push_server — admin</h1>
<p>API key: <input id="key" size="60" placeholder="sb_api_..."> <button onclick="load()">Load</button></p>
<div id="out" class="muted">Enter an API key and click Load.</div>
<script>
async function api(p){const r=await fetch(p,{headers:{Authorization:'Bearer '+document.getElementById('key').value}});if(!r.ok)throw new Error(p+' -> '+r.status);return r.json();}
function esc(s){return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));}
async function load(){
 const out=document.getElementById('out'); out.textContent='Loading...';
 try{
  const {apps}=await api('/api/v1/apps');
  if(!apps.length){out.textContent='No apps.';return;}
  let html='';
  for(const a of apps){
   const m=await api('/api/v1/apps/'+a.app_id+'/metrics');
   html+='<div class="app"><b>'+esc(a.display_name)+'</b> <code>'+esc(a.app_id)+'</code>'
    +'<div class="muted">latest release '+esc(a.latest_release_version||'—')+', latest patch '+esc(a.latest_patch_number??'—')+'</div>'
    +'<div>events: '+esc(m.total_events)+' · unique clients: '+esc(m.unique_clients)+'</div>';
   if(m.patches&&m.patches.length){
    html+='<table><tr><th>patch</th><th>downloads</th><th>installs</th><th>unique clients</th></tr>';
    for(const p of m.patches){html+='<tr><td>'+esc(p.patch_number)+'</td><td>'+esc(p.downloads)+'</td><td>'+esc(p.installs)+'</td><td>'+esc(p.unique_clients)+'</td></tr>';}
    html+='</table>';
   } else { html+='<div class="muted">no patch events yet</div>'; }
   html+='</div>';
  }
  out.innerHTML=html;
 }catch(e){out.textContent='Error: '+e.message;}
}
</script></body></html>
''';

/// Fixed-window in-memory rate limiter, keyed by bearer token (or 'anon').
class _RateLimiter {
  final Map<String, (int windowStart, int count)> _buckets = {};

  bool allow(String key, int perMinute) {
    final nowMin = DateTime.now().millisecondsSinceEpoch ~/ 60000;
    final entry = _buckets[key];
    if (entry == null || entry.$1 != nowMin) {
      _buckets[key] = (nowMin, 1);
      return true;
    }
    if (entry.$2 >= perMinute) return false;
    _buckets[key] = (nowMin, entry.$2 + 1);
    return true;
  }
}
