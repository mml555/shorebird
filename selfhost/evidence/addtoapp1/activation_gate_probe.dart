// ADD-TO-APP-1 probe: can an add-to-app release be ACTIVATED on the
// self-hosted control plane at all? Host-side, no device, no CLI.
import 'dart:convert';
import 'dart:io';

import 'package:code_push_server/src/api.dart';
import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test/support.dart';

const _key = 'sb_api_selfhost_dev';

void main() {
  late Directory tmp;
  late Repository repo;
  late Api api;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('cps_ata');
    final config = sqliteConfig(tmp.path);
    repo = await Repository.open(config);
    api = Api(repo, await ArtifactStore.open(config), config);
  });
  tearDown(() async {
    await repo.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<Response> send(String m, String path, {Object? json, String? body,
      Map<String, String> headers = const {}}) =>
      Future.sync(() => api.handler(Request(m,
          Uri.parse('http://localhost:8080$path'),
          headers: {HttpHeaders.authorizationHeader: 'Bearer $_key', ...headers},
          body: body ?? (json == null ? null : jsonEncode(json)))));

  Future<Map<String, dynamic>> j(Response r) async =>
      jsonDecode(await r.readAsString()) as Map<String, dynamic>;

  /// Registers one release artifact and uploads real bytes so it verifies.
  Future<void> artifact(String appId, int rel, String arch) async {
    const bd = 'B';
    const bytes = 'addtoapp';
    final hash = sha256.convert(utf8.encode(bytes)).toString();
    String f(String n, String v) =>
        '--$bd\r\ncontent-disposition: form-data; name="$n"\r\n\r\n$v\r\n';
    final reg = await send('POST', '/api/v1/apps/$appId/releases/$rel/artifacts',
        headers: {HttpHeaders.contentTypeHeader: 'multipart/form-data; boundary=$bd'},
        body: '${f('arch', arch)}${f('platform', 'ios')}${f('hash', hash)}'
            '${f('size', '${bytes.length}')}--$bd--\r\n');
    final url = (await j(reg))['url'] as String;
    final token = Uri.parse(url).pathSegments.last;
    await send('POST', '/api/v1/uploads/$token',
        headers: {HttpHeaders.contentTypeHeader: 'multipart/form-data; boundary=$bd'},
        body: '--$bd\r\ncontent-disposition: form-data; name="file"; '
            'filename="a.bin"\r\n\r\n$bytes\r\n--$bd--\r\n');
  }

  Future<Response> activate(String appId, int rel) => send(
      'PATCH', '/api/v1/apps/$appId/releases/$rel',
      json: {'status': 'active', 'platform': 'ios'});

  Future<({String appId, int rel})> seed() async {
    final app = await j(await send('POST', '/api/v1/apps',
        json: {'display_name': 'ata'}));
    final rel = await j(await send('POST',
        '/api/v1/apps/${app['id']}/releases', json: {'version': '1.0.0+1'}));
    return (appId: app['id'] as String, rel: (rel['release'] as Map)['id'] as int);
  }

  test('an ios-framework (add-to-app) release CANNOT be activated', () async {
    // Exactly what `createIosFrameworkReleaseArtifacts` registers: the
    // xcframework, and (obfuscated only) a supplement. Nothing else exists.
    final s = await seed();
    await artifact(s.appId, s.rel, 'xcframework');
    final res = await activate(s.appId, s.rel);
    print('  ios-framework activation -> ${res.statusCode}: '
        '${await res.readAsString()}');
    expect(res.statusCode, HttpStatus.conflict);
  });

  test('a full-app ios release CAN be activated (the control)', () async {
    final s = await seed();
    for (final a in ['xcarchive', 'runner', 'ios_supplement']) {
      await artifact(s.appId, s.rel, a);
    }
    final res = await activate(s.appId, s.rel);
    print('  full-app ios activation -> ${res.statusCode}');
    expect(res.statusCode, HttpStatus.noContent);
  });

  test('an aar (add-to-app) release CANNOT be activated either', () async {
    final s = await seed();
    const bd = 'B';
    const bytes = 'aar';
    final hash = sha256.convert(utf8.encode(bytes)).toString();
    String f(String n, String v) =>
        '--$bd\r\ncontent-disposition: form-data; name="$n"\r\n\r\n$v\r\n';
    // `createAndroidArchiveReleaseArtifacts`: per-ABI libapp.so plus the aar.
    for (final arch in ['arm', 'aarch64', 'x86_64', 'aar']) {
      final reg = await send('POST',
          '/api/v1/apps/${s.appId}/releases/${s.rel}/artifacts',
          headers: {
            HttpHeaders.contentTypeHeader:
                'multipart/form-data; boundary=$bd',
          },
          body: '${f('arch', arch)}${f('platform', 'android')}'
              '${f('hash', hash)}${f('size', '${bytes.length}')}--$bd--\r\n');
      final url = (await j(reg))['url'] as String;
      final token = Uri.parse(url).pathSegments.last;
      await send('POST', '/api/v1/uploads/$token',
          headers: {
            HttpHeaders.contentTypeHeader:
                'multipart/form-data; boundary=$bd',
          },
          body: '--$bd\r\ncontent-disposition: form-data; name="file"; '
              'filename="a.bin"\r\n\r\n$bytes\r\n--$bd--\r\n');
    }
    final res = await send('PATCH',
        '/api/v1/apps/${s.appId}/releases/${s.rel}',
        json: {'status': 'active', 'platform': 'android'});
    print('  aar activation -> ${res.statusCode}: ${await res.readAsString()}');
    expect(res.statusCode, HttpStatus.conflict);
  });
}
