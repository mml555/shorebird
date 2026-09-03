// cspell:words unrouted earer
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// The outcome an audit event records for the request that produced it.
///
/// Derived from the response the server actually sent, never asserted by a
/// handler before its work completes — so a mutation that throws, conflicts, or
/// is refused by authorization cannot leave a `success` behind. See
/// [AuditResult.fromStatus].
enum AuditResult {
  /// The server answered 2xx/3xx: the mutation was applied.
  success,

  /// The server answered 4xx: the mutation was declined (bad request,
  /// forbidden, not found, conflict, rate limited). Nothing was applied.
  refused,

  /// The server answered 5xx: the request failed in a way the server owns.
  /// Whether anything was applied is unknown, which is exactly why it is not
  /// `success`.
  error;

  static AuditResult fromStatus(int status) => status >= 500
      ? AuditResult.error
      : status >= 400
      ? AuditResult.refused
      : AuditResult.success;
}

/// The audit classification of one request: the mutating operation it performs,
/// a stable route template for it, and whatever the PATH alone already says
/// about the thing being mutated.
///
/// Deriving the ids from the path (rather than only from handler code) is
/// deliberate: it means a handler cannot forget to attribute its own event, and
/// an event is attributable even when the request never reaches the handler
/// (rejected by rate limiting or authentication).
class AuditRoute {
  const AuditRoute(
    this.operation,
    this.route, {
    this.appId,
    this.releaseId,
    this.patchId,
  });

  /// Dotted operation name, e.g. `patch.create`. The primary query key.
  final String operation;

  /// The route template this matched, e.g. `POST /api/v1/apps/{app}/patches`.
  /// Safe to store verbatim: it holds no ids, and in particular no upload
  /// token (which is a bearer capability, not an identifier).
  final String route;

  final String? appId;
  final int? releaseId;
  final int? patchId;
}

/// Classifies a request as a mutating patch-lifecycle operation, or `null`.
///
/// `null` is the answer for every read, for the device surface
/// (`patches/check`, `patches/events`, `patches/assets`, `crashes` — all POSTs,
/// none of them operator actions), and for anything unrouted. A request that
/// classifies to `null` produces no audit event at all, which is what keeps a
/// read from ever masquerading as a mutation: there is no code path that could
/// write one.
///
/// Not covered here: the identity/tenancy admin surface (org invitations,
/// members, collaborators, API-key issue). Those still write the older
/// detail-only rows through `Repository.audit` — see the `kind` distinction in
/// `Api._auditQuery`.
AuditRoute? classifyMutation(String method, List<String> segments) {
  int? id(String s) => int.tryParse(s);

  // ---- /admin/apps/{app}/patches/{patchId}/{action} ----
  if (method == 'POST' &&
      segments.length == 6 &&
      segments[0] == 'admin' &&
      segments[1] == 'apps' &&
      segments[3] == 'patches') {
    final action = segments[5];
    if (action == 'withdraw' || action == 'rollout') {
      return AuditRoute(
        'patch.$action',
        'POST /admin/apps/{app}/patches/{patch}/$action',
        appId: segments[2],
        patchId: id(segments[4]),
      );
    }
    return null;
  }

  if (segments.length < 3 || segments[0] != 'api' || segments[1] != 'v1') {
    return null;
  }
  final seg = segments.sublist(2);

  // ---- /api/v1/uploads/{token} ----
  //
  // The token is NOT recorded: presenting it is what authorizes the upload, so
  // it is a credential. `Api._upload` notes the artifact/patch ids instead.
  if ((method == 'POST' || method == 'PUT') &&
      seg.length == 2 &&
      seg[0] == 'uploads') {
    return AuditRoute('artifact.upload', '$method /api/v1/uploads/{token}');
  }

  if (seg.length == 1 && seg[0] == 'apps' && method == 'POST') {
    return const AuditRoute('app.create', 'POST /api/v1/apps');
  }

  if (seg.length < 3 || seg[0] != 'apps') return null;
  final appId = seg[1];
  final rest = seg.sublist(2);

  if (rest[0] == 'channels' && rest.length == 1 && method == 'POST') {
    return AuditRoute(
      'channel.create',
      'POST /api/v1/apps/{app}/channels',
      appId: appId,
    );
  }

  if (rest[0] == 'releases') {
    if (rest.length == 1 && method == 'POST') {
      return AuditRoute(
        'release.create',
        'POST /api/v1/apps/{app}/releases',
        appId: appId,
      );
    }
    if (rest.length == 2 && method == 'PATCH') {
      return AuditRoute(
        'release.update',
        'PATCH /api/v1/apps/{app}/releases/{release}',
        appId: appId,
        releaseId: id(rest[1]),
      );
    }
    if (rest.length == 3 && rest[2] == 'artifacts' && method == 'POST') {
      return AuditRoute(
        'release.artifact.create',
        'POST /api/v1/apps/{app}/releases/{release}/artifacts',
        appId: appId,
        releaseId: id(rest[1]),
      );
    }
    return null;
  }

  if (rest[0] == 'patches') {
    if (rest.length == 1 && method == 'POST') {
      return AuditRoute(
        'patch.create',
        'POST /api/v1/apps/{app}/patches',
        appId: appId,
      );
    }
    if (rest.length == 2 && rest[1] == 'promote' && method == 'POST') {
      return AuditRoute(
        'patch.promote',
        'POST /api/v1/apps/{app}/patches/promote',
        appId: appId,
      );
    }
    if (rest.length == 2 && method == 'PATCH') {
      return AuditRoute(
        'patch.update',
        'PATCH /api/v1/apps/{app}/patches/{patch}',
        appId: appId,
        patchId: id(rest[1]),
      );
    }
    if (rest.length == 3 && rest[2] == 'artifacts' && method == 'POST') {
      return AuditRoute(
        'patch.artifact.create',
        'POST /api/v1/apps/{app}/patches/{patch}/artifacts',
        appId: appId,
        patchId: id(rest[1]),
      );
    }
    return null;
  }

  return null;
}

