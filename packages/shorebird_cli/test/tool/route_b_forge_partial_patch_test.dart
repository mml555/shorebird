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

/// A minimal bytecode binary: magic, version, a header whose word at byte 12
/// is the string table offset, then the table (one-byte strings only) and a
/// trailer. Same layout the VM reads (little-endian words).
Uint8List _bytecode(List<String> strings, {int magic = 0x44424333}) {
  const tableOffset = 24;
  final header = ByteData(tableOffset)
    ..setUint32(0, magic, Endian.little)
    ..setUint32(4, 3, Endian.little)
    ..setUint32(8, strings.length, Endian.little)
    ..setUint32(12, tableOffset, Endian.little)
    ..setUint32(16, 0xAABBCCDD, Endian.little);
  final table = BytesBuilder()
    ..add(
      (ByteData(8)
            ..setUint32(0, strings.length, Endian.little)
            ..setUint32(4, 0, Endian.little))
          .buffer
          .asUint8List(),
    );
  var end = 0;
  final ends = ByteData(strings.length * 4);
  for (var i = 0; i < strings.length; i++) {
    end += strings[i].length;
    ends.setUint32(i * 4, end, Endian.little);
  }
  table
    ..add(ends.buffer.asUint8List())
    ..add(strings.expand((e) => e.codeUnits).toList())
    ..add([0xEE, 0xFF]);
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...table.takeBytes(),
  ]);
}

/// Indexes where [a] and [b], of equal length, differ.
List<int> _diff(Uint8List a, Uint8List b) {
  expect(a.length, b.length);
  return [
    for (var i = 0; i < a.length; i++)
      if (a[i] != b[i]) i,
  ];
}

