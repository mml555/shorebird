import 'dart:io';
import 'dart:typed_data';

import 'package:code_push_server/src/config.dart';
import 'package:crypto/crypto.dart';
import 'package:minio/minio.dart';

/// Artifact byte storage. Objects are keyed by `storage_key` (e.g.
/// `patch/12/<token>`). Shorebird hashes artifacts with sha256 over the raw
/// bytes, so release verification is a straight sha256 compare; a patch's
/// `hash` is the inflated-output hash (device-verified), so only its size is
/// checkable here.
///
/// Two backends: [FilesystemArtifactStore] (single-container default — bytes on
/// a local directory) and [S3ArtifactStore] (MinIO/S3 for scale). Both expose
/// the same surface; resumable-upload staging always uses local disk.
abstract class ArtifactStore {
  /// Opens the backend selected by [cfg]: `file` (default) or `s3`.
  static Future<ArtifactStore> open(Config cfg) => cfg.storageBackend == 's3'
      ? S3ArtifactStore.open(cfg)
      : FilesystemArtifactStore.open(cfg);

  Future<void> stageChunk(String token, int offset, List<int> bytes);
  int stagedSize(String token);
  Future<void> commitStaged(String token, String key);
  void discardStaged(String token);
  Future<void> put(String key, List<int> bytes);
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
    discardStaged(token);
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
    await f.writeAsBytes(bytes, flush: true);
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
// S3 / MinIO (scale backend)
// ---------------------------------------------------------------------------

class S3ArtifactStore with _DiskStaging implements ArtifactStore {
  S3ArtifactStore(this._minio, this._bucket, this._staging);

  static Future<S3ArtifactStore> open(Config cfg) async {
    final minio = Minio(
      endPoint: cfg.s3Endpoint,
      port: cfg.s3Port,
      useSSL: cfg.s3UseSsl,
      accessKey: cfg.s3AccessKey,
      secretKey: cfg.s3SecretKey,
    );
    if (!await minio.bucketExists(cfg.s3Bucket)) {
      await minio.makeBucket(cfg.s3Bucket);
    }
    final staging = Directory('${Directory.systemTemp.path}/cps_staging')
      ..createSync(recursive: true);
    return S3ArtifactStore(minio, cfg.s3Bucket, staging);
  }

  final Minio _minio;
  final String _bucket;
  final Directory _staging;

  @override
  Directory get staging => _staging;

  @override
  Future<void> put(String key, List<int> bytes) async {
    await _minio.putObject(
      _bucket,
      key,
      Stream.value(Uint8List.fromList(bytes)),
      size: bytes.length,
    );
  }

  @override
  Future<bool> ping() async {
    try {
      await _minio.bucketExists(_bucket);
      return true;
    } on Exception {
      return false;
    }
  }

  @override
  Future<bool> exists(String key) async {
    try {
      await _minio.statObject(_bucket, key);
      return true;
    } on Exception {
      return false;
    }
  }

  @override
  Future<int> size(String key) async {
    final stat = await _minio.statObject(_bucket, key);
    return stat.size ?? 0;
  }

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
    final stream = await _minio.getObject(_bucket, key);
    final b = BytesBuilder();
    await for (final chunk in stream) {
      b.add(chunk);
    }
    return b.takeBytes();
  }

  @override
  Future<Stream<List<int>>> openRead(
    String key, {
    int? offset,
    int? length,
  }) async {
    if (offset != null) {
      return _minio.getPartialObject(_bucket, key, offset, length);
    }
    return _minio.getObject(_bucket, key);
  }
}
