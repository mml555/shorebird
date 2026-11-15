// cspell:words flagx
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  useTempWorkingDirectory();

  group('containsFlagName', () {
    List<int> bytes(String s) => s.codeUnits;

    test('finds a flag stored between NULs', () {
      expect(
        containsFlagName(
          bytes('\x00route_b_untabled_overrides\x00'),
          'route_b_untabled_overrides',
        ),
        isTrue,
      );
    });

    test('finds a flag at either end of the data', () {
      expect(containsFlagName(bytes('abc\x00flag'), 'flag'), isTrue);
      expect(containsFlagName(bytes('flag\x00abc'), 'flag'), isTrue);
    });

    test('does not find a flag inside a longer name', () {
      expect(
        containsFlagName(
          bytes('\x00route_b_untabled_overrides_v2\x00'),
          'route_b_untabled_overrides',
        ),
        isFalse,
      );
      expect(
        containsFlagName(
          bytes('\x00no_route_b_untabled_overrides\x00'),
          'route_b_untabled_overrides',
        ),
        isFalse,
      );
    });

    test('finds the whole-name occurrence after a partial one', () {
      expect(containsFlagName(bytes('flagx\x00flag\x00'), 'flag'), isTrue);
    });
  });

  group('iosReleaseGenSnapshot', () {
    late Directory root;
    var n = 0;

    // A fresh directory per test inside the temporary working directory, which
    // useTempWorkingDirectory removes.
    setUp(() {
      root = Directory(p.join(Directory.current.path, 'case${n++}'))
        ..createSync();
    });

    File place(String dir) {
      return File(
        p.normalize(
          p.join(
            root.path,
            'src',
            'out',
            'ios_release',
            dir,
            'gen_snapshot_arm64',
          ),
        ),
      )..createSync(recursive: true);
    }

    File resolve() => iosReleaseGenSnapshot(
      flutterDirectory: Directory(p.join(root.path, 'flutter')),
      localEngineSrcPath: p.join(root.path, 'src'),
      localEngine: 'ios_release',
    );

    test('picks universal before clang_arm64, as flutter_tools does', () {
      place('clang_arm64');
      final universal = place('universal');

      expect(resolve().path, universal.path);
    });

    test('picks the out directory itself first', () {
      place('universal');
      final top = place('.');

      expect(resolve().path, top.path);
    });

    test('names the out directory itself when no candidate exists', () {
      expect(
        resolve().path,
        p.join(root.path, 'src', 'out', 'ios_release', 'gen_snapshot_arm64'),
      );
    });

    test('falls back to the cached artifact without a local engine', () {
      final gs = iosReleaseGenSnapshot(
        flutterDirectory: Directory(p.join(root.path, 'flutter')),
      );

      expect(
        gs.path,
        p.join(
          root.path,
          'flutter',
          'bin',
          'cache',
          'artifacts',
          'engine',
          'ios-release',
          'gen_snapshot_arm64',
        ),
      );
    });
  });

  group('genSnapshotHasFlag', () {
    test('is false for a missing binary', () {
      expect(
        genSnapshotHasFlag(File('missing'), 'route_b_untabled_overrides'),
        isFalse,
      );
    });

    test('reads the flag name from the binary', () {
      final binary = File('gen_snapshot')
        ..writeAsBytesSync('\x00route_b_untabled_overrides\x00'.codeUnits);

      expect(genSnapshotHasFlag(binary, 'route_b_untabled_overrides'), isTrue);
      expect(genSnapshotHasFlag(binary, 'patchable_static_calls'), isFalse);
    });
  });
}
