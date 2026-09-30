// The release under test for Route B step 4.
//
// Two patchable functions, because the whole point of step 4 is that a patch is
// a SET of targets applied atomically -- a one-target harness cannot tell an
// all-or-nothing apply from a lucky ordering.
//
// Both bodies route their value through DateTime.now(): a literal is
// constant-folded by the type-flow analysis even under vm:never-inline, which
// once made a working mechanism report OLD. See killgate/target.dart.
//
// cspell:words SBRBPTCH sbrb
// ignore_for_file: implementation_imports
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:_internal'
    show attachBytecodeToFunction, detachBytecodeFromFunction, releaseBuildId;
import 'dart:io';
import 'dart:typed_data';

@pragma('vm:never-inline')
String alpha() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-a' : 'X';

@pragma('vm:never-inline')
String beta() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-b' : 'X';

void _state(String when) => print('$when alpha=${alpha()} beta=${beta()}');

void main(List<String> args) {
  // Route B's release identity, read from the running snapshot's GNU build ID.
  final id = releaseBuildId();
  print('BUILD_ID ${id ?? "<none>"}');

  if (args.isEmpty) return; // identity-only mode, used to build the patch

  _state('before');

  final bytes = File(args[0]).readAsBytesSync();
  final result = applyPatchContainer(Uint8List.fromList(bytes), id);
  print('APPLY ${result.ok ? "ok" : "refused"}: ${result.message}');
  _state('after ');

  if (args.length > 1 && args[1] == '--revert') {
    final n = revertAll(result.attached);
    print('REVERT detached=$n');
    _state('revert');
  }
}

// --- the reference installer -------------------------------------------------
//
// This is Dart because the harness is; in the product it belongs in the
// engine's C++ patch installer, alongside the existing Shorebird lifecycle
// rather than beside it. The ORDER is the part worth copying:
//
//   1. parse + verify hashes   -- before anything is attached
//   2. match the release       -- before anything is attached
//   3. attach, tracking what succeeded
//   4. on any failure, detach what step 3 already did
//
// Steps 1 and 2 come first because they are the only failures that can be made
// harmless. Once a body is attached the program is running patched code, and
// "undo" is a second operation that can itself fail.

class ApplyResult {
  ApplyResult(this.ok, this.message, this.attached);
  final bool ok;
  final String message;
  final List<List<String>> attached; // [library, selector] pairs
}

ApplyResult applyPatchContainer(Uint8List bytes, String? runningBuildId) {
  final Object parsed;
  try {
    parsed = _parse(bytes);
  } on FormatException catch (e) {
    return ApplyResult(false, 'malformed container: ${e.message}', const []);
  }
  final container = parsed as _Container;

  if (runningBuildId == null) {
    return ApplyResult(
      false,
      'this build reports no release identity; refusing to guess',
      const [],
    );
  }
  if (container.buildId != runningBuildId) {
    // The refusal that matters most. Bytecode is compiled against one specific
    // release's kernel; applying it to another build is undefined, and the
    // symptom would be a corrupt interpreted body rather than an error.
    return ApplyResult(
      false,
      'built for ${container.buildId}, running $runningBuildId',
      const [],
    );
  }

  final attached = <List<String>>[];
  for (final t in container.targets) {
    final ok = attachBytecodeToFunction(t.bytecode, t.library, t.selector);
    if (!ok) {
      final undone = revertAll(attached);
      return ApplyResult(
        false,
        'target ${t.selector} did not attach; rolled back $undone already applied',
        const [],
      );
    }
    attached.add([t.library, t.selector]);
  }
  return ApplyResult(true, '${attached.length} target(s)', attached);
}

int revertAll(List<List<String>> attached) {
  var n = 0;
  // Reverse order: not strictly required today, since targets are independent,
  // but unwinding in the order things were done is the habit that stays correct
  // when they stop being independent.
  for (final t in attached.reversed) {
    if (detachBytecodeFromFunction(t[0], t[1])) n++;
  }
  return n;
}

// --- container parsing (mirrors packaging/patch_container.dart) --------------
// Duplicated rather than imported: the release cannot depend on host tooling,
// and the C++ installer will duplicate it again. The format is small and
// version-stamped precisely so that is safe.

class _Target {
  _Target(this.library, this.selector, this.bytecode);
  final String library;
  final String selector;
  final Uint8List bytecode;
}

class _Container {
  _Container(this.buildId, this.targets);
  final String buildId;
  final List<_Target> targets;
}

_Container _parse(Uint8List bytes) {
  if (bytes.length < 16) throw const FormatException('too short');
  const magic = 'SBRBPTCH';
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic.codeUnitAt(i)) {
      throw const FormatException('bad magic');
    }
  }
  final data = ByteData.sublistView(bytes);
  final version = data.getUint32(8, Endian.little);
  if (version != 1) throw FormatException('unsupported version $version');
  final headerLen = data.getUint32(12, Endian.little);
  if (16 + headerLen > bytes.length) {
    throw const FormatException('header runs past end');
  }
  final header = jsonDecodeMap(
    String.fromCharCodes(bytes.sublist(16, 16 + headerLen)),
  );
  final base = 16 + headerLen;

  final targets = <_Target>[];
  for (final raw in header['targets']! as List<Object?>) {
    final t = raw! as Map<String, Object?>;
    final offset = t['offset']! as int;
    final length = t['length']! as int;
    if (base + offset + length > bytes.length) {
      throw const FormatException('payload runs past end');
    }
    final blob = Uint8List.fromList(
      bytes.sublist(base + offset, base + offset + length),
    );
    // Verified HERE, in the installer, not merely in the tool that wrote the
    // container. A packer checking its own output proves nothing about a file
    // that crossed a network; and this has to happen before any attach, because
    // a transactional apply can unwind attachments but cannot unwind a corrupt
    // body that already ran.
    final actual = sha256.convert(blob).toString();
    if (actual != t['sha256']! as String) {
      throw FormatException('payload for ${t['selector']} is corrupt');
    }
    targets.add(
      _Target(t['library']! as String, t['selector']! as String, blob),
    );
  }
  final release = header['release']! as Map<String, Object?>;
  return _Container(release['buildId']! as String, targets);
}

Map<String, Object?> jsonDecodeMap(String s) =>
    (const JsonCodec().decode(s)) as Map<String, Object?>;
