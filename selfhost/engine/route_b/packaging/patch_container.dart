// Copyright (c) 2026, the Shorebird self-host fork.
//
// patch_container.dart -- Route B step 4: the on-disk patch format.
//
// WHY A FORMAT AT ALL. The spikes shipped a `*.vmcode` file whose meaning came
// entirely from its filename and the fact that exactly one function was ever
// patched. ROUTE_B.md calls that out by name: bring-up scaffolding that would
// have become the contract by default. A real patch carries several targets,
// has to refuse the wrong release, and has to be verifiable before anything is
// attached -- none of which a naming convention can express.
//
// THE SHAPE. Deliberately boring and byte-explicit, because the eventual reader
// is the engine's C++ installer, not this Dart:
//
//     magic       8 bytes   "SBRBPTCH"
//     version     uint32    little endian, format version
//     headerLen   uint32    little endian
//     header      headerLen bytes of UTF-8 JSON
//     payloads    concatenated bytecode blobs, located by the header
//
// Length-prefixed with the magic first so a truncated or misidentified file
// fails at byte 0 rather than somewhere inside the interpreter. The header is
// JSON because it is read once at install time, where clarity beats density,
// and the payloads stay raw so no decoder sits between the file and
// AttachBytecode.
//
// WHAT THE HEADER MUST CARRY, and why each field is not optional:
//
//   release.buildId  the GNU build ID of the release this was compiled for.
//                    Patch bytecode is compiled against ONE release's kernel,
//                    so applying it elsewhere is undefined rather than merely
//                    unsupported -- it would surface as a corrupt interpreted
//                    body, not a clean error.
//   targets[]        library + selector, from step 3's manifest. Selectors, not
//                    indices: an index into anything the release computed is
//                    exactly the "incidental position" the plan warns against.
//   payload.sha256   integrity, checked before attaching. A transactional apply
//                    can unwind attachments; it cannot unwind a half-read blob.
//
// cspell:words SBRBPTCH sbrb
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const magic = 'SBRBPTCH';
const formatVersion = 1;

/// One function to replace, and the bytecode to replace it with.
class PatchTarget {
  PatchTarget({
    required this.library,
    required this.selector,
    required this.bytecode,
  });

  /// Library URI exactly as the release records it — the `package:` form, not
  /// `file:`. A mismatch here is the likeliest authoring error and produces
  /// "library not found" at install time rather than anything subtler.
  final String library;

  /// From step 3's manifest `selector` field, which already handles the
  /// `get:`/`set:` mangling and class qualification.
  final String selector;

  final Uint8List bytecode;

  String get sha256Hex => sha256.convert(bytecode).toString();
}

/// Serialize [targets] into a container for the release identified by
/// [releaseBuildId].
Uint8List writeContainer({
  required String releaseBuildId,
  required List<PatchTarget> targets,
}) {
  if (targets.isEmpty) {
    throw ArgumentError('a patch with no targets would be silently inert');
  }

  final payloads = BytesBuilder();
  final entries = <Map<String, Object?>>[];
  for (final t in targets) {
    entries.add({
      'library': t.library,
      'selector': t.selector,
      'offset': payloads.length,
      'length': t.bytecode.length,
      'sha256': t.sha256Hex,
    });
    payloads.add(t.bytecode);
  }

  final header = utf8.encode(
    jsonEncode({
      'formatVersion': formatVersion,
      'release': {'buildId': releaseBuildId},
      'targets': entries,
    }),
  );

  final out = BytesBuilder()
    ..add(ascii.encode(magic))
    ..add(_uint32(formatVersion))
    ..add(_uint32(header.length))
    ..add(header)
    ..add(payloads.takeBytes());
  return out.toBytes();
}

/// A parsed container. Parsing validates structure only; [ContainerReader]
/// leaves release matching and payload hashing to the caller so that each
/// refusal can be reported with its own reason.
class ContainerReader {
  ContainerReader._(this.releaseBuildId, this.targets);

  final String releaseBuildId;
  final List<PatchTarget> targets;

  static ContainerReader parse(Uint8List bytes) {
    if (bytes.length < 16) {
      throw const FormatException('too short to be a patch container');
    }
    if (ascii.decode(bytes.sublist(0, 8)) != magic) {
      throw const FormatException('bad magic; not a patch container');
    }
    final data = ByteData.sublistView(bytes);
    final version = data.getUint32(8, Endian.little);
    if (version != formatVersion) {
      // Refuse rather than guess. A reader that tolerates unknown versions
      // ends up defining the format by what it happens to accept.
      throw FormatException(
        'unsupported format version $version (this build reads $formatVersion)',
      );
    }
    final headerLen = data.getUint32(12, Endian.little);
    if (16 + headerLen > bytes.length) {
      throw const FormatException('header runs past end of file');
    }
    final header =
        jsonDecode(utf8.decode(bytes.sublist(16, 16 + headerLen)))
            as Map<String, Object?>;
    final base = 16 + headerLen;

    final targets = <PatchTarget>[];
    for (final raw in header['targets']! as List<Object?>) {
      final t = raw! as Map<String, Object?>;
      final offset = t['offset']! as int;
      final length = t['length']! as int;
      if (base + offset + length > bytes.length) {
        throw const FormatException('payload runs past end of file');
      }
      final blob = Uint8List.sublistView(
        bytes,
        base + offset,
        base + offset + length,
      );
      final declared = t['sha256']! as String;
      final actual = sha256.convert(blob).toString();
      if (declared != actual) {
        // Before attaching anything, not after: a transactional apply can
        // unwind attachments, it cannot unwind a corrupt body already running.
        throw FormatException(
          'payload for ${t['selector']} is corrupt '
          '(declared $declared, got $actual)',
        );
      }
      targets.add(
        PatchTarget(
          library: t['library']! as String,
          selector: t['selector']! as String,
          bytecode: Uint8List.fromList(blob),
        ),
      );
    }

    final release = header['release']! as Map<String, Object?>;
    return ContainerReader._(release['buildId']! as String, targets);
  }
}

Uint8List _uint32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

/// Convenience for tools: read a container file from disk.
ContainerReader readContainerFile(String path) =>
    ContainerReader.parse(File(path).readAsBytesSync());
