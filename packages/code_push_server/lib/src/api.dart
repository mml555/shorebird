import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:code_push_server/src/analytics.dart';
import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/content_range.dart';
import 'package:code_push_server/src/db.dart' show asDbBool;
import 'package:code_push_server/src/domain.dart';
import 'package:code_push_server/src/oauth.dart';
import 'package:code_push_server/src/observability.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:code_push_server/src/rollout.dart';
import 'package:code_push_server/src/signing.dart';
import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';

/// The client's network identity: the socket [remoteIp], or a hop from
/// `X-Forwarded-For` when [isTrustedProxy] says the peer is one of our own
/// reverse proxies (`Config.trustsProxy`).
///
/// X-Forwarded-For is written by the client. Honoring it from an untrusted
/// peer means a caller gets a brand-new bucket for every request just by
/// rotating the header, which is indistinguishable from having no rate limit
/// at all — so it is read only when a proxy we control appended to it.
///
/// Which hop matters. Caddy's `reverse_proxy` (2.7+, once `trusted_proxies` is
/// set), nginx's
/// `$proxy_add_x_forwarded_for` and most cloud load balancers all *append* to
/// whatever the client sent, so the leftmost entry is again attacker-written.
/// Walking from the right and stopping at the first hop that isn't itself a
/// trusted proxy is correct for appending and replacing proxies alike, and for
/// a chain of them.
///
/// [trustAllHops] is the `TRUSTED_PROXIES=*` case: the operator has a proxy
/// they can't name (a dynamic or IPv6 load balancer) and is vouching for the
/// whole header, so the leftmost hop is the best available answer. It is the
/// weaker setting — a client that can reach the server directly can then
/// choose its own identity — which is why it is opt-in.
String clientIp({
  String? forwardedFor,
  String? remoteIp,
  bool Function(String ip)? isTrustedProxy,
  bool trustAllHops = false,
}) {
  if (forwardedFor != null && (trustAllHops || isTrustedProxy != null)) {
    final hops = forwardedFor
        .split(',')
        .map((h) => h.trim())
        .where(_looksLikeIp)
        .toList();
    if (hops.isNotEmpty) {
      if (trustAllHops) return hops.first;
      for (final hop in hops.reversed) {
        if (!isTrustedProxy!(hop)) return hop;
      }
    }
  }
  return remoteIp ?? 'unknown';
}

/// Cheap shape check on a forwarded hop before it becomes part of a bucket
/// key. The key is retained for the whole window and, with the Postgres
/// backend, written to an indexed column — so a hop is only ever taken from
/// the header if it is short and looks like an address, never verbatim.
bool _looksLikeIp(String s) =>
    s.isNotEmpty &&
    s.length <= 45 &&
    RegExp(r'^[0-9a-fA-F:.\[\]]+$').hasMatch(s);

