import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/s3_client.dart';
import 'package:crypto/crypto.dart';

/// Artifact byte storage. Objects are keyed by `storage_key` (e.g.
/// `patch/12/<token>`). Shorebird hashes artifacts with sha256 over the raw
/// bytes, so release verification is a straight sha256 compare; a patch's
/// `hash` is the inflated-output hash (device-verified), so only its size is
/// checkable here.
///
/// Two backends: [FilesystemArtifactStore] (single-container default — bytes on
/// a local directory) and [S3ArtifactStore] (any S3-compatible store, for scale). Both expose
/// the same surface; resumable-upload staging always uses local disk.
abstract class ArtifactStore {
  /// Opens the backend selected by [cfg]: `file` (default) or `s3`.
  static Future<ArtifactStore> open(Config cfg) => cfg.storageBackend == 's3'
      ? S3ArtifactStore.open(cfg)
      : FilesystemArtifactStore.open(cfg);

  Future<void> stageChunk(String token, int offset, List<int> bytes);
  int stagedSize(String token);

  /// Writes the staged bytes for [token] to [key]. Leaves the staged file in
  /// place: the caller discards it ([discardStaged]) only once it knows it
  /// still owns the upload, so a holder whose claim was reclaimed cannot delete
  /// the new owner's file.
  Future<void> commitStaged(String token, String key);
  void discardStaged(String token);
  Future<void> put(String key, List<int> bytes);

  /// Removes the object at [key]. Removing one that is already gone is not an
  /// error.
  Future<void> delete(String key);
  Future<bool> ping();
  Future<bool> exists(String key);
  Future<int> size(String key);
  Future<String?> verify(
    String key,
    String expectedHash,
    int expectedSize, {
    required bool checkHash,
  });
  Future<Stream<List<int>>> openRead(String key, {int? offset, int? length});
}

/// Verifies raw [bytes] against [expectedSize] and (when [checkHash])
/// [expectedHash] (sha256 hex). Returns null on success, or a reason string.
/// Shared by both backends.
String? verifyBytes(
  List<int> bytes,
  String expectedHash,
  int expectedSize, {
  required bool checkHash,
}) {
  if (expectedSize > 0 && bytes.length != expectedSize) {
    return 'size mismatch: got ${bytes.length}, expected $expectedSize';
  }
  if (checkHash) {
    final actual = sha256.convert(bytes).toString();
    if (actual != expectedHash) {
      return 'hash mismatch: got $actual, expected $expectedHash';
    }
  }
  return null;
}

/// Local-disk staging for GCS-style resumable uploads. Chunks accumulate in a
/// `.partial` file keyed by token, then commit to the store on completion.
/// The concrete store supplies [put]; staging itself is backend-independent.
mixin _DiskStaging {
  Directory get staging;

  /// Persists committed bytes; implemented by each backend.
  Future<void> put(String key, List<int> bytes);

  File _stagingFile(String token) => File('${staging.path}/$token.partial');

  /// Commits the staged bytes for [token] to the store under [key].
  Future<void> commitStaged(String token, String key) async {
    await put(key, await _stagingFile(token).readAsBytes());
  }

  Future<void> stageChunk(String token, int offset, List<int> bytes) async {
    final f = _stagingFile(token);
    if (offset == 0) {
      await f.writeAsBytes(bytes, flush: true); // fresh (truncate + write)
      return;
    }
    final current = f.existsSync() ? f.lengthSync() : 0;
    if (offset < current) {
      final raf = await f.open(mode: FileMode.append);
      await raf.truncate(offset);
      await raf.close();
    }
    await f.writeAsBytes(bytes, mode: FileMode.append, flush: true);
  }

  int stagedSize(String token) {
    final f = _stagingFile(token);
    return f.existsSync() ? f.lengthSync() : 0;
  }

  void discardStaged(String token) {
    final f = _stagingFile(token);
    if (f.existsSync()) f.deleteSync();
  }
}

// ---------------------------------------------------------------------------
// Filesystem (single-container default — no external object store)
// ---------------------------------------------------------------------------

class FilesystemArtifactStore with _DiskStaging implements ArtifactStore {
  FilesystemArtifactStore(this._root, this._staging);

  static Future<FilesystemArtifactStore> open(Config cfg) async {
    final root = Directory('${cfg.dataDir}/artifacts')
      ..createSync(recursive: true);
    final staging = Directory('${cfg.dataDir}/staging')
      ..createSync(recursive: true);
    unawaited(sweepTempFiles(root));
    return FilesystemArtifactStore(root, staging);
  }

  final Directory _root;
  final Directory _staging;

  @override
  Directory get staging => _staging;

  File _file(String key) => File('${_root.path}/$key');

