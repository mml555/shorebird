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

  /// Validates the `id_token` from an external IdP's token response and
  /// returns the email it asserts, or the reason it was refused.
  ///
  /// The signature is not checked: OIDC Core 3.1.3.7 allows that when the
  /// token comes straight from the token endpoint over TLS. Everything else
  /// in 3.1.3.7 that this server can check without the IdP's keys is checked:
  ///
  /// * `aud` contains [clientId], and `azp` equals it when present (and is
  ///   required when there are several audiences). Without this a token minted for another app is accepted.
  /// * `exp` is present and in the future.
  /// * `iss` equals [issuer], when one is configured (`IDP_ISSUER`).
  /// * `email_verified` is true, unless [allowUnverifiedEmail]
  ///   (`IDP_ALLOW_UNVERIFIED_EMAIL`): an IdP that lets users claim an
  ///   address they have not proved lets them sign in as its owner.
  ///
  /// A top-level `email` in the token response is deliberately ignored: OIDC
  /// token responses do not define one, and it is unauthenticated by any of
  /// the claims above.
  static IdTokenResult emailFromIdToken(
    Map<String, dynamic> tokenResp, {
    required String clientId,
    String issuer = '',
    bool allowUnverifiedEmail = false,
    DateTime? now,
  }) {
    final idToken = tokenResp['id_token'];
    if (idToken is! String) return IdTokenResult.rejected('no_id_token');
    final parts = idToken.split('.');
    if (parts.length != 3) return IdTokenResult.rejected('malformed_id_token');
    final Map<String, dynamic> payload;
    try {
      payload =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
              )
              as Map<String, dynamic>;
    } catch (_) {
      return IdTokenResult.rejected('malformed_id_token');
    }

    final aud = payload['aud'];
    final audiences = switch (aud) {
      final String a => [a],
      final List<dynamic> a => a.whereType<String>().toList(),
      _ => const <String>[],
    };
    if (!audiences.contains(clientId)) {
      return IdTokenResult.rejected('aud_mismatch');
    }
    // Core 3.1.3.7: azp, when present, must be our client id, whatever the
    // audience count; with several audiences it must be present.
    final azp = payload['azp'];
    if (azp != null ? azp != clientId : audiences.length > 1) {
      return IdTokenResult.rejected('azp_mismatch');
    }

    final exp = payload['exp'];
    if (exp is! num) return IdTokenResult.rejected('exp_missing');
    final nowSeconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    if (exp <= nowSeconds) return IdTokenResult.rejected('expired');

    if (issuer.isNotEmpty && payload['iss'] != issuer) {
      return IdTokenResult.rejected('iss_mismatch');
    }

    final email = payload['email'];
    if (email is! String || email.isEmpty) {
      return IdTokenResult.rejected('email_missing');
    }
    if (!allowUnverifiedEmail) {
      // Google has been seen to send the string "true".
      final verified = payload['email_verified'];
      if (verified != true && verified != 'true') {
        return IdTokenResult.rejected(
          verified == null ? 'email_verified_missing' : 'email_not_verified',
        );
      }
    }
    return IdTokenResult.accepted(email);
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

/// The outcome of [OAuthService.emailFromIdToken]: an [email], or a short
/// [reason] code (safe to log; never contains token material).
class IdTokenResult {
  IdTokenResult.accepted(String this.email) : reason = null;
  IdTokenResult.rejected(String this.reason) : email = null;

  final String? email;
  final String? reason;
}
