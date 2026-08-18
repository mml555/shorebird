// Route B (selfhost): the patch container, and the release identity it is
// stamped with.
//
// Ported from `selfhost/engine/route_b/packaging/patch_container.dart` — the
// format the device runtime already reads. The host tool stays as the
// reference; this is byte-compatible with it by construction, which is what
// lets `shorebird patch` be compared against the manually proven pipeline on
// SHA rather than on a shrug.
//
// The format is DETERMINISTIC: no timestamps, no map iteration order that
// depends on anything but the target list, no padding. Identical inputs give
// identical bytes, so exact equality is a legitimate gate rather than an
// aspiration.
//
//     magic       8 bytes   "SBRBPTCH"
//     version     uint32    little endian
//     headerLen   uint32    little endian
//     header      JSON      release build id + targets + payload offsets/hashes
//     payloads    concatenated bytecode blobs, located by the header
//
// Magic first so a truncated or misidentified file fails at byte 0 rather than
// somewhere inside the interpreter. Targets are named by SELECTOR, never by
// index — an index into anything the release computed is exactly the
// "incidental position" the design rules out.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The container's magic bytes.
const routeBContainerMagic = 'SBRBPTCH';

/// The container format version this build reads and writes.
const routeBContainerFormatVersion = 1;

/// Mach-O `LC_UUID`.
const _lcUuid = 0x1b;

/// One function to replace, and the bytecode to replace it with.
class RouteBPatchTarget {
  /// {@macro route_b_patch_target}
  RouteBPatchTarget({
    required this.library,
    required this.selector,
    required this.bytecode,
  });

  /// Library URI exactly as the release records it — the `package:` form, not
  /// `file:`. A mismatch here is the likeliest authoring error and produces
  /// "library not found" at install time rather than anything subtler.
  final String library;

  /// The manifest's `selector`, which already carries the `get:`/`set:`
  /// mangling and the class qualification.
  final String selector;

  /// The compiled replacement body.
  ///
  /// One payload is one function: `Dart_RouteBActivatePatch` calls
  /// `BytecodeLoader::LoadBytecode()`, takes the single `Function` it returns,
  /// and attaches that function's bytecode to the resolved target. A payload
  /// carrying a whole program has nothing to select from.
  final Uint8List bytecode;

  /// The payload's hash, as the header records it.
  String get sha256Hex => sha256.convert(bytecode).toString();
}

/// Serializes [targets] into a container for the release identified by
/// [releaseBuildId].
Uint8List writeRouteBContainer({
  required String releaseBuildId,
  required List<RouteBPatchTarget> targets,
}) {
  if (targets.isEmpty) {
    // A container with no targets installs, validates, attaches nothing and
    // reports success — the silent no-op this whole chain exists to prevent.
    throw ArgumentError('a patch with no targets would be silently inert');
  }

  final payloads = BytesBuilder();
  final entries = <Map<String, Object?>>[];
  for (final target in targets) {
    entries.add({
      'library': target.library,
      'selector': target.selector,
      'offset': payloads.length,
      'length': target.bytecode.length,
      'sha256': target.sha256Hex,
    });
    payloads.add(target.bytecode);
  }

  final header = utf8.encode(
    jsonEncode({
      'formatVersion': routeBContainerFormatVersion,
      'release': {'buildId': releaseBuildId},
      'targets': entries,
    }),
  );

  return (BytesBuilder()
        ..add(ascii.encode(routeBContainerMagic))
        ..add(_uint32(routeBContainerFormatVersion))
        ..add(_uint32(header.length))
        ..add(header)
        ..add(payloads.takeBytes()))
      .toBytes();
}

/// A parsed container.
///
/// Parsing validates structure and payload hashes only. Release matching is
/// left to the caller so each refusal reports its own reason.
class RouteBContainer {
  const RouteBContainer._(this.releaseBuildId, this.targets);

  /// The release this container may be applied to.
  final String releaseBuildId;

  /// Every function it replaces.
  final List<RouteBPatchTarget> targets;

