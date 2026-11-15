// Route B (selfhost): deciding, from bytes, whether iOS Dart code push is
// possible for a given engine and a given release.
//
// Both questions here are answered by inspecting binaries rather than by
// trusting configuration, and that is the whole point. The failure this exists
// to prevent is silent and expensive: releases 7.0.0+1 and 8.0.0+1 were built
// without `--patchable_static_calls`, a Route B patch delivered, installed,
// validated its release identity, resolved its target and attached — the engine
// reported "applied 1/1 targets" — and the app's behaviour did not change,
// because AOT had emitted ordinary direct calls that never consult
// `Function.entry_point_`.
//
// Attachment success does not prove a release is patchable. Nothing else in the
// stack notices, so this does.
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Whether an iOS engine can execute Route B patches at all.
///
/// A Route B engine is built with `dart_dynamic_modules = true`, which brings
/// in vanilla Dart's bytecode interpreter and — decisively — the
/// `InterpretCall` stub that an attached `Function` enters through. A stock
/// engine has neither, so a patchable release built against one would pay the
/// size cost and buy nothing.
///
/// `InterpretCall` alone is not enough. An engine built on vanilla Dart
/// carries it too, yet ships with the Shorebird interpreter off on iOS and
/// says so in its own log line ([iosPatchesDeclinedMarker]). Releases on such
/// an engine must not request patchable call sites: its gen_snapshot does not
/// emit them, so the release would fail its own patchability check.
///
/// Keyed on the symbol rather than on the engine revision because the revision
/// is a sha1 of the Flutter binary and Xcode re-signs embedded frameworks,
/// which changes the file without changing what it can do.
bool isRouteBEngine(File engineBinary) {
  if (!engineBinary.existsSync()) return false;
  // Substring search over the raw bytes: the symbol table is part of the file,
  // and shelling out to `nm` would make this untestable and platform-bound.
  final bytes = engineBinary.readAsBytesSync();
  return _containsAscii(bytes, 'InterpretCall') &&
      !_containsAscii(bytes, iosPatchesDeclinedMarker);
}

/// The iOS release engine binary a build in [flutterDirectory] links.
///
/// With `--local-engine` the vended `flutter` is told to use the local build
/// (`ShorebirdProcess._resolveArguments`), whose framework sits in
/// `<localEngineSrcPath>/out/<localEngine>/Flutter.framework`, not in the
/// Flutter checkout's cache. Otherwise it is the cached xcframework slice.
File iosReleaseEngineBinary({
  required Directory flutterDirectory,
  String? localEngineSrcPath,
  String? localEngine,
}) {
  if (localEngine != null && localEngineSrcPath != null) {
    return File(
      p.join(
        localEngineSrcPath,
        'out',
        localEngine,
        'Flutter.framework',
        'Flutter',
      ),
    );
  }
  return File(
    p.join(
      flutterDirectory.path,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'ios-release',
      'Flutter.xcframework',
      'ios-arm64',
      'Flutter.framework',
      'Flutter',
    ),
  );
}

/// The gen_snapshot flag that keeps app-overridden methods out of the dispatch
/// table, so a Route B patch reaches calls such as the framework's
/// `widget.build(this)`. Measured on the host; no device patch yet
/// (`selfhost/engine/route_b/evidence/untabled_overrides/RESULT.md`).
///
/// A dispatch-table call loads a raw entry point and never consults
/// `Function.entry_point_`, so a patch to a `build` method attached, reported
/// success, and had no surviving call site. Under this flag those calls stay
/// switchable calls, which the runtime links through the `Function`.
const routeBUntabledOverridesFlag = 'route_b_untabled_overrides';

/// The gen_snapshot an iOS release build in [flutterDirectory] runs.
///
/// With `--local-engine` it is the first `gen_snapshot_arm64` in the local
/// build, searched in flutter_tools' own order (`_genSnapshotPath` in
/// `artifacts.dart`), so the binary inspected here is the one the build runs.
/// Otherwise it is in the Flutter checkout's cached `ios-release` artifacts.
File iosReleaseGenSnapshot({
  required Directory flutterDirectory,
  String? localEngineSrcPath,
  String? localEngine,
}) {
  if (localEngine != null && localEngineSrcPath != null) {
    final out = p.join(localEngineSrcPath, 'out', localEngine);
    const flutterToolsOrder = [
      '.',
      'universal',
      'clang_x64',
      'clang_x86',
      'clang_i386',
      'clang_arm64',
      'clang_riscv64',
    ];
    final candidates = [
      for (final dir in flutterToolsOrder)
        File(p.normalize(p.join(out, dir, 'gen_snapshot_arm64'))),
    ];
    return candidates.firstWhere(
      (f) => f.existsSync(),
      orElse: () => candidates.first,
    );
  }
  return File(
    p.join(
      flutterDirectory.path,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'ios-release',
      'gen_snapshot_arm64',
    ),
  );
}

