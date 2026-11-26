// cspell:words pkeyopt keygen
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shorebird_cli/src/code_signer.dart';
import 'package:shorebird_cli/src/route_b_container.dart';
import 'package:test/test.dart';

import '../../tool/route_b_forge_partial_patch.dart';
import '../src/helpers.dart';

// Throwaway 2048-bit RSA keys generated for these tests only. They protect
// nothing and sign nothing outside this file.
Future<({File priv, String pub})> _keyPair(Directory dir, String name) async {
  final priv = File('${dir.path}/$name.pem');
  final r1 = await Process.run('openssl', [
    'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', //
    '-out', priv.path,
  ]);
  expect(r1.exitCode, 0, reason: '${r1.stderr}');
  final r2 = await Process.run('openssl', ['rsa', '-in', priv.path, '-pubout']);
  expect(r2.exitCode, 0, reason: '${r2.stderr}');
  return (priv: priv, pub: r2.stdout as String);
}

void main() {
  useTempWorkingDirectory();

  group('forgePartialContainer', () {
    late Uint8List original;
    final payload = Uint8List.fromList([1, 2, 3, 4]);

    setUp(() {
      original = writeRouteBContainer(
        releaseBuildId: 'abc123',
        targets: [
          RouteBPatchTarget(
            library: 'package:app/main.dart',
            selector: 'real',
            bytecode: payload,
          ),
        ],
      );
    });

    test('round-trips through the container reader', () {
      final parsed = RouteBContainer.parse(forgePartialContainer(original));
      expect(parsed.targets, hasLength(2));
    });

    test('keeps the real target first and the release build id', () {
      final parsed = RouteBContainer.parse(forgePartialContainer(original));
      expect(parsed.releaseBuildId, 'abc123');
      expect(parsed.targets.first.selector, 'real');
      expect(parsed.targets.first.bytecode, payload);
    });

    test('appends the bogus target last, with the real payload copied', () {
      final parsed = RouteBContainer.parse(
        forgePartialContainer(original, bogusSelector: 'nope'),
      );
      expect(parsed.targets.last.selector, 'nope');
      expect(parsed.targets.last.library, 'package:app/main.dart');
      expect(parsed.targets.last.bytecode, payload);
    });

    test('defaults to a clearly fake selector', () {
      final parsed = RouteBContainer.parse(forgePartialContainer(original));
      expect(parsed.targets.last.selector, defaultBogusSelector);
    });

    test('refuses a selector the container already has', () {
      expect(
        () => forgePartialContainer(original, bogusSelector: 'real'),
        throwsA(isA<ForgeException>()),
      );
    });

    test('refuses bytes that are not a container', () {
      expect(() => forgePartialContainer(Uint8List(32)), throwsFormatException);
    });

    group('retargetLast', () {
      final second = Uint8List.fromList([5, 6, 7]);
      late Uint8List two;

      setUp(() {
        two = writeRouteBContainer(
          releaseBuildId: 'abc123',
          targets: [
            RouteBPatchTarget(
              library: 'package:app/main.dart',
              selector: 'real',
              bytecode: payload,
            ),
            RouteBPatchTarget(
              library: 'package:app/other.dart',
              selector: 'second',
              bytecode: second,
            ),
          ],
        );
      });

      test('renames the last target and keeps its own payload', () {
        final parsed = RouteBContainer.parse(
          forgePartialContainer(two, retargetLast: true),
        );
        expect(parsed.releaseBuildId, 'abc123');
        expect(parsed.targets, hasLength(2));
        expect(parsed.targets.first.selector, 'real');
        expect(parsed.targets.first.bytecode, payload);
        expect(parsed.targets.last.selector, defaultBogusSelector);
        expect(parsed.targets.last.library, 'package:app/other.dart');
        expect(parsed.targets.last.bytecode, second);
      });

      test('refuses a last payload identical to an earlier one', () {
        final same = writeRouteBContainer(
          releaseBuildId: 'abc123',
          targets: [
            RouteBPatchTarget(
              library: 'package:app/main.dart',
              selector: 'real',
              bytecode: payload,
            ),
            RouteBPatchTarget(
              library: 'package:app/main.dart',
              selector: 'second',
              bytecode: Uint8List.fromList(payload),
            ),
          ],
        );
        expect(
          () => forgePartialContainer(same, retargetLast: true),
          throwsA(
            isA<ForgeException>().having(
              (e) => e.message,
              'message',
              contains('same payload'),
            ),
          ),
        );
      });

      test('refuses a one-target container', () {
        expect(
          () => forgePartialContainer(original, retargetLast: true),
          throwsA(
            isA<ForgeException>().having(
              (e) => e.message,
              'message',
              contains('at least two targets'),
            ),
          ),
        );
      });

      test('refuses a selector the container already has', () {
        expect(
          () => forgePartialContainer(
            two,
            retargetLast: true,
            bogusSelector: 'real',
          ),
          throwsA(isA<ForgeException>()),
        );
      });
    });
  });

  group('signAndVerify', () {
    late Directory dir;
    late Uint8List forged;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('forge_test_');
      forged = forgePartialContainer(
        writeRouteBContainer(
          releaseBuildId: 'abc123',
          targets: [
            RouteBPatchTarget(
              library: 'package:app/main.dart',
              selector: 'real',
              bytecode: Uint8List.fromList([9, 9]),
            ),
          ],
        ),
      );
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test(
      'signs the hex sha256 of the bytes; verifies with the public key',
      () async {
        final keys = await _keyPair(dir, 'a');
        final signature = signAndVerify(
          forged,
          privateKeyFile: keys.priv,
          publicKeyPem: keys.pub,
        );
        expect(
          CodeSigner().verify(
            message: sha256.convert(forged).toString(),
            signature: signature,
            publicKeyPem: keys.pub,
          ),
          isTrue,
        );
      },
    );

    test('the signature does not cover other bytes', () async {
      final keys = await _keyPair(dir, 'a');
      final signature = signAndVerify(
        forged,
        privateKeyFile: keys.priv,
        publicKeyPem: keys.pub,
      );
      expect(
        CodeSigner().verify(
          message: sha256.convert([...forged, 0]).toString(),
          signature: signature,
          publicKeyPem: keys.pub,
        ),
        isFalse,
      );
    });

    test('fails against a public key from another pair', () async {
      final a = await _keyPair(dir, 'a');
      final b = await _keyPair(dir, 'b');
      expect(
        () =>
            signAndVerify(forged, privateKeyFile: a.priv, publicKeyPem: b.pub),
        throwsA(isA<ForgeException>()),
      );
    });
  });
}
