// cspell:words pkce
// Upstream 1.6.138 login: a standard authorization-code request with PKCE
// (`redirect_uri`, `state`, S256 `code_challenge`), RFC 7009 `/revoke`, and
// the older `continue` flow that sends none of that.
import 'dart:convert';
import 'dart:io';

import 'package:code_push_server/src/api.dart';
import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support.dart';

const _key = 'sb_api_selfhost_dev';
// RFC 7636 appendix B.
const _verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
const _challenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';

void main() {
  late Directory tmp;
  late Repository repo;
  late Api api;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('cps_pkce');
    final config = sqliteConfig(tmp.path);
    repo = await Repository.open(config);
    api = Api(repo, await ArtifactStore.open(config), config);
  });

  tearDown(() async {
    await repo.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<Response> send(
    String method,
    String path, {
    Map<String, String>? form,
  }) => Future.sync(
    () => api.handler(
      Request(
        method,
        Uri.parse('http://localhost:8080$path'),
        headers: form == null
            ? {}
            : {'content-type': 'application/x-www-form-urlencoded'},
        body: form == null ? null : Uri(queryParameters: form).query,
      ),
    ),
  );

  /// Logs in the way upstream's CLI does, returning the redirect's query.
  Future<Map<String, String>> login({
    String? challenge = _challenge,
    String state = 'st4te',
  }) async {
    final query = Uri(
      queryParameters: {
        'response_type': 'code',
        'client_id': 'shorebird-cli',
        'redirect_uri': 'http://localhost:4242/callback',
        'scope': 'api',
        'state': state,
        'code_challenge': ?challenge,
        if (challenge != null) 'code_challenge_method': 'S256',
      },
    ).query;
    final form = await send('GET', '/login?$query');
    expect(form.statusCode, HttpStatus.ok);
    final html = await form.readAsString();
    final cont = RegExp('name="continue" value="([^"]*)"')
        .firstMatch(html)!
        .group(1)!
        .replaceAll('&#47;', '/')
        .replaceAll('&amp;', '&');
    final hasChallenge = html.contains('name="code_challenge"');
    expect(hasChallenge, challenge != null);
    final post = await send(
      'POST',
      '/login',
      form: {
        'continue': cont,
        'api_key': _key,
        'code_challenge': ?(hasChallenge ? challenge : null),
      },
    );
    expect(
      post.statusCode,
      HttpStatus.found,
      reason: await post.readAsString(),
    );
    final loc = Uri.parse(post.headers[HttpHeaders.locationHeader]!);
    expect(loc.origin, 'http://localhost:4242');
    expect(loc.path, '/callback');
    return loc.queryParameters;
  }

  Future<Response> token(Map<String, String> form) =>
      send('POST', '/token', form: form);

  test('the S256 challenge matches the RFC 7636 test vector', () {
    expect(
      base64Url
          .encode(sha256.convert(ascii.encode(_verifier)).bytes)
          .replaceAll('=', ''),
      _challenge,
    );
    expect(Api.pkceVerifierMatches(_verifier, _challenge), isTrue);
    expect(Api.pkceVerifierMatches('${_verifier}x', _challenge), isFalse);
    expect(Api.pkceVerifierMatches('short', _challenge), isFalse);
  });

  test('login echoes state and the code redeems with its verifier', () async {
    final q = await login();
    expect(q['state'], 'st4te');
    final r = await token({
      'grant_type': 'authorization_code',
      'code': q['code']!,
      'code_verifier': _verifier,
      'client_id': 'shorebird-cli',
      'redirect_uri': 'http://localhost:4242/callback',
    });
    expect(r.statusCode, HttpStatus.ok);
    final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    expect(body['access_token'], isNotEmpty);
    expect(body['refresh_token'], isNotEmpty);
  });

  test('a wrong or missing verifier is refused, and burns the code', () async {
    for (final verifier in [null, 'x' * 43]) {
      final q = await login();
      final r = await token({
        'grant_type': 'authorization_code',
        'code': q['code']!,
        'code_verifier': ?verifier,
      });
      expect(r.statusCode, HttpStatus.badRequest);
      expect(jsonDecode(await r.readAsString())['code'], 'invalid_grant');
      // Not retryable with the right verifier.
      final retry = await token({
        'grant_type': 'authorization_code',
        'code': q['code']!,
        'code_verifier': _verifier,
      });
      expect(retry.statusCode, HttpStatus.badRequest);
    }
  });

  test('a redirect_uri login without a PKCE challenge is refused', () async {
    for (final extra in [
      <String, String>{},
      {'code_challenge_method': 'S256'},
    ]) {
      final r = await send(
        'GET',
        '/login?${Uri(queryParameters: {'redirect_uri': 'http://localhost:1/callback', 'state': 's', ...extra}).query}',
      );
      expect(r.statusCode, HttpStatus.badRequest, reason: '$extra');
      expect(await r.readAsString(), contains('code_challenge'));
    }
  });

  test('a login with no challenge (older CLI, `continue`) redeems without a '
      'verifier', () async {
    final cont = 'http://localhost:1234/cb';
    expect(
      (await send(
        'GET',
        '/login?continue=${Uri.encodeQueryComponent(cont)}',
      )).statusCode,
      HttpStatus.ok,
    );
    final post = await send(
      'POST',
      '/login',
      form: {'continue': cont, 'api_key': _key},
    );
    final code = Uri.parse(
      post.headers[HttpHeaders.locationHeader]!,
    ).queryParameters['code']!;
    final r = await token({'grant_type': 'authorization_code', 'code': code});
    expect(r.statusCode, HttpStatus.ok);
  });

  test('/cli/login-result is public and says how the login went', () async {
    final ok = await send('GET', '/cli/login-result?status=success');
    expect(ok.statusCode, HttpStatus.ok);
    expect(ok.headers[HttpHeaders.contentTypeHeader], contains('text/html'));
    expect(await ok.readAsString(), contains('logged in'));
    final bad = await send('GET', '/cli/login-result?status=failed');
    expect(bad.statusCode, HttpStatus.ok);
    expect(await bad.readAsString(), contains('did not complete'));
    // Anything else is treated as a failure and never reflected.
    final evil = await send(
      'GET',
      '/cli/login-result?status=%3Cscript%3Ealert(1)%3C/script%3E',
    );
    final html = await evil.readAsString();
    expect(html, isNot(contains('<script>alert')));
    expect(html, contains('did not complete'));
  });

  test('the older `continue` flow is unchanged', () async {
    final form = await send(
      'GET',
      '/login?continue=${Uri.encodeQueryComponent('http://localhost:1234/cb')}',
    );
    expect(form.statusCode, HttpStatus.ok);
    final post = await send(
      'POST',
      '/login',
      form: {'continue': 'http://localhost:1234/cb', 'api_key': _key},
    );
    final loc = Uri.parse(post.headers[HttpHeaders.locationHeader]!);
    expect(loc.queryParameters.keys, ['code']);
  });

  test(
    'plain, malformed challenges and non-loopback redirects are 400',
    () async {
      final base = {'redirect_uri': 'http://localhost:1/callback'};
      for (final extra in [
        {'code_challenge': _challenge, 'code_challenge_method': 'plain'},
        {'code_challenge': _challenge},
        {'code_challenge': 'short', 'code_challenge_method': 'S256'},
      ]) {
        final r = await send(
          'GET',
          '/login?${Uri(queryParameters: {...base, ...extra}).query}',
        );
        expect(r.statusCode, HttpStatus.badRequest, reason: '$extra');
      }
      final off = await send(
        'GET',
        '/login?${Uri(queryParameters: {'redirect_uri': 'http://evil.test/cb', 'state': 's'}).query}',
      );
      expect(off.statusCode, HttpStatus.badRequest);
    },
  );

  test(
    '/revoke kills the refresh token, and answers 200 for any token',
    () async {
      final q = await login();
      final issued =
          jsonDecode(
                await (await token({
                  'grant_type': 'authorization_code',
                  'code': q['code']!,
                  'code_verifier': _verifier,
                })).readAsString(),
              )
              as Map<String, dynamic>;
      final refresh = issued['refresh_token'] as String;
      expect(
        (await send(
          'POST',
          '/revoke',
          form: {
            'token': refresh,
            'token_type_hint': 'refresh_token',
            'client_id': 'shorebird-cli',
          },
        )).statusCode,
        HttpStatus.ok,
      );
      expect(
        (await token({
          'grant_type': 'refresh_token',
          'refresh_token': refresh,
        })).statusCode,
        HttpStatus.badRequest,
      );
      expect(
        (await send(
          'POST',
          '/revoke',
          form: {'token': 'never-existed'},
        )).statusCode,
        HttpStatus.ok,
      );
    },
  );
}