  @override
  Future<void> put(String key, List<int> bytes) async {
    final f = _file(key);
    await f.parent.create(recursive: true);
    // Write beside the target, then rename over it. A rename within one
    // directory is atomic, so a reader (or a process killed mid-write) sees
    // the old object or the whole new one, never a prefix, and two writers on
    // one key cannot interleave bytes. A killed write leaves its temp file
    // behind; [open] sweeps those.
    final tmp = File('${f.path}$_tmpMarker${_randomHex()}');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
    } on Object {
      try {
        if (tmp.existsSync()) await tmp.delete();
      } on Object {
        // Best effort: the caller must see the write's own error, and the
        // sweep removes what is left.
      }
      rethrow;
    }
  }

  static const _tmpMarker = '.tmp-';

  static String _randomHex() {
    final rng = Random.secure();
    return List<String>.generate(
      8,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// Matches a temp file name written by [put]: the key's name, then `.tmp-`
  /// and 16 hex characters. Matched against the file name alone, never the
  /// path, so a data directory whose own path contains `.tmp-` is safe.
  static final _tmpName = RegExp(r'\.tmp-[0-9a-f]{16}$');

  /// Removes temp files from writes that were killed before their rename and
  /// are older than [maxAge]. The age check makes it safe beside other
  /// replicas on the same volume, whose live writes are young. Walks the tree
  /// asynchronously; [open] does not wait for it.
  static Future<void> sweepTempFiles(Directory root, {Duration? maxAge}) async {
    final cutoff = DateTime.now().subtract(maxAge ?? const Duration(days: 1));
    try {
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is! File || !_tmpName.hasMatch(e.uri.pathSegments.last)) continue;
        try {
          if ((await e.lastModified()).isBefore(cutoff)) await e.delete();
        } on FileSystemException {
          // Gone already, or not ours to remove; the next start tries again.
        }
      }
    } on FileSystemException {
      // An unreadable directory must not stop the sweep or the server.
    }
  }

  @override
  Future<void> delete(String key) async {
    final f = _file(key);
    if (f.existsSync()) await f.delete();
  }

  @override
  Future<bool> ping() async => _root.existsSync();

  @override
  Future<bool> exists(String key) async => _file(key).existsSync();

  @override
  Future<int> size(String key) async => _file(key).length();

  @override
  Future<String?> verify(
    String key,
    String expectedHash,
    int expectedSize, {
    required bool checkHash,
  }) async {
    final bytes = await _file(key).readAsBytes();
    return verifyBytes(bytes, expectedHash, expectedSize, checkHash: checkHash);
  }

  @override
  Future<Stream<List<int>>> openRead(
    String key, {
    int? offset,
    int? length,
  }) async {
    final f = _file(key);
    if (offset != null) {
      final end = length != null ? offset + length : null;
      return f.openRead(offset, end);
    }
    return f.openRead();
  }
}

// ---------------------------------------------------------------------------
// S3-compatible object store (scale backend)
// ---------------------------------------------------------------------------

class S3ArtifactStore with _DiskStaging implements ArtifactStore {
  S3ArtifactStore(this._s3, this._staging);

  static Future<S3ArtifactStore> open(Config cfg) async {
    final s3 = S3Client(
      endpoint: Uri(
        scheme: cfg.s3UseSsl ? 'https' : 'http',
        host: cfg.s3Endpoint,
        port: cfg.s3Port,
      ),
      region: cfg.s3Region,
      accessKey: cfg.s3AccessKey,
      secretKey: cfg.s3SecretKey,
      bucket: cfg.s3Bucket,
      pathStyle: cfg.s3PathStyle,
    );
    if (!await s3.bucketExists()) {
      await s3.createBucket();
    }
    final staging = Directory('${Directory.systemTemp.path}/cps_staging')
      ..createSync(recursive: true);
    return S3ArtifactStore(s3, staging);
  }

  final S3Client _s3;
  final Directory _staging;

  @override
  Directory get staging => _staging;

  @override
  Future<void> put(String key, List<int> bytes) => _s3.putObject(key, bytes);

  @override
  Future<void> delete(String key) => _s3.deleteObject(key);

  @override
  Future<bool> ping() async {
    try {
      await _s3.bucketExists();
      return true;
    } on Exception {
      return false;
    }
  }

  @override
  Future<bool> exists(String key) async {
    try {
      await _s3.statObject(key);
      return true;
    } on Exception {
      return false;
    }
  }

  @override
  Future<int> size(String key) => _s3.statObject(key);

  @override
  Future<String?> verify(
    String key,
    String expectedHash,
    int expectedSize, {
    required bool checkHash,
  }) async {
    final bytes = await _readAll(key);
    return verifyBytes(bytes, expectedHash, expectedSize, checkHash: checkHash);
  }

  Future<List<int>> _readAll(String key) async {
    final stream = await _s3.getObject(key);
    final b = BytesBuilder();
    await for (final chunk in stream) {
      b.add(chunk);
    }
    return b.takeBytes();
  }

  @override
  Future<Stream<List<int>>> openRead(String key, {int? offset, int? length}) =>
      _s3.getObject(key, offset: offset, length: length);
}
