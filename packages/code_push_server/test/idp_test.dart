import 'dart:convert';

import 'package:code_push_server/src/oauth.dart';
import 'package:test/test.dart';

String _b64(Object json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

const _clientId = 'client-id';
const _issuer = 'https://idp.test';

/// A token response whose id_token payload is the defaults overlaid with
/// [overrides]; a null override removes the claim.
Map<String, dynamic> _resp([Map<String, Object?> overrides = const {}]) {
  final claims = <String, Object?>{
    'aud': _clientId,
    'iss': _issuer,
    'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
    'email': 'idp@x.com',
    'email_verified': true,
    ...overrides,
  }..removeWhere((_, v) => v == null);
  return {
    'id_token': '${_b64({'alg': 'RS256'})}.${_b64(claims)}.sig',
  };
}

IdTokenResult _check(
  Map<String, dynamic> resp, {
  String issuer = '',
  bool allowUnverified = false,
}) => OAuthService.emailFromIdToken(
  resp,
  clientId: _clientId,
  issuer: issuer,
  allowUnverifiedEmail: allowUnverified,
);

void main() {
  group('OAuthService.emailFromIdToken', () {
    test('accepts a valid token', () {
      final r = _check(_resp(), issuer: _issuer);
      expect(r.email, 'idp@x.com');
      expect(r.reason, isNull);
    });

    test('ignores a top-level email in the token response', () {
      final r = _check({..._resp(), 'email': 'top@x.com'});
      expect(r.email, 'idp@x.com');
      final none = _check({'email': 'top@x.com', 'access_token': 'x'});
      expect(none.email, isNull);
      expect(none.reason, 'no_id_token');
    });

    test('rejects a malformed id_token', () {
      expect(_check({'id_token': 'not-a-jwt'}).reason, 'malformed_id_token');
      expect(_check({'id_token': 'a.b'}).reason, 'malformed_id_token');
      expect(_check({'id_token': 'a.!!.c'}).reason, 'malformed_id_token');
    });

    test('rejects a wrong or missing audience', () {
      expect(_check(_resp({'aud': 'other'})).reason, 'aud_mismatch');
      expect(_check(_resp({'aud': null})).reason, 'aud_mismatch');
      expect(_check(_resp({'aud': 42})).reason, 'aud_mismatch');
    });

    test('accepts an audience list that contains the client id', () {
      final r = _check(
        _resp({
          'aud': ['other', _clientId],
          'azp': _clientId,
        }),
      );
      expect(r.email, 'idp@x.com');
    });

    test(
      'requires azp to be the client id when there are several audiences',
      () {
        final aud = ['other', _clientId];
        expect(_check(_resp({'aud': aud})).reason, 'azp_mismatch');
        expect(
          _check(_resp({'aud': aud, 'azp': 'other'})).reason,
          'azp_mismatch',
        );
      },
    );

    test('rejects an expired or exp-less token', () {
      final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 10;
      expect(_check(_resp({'exp': past})).reason, 'expired');
      expect(_check(_resp({'exp': null})).reason, 'exp_missing');
      expect(_check(_resp({'exp': 'soon'})).reason, 'exp_missing');
    });

    test('rejects a wrong issuer only when one is configured', () {
      final other = _resp({'iss': 'https://evil.test'});
      expect(_check(other, issuer: _issuer).reason, 'iss_mismatch');
      expect(
        _check(_resp({'iss': null}), issuer: _issuer).reason,
        'iss_mismatch',
      );
      expect(_check(other).email, 'idp@x.com');
    });

    test('rejects an unverified email', () {
      expect(
        _check(_resp({'email_verified': false})).reason,
        'email_not_verified',
      );
      expect(
        _check(_resp({'email_verified': 'false'})).reason,
        'email_not_verified',
      );
    });

    test('rejects a missing email_verified', () {
      expect(
        _check(_resp({'email_verified': null})).reason,
        'email_verified_missing',
      );
    });

    test('accepts the string "true" for email_verified', () {
      expect(_check(_resp({'email_verified': 'true'})).email, 'idp@x.com');
    });

    test('the opt-out accepts a false or missing email_verified', () {
      for (final v in [false, null]) {
        final r = _check(_resp({'email_verified': v}), allowUnverified: true);
        expect(r.email, 'idp@x.com', reason: 'email_verified=$v');
      }
    });

    test('the opt-out does not relax the other checks', () {
      expect(
        _check(_resp({'aud': 'other'}), allowUnverified: true).reason,
        'aud_mismatch',
      );
    });

    test('rejects a missing email', () {
      expect(_check(_resp({'email': null})).reason, 'email_missing');
      expect(_check(_resp({'email': ''})).reason, 'email_missing');
    });
  });
}
