import 'dart:convert';
import 'dart:math';

import 'package:jose/jose.dart';

/// Minimal OAuth-ish auth service compatible with `shorebird login`.
///
/// The CLI flow (reverse-engineered from shorebird_oauth.dart):
///   GET  /login?continue=http://localhost:PORT/callback  -> 302 continue?code=..
///   POST /token  (form: grant_type=authorization_code&code=..)  -> tokens
///   POST /token  (form: grant_type=refresh_token&refresh_token=..) -> tokens
///   POST /api/logout  (Authorization: Bearer `<refresh_token>`)   -> 2xx
///
/// `access_token` is the RS256 JWT the CLI then sends as a bearer to the
/// code-push server. Header carries alg/kid/typ; payload carries iss
/// (== SHOREBIRD_JWT_ISSUER), aud, sub, exp, iat, and an `email` claim.
class OAuthService {
  OAuthService(this.issuer, {JsonWebKey? key, String? keyJson})
    : _key = key ?? (keyJson != null ? keyFromJson(keyJson) : _genKey()) {
    _keyStore = JsonWebKeyStore()..addKey(_key);
  }

  /// Generates a fresh RS256 signing key (with a stable `kid`).
  static JsonWebKey generateKey() => _genKey();

  /// Serializes a key to JWK JSON for persistence.
  static String keyToJson(JsonWebKey k) => jsonEncode(k.toJson());

  /// Rebuilds a key from persisted JWK JSON.
  static JsonWebKey keyFromJson(String s) =>
      JsonWebKey.fromJson(jsonDecode(s) as Map<String, dynamic>);

  /// Extracts an email from an external IdP token response — a top-level
  /// `email`, else the `email` claim of the `id_token` JWT (decode-only; the
  /// token came directly from the IdP token endpoint over TLS). Null if none.
  static String? emailFromIdToken(Map<String, dynamic> tokenResp) {
    if (tokenResp['email'] is String) return tokenResp['email'] as String;
    final idToken = tokenResp['id_token'];
    if (idToken is! String) return null;
    final parts = idToken.split('.');
    if (parts.length != 3) return null;
    try {
      final payload =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
              )
              as Map<String, dynamic>;
      return payload['email'] as String?;
    } catch (_) {
      return null;
    }
  }

  final String issuer;
  final JsonWebKey _key;
  late final JsonWebKeyStore _keyStore;

  static final _rng = Random.secure();

  static JsonWebKey _genKey() {
    final k = JsonWebKey.generate('RS256');
    if (k.keyId != null) return k;
    return JsonWebKey.fromJson({...k.toJson(), 'kid': _rndId()});
  }

  /// An opaque, URL-safe random token with a [prefix] (for codes / refresh
  /// tokens). Storage/single-use is handled by the repository.
  static String randomToken(String prefix) {
    final b = List<int>.generate(24, (_) => _rng.nextInt(256));
    return '$prefix${base64Url.encode(b).replaceAll('=', '')}';
  }

  static String _rndId() {
    final b = List<int>.generate(8, (_) => _rng.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  String mintAccessToken(String email, {int ttlSeconds = 900}) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final claims = <String, Object?>{
      'iss': issuer,
      'aud': 'shorebird',
      'sub': email,
      'email': email,
      'iat': now,
      'auth_time': now,
      'exp': now + ttlSeconds,
    };
    final builder = JsonWebSignatureBuilder()
      ..jsonContent = claims
      ..addRecipient(_key, algorithm: 'RS256')
      ..setProtectedHeader('typ', 'JWT');
    return builder.build().toCompactSerialization();
  }

  Future<String?> emailFromToken(String token) async {
    try {
      final jwt = JsonWebToken.unverified(token);
      final verified = await jwt.verify(_keyStore);
      if (!verified) return null;
      final claims = jwt.claims;
      if (claims.issuer?.toString() != issuer) return null;
      final exp = claims.expiry;
      if (exp != null && DateTime.now().isAfter(exp)) return null;
      return claims['email'] as String?;
    } catch (_) {
      // Malformed tokens can throw Error (not just Exception) from the JOSE
      // parser (e.g. wrong number of segments) — treat all as invalid.
      return null;
    }
  }

  Map<String, Object?> jwks() => {
    'keys': [
      // _key.toJson() may be unmodifiable; copy before stripping privates.
      Map<String, dynamic>.from(_key.toJson())
        ..removeWhere((k, _) => _privateRsaFields.contains(k)),
    ],
  };

  static const _privateRsaFields = {'d', 'p', 'q', 'dp', 'dq', 'qi'};
}
