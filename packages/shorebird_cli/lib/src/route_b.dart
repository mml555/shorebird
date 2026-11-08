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

/// Whether an iOS engine can execute Route B patches at all.
///
/// A Route B engine is built with `dart_dynamic_modules = true`, which brings
/// in vanilla Dart's bytecode interpreter and — decisively — the
/// `InterpretCall` stub that an attached `Function` enters through. A stock
/// engine has neither, so a patchable release built against one would pay the
/// size cost and buy nothing.
///
/// Keyed on the symbol rather than on the engine revision because the revision
/// is a sha1 of the Flutter binary and Xcode re-signs embedded frameworks,
/// which changes the file without changing what it can do.
bool isRouteBEngine(File engineBinary) {
  if (!engineBinary.existsSync()) return false;
  // Substring search over the raw bytes: the symbol table is part of the file,
  // and shelling out to `nm` would make this untestable and platform-bound.
  return _containsAscii(engineBinary.readAsBytesSync(), 'InterpretCall');
}

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
