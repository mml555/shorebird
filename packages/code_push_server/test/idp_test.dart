import 'dart:convert';

import 'package:code_push_server/src/oauth.dart';
import 'package:test/test.dart';

String _b64(Object json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

void main() {
  group('OAuthService.emailFromIdToken', () {
    test('reads a top-level email', () {
      expect(OAuthService.emailFromIdToken({'email': 'a@b.com'}), 'a@b.com');
    });

    test('reads the email claim from an id_token JWT', () {
      final jwt =
          '${_b64({'alg': 'RS256'})}.${_b64({'email': 'idp@x.com', 'sub': 'u1'})}.sig';
      expect(OAuthService.emailFromIdToken({'id_token': jwt}), 'idp@x.com');
    });

    test('prefers a top-level email over the id_token', () {
      final jwt = '${_b64({})}.${_b64({'email': 'jwt@x.com'})}.sig';
      expect(
        OAuthService.emailFromIdToken({'email': 'top@x.com', 'id_token': jwt}),
        'top@x.com',
      );
    });

    test('returns null when no email is present', () {
      expect(OAuthService.emailFromIdToken({'access_token': 'x'}), isNull);
      final noEmail = '${_b64({})}.${_b64({'sub': 'u1'})}.sig';
      expect(OAuthService.emailFromIdToken({'id_token': noEmail}), isNull);
    });

    test('returns null for a malformed id_token', () {
      expect(OAuthService.emailFromIdToken({'id_token': 'not-a-jwt'}), isNull);
      expect(OAuthService.emailFromIdToken({'id_token': 'a.b'}), isNull);
    });
  });
}