/// How the caller authenticated, for the `actor_credential` field.
enum CredentialKind {
  /// A bearer that matched `API_KEY` — the operator key `setup.sh` seeds.
  bootstrap,

  /// A bearer that resolved through the `api_keys` table.
  apiKey,

  /// An OAuth login JWT (`shorebird login`).
  oauth,

  /// A bearer was presented but resolved to no identity.
  rejected,

  /// No bearer at all.
  anonymous;

  String get wireName => switch (this) {
    CredentialKind.bootstrap => 'bootstrap',
    CredentialKind.apiKey => 'api_key',
    CredentialKind.oauth => 'oauth',
    CredentialKind.rejected => 'rejected',
    CredentialKind.anonymous => 'anonymous',
  };
}

/// A non-reversible, stable fingerprint of a presented bearer.
///
/// The audit trail has to say WHICH credential acted — two API keys on the same
/// user account are different actors operationally — without ever storing a
/// usable one. 12 hex characters of SHA-256 is enough to correlate rows and
/// enough to match against a key an operator re-fingerprints on purpose, and it
/// is not enough to replay.
String credentialFingerprint(String bearer) =>
    sha256.convert(utf8.encode(bearer)).toString().substring(0, 12);

/// The per-request audit accumulator.
///
/// Created by `Api._auditing` for a request that [classifyMutation] recognizes,
/// carried in the shelf request context, and enriched as the request proceeds:
/// `Api._auth` fills in the actor, handlers fill in ids the path does not carry
/// (a new patch's id and number, the promoted track, the app behind an upload
/// token). Exactly one event is written from it, after the response status is
/// known.
class AuditScope {
  AuditScope({
    required this.requestId,
    required this.method,
    required this.operation,
    required this.route,
    this.appId,
    this.releaseId,
    this.patchId,
  });

  /// Shelf request-context key. Read it through `Api._audit`.
  static const String contextKey = 'cps.audit.scope';

  final String requestId;
  final String method;
  final String operation;
  final String route;

  String? appId;
  int? releaseId;
  int? patchId;
  int? patchNumber;
  String? track;

  int? actorId;
  String? actorEmail;
  CredentialKind credentialKind = CredentialKind.anonymous;
  String? credentialFp;

  final Map<String, Object?> detail = {};

  /// Records who acted. Takes the bearer only to fingerprint it; the value is
  /// never retained.
  void identify({
    int? userId,
    String? email,
    required CredentialKind kind,
    String? bearer,
  }) {
    actorId = userId ?? actorId;
    actorEmail = email ?? actorEmail;
    credentialKind = kind;
    if (bearer != null && bearer.isNotEmpty) {
      credentialFp = credentialFingerprint(bearer);
    }
  }

  /// Adds what the path could not say. Every argument is optional and a null
  /// leaves the current value alone, so a handler can call this more than once
  /// as it learns more.
  void note({
    String? appId,
    int? releaseId,
    int? patchId,
    int? patchNumber,
    String? track,
    Map<String, Object?> detail = const {},
  }) {
    this.appId ??= appId;
    this.releaseId ??= releaseId;
    this.patchId ??= patchId;
    this.patchNumber ??= patchNumber;
    this.track ??= track;
    this.detail.addAll(detail);
  }