/// The rate-limit bucket key for a request's *principal*: its bearer if one is
/// presented, else [ip] — the already-resolved [clientIp] for the request.
///
/// Taking the resolved address rather than re-deriving it keeps this from
/// drifting out of step with the hop resolution the caller already did.
///
/// The bearer is hashed rather than used verbatim: it is an unbounded,
/// unvalidated client-supplied header, and the key is retained for the whole
/// window (and, with the Postgres backend, written to an indexed column), so
/// keying on the raw value lets an unauthenticated caller pin megabytes per
/// request. Hashing also makes the key fixed-size and keeps credentials out of
/// the counter table.
///
/// This key alone is not a limit: a caller can rotate bearers freely. Every
/// request must also be charged against the un-rotatable per-IP bucket — see
/// `Api._rateLimit`.
String rateLimitKey({String? auth, required String ip}) {
  if (auth != null && auth.isNotEmpty) {
    return 'auth:${sha256.convert(utf8.encode(auth)).toString().substring(0, 32)}';
  }
  return 'ip:$ip';
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

  /// `shorebird doctor` runs the speed check a couple of times per invocation;
  /// a handful per minute per client is plenty and caps egress amplification.
  static const int _speedtestPerMinute = 6;

  /// When the untrusted-proxy warning was last emitted, so a proxied fleet
  /// doesn't log one line per request. Null until the first occurrence.
  DateTime? _untrustedProxyWarnedAt;

  /// How often to repeat that warning. Long enough to stay out of the way,
  /// short enough that an operator tailing logs sees it.
  static const Duration _untrustedProxyWarnInterval = Duration(minutes: 10);

  /// Warns, at most once per [_untrustedProxyWarnInterval], that an
  /// `X-Forwarded-For` arrived from a peer not listed in `TRUSTED_PROXIES` and
  /// was therefore ignored.
  ///
  /// This header used to be honored unconditionally. Tightening it is correct —
  /// otherwise any direct caller picks its own rate-limit bucket by writing the
  /// header — but it is silent on upgrade: behind an operator's own
  /// nginx/Caddy the peer is the Docker bridge gateway (e.g. `172.17.0.1`),
  /// not loopback, so every device in the fleet collapses into one bucket and
  /// starts seeing 429s on `/patches/check` with nothing in the logs to say
  /// why. Cheap to emit and it names the exact value to add.
  void _warnUntrustedProxy(String? peer) {
    // Counted on every occurrence — only the log line is rate limited, so a
    // dashboard still sees the true rate.
    obs.metrics.untrustedForwardedFor++;
    final now = DateTime.now();
    final last = _untrustedProxyWarnedAt;
    if (last != null && now.difference(last) < _untrustedProxyWarnInterval) {
      return;
    }
    _untrustedProxyWarnedAt = now;
    obs.info('WARNING: ignoring X-Forwarded-For from an untrusted peer', {
      'peer': peer ?? 'unknown',
      'trusted_proxies': config.trustedProxies.join(','),
      'hint':
          'every client behind this proxy shares one rate-limit bucket; '
          'add the proxy to TRUSTED_PROXIES (e.g. TRUSTED_PROXIES=$peer) '
          'if it is really your reverse proxy',
    });
  }

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
        final peer = conn is HttpConnectionInfo
            ? conn.remoteAddress.address
            : null;
        final forwardedFor = req.headers['x-forwarded-for'];
        // X-Forwarded-For is read only when the socket peer is a proxy we
        // configured; the same predicate then skips over any further trusted
        // hops inside the header. Under `TRUSTED_PROXIES=*` no hop can be
        // told apart from a proxy, so the header is taken at face value.
        final trustAllHops = config.trustsAnyProxy;
        final peerIsTrusted = trustAllHops || config.trustsProxy(peer);
        if (forwardedFor != null && !peerIsTrusted) {
          _warnUntrustedProxy(peer);
        }
        final isTrustedProxy = !trustAllHops && config.trustsProxy(peer)
            ? config.trustsProxy
            : null;
        final ip = clientIp(
          forwardedFor: forwardedFor,
          remoteIp: peer,
          isTrustedProxy: isTrustedProxy,
          trustAllHops: trustAllHops,
        );

        // The speedtest moves 16 MB per call from a public endpoint, so it
        // gets its own much tighter window rather than sharing the general
        // per-minute allowance. It is keyed on the peer alone: the endpoint is
        // unauthenticated, so a bearer here carries no identity and would only
        // hand the caller an unlimited supply of fresh buckets.
        final isSpeedtest =
            req.url.pathSegments.length == 2 &&
            req.url.pathSegments[0] == 'diagnostics' &&
            req.url.pathSegments[1] == 'speedtest';
        if (isSpeedtest) {
          // Its own key namespace, but through the same backend as everything
          // else: with RATE_LIMIT_BACKEND=postgres and N replicas, an
          // in-process counter would make the real cap 6xN per IP — on the one
          // endpoint whose cap exists specifically to bound egress.
          if (!await _withinLimit('speed:$ip', _speedtestPerMinute)) {
            return _err(429, 'rate_limited', 'Too many speedtest requests');
          }
          return inner(req);
        }

        // Two buckets, in separate key namespaces so both always apply:
        //
        //   host:<ip>  — the ceiling, at ipRateLimitPerMinute. The only key a
        //                caller cannot rotate out of.
        //   auth:<h> / ip:<ip> — the principal, at rateLimitPerMinute, so one
        //                busy API key can't spend a shared NAT's whole
        //                allowance. Anonymous traffic keys on the IP here too;
        //                the distinct `host:` prefix keeps that from
        //                collapsing into a single (looser) charge.
        if (!await _withinLimit('host:$ip', config.ipRateLimitPerMinute)) {
          return _err(429, 'rate_limited', 'Too many requests');
        }
        final principal = rateLimitKey(
          auth: req.headers['authorization'],
          ip: ip,
        );
        if (!await _withinLimit(principal, config.rateLimitPerMinute)) {
          return _err(429, 'rate_limited', 'Too many requests');
        }
        return inner(req);
      };

  /// Charges one request against [key] and reports whether it stayed within
  /// [perMinute], using the shared Postgres window when configured.
  Future<bool> _withinLimit(String key, int perMinute) async {
    if (config.rateLimitShared) {
      // Shared fixed window in Postgres — correct across restarts + nodes.
      final window = DateTime.now().millisecondsSinceEpoch ~/ 60000;
      return await repo.incrementRateWindow(key, window) <= perMinute;
    }
    return _rateLimiter.allow(key, perMinute);
  }

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
        if (key == null || key.isEmpty) {
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
        } else if (config.bootstrapApiKey.isNotEmpty &&
            key == config.bootstrapApiKey) {
          // Guarded on isNotEmpty: with API_KEY unset to "", a blank
          // `Authorization: Bearer ` header would otherwise match here and
          // authenticate the caller as the seeded owner.
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

  /// The authenticated caller. `_auth` puts this in the context for every
  /// non-public route, so its absence means a handler that needs an identity
  /// was reached without authentication. Defaulting to 1 here would silently
  /// run it as the root-org owner, turning any future `_isPublic` mistake into
  /// a full auth bypass; failing loudly keeps that a 500 instead.
  int _uid(Request req) {
    final id = req.context['userId'];
    if (id is! int) {
      throw StateError('handler requires authentication but _auth did not run');
    }
    return id;
  }

  /// Parses a numeric path segment. A non-numeric segment is a client error,
  /// so it becomes a 400 rather than escaping as an unhandled FormatException
  /// (a 500 plus a logged stack trace, which a client could trigger at will).
  static int _pathId(String segment, String what) {
    final n = int.tryParse(segment);
    if (n == null) throw badRequest('Invalid $what: "$segment"');
    return n;
  }

  /// Parses an optional ISO-8601 date query parameter. Absent is `null`;
  /// malformed is a 400, for the same reason as [_pathId] — `DateTime.parse`
  /// would otherwise throw a FormatException that escapes as a 500.
  static DateTime? _dateParam(Map<String, String> query, String name) {
    final raw = query[name];
    if (raw == null) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      throw badRequest('Invalid $name: "$raw" (expected an ISO-8601 date)');
    }
    return parsed;
  }

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
    if (seg.length == 1 && seg[0] == 'login' && m == 'POST') {
      return _loginSubmit(req);
    }
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
              '${config.publicBaseUrl}/diagnostics/speedtest'
              '?size=$_speedtestBytes',
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
                start: _dateParam(q, 'start'),
                end: _dateParam(q, 'end'),
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
        return _createPatchArtifact(req, appId, _pathId(rest[1], 'patch id'));
      }
      // Fork addition: upstream exposes no way to write patch notes, even
      // though its own `Patch` DTO carries the field and `shorebird patches
      // info` prints it. Mirrors the shape of the release PATCH above.
      if (rest.length == 2 && rest[0] == 'patches' && m == 'PATCH') {
        return _updatePatch(req, appId, _pathId(rest[1], 'patch id'));
      }
      if (rest.length == 1 && rest[0] == 'releases') {
        if (m == 'POST') return _createRelease(req, appId);
        if (m == 'GET') return _getReleases(appId);
      }
      if (rest.length == 2 && rest[0] == 'releases' && m == 'PATCH') {
        return _updateRelease(req, appId, _pathId(rest[1], 'release id'));
      }
      if (rest.length == 3 && rest[0] == 'releases' && rest[2] == 'artifacts') {
        final releaseId = _pathId(rest[1], 'release id');
        if (m == 'POST') return _createReleaseArtifact(req, appId, releaseId);
        if (m == 'GET') return _getReleaseArtifacts(req, appId, releaseId);
      }
      if (rest.length == 3 &&
          rest[0] == 'releases' &&
          rest[2] == 'patches' &&
          m == 'GET') {
        return _getReleasePatches(appId, _pathId(rest[1], 'release id'));
      }
    }

    return _err(
      HttpStatus.notFound,
      'not_found',
      'No route $m /${req.url.path}',
    );
  }

  // ---- OAuth auth service ----

  /// GET `/login?continue=<loopback>`.
  ///
  /// Broker mode (an external IdP is configured) bounces to the IdP. Otherwise
  /// the server has no identity provider of its own, so it authenticates the
  /// operator against an API key: the browser gets a form, and only a correct
  /// key yields an auth code. The identity is then whatever that key is bound
  /// to — never anything supplied in the request.
  Future<Response> _login(Request req) async {
    final cont = req.url.queryParameters['continue'];
    if (cont == null || !_safeContinue(cont)) {
      return _err(
        HttpStatus.badRequest,
        'bad_request',
        'A loopback `continue` URL is required',
      );
    }

    // Broker mode: bounce to the external IdP; the real email arrives at
    // /oauth/callback, which then issues our own code back to `continue`.
    if (config.idpEnabled) {
      final state = OAuthService.randomToken('sb_state_');
      await repo.insertIdpState(
        state,
        cont,
        DateTime.now().add(const Duration(minutes: 10)),
      );
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

    return _loginFormResponse(cont);
  }

  /// POST `/login` (form-encoded `continue` + `api_key`): the self-consent
  /// flow's credential check. A valid key mints an auth code for the identity
  /// that key belongs to; anything else re-renders the form with an error.
  Future<Response> _loginSubmit(Request req) async {
    final form = Uri.splitQueryString(await _readText(req));
    final cont = form['continue'];
    if (cont == null || !_safeContinue(cont)) {
      return _err(
        HttpStatus.badRequest,
        'bad_request',
        'A loopback `continue` URL is required',
      );
    }
    if (config.idpEnabled) {
      return _err(
        HttpStatus.badRequest,
        'bad_request',
        'An external IdP is configured; use GET /login',
      );
    }

    final email = await _identityForApiKey(form['api_key'] ?? '');
    if (email == null) {
      // Logged, not audited. `POST /login` is public, so an audit row per
      // failed attempt is an unauthenticated write into the one table with no
      // default retention — the same unbounded growth the housekeeping sweeps
      // exist to prevent. The structured log is where auth failures belong.
      obs.info('login denied', {'reason': 'invalid api key'});
      return _loginFormResponse(cont, error: 'That API key was not accepted.');
    }

    final code = OAuthService.randomToken('sb_code_');
    await repo.insertAuthCode(
      code,
      email,
      DateTime.now().add(const Duration(minutes: 5)),
    );
    await repo.audit('login.consent', actor: email);
    final sep = cont.contains('?') ? '&' : '?';
    return Response.found('$cont${sep}code=$code');
  }

  /// Resolves an API key to the email it authenticates as, or null if the key
  /// is unknown. The bootstrap key maps to the configured [Config.loginEmail].
  Future<String?> _identityForApiKey(String key) async {
    if (key.isEmpty) return null;
    if (config.bootstrapApiKey.isNotEmpty && key == config.bootstrapApiKey) {
      return config.loginEmail;
    }
    final userId = await repo.userIdForApiKey(key);
    if (userId == null) return null;
    return (await repo.userById(userId))?.email;
  }

  /// The CLI always passes a loopback `continue`; refusing anything else stops
  /// the login redirect being used to bounce a fresh auth code off-host.
  static bool _safeContinue(String cont) {
    // Header-safe characters first. `cont` is echoed into a `Location:` header,
    // and `Uri.tryParse` happily keeps a CR/LF — or any non-ASCII byte —
    // inside the path. dart:io then rejects the header value *while writing
    // the response*, so the request never completes and its socket stays open.
    // Both `/login` and `/oauth/callback` are public, so that is an
    // unauthenticated way to pin connections until the process runs out of
    // file descriptors. This mirrors dart:io's own validator: printable ASCII
    // only, which is all a percent-encoded loopback URL ever needs.
    if (cont.length > 2048) return false;
    if (cont.codeUnits.any((c) => c < 0x20 || c >= 0x7f)) return false;
    final uri = Uri.tryParse(cont);
    if (uri == null || !uri.hasScheme || !uri.isScheme('http')) return false;
    return uri.host == 'localhost' ||
        uri.host == '127.0.0.1' ||
        uri.host == '::1';
  }

  Response _loginFormResponse(String cont, {String? error}) => Response(
    error == null ? HttpStatus.ok : HttpStatus.unauthorized,
    body: _loginHtml(cont, error),
    headers: {HttpHeaders.contentTypeHeader: 'text/html; charset=utf-8'},
  );

  static String _loginHtml(String cont, String? error) {
    String esc(String s) => const HtmlEscape().convert(s);
    return '''
<!doctype html><html><head><meta charset="utf-8"><title>Sign in</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
 body{font:15px/1.5 system-ui,sans-serif;margin:0;display:grid;place-items:center;
      min-height:100vh;background:#f6f7f9;color:#222}
 form{background:#fff;padding:2rem;border-radius:12px;box-shadow:0 1px 4px #0002;width:min(26rem,90vw)}
 h1{font-size:1.15rem;margin:0 0 .25rem} p{margin:.25rem 0 1rem;color:#666;font-size:.9rem}
 input{width:100%;padding:.6rem;font:inherit;border:1px solid #ccc;border-radius:6px;box-sizing:border-box}
 button{margin-top:1rem;width:100%;padding:.6rem;font:inherit;border:0;border-radius:6px;
        background:#2f6feb;color:#fff;cursor:pointer}
 .err{background:#fdecec;color:#a11;padding:.5rem .75rem;border-radius:6px;font-size:.9rem;margin-bottom:1rem}
</style></head><body>
<!-- Empty action posts back to this exact URL, so the form survives being
     served under a reverse-proxy path prefix. -->
<form method="post" action="">
 <h1>Sign in to code_push_server</h1>
 <p>Paste an API key. <code>setup.sh</code> printed one; more can be issued with
    <code>POST /admin/users</code>.</p>
 ${error == null ? '' : '<div class="err">${esc(error)}</div>'}
 <input type="hidden" name="continue" value="${esc(cont)}">
 <input type="password" name="api_key" placeholder="sb_api_…" autofocus
        autocomplete="off" spellcheck="false">
 <button type="submit">Sign in</button>
</form></body></html>
''';
  }

  /// External-IdP redirect target: exchange the IdP code for the user's email,
  /// then hand our own code back to the CLI's loopback (`continue`).
  Future<Response> _oauthCallback(Request req) async {
    final q = req.url.queryParameters;
    // Single-use and persisted, so the state survives a restart and is valid
    // on whichever replica the IdP redirects the browser back to.
    final cont = await repo.consumeIdpState(q['state'] ?? '');
    if (cont == null) {
      return _err(
        HttpStatus.badRequest,
        'bad_request',
        'Invalid or expired state',
      );
    }
    // `_safeContinue` allows a loopback URL that already carries a query
    // string, so the separator has to be computed — and the IdP's `error` is
    // its text, not ours, so it has to be encoded before being pasted in.
    String back(String param, String value) {
      final sep = cont.contains('?') ? '&' : '?';
      return '$cont$sep$param=${Uri.encodeQueryComponent(value)}';
    }

    final idpError = q['error'];
    if (idpError != null) return Response.found(back('error', idpError));
    final idpCode = q['code'];
    if (idpCode == null) return Response.found(back('error', 'missing_code'));

    final tokenResp = await _idpTokenExchange(idpCode);
    final email = OAuthService.emailFromIdToken(tokenResp);
    if (email == null) return Response.found(back('error', 'no_email'));

    final code = OAuthService.randomToken('sb_code_');
    await repo.insertAuthCode(
      code,
      email,
      DateTime.now().add(const Duration(minutes: 5)),
    );
    return Response.found(back('code', code));
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
    final form = Uri.splitQueryString(await _readText(req));
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
    // `expired` is computed in SQL by `repo.invitation` — see the note there.
    // WAS: `exp is DateTime && …`, which on the SQLite backend (the default)
    // tested a String and so never fired: invitations never expired, and a
    // leaked accept link kept granting its role — up to `owner` — forever.
    if (asDbBool(inv['expired'])) {
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
      current?.email ?? config.loginEmail,
      _optStringField(body, 'name'),
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
    final orgId = _optIntField(body, 'organization_id') ?? _rootOrgId;
    if (!await repo.userInOrg(_uid(req), orgId)) {
      throw DomainException(
        HttpStatus.forbidden,
        'forbidden',
        'Not a member of org $orgId',
      );
    }
    final app = await repo.createApp(
      _optStringField(body, 'display_name') ?? 'app',
      orgId,
    );
    await repo.audit('app.create', actor: '${_uid(req)}', target: app.appId);
    return _json({'id': app.appId, 'display_name': app.displayName});
  }

  /// Authorizes the caller for [appId] via org membership or collaboration.
  /// Enforces an org's email-domain allowlist before [email] is granted access
  /// to it (or to one of its apps).
  ///
  /// A no-op for orgs with no policy, which is the default. Existing members are
  /// never re-checked: setting a policy governs who can be added from then on,
  /// it does not evict anyone — evicting silently on the next request would be a
  /// far worse failure than refusing the add.
  Future<void> _requireEmailAllowedInOrg(int orgId, String email) async {
    final domains = await repo.orgAllowedDomains(orgId);
    if (emailAllowedByDomains(email, domains)) return;
    // Names the policy: the caller is an org admin who can change it, and
    // "forbidden" with no reason is the kind of thing that turns into a support
    // ticket.
    throw DomainException(
      HttpStatus.forbidden,
      'forbidden',
      'Organization $orgId only admits addresses at ${domains.join(', ')}',
    );
  }

  Future<void> _authorizeApp(Request req, String appId) async {
    if (!await repo.userCanAccessApp(_uid(req), appId)) {
      throw DomainException(
        HttpStatus.forbidden,
        'forbidden',
        'No access to app $appId',
      );
    }
  }

  /// Authorizes the caller to administer [appId] (manage collaborators).
  Future<void> _authorizeAppAdmin(Request req, String appId) async {
    if (!await repo.userIsAppAdmin(_uid(req), appId)) {
      throw DomainException(
        HttpStatus.forbidden,
        'forbidden',
        'Managing collaborators on $appId requires an admin role',
      );
    }
  }

  /// The roles a membership or collaboration may hold. Anything outside this
  /// set is a 400 rather than a stored string nobody interprets: authorization
  /// matches on exact values (`userIsOrgAdmin`, `userIsAppAdmin`), so a typo
  /// like `Admin` reads as "no privileges at all" wherever it lands.
  static const Set<String> _roles = {'owner', 'admin', 'developer'};

  /// The subset of [_roles] that confers administrative rights.
  static const Set<String> _adminRoles = {'owner', 'admin'};

  /// Validates a `role` query parameter. [orDefault] is the value to use when
  /// the parameter is absent — supplied only where "unspecified" has an
  /// obvious meaning (creating an invitation or a collaborator). On an update
  /// there is no such default: a mistyped parameter name would otherwise read
  /// as a silent demotion rather than an error.
  static String _validRole(String? role, {String? orDefault}) {
    final r = role ?? orDefault;
    if (r == null) throw badRequest('role required');
    if (!_roles.contains(r)) {
      throw badRequest('role must be one of ${_roles.join(', ')}');
    }
    return r;
  }

  /// The org `Repository._seed` creates, which the bootstrap API key's user is
  /// an owner of. Membership in it is what distinguishes an operator of this
  /// server from an ordinary tenant, who gets a personal org of their own.
  static const int _rootOrgId = 1;

  /// Authorizes the caller as an operator of this deployment: an owner/admin
  /// of the root org. This is the identity `setup.sh`'s bootstrap key maps to.
  Future<void> _authorizeServerAdmin(Request req) async {
    if (!await repo.userIsOrgAdmin(_uid(req), _rootOrgId)) {
      await repo.audit('admin.denied', actor: '${_uid(req)}', target: 'users');
      throw DomainException(
        HttpStatus.forbidden,
        'forbidden',
        'Issuing API keys requires an owner/admin of the root organization',
      );
    }
  }

  // ---- ownership resolution --------------------------------------------
  //
  // `_authorizeApp` only proves the caller may act on the app named in the
  // PATH. Every id taken from a body or a deeper path segment must then be
  // confirmed to belong to that same app, or a caller could operate on another
  // tenant's release/patch/channel by pairing their own app id with a foreign
  // numeric id. These resolvers are the only sanctioned way to load one.
  // They 404 rather than 403 on mismatch so they don't confirm the id exists.

  Future<ReleaseRow> _ownedRelease(String appId, int releaseId) async {
    final release = await repo.release(releaseId);
    if (release == null || release.appId != appId) {
      throw notFound('No release $releaseId on app $appId');
    }
    return release;
  }

  Future<PatchRow> _ownedPatch(String appId, int patchId) async {
    final patch = await repo.patch(patchId);
    if (patch == null || patch.appId != appId) {
      throw notFound('No patch $patchId on app $appId');
    }
    return patch;
  }

  Future<ChannelRow> _ownedChannel(String appId, int channelId) async {
    final channel = await repo.channelById(channelId);
    if (channel == null || channel.appId != appId) {
      throw notFound('No channel $channelId on app $appId');
    }
    return channel;
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
      version: _stringField(body, 'version'),
      flutterRevision: _optStringField(body, 'flutter_revision'),
      flutterVersion: _optStringField(body, 'flutter_version'),
      displayName: _optStringField(body, 'display_name'),
      notes: _optNotesField(body),
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
    final release = await _ownedRelease(appId, releaseId);
    // Upstream's `UpdateReleaseRequest` documents `notes: null` as "leave
    // unchanged" — and it serializes the key on every request, including the
    // status updates the CLI sends mid-release — so only an explicitly present,
    // non-null value writes. An empty string is the clear signal.
    //
    // Validated here but written after the status handling below, so an
    // over-long value is a 400 before anything is touched and a status conflict
    // doesn't leave the notes changed by a request that failed.
    final writesNotes = body['notes'] != null;
    final notes = writesNotes ? _optNotesField(body) : null;
    // Build provenance: the CLI attaches this to every release status update.
    //
    // Written *before* the status handling below, unlike notes. The status gate
    // can fail closed with a 409 (activating before every artifact verified),
    // and that is exactly the case where knowing what built this release is
    // most useful — discarding the diagnostics attached to a failed deploy is
    // backwards. Metadata is also not a field anyone reads as state, so there's
    // no partial-update surprise in recording it.
    final metadata = _optMetadataField(body);
    if (metadata != null) await repo.setReleaseMetadata(releaseId, metadata);
    final status = _optStringField(body, 'status');
    final platform = _optStringField(body, 'platform');
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
    if (writesNotes) {
      await repo.setReleaseNotes(releaseId, notes);
      await repo.audit(
        'release.notes',
        actor: '${_uid(req)}',
        target: '$releaseId',
      );
    }
    return Response(HttpStatus.noContent);
  }

  Future<Response> _createPatch(Request req, String appId) async {
    final body = await _jsonBody(req);
    final releaseId = _intField(body, 'release_id');
    await _ownedRelease(appId, releaseId);
    // `notes` is optional and the pinned CLI never sends it; accepted here so a
    // script or the console can annotate a patch at creation time instead of
    // needing a follow-up PATCH.
    final p = await repo.createPatch(
      appId,
      releaseId,
      notes: _optNotesField(body),
      metadata: _optMetadataField(body),
    );
    return _json({'id': p.id, 'number': p.number, 'notes': p.notes});
  }

  /// `PATCH /api/v1/apps/{appId}/patches/{patchId}` with `{"notes": "..."}`.
  ///
  /// Same null-means-unchanged / empty-means-clear semantics as the release
  /// endpoint. Returns the patch so a caller can confirm what was stored.
  Future<Response> _updatePatch(Request req, String appId, int patchId) async {
    final body = await _jsonBody(req);
    final patch = await _ownedPatch(appId, patchId);
    var notes = patch.notes;
    if (body['notes'] != null) {
      notes = _optNotesField(body);
      await repo.setPatchNotes(patchId, notes);
      await repo.audit(
        'patch.notes',
        actor: '${_uid(req)}',
        target: '$patchId',
      );
    }
    return _json({'id': patch.id, 'number': patch.number, 'notes': notes});
  }

  /// Reads and validates an optional freeform `notes` field.
  ///
  /// Absent/JSON-null means "leave unchanged", matching the documented
  /// `UpdateReleaseRequest.notes` contract. An explicitly empty string is the
  /// way to *clear* notes, and is normalized to null here so a cleared field
  /// reads back as null rather than `''`.
  static String? _optNotesField(Map<String, Object?> body) {
    final v = _optStringField(body, 'notes');
    if (v == null) return null;
    if (v.length > _maxNotesChars) {
      throw badRequest('notes must be at most $_maxNotesChars characters');
    }
    return v.isEmpty ? null : v;
  }

  /// Ceiling on stored notes. Generous for a changelog entry, small enough that
  /// the field can't be used to park bulk data in the control-plane database.
  static const int _maxNotesChars = 4096;

  /// Reads the optional build-provenance `metadata` object the CLI sends on
  /// release updates and patch creation.
  ///
  /// Anything that isn't a JSON object is ignored rather than rejected: this is
  /// diagnostic data the CLI attaches on its own, and its shape is upstream's to
  /// change. Failing a release because a future CLI sent a field we didn't
  /// expect would trade a working deploy for a blob we only read out-of-band.
  /// Oversized blobs are dropped for the same reason — see [_maxMetadataChars].
  static Map<String, Object?>? _optMetadataField(Map<String, Object?> body) {
    final v = body['metadata'];
    if (v is! Map) return null;
    final map = v.cast<String, Object?>();
    if (map.isEmpty) return null;
    if (jsonEncode(map).length > _maxMetadataChars) {
      logInfo('WARNING: dropping oversized metadata blob', {
        'limit': _maxMetadataChars,
      });
      return null;
    }
    return map;
  }

  /// Ceiling on a stored metadata blob. The CLI's own payload — versions, flags,
  /// and `BuildTraceSummary` counters — is a few KB; this leaves generous room
  /// while keeping one release row from holding megabytes.
  static const int _maxMetadataChars = 64 * 1024;

  Future<Response> _createReleaseArtifact(
    Request req,
    String appId,
    int releaseId,
  ) async {
    final release = await _ownedRelease(appId, releaseId);
    // Parse and validate before advancing the lifecycle, matching `_upload` and
    // `_createPatchArtifact`. Unlike those two this was not a dead end — the
    // release lifecycle has no transition guard, so a release left in
    // `uploading` still accepts artifacts and still finalizes — but there is no
    // reason for a rejected request to move it at all.
    final (fields, _) = await _parseMultipart(req);
    final arch = _requiredField(fields, 'arch');
    final platform = _requiredField(fields, 'platform');
    final hash = _requiredField(fields, 'hash');
    if (await repo.existingArtifact('release', releaseId, arch, platform) !=
        null) {
      throw conflict('Artifact already registered for $arch/$platform');
    }
    if (release.lifecycle == ReleaseLifecycle.draft) {
      await repo.setReleaseLifecycle(releaseId, ReleaseLifecycle.uploading);
    }
    final art = await repo.createArtifact(
      ownerKind: 'release',
      ownerId: releaseId,
      arch: arch,
      platform: platform,
      hash: hash,
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
    final patch = await _ownedPatch(appId, patchId);
    // A promoted patch's artifact set is frozen. Re-opening it to `uploading`
    // would stop `patches/check` serving it (it requires `ready`), silently
    // unserving every device mid-rollout until the new arch finished.
    if (await repo.patchIsPromoted(patchId)) {
      throw conflict(
        'Patch $patchId has already been promoted; artifacts can no longer be '
        'added. Create a new patch instead.',
      );
    }
    requirePatchTransition(patch.status, PatchStatus.uploading);
    // Parse and validate BEFORE moving the patch to `uploading`: a body that
    // turns out to be unusable would otherwise leave the patch parked in a
    // state `patches/check` won't serve, with no request left to finish it.
    final (fields, _) = await _parseMultipart(req);
    final arch = _requiredField(fields, 'arch');
    final platform = _requiredField(fields, 'platform');
    final hash = _requiredField(fields, 'hash');
    // The duplicate check belongs here too, above the transition. `_patchNext`
    // allows ready -> uploading, so a retried registration whose response was
    // lost (the CLI's last arch succeeded, the patch verified to `ready`, the
    // client didn't hear it) would flip the patch back to `uploading` and only
    // then 409. Nothing can move it forward from there — `patches/check` and
    // `_promotePatch` both require `ready` — so the patch is stranded for good.
    if (await repo.existingArtifact('patch', patchId, arch, platform) != null) {
      throw conflict('Artifact already registered for $arch/$platform');
    }
    await repo.setPatchStatus(patchId, PatchStatus.uploading);
    final art = await repo.createArtifact(
      ownerKind: 'patch',
      ownerId: patchId,
      arch: arch,
      platform: platform,
      hash: hash,
      size: int.tryParse(fields['size'] ?? '0') ?? 0,
      hashSignature: fields['hash_signature'],
      podfileLockHash: fields['podfile_lock_hash'],
    );
    return _json(_registerJson(art, releaseKey: false));
  }

  Future<Response> _getReleaseArtifacts(
    Request req,
    String appId,
    int releaseId,
  ) async {
    await _ownedRelease(appId, releaseId);
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
    final name = _stringField(body, 'channel');
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

  Future<Response> _getReleasePatches(String appId, int releaseId) async {
    await _ownedRelease(appId, releaseId);
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
        'notes': p.notes,
        'metadata': p.metadata,
      });
    }
    return _json({'patches': out});
  }

  /// The exact payload size `NetworkChecker.performGCPDownloadSpeedTest`
  /// expects; it errors on any other length. Also the response cap, so this
  /// public endpoint can't be used as a bandwidth amplifier.
  static const _speedtestBytes = 16000000;

  /// Byte source/sink for `shorebird doctor`'s network speed check. Public:
  /// the CLI fetches it with an unauthenticated client. Bucketed under its own
  /// tighter rate limit — see [_rateLimit].
  Future<Response> _speedtest(Request req) async {
    if (req.method == 'GET') {
      final size =
          (int.tryParse(req.url.queryParameters['size'] ?? '') ??
                  _speedtestBytes)
              .clamp(0, _speedtestBytes);
      return Response.ok(
        Stream<List<int>>.value(Uint8List(size)),
        headers: {
          HttpHeaders.contentTypeHeader: 'application/octet-stream',
          HttpHeaders.contentLengthHeader: '$size',
        },
      );
    }
    // Upload: count + discard, never buffer. `_collect` would hold the whole
    // payload in memory and only throw once the cap was already exceeded — on
    // a public, unauthenticated endpoint that is MAX_UPLOAD_BYTES (512 MiB by
    // default) of heap pinned per in-flight request, so a handful of concurrent
    // POSTs is an OOM. Nothing here reads the bytes, so streaming past them
    // costs O(1). The cap is the speedtest's own payload size, not the artifact
    // limit: the CLI uploads a fixed 5 MB probe.
    await _drain(req.read(), max: _speedtestBytes);
    return Response(HttpStatus.noContent);
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
    final patchId = _intField(body, 'patch_id');
    final channelId = _intField(body, 'channel_id');
    final rollout = _optIntField(body, 'rollout') ?? 100;
    if (rollout < 0 || rollout > 100) {
      throw badRequest('rollout must be between 0 and 100');
    }
    final patch = await _ownedPatch(appId, patchId);
    await _ownedChannel(appId, channelId);
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
    // Parse and validate BEFORE leaving `pending`, for the same reason as
    // `_createPatchArtifact`. Moving to `uploading` first made any body that
    // failed to parse — a part-count or aggregate-size cap in `_parseMultipart`,
    // or a body with no file part — permanently burn the upload token: the
    // retry hits the `status != pending` conflict above, and re-registering the
    // artifact hits the duplicate check in `_createPatchArtifact`. Nothing can
    // move the artifact forward from there, so the patch never reaches `ready`.
    final (_, file) = await _parseMultipart(req);
    if (file == null) throw badRequest('Missing file part');
    await repo.setArtifactStatus(art.id, ArtifactStatus.uploading);
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
    // Fault injection for the updater's resume/retry tests. Never honored in
    // production — it's a way to make a real download return truncated bytes.
    final failAfter = config.production
        ? null
        : int.tryParse(q['fail_after'] ?? '');

    final rangeHeader = req.headers[HttpHeaders.rangeHeader];
    // A header we can't honor falls through to the full 200 below, which is
    // what RFC 7233 asks for and what a CDN in front of /download expects.
    final parsed = rangeHeader == null
        ? const ParsedRange(RangeOutcome.ignore)
        : parseByteRange(rangeHeader, total);
    if (parsed.outcome == RangeOutcome.unsatisfiable) {
      return Response(
        HttpStatus.requestedRangeNotSatisfiable,
        headers: {HttpHeaders.contentRangeHeader: 'bytes */$total'},
      );
    }
    if (parsed.outcome == RangeOutcome.partial) {
      final range = parsed.range!;
      final body = await store.openRead(
        art.storageKey,
        offset: range.start,
        length: range.length,
      );
      return Response(
        HttpStatus.partialContent,
        body: _maybeTruncate(body, failAfter),
        headers: {
          HttpHeaders.contentTypeHeader: 'application/octet-stream',
          HttpHeaders.acceptRangesHeader: 'bytes',
          HttpHeaders.contentRangeHeader:
              'bytes ${range.start}-${range.end}/$total',
          HttpHeaders.contentLengthHeader: '${range.length}',
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
    // Deliberately tolerant, unlike the CLI-facing endpoints: this is the
    // updater's hot path, and a device that sends a wrong-typed field should
    // be told "no patch for you" rather than have the cast escape as a 500.
    String? str(String key) {
      final v = body[key];
      return v is String ? v : null;
    }

    int? integer(String key) {
      final v = body[key];
      return v is int ? v : null;
    }

    final appId = str('app_id');
    final version = str('release_version');
    final platform = str('platform');
    final arch = str('arch');
    final channelName = str('channel') ?? 'stable';
    final clientId = str('client_id');
    final clientPatch =
        integer('current_patch_number') ?? integer('patch_number') ?? 0;

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

    // Platform-scoped: a channel can hold one active patch per platform, so an
    // Android device must not be handed the newest patch when that patch is
    // iOS-only (and vice versa).
    final active = await repo.activeChannelPatch(
      channel.id,
      platform: platform,
    );
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
    final raw = await _readText(req);
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
      final orgId = _pathId(seg[1], 'org id');
      if (!await repo.userIsOrgAdmin(_uid(req), orgId)) {
        throw DomainException(
          HttpStatus.forbidden,
          'forbidden',
          'Not an org admin',
        );
      }
      final email = req.url.queryParameters['email'];
      final role = _validRole(
        req.url.queryParameters['role'],
        orDefault: 'developer',
      );
      if (email == null) throw badRequest('email required');
      await _requireEmailAllowedInOrg(orgId, email);
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
      // Being authenticated is not enough. `upsertUser` returns the EXISTING
      // row on an email conflict, so this route hands the caller a working API
      // key for *any* address already registered — name the seeded owner and
      // you own the server. That escalation would undo every role and tenancy
      // check elsewhere in this file, so it is gated on being an operator.
      await _authorizeServerAdmin(req);
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
      // Granting access is an admin action: a `developer` collaborator can
      // ship patches but must not be able to add or remove other people.
      await _authorizeAppAdmin(req, appId);
      final email = req.url.queryParameters['email'];
      final role = _validRole(
        req.url.queryParameters['role'],
        orDefault: 'developer',
      );
      if (email == null) throw badRequest('email required');
      // The policy lives on the owning org, and a collaborator grant is a way
      // into that org's app — so it has to be checked here too, not just on the
      // invitation path. This is the case the upstream request is really about:
      // a personal account added straight onto a company app.
      final appOrgId = await repo.appOrgId(appId);
      if (appOrgId == null) throw notFound('No app $appId');
      await _requireEmailAllowedInOrg(appOrgId, email);
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
      final patchId = _pathId(seg[3], 'patch id');
      final action = seg[4];
      // /admin is dispatched outside the /api/v1/apps block, so it gets no
      // authorization for free — withdraw and rollout must check it here.
      await _authorizeApp(req, appId);
      await _ownedPatch(appId, patchId);
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
        final percent = int.tryParse(
          req.url.queryParameters['percent'] ?? '100',
        );
        if (percent == null || percent < 0 || percent > 100) {
          throw badRequest('percent must be an integer between 0 and 100');
        }
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
      final orgId = _pathId(seg[1], 'org id');
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
      final orgId = _pathId(seg[1], 'org id');
      final userId = _pathId(seg[3], 'user id');
      if (!await repo.userIsOrgAdmin(_uid(req), orgId)) {
        throw DomainException(
          HttpStatus.forbidden,
          'forbidden',
          'Not an org admin',
        );
      }
      final role = _validRole(req.url.queryParameters['role']);
      // Same "don't strand the org" rule the DELETE below enforces: demoting
      // the last owner/admin leaves nobody who can invite, manage members, or
      // (for the root org) issue API keys, with no recovery short of the
      // database. A near-miss like `Admin` or `ownr` used to be written
      // straight through, which is exactly how that happened.
      if (!_adminRoles.contains(role) &&
          await repo.userIsOrgAdmin(userId, orgId) &&
          await repo.orgAdminCount(orgId) <= 1) {
        throw conflict('Cannot demote the last owner/admin of the org');
      }
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
      final orgId = _pathId(seg[1], 'org id');
      final userId = _pathId(seg[3], 'user id');
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
      if (r is String &&
          _adminRoles.contains(r) &&
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
      final orgId = _pathId(seg[1], 'org id');
      if (!await repo.userIsOrgAdmin(_uid(req), orgId)) {
        throw DomainException(
          HttpStatus.forbidden,
          'forbidden',
          'Not an org admin',
        );
      }
      return _json({'invitations': await repo.orgInvitations(orgId)});
    }
    // GET  /admin/orgs/{orgId}/domains
    // PUT  /admin/orgs/{orgId}/domains?domains=example.com,example.org
    //
    // The org's email-domain allowlist. An empty `domains` clears the policy.
    if (seg.length == 3 &&
        seg[0] == 'orgs' &&
        seg[2] == 'domains' &&
        (req.method == 'GET' || req.method == 'PUT')) {
      final orgId = _pathId(seg[1], 'org id');
      // Reading is admin-only too: the allowlist names the company's mail
      // domains, which is not something a `developer` needs.
      if (!await repo.userIsOrgAdmin(_uid(req), orgId)) {
        throw DomainException(
          HttpStatus.forbidden,
          'forbidden',
          'Not an org admin',
        );
      }
      if (req.method == 'GET') {
        return _json({'domains': await repo.orgAllowedDomains(orgId)});
      }
      final raw = req.url.queryParameters['domains'] ?? '';
      final domains = parseDomainList(raw);
      // Refuse a policy that would lock out every current owner/admin: nobody
      // left could invite, and it is only ever a typo. Existing members keep
      // access either way, so this is about not stranding administration.
      if (domains.isNotEmpty) {
        final admins = (await repo.orgMembers(orgId))
            .where((m) => _adminRoles.contains(m['role']))
            .map((m) => (m['email'] as String?) ?? '')
            .toList();
        if (admins.isNotEmpty &&
            !admins.any((e) => emailAllowedByDomains(e, domains))) {
          throw conflict(
            'That policy would exclude every owner/admin of the org '
            '(${admins.join(', ')})',
          );
        }
      }
      // A non-empty request that parses to nothing is a malformed list, not a
      // request to clear — clearing is `?domains=`.
      if (domains.isEmpty && raw.trim().isNotEmpty) {
        throw badRequest('No valid domains in "$raw"');
      }
      await repo.setOrgAllowedDomains(orgId, domains);
      await repo.audit(
        'org.domains',
        actor: '${_uid(req)}',
        target: '$orgId',
        detail: domains.isEmpty ? 'cleared' : domains.join(','),
      );
      return _json({'org_id': orgId, 'domains': domains});
    }
    // DELETE /admin/orgs/{orgId}/invitations/{token}
    if (req.method == 'DELETE' &&
        seg.length == 4 &&
        seg[0] == 'orgs' &&
        seg[2] == 'invitations') {
      final orgId = _pathId(seg[1], 'org id');
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
      // `can_manage` mirrors what _authorizeAppAdmin will allow, so the
      // console can hide the add/remove controls instead of offering everyone
      // buttons that answer 403.
      return _json({
        'collaborators': await repo.appCollaborators(appId),
        'can_manage': await repo.userIsAppAdmin(_uid(req), appId),
      });
    }
    // DELETE /admin/apps/{appId}/collaborators/{userId}
    if (req.method == 'DELETE' &&
        seg.length == 4 &&
        seg[0] == 'apps' &&
        seg[2] == 'collaborators') {
      final appId = seg[1];
      await _authorizeAppAdmin(req, appId);
      final userId = _pathId(seg[3], 'user id');
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
    'notes': r.notes,
    // Extra key the pinned CLI ignores (its DTOs parse field by field), so the
    // console and any operator tooling can read build provenance without a
    // second round trip.
    'metadata': r.metadata,
  };

  /// Ceiling on any body we turn into a String. Every payload at these
  /// endpoints is a small control-plane document; `readAsString` on its own has
  /// no ceiling at all, and several of these routes are public, so an
  /// unauthenticated POST could pin arbitrary heap (worse than the raw bytes:
  /// UTF-8 decoding to a Dart String roughly doubles it).
  static const int _maxTextBodyBytes = 1 << 20; // 1 MiB

  /// Artifact registration sends a handful of fields plus one file.
  static const int _maxMultipartParts = 32;

  /// `allowMalformed` because strict UTF-8 decoding throws a FormatException
  /// on bytes the client chose — another client-triggerable 500. Invalid
  /// sequences become U+FFFD, and the JSON/form parse downstream then fails
  /// with a 400 like any other bad body.
  Future<String> _readText(Request req) async => utf8.decode(
    await _collect(req.read(), max: _maxTextBodyBytes),
    allowMalformed: true,
  );

  Future<Map<String, dynamic>> _jsonBody(Request req) async {
    final s = await _readText(req);
    if (s.isEmpty) return {};
    final Object? decoded;
    try {
      decoded = jsonDecode(s);
    } on FormatException {
      throw badRequest('Body is not valid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw badRequest('Body must be a JSON object');
    }
    return decoded;
  }

  // Body-field readers. These values arrive straight off the wire, so a
  // missing or wrong-typed one is a client error. A raw `as` cast instead
  // throws a TypeError that escapes as a 500 plus a logged stack trace — which
  // any caller could trigger at will with `{"release_id": "1"}`. Same defect
  // class as the non-numeric path segments [_pathId] handles.

  static int _intField(Map<String, dynamic> body, String key) =>
      _optIntField(body, key) ?? (throw badRequest('$key is required'));

  static int? _optIntField(Map<String, dynamic> body, String key) {
    final v = body[key];
    if (v == null) return null;
    if (v is int) return v;
    throw badRequest('$key must be an integer');
  }

  static String _stringField(Map<String, dynamic> body, String key) =>
      _optStringField(body, key) ?? (throw badRequest('$key is required'));

  /// The multipart equivalent of [_stringField]. A bare `fields['arch']!` is
  /// the same client-triggerable 500 as a raw body cast: post an artifact
  /// registration without the part and the null-check throws.
  static String _requiredField(Map<String, String> fields, String key) =>
      fields[key] ?? (throw badRequest('Missing form field "$key"'));

  static String? _optStringField(Map<String, dynamic> body, String key) {
    final v = body[key];
    if (v == null) return null;
    if (v is String) return v;
    throw badRequest('$key must be a string');
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
    // Per-part caps alone bound nothing: a body of many parts, or many small
    // fields, is unbounded in aggregate. Every real request here is a handful
    // of fields plus one file.
    var remaining = config.maxUploadBytes;
    var parts = 0;
    await for (final part in MimeMultipartTransformer(
      boundary,
    ).bind(req.read())) {
      if (++parts > _maxMultipartParts) {
        throw badRequest('Too many multipart parts (max $_maxMultipartParts)');
      }
      final disposition = part.headers['content-disposition'] ?? '';
      final name = _dispositionParam(disposition, 'name');
      final filename = _dispositionParam(disposition, 'filename');
      final bytes = await _collect(part, max: remaining);
      remaining -= bytes.length;
      if (filename != null) {
        file = (name: name ?? 'file', bytes: bytes);
      } else if (name != null) {
        // Lenient for the same reason as [_readText]: a malformed byte in a
        // form field is a 400 from whatever consumes it, not a 500 here.
        fields[name] = utf8.decode(bytes, allowMalformed: true);
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
      if (max != null && b.length > max) throw _tooLarge(max);
    }
    return b.takeBytes();
  }

  /// Consumes and discards [s], enforcing [max] without retaining a byte of
  /// it. Use wherever the payload is unwanted; [_collect] buffers first, which
  /// makes the cap a memory *reservation* rather than a limit.
  Future<int> _drain(Stream<List<int>> s, {required int max}) async {
    var received = 0;
    await for (final chunk in s) {
      received += chunk.length;
      if (received > max) throw _tooLarge(max);
    }
    return received;
  }

  static DomainException _tooLarge(int max) => DomainException(
    HttpStatus.requestEntityTooLarge,
    'payload_too_large',
    'Upload exceeds the maximum size of $max bytes',
  );
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

/// Fixed-window in-memory rate limiter, keyed by bearer token or client IP.
///
/// Buckets from closed windows are swept as the window rolls over. Without
/// that the map grows one entry per distinct IP forever, which is unbounded
/// memory driven entirely by unauthenticated traffic.
class _RateLimiter {
  final Map<String, (int windowStart, int count)> _buckets = {};
  int _lastSweptWindow = 0;

  bool allow(String key, int perMinute) {
    final nowMin = DateTime.now().millisecondsSinceEpoch ~/ 60000;
    if (nowMin != _lastSweptWindow) {
      _lastSweptWindow = nowMin;
      _buckets.removeWhere((_, v) => v.$1 < nowMin);
    }
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
