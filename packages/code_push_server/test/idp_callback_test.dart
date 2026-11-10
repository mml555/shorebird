import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:code_push_server/src/api.dart';
import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support.dart';

String _b64(Object json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

/// Drives GET /oauth/callback against a local stand-in for the IdP's token
/// endpoint, so the claim checks are tested as wired into the handler.
void main() {
  late Directory tmp;
  late HttpServer idp;
  late Repository repo;
  late Api api;
  var claims = <String, Object?>{};

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('cps_idp_cb');
    idp = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      idp.forEach((req) async {
        await req.drain<void>();
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'id_token': '${_b64({'alg': 'RS256'})}.${_b64(claims)}.sig',
            }),
          );
        await req.response.close();
      }),
    );
    final config = sqliteConfig(
      tmp.path,
      idpEnabled: true,
      idpTokenUrl: 'http://127.0.0.1:${idp.port}/token',
      idpIssuer: 'https://idp.test',
    );
    repo = await Repository.open(config);
    api = Api(repo, await ArtifactStore.open(config), config);
    claims = {
      'aud': 'client-id',
      'iss': 'https://idp.test',
      'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
      'email': 'idp@x.com',
      'email_verified': true,
    };
  });

  tearDown(() async {
    await idp.close(force: true);
    await repo.close();
    tmp.deleteSync(recursive: true);
  });

  Future<Response> callback() async {
    await repo.insertIdpState(
      'st',
      'http://localhost:1234/cb',
      DateTime.now().add(const Duration(minutes: 5)),
    );
    return api.handler(
      Request(
        'GET',
        Uri.parse('http://localhost:8080/oauth/callback?state=st&code=c'),
      ),
    );
  }

  Future<int> authCodes() async =>
      (await repo.db.query('SELECT code FROM auth_codes')).length;

  test('a valid token yields a code', () async {
    final r = await callback();
    expect(r.statusCode, 302);
    expect(r.headers['location'], contains('code=sb_code_'));
    expect(await authCodes(), 1);
  });

  test('a rejected token redirects with invalid_id_token, no code', () async {
    claims['aud'] = 'someone-else';
    final r = await callback();
    expect(r.statusCode, 302);
    expect(r.headers['location'], contains('error=invalid_id_token'));
    expect(await authCodes(), 0);
  });

  test('IDP_ISSUER from the config is enforced', () async {
    claims['iss'] = 'https://evil.test';
    final r = await callback();
    expect(r.headers['location'], contains('error=invalid_id_token'));
    expect(await authCodes(), 0);
  });

  test('a missing email maps to no_email', () async {
    claims.remove('email');
    final r = await callback();
    expect(r.headers['location'], contains('error=no_email'));
    expect(await authCodes(), 0);
  });
}
