// cspell:words pkeyopt keygen
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shorebird_cli/src/route_b_container.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import '../../tool/route_b_forge_partial_patch.dart';
import '../src/helpers.dart';

String _release(int id, String version) => jsonEncode({
  'id': id,
  'app_id': 'app',
  'version': version,
  'flutter_revision': 'r',
  'platforms': <String, Object?>{},
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
});

void main() {
  useTempWorkingDirectory();

  group('runForge', () {
    late Directory dir;
    late File container;
    late File priv;
    late File pub;
    late StringBuffer out;
    late StringBuffer err;
    late List<String> calls;
    late CodePushClient client;
    late List<String> channels;
    late File shim;

    List<String> base(List<String> more) => [
      '--$acknowledgeFlag',
      '--container=${container.path}',
      '--private-key=${priv.path}',
      '--public-key=${pub.path}',
      '--app-id=app',
      '--release-version=1.0.0+1',
      ...more,
    ];

    Future<int> run(List<String> args) => runForge(
      args,
      out: out,
      err: err,
      environment: {
        'SHOREBIRD_TOKEN': 't',
        'SHOREBIRD_HOSTED_URL': 'http://h',
        'HOME': dir.path,
      },
      clientFactory: (_, _) => client,
    );

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('forge_run_');
      priv = File('${dir.path}/k.pem');
      final r1 = await Process.run('openssl', [
        'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', //
        '-out', priv.path,
      ]);
      expect(r1.exitCode, 0);
      pub = File('${dir.path}/k.pub')
        ..writeAsStringSync(
          (await Process.run('openssl', [
                'rsa', '-in', priv.path, '-pubout', //
              ])).stdout
              as String,
        );
      container = File('${dir.path}/patch.sbrbptch')
        ..writeAsBytesSync(
          writeRouteBContainer(
            releaseBuildId: 'abc',
            targets: [
              RouteBPatchTarget(
                library: 'package:a/a.dart',
                selector: 'f',
                bytecode: Uint8List.fromList([1]),
              ),
            ],
          ),
        );
      // Stands in for the engine `patch` tool: base, container, diff.
      shim = File('${dir.path}/patch')
        ..writeAsStringSync('#!/bin/sh\ncp "\$2" "\$3"\n');
      await Process.run('chmod', ['+x', shim.path]);
      out = StringBuffer();
      err = StringBuffer();
      calls = [];
      channels = ['beta'];
      client = CodePushClient(
        hostedUri: Uri.parse('http://h'),
        httpClient: MockClient((req) async {
          calls.add('${req.method} ${req.url.path}');
          final path = req.url.path;
          if (path.endsWith('/releases')) {
            return http.Response(
              jsonEncode({
                'releases': [jsonDecode(_release(7, '1.0.0+1'))],
              }),
              200,
            );
          }
          if (path.endsWith('/channels')) {
            return http.Response(
              jsonEncode([
                for (var i = 0; i < channels.length; i++)
                  {'id': i + 1, 'app_id': 'app', 'name': channels[i]},
              ]),
              200,
            );
          }
          if (path.endsWith('/artifacts')) {
            return http.Response(
              jsonEncode({
                'id': 1,
                'patch_id': 3,
                'arch': 'aarch64',
                'platform': 'ios',
                'hash': 'h',
                'size': 1,
                'url': 'http://u/up',
              }),
              200,
            );
          }
          if (path.endsWith('/patches')) {
            return http.Response(jsonEncode({'id': 3, 'number': 1}), 201);
          }
          return http.Response('{}', 200);
        }),
      );
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('refuses without the acknowledgement flag', () async {
      final code = await run(
        base(['--channel=beta']).skip(1).toList(),
      );
      expect(code, isNot(0));
      expect(err.toString(), contains(acknowledgeFlag));
      expect(calls, isEmpty);
    });

    test('refuses without --channel', () async {
      expect(await run(base([])), isNot(0));
      expect(err.toString(), contains('--channel is required'));
    });

    test('refuses stable without --allow-stable, before any request', () async {
      expect(await run(base(['--channel=stable'])), isNot(0));
      expect(err.toString(), contains(allowStableFlag));
      expect(calls, isEmpty);
    });

    test('dry run writes the forged file and publishes nothing', () async {
      expect(await run(base(['--channel=beta', '--dry-run'])), 0);
      final forged = File('${container.path}.partial');
      expect(forged.existsSync(), isTrue);
      expect(
        RouteBContainer.parse(forged.readAsBytesSync()).targets,
        hasLength(2),
      );
      expect(calls, isEmpty);
    });

    test('--retarget-last renames the last target in a dry run', () async {
      final two = File('${dir.path}/two.sbrbptch')
        ..writeAsBytesSync(
          writeRouteBContainer(
            releaseBuildId: 'abc123',
            targets: [
              RouteBPatchTarget(
                library: 'package:app/main.dart',
                selector: 'real',
                bytecode: Uint8List.fromList([1, 2, 3]),
              ),
              RouteBPatchTarget(
                library: 'package:app/main.dart',
                selector: 'second',
                bytecode: Uint8List.fromList([4, 5, 6]),
              ),
            ],
          ),
        );
      final code = await run([
        ...base(['--channel=beta', '--dry-run', '--retarget-last']),
        '--container=${two.path}',
      ]);
      expect(code, 0, reason: err.toString());
      final targets = RouteBContainer.parse(
        File('${two.path}.partial').readAsBytesSync(),
      ).targets;
      expect(targets.map((t) => t.selector), ['real', defaultBogusSelector]);
      expect(calls, isEmpty);
    });

    test('--retarget-last refuses a one-target container', () async {
      expect(
        await run(base(['--channel=beta', '--dry-run', '--retarget-last'])),
        64,
      );
      expect(err.toString(), contains('at least two targets'));
      expect(File('${container.path}.partial').existsSync(), isFalse);
    });

    test(
      '--reuse-first-payload keeps the last selector in a dry run',
      () async {
        final two = File('${dir.path}/two.sbrbptch')
          ..writeAsBytesSync(
            writeRouteBContainer(
              releaseBuildId: 'abc123',
              targets: [
                RouteBPatchTarget(
                  library: 'package:app/main.dart',
                  selector: 'real',
                  bytecode: Uint8List.fromList([1, 2, 3]),
                ),
                RouteBPatchTarget(
                  library: 'package:app/main.dart',
                  selector: 'second',
                  bytecode: Uint8List.fromList([4, 5, 6]),
                ),
              ],
            ),
          );
        final code = await run([
          ...base(['--channel=beta', '--dry-run', '--reuse-first-payload']),
          '--container=${two.path}',
        ]);
        expect(code, 0, reason: err.toString());
        final targets = RouteBContainer.parse(
          File('${two.path}.partial').readAsBytesSync(),
        ).targets;
        expect(targets.map((t) => t.selector), ['real', 'second']);
        expect(targets.last.bytecode, [1, 2, 3]);
        expect(out.toString(), contains("carries target 1's payload"));
        expect(calls, isEmpty);
      },
    );

    test('refuses --retarget-last with --reuse-first-payload', () async {
      expect(
        await run(
          base([
            '--channel=beta',
            '--dry-run',
            '--retarget-last',
            '--reuse-first-payload',
          ]),
        ),
        64,
      );
      expect(err.toString(), contains('pick one'));
      expect(File('${container.path}.partial').existsSync(), isFalse);
    });

    test('refuses --bogus-selector with --reuse-first-payload', () async {
      expect(
        await run(
          base([
            '--channel=beta',
            '--dry-run',
            '--reuse-first-payload',
            '--bogus-selector=nope',
          ]),
        ),
        64,
      );
      expect(err.toString(), contains('has no effect'));
      expect(File('${container.path}.partial').existsSync(), isFalse);
    });

    test('refuses a channel that does not exist and creates none', () async {
      expect(
        await run(base(['--channel=nope', '--patch-tool=${shim.path}'])),
        isNot(0),
      );
      expect(err.toString(), contains('no channel nope'));
      expect(calls.where((c) => c.startsWith('POST')), isEmpty);
    });

    test('publishes in the CLI order and prints the build id', () async {
      expect(
        await run(base(['--channel=beta', '--patch-tool=${shim.path}'])),
        0,
      );
      expect(out.toString(), contains('CHECK THAT abc'));
      final posts = calls.where((c) => c.startsWith('POST')).toList();
      expect(posts, [
        'POST /api/v1/apps/app/patches',
        'POST /api/v1/apps/app/patches/3/artifacts',
        'POST /up',
        'POST /api/v1/apps/app/patches/promote',
      ]);
    });
  });
}