  /// `actor_credential`: the kind of credential plus its fingerprint, e.g.
  /// `api_key:9f2a1c4e77b0`. Never the credential itself.
  String get credential => credentialFp == null
      ? credentialKind.wireName
      : '${credentialKind.wireName}:$credentialFp';

  /// The event as it is written to the log sink and the `audit_log` table.
  ///
  /// This map is the whole audit record. It is built field by field from values
  /// this class holds — there is no path by which a request header, a bearer,
  /// or a raw request body reaches it. Free text is additionally scrubbed by
  /// [auditSafeText].
  Map<String, Object?> toEvent({
    required AuditResult result,
    required int httpStatus,
    required DateTime at,
  }) => {
    'timestamp': at.toUtc().toIso8601String(),
    'request_id': requestId,
    'operation': operation,
    'route': route,
    'method': method,
    'actor_id': actorId,
    'actor': actorEmail == null ? null : auditSafeText(actorEmail!),
    'actor_credential': credential,
    'app_id': appId == null ? null : auditSafeText(appId!),
    'release_id': releaseId,
    'patch_id': patchId,
    'patch_number': patchNumber,
    'track': track == null ? null : auditSafeText(track!),
    'result': result.name,
    'http_status': httpStatus,
    if (detail.isNotEmpty) 'detail': auditSafeDetail(detail),
  };
}

/// Credential shapes that must never appear in an audit record.
///
/// This is a backstop, not the mechanism. The mechanism is that the record is
/// an allowlist of computed fields ([AuditScope.toEvent]) — headers, bearers,
/// upload tokens and request bodies are never copied into it. These patterns
/// catch a value that reached a `detail` entry by mistake, so the failure mode
/// of such a mistake is a redacted string rather than a leaked secret.
final List<RegExp> _credentialShapes = [
  // This server's own API keys (`Repository.createApiKey`) and the seeded one.
  RegExp(r'sb_api_[A-Za-z0-9_-]{4,}'),
  // An Authorization header value, however it got here.
  RegExp(r'[Bb]earer\s+[A-Za-z0-9._~+/=-]{4,}'),
  // A compact JWS/JWT — the shape `shorebird login` credentials take.
  RegExp(r'eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}'),
];

/// Longest free-text value an audit field keeps. An audit row is written per
/// mutation and read by machines; an unbounded value would let a caller pad the
/// table and the log line.
const int auditTextLimit = 512;

/// Makes [value] safe to put in a structured record and in a one-line text log:
/// credential shapes redacted, bytes outside printable ASCII replaced (so no
/// caller can inject a newline and forge a second log line), and clipped.
String auditSafeText(String value) {
  var s = value;
  for (final re in _credentialShapes) {
    s = s.replaceAll(re, '[redacted]');
  }
  s = s.replaceAll(RegExp(r'[^\x20-\x7E]'), '?');
  return s.length > auditTextLimit
      ? '${s.substring(0, auditTextLimit)}(clipped)'
      : s;
}

/// [auditSafeText] applied to every string in a detail map, recursively.
Map<String, Object?> auditSafeDetail(Map<String, Object?> detail) => {
  for (final e in detail.entries)
    auditSafeText(e.key): switch (e.value) {
      final String s => auditSafeText(s),
      final Map<String, Object?> m => auditSafeDetail(m),
      final Object? v => v,
    },
};

final _rng = Random.secure();

/// A fresh request id: `req_` plus 128 bits of hex.
///
/// Correlation identifier only — it authorizes nothing, so it is safe to return
/// in `X-Request-Id` and to paste into an issue.
String newRequestId() =>
    'req_'
    '${List<int>.generate(16, (_) => _rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

/// An inbound `X-Request-Id`, if it is safe to adopt.
///
/// Adopted only when the socket peer is one of our own reverse proxies
/// ([peerIsTrustedProxy]): the value becomes a stored, indexed correlation key,
/// and honoring it from any caller would let one forge collisions with another
/// operator's rows. Shape is constrained for the same reason a hop is in
/// `clientIp`.
String? adoptedRequestId(String? header, {required bool peerIsTrustedProxy}) {
  if (!peerIsTrustedProxy || header == null) return null;
  final v = header.trim();
  if (v.isEmpty || v.length > 64) return null;
  return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(v) ? v : null;
}
