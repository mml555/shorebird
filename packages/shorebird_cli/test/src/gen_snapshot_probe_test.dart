import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/gen_snapshot_probe.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group(GenSnapshotProbe, () {
    const flutterRevision = 'release-pinned-revision';

    late Directory shorebirdRoot;
    late ShorebirdEnv shorebirdEnv;
    late GenSnapshotProbe probe;

    /// The engine artifact cache for [flutterRevision].
    Directory engineDirectory() => Directory(
      p.join(
        shorebirdRoot.path,
        'bin',
        'cache',
        'flutter',
        flutterRevision,
        'bin',
        'cache',
        'artifacts',
        'engine',
      ),
    );

    /// Writes a fake gen_snapshot at [relativePath] under the engine cache,
    /// padded so the content straddles the probe's 1MiB read chunks.
    File writeGenSnapshot(
      String relativePath, {
      required List<String> strings,
      int padding = 0,
    }) {
      final contents = StringBuffer(' ' * padding);
      for (final s in strings) {
        contents.write('$s ');
      }
      return File(p.join(engineDirectory().path, relativePath))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents.toString());
    }

    R runWithOverrides<R>(R Function() body) => runScoped(
      body,
      values: {shorebirdEnvRef.overrideWith(() => shorebirdEnv)},
    );

    setUp(() {
      shorebirdRoot = Directory.systemTemp.createTempSync();
      shorebirdEnv = MockShorebirdEnv();
      probe = GenSnapshotProbe();
      when(
        () => shorebirdEnv.copyWith(
          flutterRevisionOverride: any(named: 'flutterRevisionOverride'),
        ),
      ).thenAnswer((invocation) {
        final revision =
            invocation.namedArguments[#flutterRevisionOverride] as String;
        final env = MockShorebirdEnv();
        when(() => env.flutterDirectory).thenReturn(
          Directory(
            p.join(shorebirdRoot.path, 'bin', 'cache', 'flutter', revision),
          ),
        );
        return env;
      });
    });

    tearDown(() {
      if (shorebirdRoot.existsSync()) shorebirdRoot.deleteSync(recursive: true);
    });

    Future<GenSnapshotFlagSupport> ask(ReleasePlatform platform) =>
        runWithOverrides(
          () => probe.supportsLoadObfuscationMap(
            flutterRevision: flutterRevision,
            platform: platform,
          ),
        );

    group('resolveGenSnapshots', () {
      test('returns nothing when the engine cache does not exist', () {
        expect(
          runWithOverrides(
            () => probe.resolveGenSnapshots(
              flutterRevision: flutterRevision,
              platform: ReleasePlatform.ios,
            ),
          ),
          isEmpty,
        );
      });

      test('finds the iOS gen_snapshot', () {
        writeGenSnapshot(
          p.join('ios-release', 'gen_snapshot_arm64'),
          strings: ['--save-obfuscation-map'],
        );

        final resolved = runWithOverrides(
          () => probe.resolveGenSnapshots(
            flutterRevision: flutterRevision,
            platform: ReleasePlatform.ios,
          ),
        );

        expect(resolved, hasLength(1));
        expect(p.basename(resolved.single.path), 'gen_snapshot_arm64');
      });

      test('ignores non-release artifact directories', () {
        writeGenSnapshot(
          p.join('ios-profile', 'gen_snapshot_arm64'),
          strings: ['--save-obfuscation-map'],
        );

        expect(
          runWithOverrides(
            () => probe.resolveGenSnapshots(
              flutterRevision: flutterRevision,
              platform: ReleasePlatform.ios,
            ),
          ),
          isEmpty,
        );
      });

      test('ignores files that are not gen_snapshot', () {
        writeGenSnapshot(
          p.join('ios-release', 'LICENSE.gen_snapshot.md'),
          strings: ['--save-obfuscation-map'],
        );
        // A stray file at the engine root is not a directory and is skipped.
        File(p.join(engineDirectory().path, 'stray.txt'))
          ..createSync(recursive: true)
          ..writeAsStringSync('x');

        expect(
          runWithOverrides(
            () => probe.resolveGenSnapshots(
              flutterRevision: flutterRevision,
              platform: ReleasePlatform.ios,
            ),
          ),
          isEmpty,
        );
      });

      test('finds every Android host gen_snapshot, one level down', () {
        for (final arch in ['arm', 'arm64', 'x64']) {
          writeGenSnapshot(
            p.join('android-$arch-release', 'darwin-x64', 'gen_snapshot'),
            strings: ['--save-obfuscation-map'],
          );
        }

        final resolved = runWithOverrides(
          () => probe.resolveGenSnapshots(
            flutterRevision: flutterRevision,
            platform: ReleasePlatform.android,
          ),
        );

        expect(resolved, hasLength(3));
      });

      test('resolves per-platform artifact directories', () {
        writeGenSnapshot(
          p.join('darwin-x64-release', 'gen_snapshot_arm64'),
          strings: ['x'],
        );
        writeGenSnapshot(
          p.join('linux-x64-release', 'gen_snapshot'),
          strings: ['x'],
        );
        writeGenSnapshot(
          p.join('windows-x64-release', 'gen_snapshot'),
          strings: ['x'],
        );

        for (final platform in [
          ReleasePlatform.macos,
          ReleasePlatform.linux,
          ReleasePlatform.windows,
        ]) {
          expect(
            runWithOverrides(
              () => probe.resolveGenSnapshots(
                flutterRevision: flutterRevision,
                platform: platform,
              ),
            ),
            hasLength(1),
            reason: 'expected one gen_snapshot for ${platform.name}',
          );
        }
      });
    });

    group('supportsLoadObfuscationMap', () {
      test('is indeterminate when no gen_snapshot can be found', () async {
        expect(
          await ask(ReleasePlatform.ios),
          GenSnapshotFlagSupport.indeterminate,
        );
      });

      test(
        'is present when the underscore flag name is in the bytes',
        () async {
          writeGenSnapshot(
            p.join('ios-release', 'gen_snapshot_arm64'),
            strings: ['--save-obfuscation-map', 'load_obfuscation_map'],
          );

          expect(
            await ask(ReleasePlatform.ios),
            GenSnapshotFlagSupport.present,
          );
        },
      );

      test(
        'is present when only the dashed spelling is in the bytes',
        () async {
          writeGenSnapshot(
            p.join('ios-release', 'gen_snapshot_arm64'),
            strings: ['--load-obfuscation-map=<map-filename>'],
          );

          expect(
            await ask(ReleasePlatform.ios),
            GenSnapshotFlagSupport.present,
          );
        },
      );

      test('is absent when only the save control string is present', () async {
        writeGenSnapshot(
          p.join('ios-release', 'gen_snapshot_arm64'),
          strings: ['--save-obfuscation-map=<map-filename>'],
        );

        expect(await ask(ReleasePlatform.ios), GenSnapshotFlagSupport.absent);
      });

      test(
        '''is indeterminate when neither the flag nor its control is present''',
        () async {
          // Absence of the flag only means something if the scan is known to
          // work. A file with no obfuscation strings at all proves nothing.
          writeGenSnapshot(
            p.join('ios-release', 'gen_snapshot_arm64'),
            strings: ['not a gen_snapshot'],
          );

          expect(
            await ask(ReleasePlatform.ios),
            GenSnapshotFlagSupport.indeterminate,
          );
        },
      );

      test('finds a flag name that straddles a read-chunk boundary', () async {
        // The probe streams in 1MiB chunks. Without the carry-over window a
        // needle split across two chunks is missed, and — because the control
        // string is still found — the answer flips from `present` to `absent`,
        // i.e. the CLI refuses a patch it should have built. The load needle
        // must be the one that straddles; if only the save needle straddles,
        // the load needle is found whole in the next chunk and the test cannot
        // fail. (Verified by mutation: dropping the carry window fails this.)
        const chunkSize = 1 << 20;
        const loadFlag = '--load-obfuscation-map';
        writeGenSnapshot(
          p.join('ios-release', 'gen_snapshot_arm64'),
          strings: [loadFlag, '--save-obfuscation-map'],
          padding: chunkSize - (loadFlag.length ~/ 2),
        );

        expect(await ask(ReleasePlatform.ios), GenSnapshotFlagSupport.present);
      });

      test('refuses when any resolved binary lacks the flag', () async {
        writeGenSnapshot(
          p.join('android-arm64-release', 'darwin-x64', 'gen_snapshot'),
          strings: ['--save-obfuscation-map', '--load-obfuscation-map'],
        );
        writeGenSnapshot(
          p.join('android-arm-release', 'darwin-x64', 'gen_snapshot'),
          strings: ['--save-obfuscation-map'],
        );

        expect(
          await ask(ReleasePlatform.android),
          GenSnapshotFlagSupport.absent,
        );
      });

      test('is present when a resolvable binary carries the flag', () async {
        writeGenSnapshot(
          p.join('android-arm64-release', 'darwin-x64', 'gen_snapshot'),
          strings: ['--save-obfuscation-map', '--load-obfuscation-map'],
        );
        // Not readable / not a gen_snapshot: indeterminate on its own, but it
        // must not veto a positive answer from a sibling.
        writeGenSnapshot(
          p.join('android-arm-release', 'darwin-x64', 'gen_snapshot'),
          strings: ['nothing useful'],
        );

        expect(
          await ask(ReleasePlatform.android),
          GenSnapshotFlagSupport.present,
        );
      });

      test('is indeterminate when the binary cannot be opened', () async {
        // A directory named `gen_snapshot` resolves like a file but cannot be
        // opened for reading.
        Directory(
          p.join(engineDirectory().path, 'ios-release', 'gen_snapshot_arm64'),
        ).createSync(recursive: true);
        writeGenSnapshot(
          p.join('ios-release', 'gen_snapshot_x64'),
          strings: ['--save-obfuscation-map'],
        );

        // The directory is skipped by resolveGenSnapshots (it is not a File),
        // so only the readable sibling answers.
        expect(await ask(ReleasePlatform.ios), GenSnapshotFlagSupport.absent);
      });

      test('is indeterminate when the file is deleted mid-probe', () async {
        final file = writeGenSnapshot(
          p.join('ios-release', 'gen_snapshot_arm64'),
          strings: ['--save-obfuscation-map'],
        );
        final resolved = runWithOverrides(
          () => probe.resolveGenSnapshots(
            flutterRevision: flutterRevision,
            platform: ReleasePlatform.ios,
          ),
        );
        expect(resolved, hasLength(1));
        file.deleteSync();

        expect(
          await ask(ReleasePlatform.ios),
          GenSnapshotFlagSupport.indeterminate,
        );
      });

      test('memoizes results per file path', () async {
        final file = writeGenSnapshot(
          p.join('ios-release', 'gen_snapshot_arm64'),
          strings: ['--save-obfuscation-map'],
        );

        expect(await ask(ReleasePlatform.ios), GenSnapshotFlagSupport.absent);

        // Rewriting the bytes must not change the answer: the first scan is
        // remembered so a single command invocation never re-reads ~16MB.
        file.writeAsStringSync('--load-obfuscation-map');

        expect(await ask(ReleasePlatform.ios), GenSnapshotFlagSupport.absent);
      });
    });
  });
}