Uint8List _container(List<Uint8List> payloads) => writeRouteBContainer(
  releaseBuildId: 'abc123',
  targets: [
    for (var i = 0; i < payloads.length; i++)
      RouteBPatchTarget(
        library: 'package:app/f$i.dart',
        selector: 's$i',
        bytecode: payloads[i],
      ),
  ],
);

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

    group('reuseFirstPayload', () {
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

      test("keeps the last selector and gives it the first's payload", () {
        final parsed = RouteBContainer.parse(
          forgePartialContainer(two, reuseFirstPayload: true),
        );
        expect(parsed.releaseBuildId, 'abc123');
        expect(parsed.targets, hasLength(2));
        expect(parsed.targets.first.selector, 'real');
        expect(parsed.targets.first.bytecode, payload);
        expect(parsed.targets.last.library, 'package:app/other.dart');
        expect(parsed.targets.last.selector, 'second');
        expect(parsed.targets.last.bytecode, payload);
      });

      test('keeps every target before the last, in order', () {
        final third = Uint8List.fromList([8, 9]);
        final three = writeRouteBContainer(
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
            RouteBPatchTarget(
              library: 'package:app/third.dart',
              selector: 'third',
              bytecode: third,
            ),
          ],
        );
        final targets = RouteBContainer.parse(
          forgePartialContainer(three, reuseFirstPayload: true),
        ).targets;
        expect(targets.map((t) => t.selector), ['real', 'second', 'third']);
        expect(targets[1].bytecode, second);
        expect(targets[2].library, 'package:app/third.dart');
        expect(targets[2].bytecode, payload);
      });

      test('refuses a container whose last payload is already the first', () {
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
          () => forgePartialContainer(same, reuseFirstPayload: true),
          throwsA(
            isA<ForgeException>().having(
              (e) => e.message,
              'message',
              contains("already carries the first target's payload"),
            ),
          ),
        );
      });

      test('refuses a one-target container', () {
        expect(
          () => forgePartialContainer(original, reuseFirstPayload: true),
          throwsA(
            isA<ForgeException>().having(
              (e) => e.message,
              'message',
              contains('at least two targets'),
            ),
          ),
        );
      });

      test('refuses to combine with retargetLast', () {
        expect(
          () => forgePartialContainer(
            two,
            retargetLast: true,
            reuseFirstPayload: true,
          ),
          throwsA(
            isA<ForgeException>().having(
              (e) => e.message,
              'message',
              contains('pick one'),
            ),
          ),
        );
      });
    });

    group('badFormatLast', () {
      final first = _bytecode(['dart:core', 'a']);
      final last = _bytecode(['dart:core', 'bb']);

      test('changes only the format version word of the last payload', () {
        final parsed = RouteBContainer.parse(
          forgePartialContainer(_container([first, last]), badFormatLast: true),
        );
        expect(parsed.targets.first.bytecode, first);
        expect(parsed.targets.last.library, 'package:app/f1.dart');
        expect(parsed.targets.last.selector, 's1');
        final forged = parsed.targets.last.bytecode;
        expect(_diff(last, forged), [4, 5, 6, 7]);
        expect(
          ByteData.sublistView(forged).getUint32(4, Endian.little),
          badBytecodeFormatVersion,
        );
        expect(forged.sublist(0, 4), last.sublist(0, 4));
      });

      test('keeps every earlier target', () {
        final mid = _bytecode(['dart:core', 'c']);
        final targets = RouteBContainer.parse(
          forgePartialContainer(
            _container([first, mid, last]),
            badFormatLast: true,
          ),
        ).targets;
        expect(targets[0].bytecode, first);
        expect(targets[1].bytecode, mid);
      });

      test('refuses a payload without the magic', () {
        final bad = _bytecode(['dart:core'], magic: 0x12345678);
        expect(
          () => forgePartialContainer(
            _container([first, bad]),
            badFormatLast: true,
          ),
          throwsA(
            isA<ForgeException>().having(
              (e) => e.message,
              'message',
              contains('bytecode magic'),
            ),
          ),
        );
      });

      test('refuses a one-target container', () {
        expect(
          () => forgePartialContainer(_container([last]), badFormatLast: true),
          throwsA(
            isA<ForgeException>().having(
              (e) => e.message,
              'message',
              contains('at least two targets'),
            ),
          ),
        );
      });

      test('refuses a last payload equal to the first', () {
        expect(
          () => forgePartialContainer(
            _container([first, Uint8List.fromList(first)]),
            badFormatLast: true,
          ),
          throwsA(isA<ForgeException>()),
        );
      });

      test('refuses to combine with another mode', () {
        for (final other in [
          () => forgePartialContainer(
            _container([first, last]),
            badFormatLast: true,
            retargetLast: true,
          ),
          () => forgePartialContainer(
            _container([first, last]),
            badFormatLast: true,
            reuseFirstPayload: true,
          ),
          () => forgePartialContainer(
            _container([first, last]),
            badFormatLast: true,
            unresolveLast: true,
          ),
        ]) {
          expect(other, throwsA(isA<ForgeException>()));
        }
      });
    });

    group('unresolveLast', () {
      final first = _bytecode(['dart:core', 'a']);

      Uint8List forge(Uint8List last, {String? uri}) => RouteBContainer.parse(
        forgePartialContainer(
          _container([first, last]),
          unresolveLast: true,
          unresolveUri: uri ?? defaultUnresolveUri,
        ),
      ).targets.last.bytecode;

      test('renames the string, same length, nothing else', () {
        final last = _bytecode(['x', 'dart:core', 'dart:async', 'dart:core']);
        final forged = forge(last);
        // Strings are deduplicated by the compiler, but every equal string is
        // changed, so a repeat is too.
        final text = String.fromCharCodes(forged);
        expect(text, contains('dart:cor_'));
        expect(text, isNot(contains('dart:core')));
        expect(text, contains('dart:async'));
        final changed = _diff(last, forged);
        expect(changed, hasLength(2));
        for (final i in changed) {
          expect(last[i], 0x65); // e
          expect(forged[i], 0x5f); // _
        }
      });

      test('keeps the earlier target, library and selector', () {
        final parsed = RouteBContainer.parse(
          forgePartialContainer(
            _container([
              first,
              _bytecode(['dart:core']),
            ]),
            unresolveLast: true,
          ),
        );
        expect(parsed.targets.first.bytecode, first);
        expect(parsed.targets.last.library, 'package:app/f1.dart');
        expect(parsed.targets.last.selector, 's1');
      });

      test('uses ~ when the URI ends in an underscore', () {
        final forged = forge(_bytecode(['pkg:a_']), uri: 'pkg:a_');
        expect(String.fromCharCodes(forged), contains('pkg:a~'));
      });

      test('refuses a URI the payload does not have', () {
        expect(
          () => forge(_bytecode(['dart:async'])),
          throwsA(
            isA<ForgeException>().having(
              (e) => e.message,
              'message',
              contains('does not reference'),
            ),
          ),
        );
      });

      test('refuses a URI that is the prefix of a longer string', () {
        expect(
          () => forge(_bytecode(['dart:core', 'dart:core_patch'])),
          throwsA(
            isA<ForgeException>().having(
              (e) => e.message,
              'message',
              contains('dart:core_patch'),
            ),
          ),
        );
      });

      test('is not fooled by strings meeting inside the contents', () {
        // `dart:co` + `re` concatenate to dart:core without being one string.
        expect(
          () => forge(_bytecode(['dart:co', 're'])),
          throwsA(isA<ForgeException>()),
        );
      });

      test('refuses when the replacement already exists', () {
        expect(
          () => forge(_bytecode(['dart:core', 'dart:cor_'])),
          throwsA(isA<ForgeException>()),
        );
      });

      test('refuses a payload without the magic', () {
        expect(
          () => forge(_bytecode(['dart:core'], magic: 1)),
          throwsA(isA<ForgeException>()),
        );
      });

      test('refuses a one-target container', () {
        expect(
          () => forgePartialContainer(
            _container([
              _bytecode(['dart:core']),
            ]),
            unresolveLast: true,
          ),
          throwsA(
            isA<ForgeException>().having(
              (e) => e.message,
              'message',
              contains('at least two targets'),
            ),
          ),
        );
      });

      test('refuses a last payload equal to the first', () {
        expect(
          () => forge(Uint8List.fromList(first)),
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
