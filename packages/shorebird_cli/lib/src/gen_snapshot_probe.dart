import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

/// A reference to a [GenSnapshotProbe] instance.
final genSnapshotProbeRef = create(GenSnapshotProbe.new);

/// The [GenSnapshotProbe] instance available in the current zone.
GenSnapshotProbe get genSnapshotProbe => read(genSnapshotProbeRef);

/// The answer to "does this gen_snapshot carry this flag?".
enum GenSnapshotFlagSupport {
  /// The flag's name was found in the binary that will run.
  present,

  /// The flag's name was *not* found, and a control string that must be in
  /// every gen_snapshot *was*, so the scan itself is known to work. The flag
  /// is genuinely missing.
  absent,

  /// No conclusion could be drawn: no gen_snapshot could be located, it could
  /// not be read, or neither the flag nor its control string was found (which
  /// means the scan is not measuring what it thinks it is).
  indeterminate,
}

/// {@template gen_snapshot_probe}
/// Asks a `gen_snapshot` binary, by inspecting its bytes, whether it carries a
/// given VM flag.
/// {@endtemplate}
class GenSnapshotProbe {
  /// {@macro gen_snapshot_probe}
  GenSnapshotProbe();

  /// Both spellings of the `--load-obfuscation-map` flag. `gen_snapshot`
  /// stores VM flag names with underscores (`load_obfuscation_map`, which is
  /// the spelling its "Unrecognized flags:" error uses) and its usage text
  /// with dashes, so either spelling proves the flag exists.
  static const _loadObfuscationMapNeedles = [
    'load_obfuscation_map',
    'load-obfuscation-map',
  ];

  /// The control strings for [_loadObfuscationMapNeedles].
  ///
  /// `--save-obfuscation-map` has been in every `gen_snapshot` that Shorebird
  /// supports (see `minimumObfuscationFlutterVersion`), so finding it proves
  /// the byte scan is reading a real gen_snapshot and can see its flag table.
  /// Without this control, "the load flag is not in the bytes" would be an
  /// unverified negative — indistinguishable from scanning the wrong file.
  static const _saveObfuscationMapNeedles = [
    'save_obfuscation_map',
    'save-obfuscation-map',
  ];

  /// Memoizes per-file scan results. gen_snapshot binaries are ~16MB each and
  /// Android resolves three of them, so a repeated question within one command
  /// invocation should not re-read ~48MB.
  final Map<String, GenSnapshotFlagSupport> _resultsByPath = {};

  /// Whether the `gen_snapshot` binaries that will build a patch for
  /// [platform], using the Flutter pin identified by [flutterRevision],
  /// understand `--load-obfuscation-map`.
  ///
  /// **This must not be answered from a Flutter version, and a version gate
  /// here would be inert.** In this fork the flag is a property of the minted
  /// engine *cell*, not of the Flutter version: `selfhost/cdn/`
  /// `experimental_hashes.map` maps BOTH cell
  /// `4df8f9b6139b67d2cfe9f6aa8212372cade36278` and cell
  /// `40eaa0ef6cb6485833bf2e10ac97224ca82cbf25` to engine revision
  /// `69f9831c360d9152862ec3897c67fb09ae843f3b`, which `selfhost/`
  /// `compatibility.yaml` ties to flutter revision
  /// `c15ef6379403a0a55531a058bdb2c8e55bc05c98` (Flutter 3.44.8) — yet only
  /// `40eaa0ef` ships a gen_snapshot carrying the flag, and an obfuscated
  /// release cut against `4df8f9b6` dies at the AOT step with exit 255
  /// (`selfhost/PARITY.md` §4). Two cells, one flutter revision, opposite
  /// answers: no version comparison can separate them. Only the binary can.
  ///
  /// Returns [GenSnapshotFlagSupport.indeterminate] when no gen_snapshot can
  /// be located or read; see [ShorebirdEnv.flutterDirectory] for where the
  /// release's toolchain lives. Callers decide what an indeterminate answer
  /// means; this method does not guess.
  Future<GenSnapshotFlagSupport> supportsLoadObfuscationMap({
    required String flutterRevision,
    required ReleasePlatform platform,
  }) async {
    final binaries = resolveGenSnapshots(
      flutterRevision: flutterRevision,
      platform: platform,
    );
    if (binaries.isEmpty) return GenSnapshotFlagSupport.indeterminate;

    var sawPresent = false;
    for (final binary in binaries) {
      final result = _scan(binary);
      // `absent` wins outright. The binaries resolved here all come from one
      // engine build, so a disagreement between them is itself a reason to
      // refuse rather than to pick the optimistic answer.
      if (result == GenSnapshotFlagSupport.absent) {
        return GenSnapshotFlagSupport.absent;
      }
      if (result == GenSnapshotFlagSupport.present) sawPresent = true;
    }
    return sawPresent
        ? GenSnapshotFlagSupport.present
        : GenSnapshotFlagSupport.indeterminate;
  }