  /// Parses [bytes], or throws [FormatException].
  static RouteBContainer parse(Uint8List bytes) {
    if (bytes.length < 16) {
      throw const FormatException('too short to be a patch container');
    }
    if (ascii.decode(bytes.sublist(0, 8)) != routeBContainerMagic) {
      throw const FormatException('bad magic; not a patch container');
    }
    final data = ByteData.sublistView(bytes);
    final version = data.getUint32(8, Endian.little);
    if (version != routeBContainerFormatVersion) {
      // Refuse rather than guess. A reader that tolerates unknown versions ends
      // up defining the format by what it happens to accept.
      throw FormatException(
        'unsupported format version $version '
        '(this build reads $routeBContainerFormatVersion)',
      );
    }
    final headerLength = data.getUint32(12, Endian.little);
    if (16 + headerLength > bytes.length) {
      throw const FormatException('header runs past end of file');
    }
    final header =
        jsonDecode(utf8.decode(bytes.sublist(16, 16 + headerLength)))
            as Map<String, Object?>;
    final base = 16 + headerLength;

    final targets = <RouteBPatchTarget>[];
    for (final raw in header['targets']! as List<Object?>) {
      final entry = raw! as Map<String, Object?>;
      final offset = entry['offset']! as int;
      final length = entry['length']! as int;
      if (base + offset + length > bytes.length) {
        throw const FormatException('payload runs past end of file');
      }
      final blob = Uint8List.sublistView(
        bytes,
        base + offset,
        base + offset + length,
      );
      final declared = entry['sha256']! as String;
      final actual = sha256.convert(blob).toString();
      if (declared != actual) {
        // Before attaching anything, not after: a transactional apply can
        // unwind attachments, it cannot unwind a corrupt body already running.
        throw FormatException(
          'payload for ${entry['selector']} is corrupt '
          '(declared $declared, got $actual)',
        );
      }
      targets.add(
        RouteBPatchTarget(
          library: entry['library']! as String,
          selector: entry['selector']! as String,
          bytecode: Uint8List.fromList(blob),
        ),
      );
    }

    final release = header['release']! as Map<String, Object?>;
    return RouteBContainer._(release['buildId']! as String, targets);
  }
}

/// The release identity a container must be stamped with, read from the
/// shipped `App` binary's Mach-O `LC_UUID`.
///
/// `OS::GetAppBuildId` prefers the instructions image's own build ID, and for a
/// snapshot compiled to Mach-O that IS the `LC_UUID`
/// (`Image::build_id()` -> `uuid_command->uuid`). Lowercase hex, no dashes.
///
/// Codesigning does not change it — the linker sets it — which is why this
/// survives Xcode re-signing an embedded framework, unlike the engine hash.
///
/// Parsed here rather than shelled out to `dwarfdump`, so it is testable, has
/// no tool dependency, and cannot silently pick a different slice than intended.
/// Returns null when the file carries none.
String? readMachOBuildId(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final data = ByteData.sublistView(bytes);

  // Universal binary: pick the 64-bit slices in order. iOS device builds are
  // thin arm64 in practice, but a fat file must not silently read the header of
  // whatever happens to be first.
  final fatMagic = data.getUint32(0, Endian.big);
  if (fatMagic == 0xcafebabe || fatMagic == 0xcafebabf) {
    final is64 = fatMagic == 0xcafebabf;
    final count = data.getUint32(4, Endian.big);
    var cursor = 8;
    for (var i = 0; i < count; i++) {
      final entrySize = is64 ? 32 : 20;
      if (cursor + entrySize > bytes.length) return null;
      final offset = is64
          ? data.getUint64(cursor + 8, Endian.big)
          : data.getUint32(cursor + 8, Endian.big);
      final size = is64
          ? data.getUint64(cursor + 16, Endian.big)
          : data.getUint32(cursor + 12, Endian.big);
      if (offset + size <= bytes.length) {
        final uuid = readMachOBuildId(
          Uint8List.sublistView(bytes, offset, offset + size),
        );
        if (uuid != null) return uuid;
      }
      cursor += entrySize;
    }
    return null;
  }

  final magic = data.getUint32(0, Endian.little);
  final is64 = magic == 0xfeedfacf;
  if (!is64 && magic != 0xfeedface) return null;
  final headerSize = is64 ? 32 : 28;
  if (bytes.length < headerSize) return null;

  final commandCount = data.getUint32(16, Endian.little);
  var cursor = headerSize;
  for (var i = 0; i < commandCount; i++) {
    if (cursor + 8 > bytes.length) return null;
    final command = data.getUint32(cursor, Endian.little);
    final commandSize = data.getUint32(cursor + 4, Endian.little);
    if (commandSize < 8 || cursor + commandSize > bytes.length) return null;
    if (command == _lcUuid && commandSize >= 24) {
      final uuid = Uint8List.sublistView(bytes, cursor + 8, cursor + 24);
      return uuid
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .toLowerCase();
    }
    cursor += commandSize;
  }
  return null;
}

Uint8List _uint32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);
