import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// An [AssetBundle] that prefers assets from a patch's downloaded bundle and
/// falls back to the assets compiled into the app.
///
/// Overlay semantics, not replacement: a patch bundle that omits an asset still
/// resolves it from [fallback]. That keeps a patch honest about being additive,
/// and means a bundle missing something can never turn into a crash on an asset
/// that shipped in the release.
class PatchAssetBundle extends AssetBundle {
  /// Creates a bundle reading from [directory], falling back to [fallback].
  PatchAssetBundle({required this.directory, AssetBundle? fallback})
    : fallback = fallback ?? rootBundle;

  /// The unpacked patch bundle, laid out relative to the asset root — the same
  /// shape as `flutter_assets`, because that is the tree the CLI zipped.
  final Directory directory;

  /// Where a key not present in [directory] is resolved.
  final AssetBundle fallback;

  /// The file backing [key], or `null` if this bundle does not carry it.
  File? _fileFor(String key) {
    // Normalize and reject traversal so a crafted key cannot read outside the
    // bundle, e.g. `../../shorebird.yaml`.
    final normalized = p.normalize(key);
    if (p.isAbsolute(normalized) || p.split(normalized).contains('..')) {
      return null;
    }
    final file = File(p.join(directory.path, normalized));
    return file.existsSync() ? file : null;
  }

  @override
  Future<ByteData> load(String key) async {
    final file = _fileFor(key);
    if (file == null) return fallback.load(key);

    try {
      final bytes = await file.readAsBytes();
      return ByteData.sublistView(bytes);
    } on Object {
      // Present but unreadable: fall back rather than fail the lookup.
      return fallback.load(key);
    }
  }

  @override
  Future<ImmutableBuffer> loadBuffer(String key) async {
    final file = _fileFor(key);
    if (file == null) return fallback.loadBuffer(key);

    try {
      // Goes through the file path so the engine can memory-map it, which is
      // what makes large assets (images) cheap. Copying via ByteData here would
      // silently regress image loading.
      return await ImmutableBuffer.fromFilePath(file.path);
    } on Object {
      return fallback.loadBuffer(key);
    }
  }

  @override
  Future<T> loadStructuredData<T>(
    String key,
    Future<T> Function(String value) parser,
  ) async {
    final file = _fileFor(key);
    if (file == null) return fallback.loadStructuredData(key, parser);

    try {
      return await parser(await file.readAsString());
    } on Object {
      return fallback.loadStructuredData(key, parser);
    }
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    final file = _fileFor(key);
    if (file == null) return fallback.loadString(key, cache: cache);

    try {
      return await file.readAsString();
    } on Object {
      return fallback.loadString(key, cache: cache);
    }
  }

  @override
  void evict(String key) {
    super.evict(key);
    fallback.evict(key);
  }

  @override
  void clear() {
    super.clear();
    fallback.clear();
  }
}