/// Whether [genSnapshot] defines the VM flag [flag].
///
/// Read from the bytes rather than by running the binary: gen_snapshot rejects
/// an unknown flag only once it is compiling, and `--version` exits 0 whatever
/// flags precede it.
bool genSnapshotHasFlag(File genSnapshot, String flag) {
  if (!genSnapshot.existsSync()) return false;
  return containsFlagName(genSnapshot.readAsBytesSync(), flag);
}

/// Whether [bytes] hold [flag] as a whole name: with a non-identifier byte (or
/// the end of the data) on both sides, so a flag is not matched inside a longer
/// one. The VM stores flag names as plain strings in the executable.
bool containsFlagName(List<int> bytes, String flag) {
  final needle = flag.codeUnits;
  outer:
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) continue outer;
    }
    final before = i == 0 ? 0 : bytes[i - 1];
    final afterIndex = i + needle.length;
    final after = afterIndex < bytes.length ? bytes[afterIndex] : 0;
    if (!_isIdentifierByte(before) && !_isIdentifierByte(after)) return true;
  }
  return false;
}

bool _isIdentifierByte(int b) =>
    (b >= 0x30 && b <= 0x39) ||
    (b >= 0x41 && b <= 0x5a) ||
    (b >= 0x61 && b <= 0x7a) ||
    b == 0x5f;

/// Whether [engineBinary] declares, in its own log text, that it cannot run
/// iOS patches ([iosPatchesDeclinedMarker]). Reads the file once.
///
/// Distinct from `!isRouteBEngine`: a missing or unrecognised binary is not a
/// declaration, so this is false for it and the caller proceeds as before.
///
/// Relies on the engine emitting the marker only when its interpreter is
/// compiled out (`FlutterDartProject.mm` and `shorebird.cc`); an engine that
/// can run patches must never carry it.
bool engineDeclinesIosPatches(File engineBinary) {
  if (!engineBinary.existsSync()) return false;
  return _containsAscii(
    engineBinary.readAsBytesSync(),
    iosPatchesDeclinedMarker,
  );
}

/// Text an iOS engine logs when it will not start the Shorebird updater
/// because it cannot run patches (`FlutterDartProject.mm` and `shorebird.cc`
/// in the engine). Its presence in the binary is the engine declaring that.
const iosPatchesDeclinedMarker = 'engine cannot run iOS patches';

/// The two instructions every patchable static call ends in, on arm64.
///
///     ldur lr, [r0, #7]     ; Function.entry_point_  (offset 7 = tagged 8)
///     blr  lr
///
/// Fixed encodings, so counting adjacent pairs of them is a property of the
/// shipped bytes. A stale build, a cached artifact, or provenance that claims
/// the right thing cannot defeat it.
const _ldurLrR0Offset7 = 0xF840701E;
const _blrLr = 0xD63F03C0;

/// Patchable call sites per MiB required to call a release patchable.
///
/// NOT `> 0`. A release built WITHOUT the flag still contains a handful,
/// because AOT already dispatches some closure and tear-off calls through
/// `entry_point_` regardless. Measured on the two releases that produced the
/// failure and the fix:
///
/// | release  | flag | pairs | per MiB |
/// |----------|------|-------|---------|
/// | 8.0.0+1  | no   |     8 |       2 |
/// | 9.0.0+1  | yes  | 7,109 |   1,788 |
///
/// Three orders of magnitude apart, so this threshold is not a fine judgement
/// call. Re-measure if the call form ever changes shape.
const routeBPatchableSitesPerMiBThreshold = 100;

/// How many patchable call sites [appBinary] contains, and how dense they are.
({int sites, double perMiB}) countPatchableCallSites(File appBinary) {
  final bytes = appBinary.readAsBytesSync();
  final words = Uint32List.sublistView(
    bytes,
    0,
    bytes.length - (bytes.length % 4),
  );
  var sites = 0;
  for (var i = 0; i < words.length - 1; i++) {
    if (words[i] == _ldurLrR0Offset7 && words[i + 1] == _blrLr) sites++;
  }
  final mib = bytes.length / (1024 * 1024);
  return (sites: sites, perMiB: mib == 0 ? 0 : sites / mib);
}

/// Whether a built release's `App` binary carries the patchable call form.
///
/// This is the check that must run AFTER the build even when the flag was
/// passed: passing it and having it take effect are different claims, and only
/// one of them is observable in the artifact that ships.
bool isPatchableRelease(File appBinary) {
  if (!appBinary.existsSync()) return false;
  return countPatchableCallSites(appBinary).perMiB >=
      routeBPatchableSitesPerMiBThreshold;
}

bool _containsAscii(Uint8List haystack, String needle) {
  final n = needle.codeUnits;
  outer:
  for (var i = 0; i + n.length <= haystack.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}
