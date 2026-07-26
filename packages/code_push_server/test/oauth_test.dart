import 'dart:convert';

import 'package:code_push_server/src/oauth.dart';
import 'package:jose/jose.dart';
import 'package:test/test.dart';

/// Decodes a base64url JWT segment (which may lack `=` padding) to a JSON map.
Map<String, Object?> _decodeSegment(String segment) {
  final normalized = base64Url.normalize(segment);
  return jsonDecode(utf8.decode(base64Url.decode(normalized)))
      as Map<String, Object?>;
}

void main() {
  group('OAuthService', () {
    const issuer = 'https://issuer.example.com';
    const email = 'alice@example.com';
    late OAuthService service;

    setUp(() {
      service = OAuthService(issuer);
    });

    group('mintAccessToken', () {
      test('produces a 3-part JWT', () {
        final token = service.mintAccessToken(email);
        expect(token.split('.'), hasLength(3));
      });

      test('header contains alg=RS256, a kid, and typ=JWT', () {
        final token = service.mintAccessToken(email);
        final header = _decodeSegment(token.split('.')[0]);
        expect(header['alg'], equals('RS256'));
        expect(header['typ'], equals('JWT'));
        expect(header['kid'], isNotNull);
        expect(header['kid'], isA<String>());
      });

      test('payload contains the expected claims', () {
        final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final token = service.mintAccessToken(email);
        final payload = _decodeSegment(token.split('.')[1]);

        expect(payload['iss'], equals(issuer));
        expect(payload['aud'], equals('shorebird'));
        expect(payload['sub'], equals(email));
        expect(payload['email'], equals(email));
        expect(payload['iat'], isA<int>());
        expect(payload['exp'], isA<int>());

        final iat = payload['iat']! as int;
        final exp = payload['exp']! as int;
        expect(iat, greaterThanOrEqualTo(before));
        expect(exp, greaterThan(iat));
        expect(exp - iat, equals(900));
      });

      test('honors a custom ttlSeconds', () {
        final token = service.mintAccessToken(email, ttlSeconds: 60);
        final payload = _decodeSegment(token.split('.')[1]);
        final iat = payload['iat']! as int;
        final exp = payload['exp']! as int;
        expect(exp - iat, equals(60));
      });
    });

    group('emailFromToken', () {
      test('round-trips the email for a freshly minted token', () async {
        final token = service.mintAccessToken(email);
        expect(await service.emailFromToken(token), equals(email));
      });

      test('returns null for a tampered token', () async {
        final token = service.mintAccessToken(email);
        final parts = token.split('.');
        // Re-encode the payload with a different email; the signature no
        // longer matches.
        final payload = _decodeSegment(parts[1])
          ..['email'] = 'mallory@evil.com';
        final tamperedPayload = base64Url
            .encode(utf8.encode(jsonEncode(payload)))
            .replaceAll('=', '');
        final tampered = '${parts[0]}.$tamperedPayload.${parts[2]}';
        expect(await service.emailFromToken(tampered), isNull);
      });

      test('returns null for a garbage token', () async {
        expect(await service.emailFromToken('not.a.jwt'), isNull);
      });

      test('returns null for a token minted by a different service '
          '(different key)', () async {
        final other = OAuthService(issuer);
        final token = other.mintAccessToken(email);
        // Same issuer, but our service does not know the other's signing key,
        // so verification fails.
        expect(await service.emailFromToken(token), isNull);
      });

      test('returns null for an expired token', () async {
        final token = service.mintAccessToken(email, ttlSeconds: -10);
        expect(await service.emailFromToken(token), isNull);
      });

      test('returns null when the token issuer differs from the service '
          'issuer', () async {
        // Share one signing key so the signature verifies, but mint with a
        // different issuer than the verifying service expects. This isolates
        // the issuer check from the signature check.
        final key = JsonWebKey.generate('RS256');
        final minter = OAuthService(
          'https://other-issuer.example.com',
          key: key,
        );
        final verifier = OAuthService(issuer, key: key);
        final token = minter.mintAccessToken(email);
        // Sanity: the minter itself accepts its own token.
        expect(await minter.emailFromToken(token), equals(email));
        // The verifier rejects it purely on issuer mismatch.
        expect(await verifier.emailFromToken(token), isNull);
      });
    });
  });
}
