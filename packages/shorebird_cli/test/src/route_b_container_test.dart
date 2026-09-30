import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shorebird_cli/src/route_b_container.dart';
import 'package:test/test.dart';

void main() {
  group('route_b container', () {
    RouteBPatchTarget target(String selector, String body) => RouteBPatchTarget(
      library: 'package:app/main.dart',
      selector: selector,
      bytecode: Uint8List.fromList(utf8.encode(body)),
    );

    group('writeRouteBContainer', () {
      test('round-trips through the reader', () {
        final bytes = writeRouteBContainer(
          releaseBuildId: 'deadbeef',
          targets: [target('alpha', 'A'), target('Holder.get:tag', 'BB')],
        );

        final container = RouteBContainer.parse(bytes);

        expect(container.releaseBuildId, 'deadbeef');
        expect(
          container.targets.map((t) => t.selector),
          ['alpha', 'Holder.get:tag'],
        );
        expect(utf8.decode(container.targets.last.bytecode), 'BB');
      });

      test('is deterministic', () {
        // No timestamps, no ordering that depends on anything but the target
        // list. This is what makes SHA equality against the reference packer a
        // legitimate gate rather than an aspiration.
        List<int> build() => writeRouteBContainer(
          releaseBuildId: 'deadbeef',
          targets: [target('alpha', 'A'), target('beta', 'B')],
        );

        expect(sha256.convert(build()), sha256.convert(build()));
      });

      test('starts with the magic, so a wrong file fails at byte 0', () {
        final bytes = writeRouteBContainer(
          releaseBuildId: 'deadbeef',
          targets: [target('alpha', 'A')],
        );

        expect(ascii.decode(bytes.sublist(0, 8)), routeBContainerMagic);
      });

      test('refuses a container with no targets', () {
        // It would install, validate, attach nothing and report success.
        expect(
          () => writeRouteBContainer(
            releaseBuildId: 'deadbeef',
            targets: const [],
          ),
          throwsArgumentError,
        );
      });
    });

    group('RouteBContainer.parse', () {
      test('refuses a file that is not a container', () {
        expect(
          () => RouteBContainer.parse(
            Uint8List.fromList(utf8.encode('not a container at all')),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('bad magic'),
            ),
          ),
        );
      });

      test('refuses a truncated file', () {
        expect(
          () => RouteBContainer.parse(Uint8List(4)),
          throwsA(isA<FormatException>()),
        );
      });

      test('refuses an unknown format version', () {
        // A reader that tolerates unknown versions ends up defining the format
        // by what it happens to accept.
        final bytes = writeRouteBContainer(
          releaseBuildId: 'deadbeef',
          targets: [target('alpha', 'A')],
        )..buffer.asByteData().setUint32(8, 99, Endian.little);

        expect(
          () => RouteBContainer.parse(bytes),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('unsupported format version 99'),
            ),
          ),
        );
      });

      test('refuses a corrupt payload before anything is attached', () {
        // A transactional apply can unwind attachments; it cannot unwind a
        // corrupt body already running.
        final bytes = writeRouteBContainer(
          releaseBuildId: 'deadbeef',
          targets: [target('alpha', 'AAAA')],
        );
        bytes[bytes.length - 1] ^= 0xff;

        expect(
          () => RouteBContainer.parse(bytes),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('is corrupt'),
            ),
          ),
        );
      });
    });

    group('readMachOBuildId', () {
      test('agrees with dwarfdump on a real shipped App binary', () {
        // The release identity the container is stamped with, checked against
        // the tool the host pipeline used. Compared to `dwarfdump` rather than
        // to a constant: the fixture's UUID legitimately changes every time it
        // is rebuilt, and pinning it makes an ordinary release look like a
        // regression here.
        final app = File(
          '../../selfhost/fixtures/airgap_app/build/ios/archive/'
          'Runner.xcarchive/Products/Applications/Runner.app/Frameworks/'
          'App.framework/App',
        );
        if (!app.existsSync() || !Platform.isMacOS) {
          markTestSkipped('no built fixture App binary on a macOS host');
          return;
        }

        final dwarfdump = Process.runSync('dwarfdump', ['--uuid', app.path]);
        final expected = RegExp(r'UUID: ([0-9A-Fa-f-]+)')
            .firstMatch(dwarfdump.stdout as String)
            ?.group(1)
            ?.replaceAll('-', '')
            .toLowerCase();
        expect(expected, isNotNull, reason: 'dwarfdump reported no UUID');

        expect(readMachOBuildId(app.readAsBytesSync()), expected);
      });

      test('returns null for a file that is not Mach-O', () {
        // Never "any identity": a caller must refuse rather than proceed.
        expect(
          readMachOBuildId(Uint8List.fromList(utf8.encode('hello world'))),
          isNull,
        );
      });

      test('returns null for a Mach-O with no LC_UUID', () {
        final header = ByteData(32)
          ..setUint32(0, 0xfeedfacf, Endian.little)
          ..setUint32(16, 0);
        expect(readMachOBuildId(header.buffer.asUint8List()), isNull);
      });

      test('returns null rather than reading past a bad command size', () {
        final bytes = ByteData(40)
          ..setUint32(0, 0xfeedfacf, Endian.little)
          ..setUint32(16, 1, Endian.little)
          ..setUint32(32, 0x1b, Endian.little)
          ..setUint32(36, 4, Endian.little);
        expect(readMachOBuildId(bytes.buffer.asUint8List()), isNull);
      });
    });
  });
}