  /// The `gen_snapshot` binaries a patch build for [platform] would invoke,
  /// under the Flutter pin identified by [flutterRevision].
  ///
  /// Resolved by *enumerating* the pin's engine artifact cache rather than by
  /// hard-coding paths, because the shape differs per platform and per Flutter
  /// version: iOS is `ios-release/gen_snapshot_arm64`, macOS is
  /// `darwin-x64-release/gen_snapshot_{arm64,x64}`, and Android nests the host
  /// build under the target — `android-arm64-release/darwin-x64/gen_snapshot`
  /// — where the host directory name is not stable across host architectures.
  /// Anything not found simply yields an empty list.
  List<File> resolveGenSnapshots({
    required String flutterRevision,
    required ReleasePlatform platform,
  }) {
    final engineDirectory = Directory(
      p.join(
        shorebirdEnv
            .copyWith(flutterRevisionOverride: flutterRevision)
            .flutterDirectory
            .path,
        'bin',
        'cache',
        'artifacts',
        'engine',
      ),
    );
    if (!engineDirectory.existsSync()) return [];

    final prefix = switch (platform) {
      ReleasePlatform.android => 'android-',
      ReleasePlatform.ios => 'ios-',
      ReleasePlatform.macos => 'darwin-',
      ReleasePlatform.linux => 'linux-',
      ReleasePlatform.windows => 'windows-',
    };

    final binaries = <File>[];
    for (final entity in engineDirectory.listSync()) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      // `-release` excludes the debug/profile artifact directories: a patch is
      // always an AOT release build.
      if (!name.startsWith(prefix) || !name.contains('-release')) continue;
      binaries.addAll(_genSnapshotsIn(entity));
    }
    binaries.sort((a, b) => a.path.compareTo(b.path));
    return binaries;
  }

  /// Files named `gen_snapshot*` directly in [directory] or one level below it
  /// (Android's per-target directories hold a host-named subdirectory).
  List<File> _genSnapshotsIn(Directory directory) {
    bool isGenSnapshot(FileSystemEntity e) =>
        e is File && p.basename(e.path).startsWith('gen_snapshot');

    final found = <File>[];
    final List<FileSystemEntity> entities;
    try {
      entities = directory.listSync();
    } on FileSystemException {
      return found;
    }
    for (final entity in entities) {
      if (isGenSnapshot(entity)) {
        found.add(entity as File);
      } else if (entity is Directory) {
        try {
          found.addAll(entity.listSync().where(isGenSnapshot).cast<File>());
        } on FileSystemException {
          continue;
        }
      }
    }
    return found;
  }

  /// Scans [binary] for the `--load-obfuscation-map` flag name, streaming it
  /// in chunks so a ~16MB executable is never held in memory whole.
  GenSnapshotFlagSupport _scan(File binary) {
    final cached = _resultsByPath[binary.path];
    if (cached != null) return cached;
    final result = _resultsByPath[binary.path] = _scanUncached(binary);
    return result;
  }

  GenSnapshotFlagSupport _scanUncached(File binary) {
    final loadNeedles = _loadObfuscationMapNeedles
        .map(ascii.encode)
        .toList(growable: false);
    final saveNeedles = _saveObfuscationMapNeedles
        .map(ascii.encode)
        .toList(growable: false);
    final overlap =
        [
          ...loadNeedles,
          ...saveNeedles,
        ].map((n) => n.length).reduce((a, b) => a > b ? a : b) -
        1;

    const chunkSize = 1 << 20;
    var sawSave = false;
    RandomAccessFile? handle;
    try {
      handle = binary.openSync();
      var carry = Uint8List(0);
      while (true) {
        final chunk = handle.readSync(chunkSize);
        if (chunk.isEmpty) break;
        final Uint8List window;
        if (carry.isEmpty) {
          window = chunk;
        } else {
          window = Uint8List(carry.length + chunk.length)
            ..setRange(0, carry.length, carry)
            ..setRange(carry.length, carry.length + chunk.length, chunk);
        }
        if (_containsAny(window, loadNeedles)) {
          return GenSnapshotFlagSupport.present;
        }
        sawSave = sawSave || _containsAny(window, saveNeedles);
        carry = window.length > overlap
            ? window.sublist(window.length - overlap)
            : window;
      }
    } on FileSystemException {
      return GenSnapshotFlagSupport.indeterminate;
    } finally {
      handle?.closeSync();
    }

    // The load flag was not found. Only call that a real absence if the
    // control string *was* found; otherwise the scan proved nothing.
    return sawSave
        ? GenSnapshotFlagSupport.absent
        : GenSnapshotFlagSupport.indeterminate;
  }

  static bool _containsAny(Uint8List haystack, List<List<int>> needles) {
    for (final needle in needles) {
      final limit = haystack.length - needle.length;
      outer:
      for (var i = 0; i <= limit; i++) {
        for (var j = 0; j < needle.length; j++) {
          if (haystack[i + j] != needle[j]) continue outer;
        }
        return true;
      }
    }
    return false;
  }
}
