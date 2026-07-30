import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:code_push_runtime/src/environment.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Downloads and caches the asset bundle attached to a patch.
///
/// The bundle is fetched from the control plane rather than read out of the
/// updater's patch directory, because the native updater never sees it: it
/// downloads exactly one artifact and applies it as a binary diff. Keeping
/// assets out of that payload is what lets this work on iOS as well as Android
/// with a stock updater.
///
/// The consequence is that the asset fetch is **not atomic** with the code
/// patch, which drives every invariant here: a bundle is stored under its patch
/// number, served only when that number is the one running, and every other
/// patch's bundle is deleted as soon as a different one is running.
class PatchAssetStore {
  /// Creates a store for [environment], caching under [rootDirectory].
  PatchAssetStore({
    required this.environment,
    required this.rootDirectory,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// The app and control plane to fetch from.
  final ShorebirdEnvironment environment;

  /// Where bundles are unpacked, one subdirectory per patch number.
  final Directory rootDirectory;

  final http.Client _http;

  /// Written last, after every asset is on disk, so a directory containing it
  /// is known to be a complete bundle. Without it an interrupted unpack would
  /// look identical to a finished one and serve a half-populated asset tree.
  static const _completeMarker = '.complete';

  /// The directory a completed bundle for [patchNumber] lives in.
  Directory directoryFor(int patchNumber) =>
      Directory(p.join(rootDirectory.path, '$patchNumber'));

  /// Whether a complete bundle for [patchNumber] is already on disk.
  bool isCached(int patchNumber) => File(
    p.join(directoryFor(patchNumber).path, _completeMarker),
  ).existsSync();

  /// Ensures the bundle for [patchNumber] is on disk, fetching it if needed,
  /// and returns its directory — or `null` if the patch has no bundle or it
  /// could not be fetched.
  ///
  /// Never throws. A failed asset fetch must leave the app running on its
  /// built-in assets, not crash it.
  Future<Directory?> ensure({
    required int patchNumber,
    required String releaseVersion,
  }) async {
    // Do this first and unconditionally, so a rollback drops the newer bundle
    // even when the patch now running has none of its own to fetch.
    _evictAllExcept(patchNumber);

    if (isCached(patchNumber)) return directoryFor(patchNumber);

    try {
      final descriptor = await _describe(
        patchNumber: patchNumber,
        releaseVersion: releaseVersion,
      );
      if (descriptor == null) return null;

      final bytes = await _download(descriptor);
      if (bytes == null) return null;

      return await _unpack(bytes, patchNumber: patchNumber);
    } on Object {
      return null;
    }
  }

  /// Asks the control plane where this patch's bundle is.
  Future<_BundleDescriptor?> _describe({
    required int patchNumber,
    required String releaseVersion,
  }) async {
    final response = await _http.post(
      environment.baseUrl.resolve('patches/assets'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'app_id': environment.appId,
        'release_version': releaseVersion,
        'platform': DeviceAbi.current().platform,
        'patch_number': patchNumber,
      }),
    );
    if (response.statusCode != HttpStatus.ok) return null;

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) return null;
    if (decoded['assets_available'] != true) return null;
    final assets = decoded['assets'];
    if (assets is! Map) return null;

    final url = assets['url'];
    final hash = assets['hash'];
    if (url is! String) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    return _BundleDescriptor(url: uri, hash: hash is String ? hash : null);
  }

  /// Fetches the bundle, rejecting it if it does not match its stated hash.
  Future<List<int>?> _download(_BundleDescriptor descriptor) async {
    final response = await _http.get(descriptor.url);
    if (response.statusCode != HttpStatus.ok) return null;

    final bytes = response.bodyBytes;
    final expected = descriptor.hash;
    if (expected != null) {
      // The URL is signed, so this is not a trust check — it catches a
      // truncated or corrupted transfer before it becomes a cached bundle that
      // looks complete and serves broken assets on every later launch.
      if (sha256.convert(bytes).toString() != expected) return null;
    }
    return bytes;
  }

  /// Unpacks [bytes] into the directory for [patchNumber], atomically enough
  /// that a crash mid-unpack cannot leave a bundle that looks complete.
  Future<Directory?> _unpack(
    List<int> bytes, {
    required int patchNumber,
  }) async {
    final target = directoryFor(patchNumber);
    final staging = Directory('${target.path}.staging');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);

    final stagingPath = staging.path;
    final written = await Isolate.run(() {
      try {
        final archive = ZipDecoder().decodeBytes(bytes);
        var count = 0;
        for (final entry in archive.files) {
          if (!entry.isFile) continue;
          // Reject traversal: entries come from our own CLI, but an unpacker
          // that honors `../` is a foothold if that ever stops being true.
          final normalized = p.normalize(entry.name);
          if (p.isAbsolute(normalized) || p.split(normalized).contains('..')) {
            continue;
          }
          File(p.join(stagingPath, normalized))
            ..createSync(recursive: true)
            ..writeAsBytesSync(entry.content as List<int>);
          count++;
        }
        return count;
      } on Object {
        return -1;
      }
    });

    // Zero extracted files is a failure, not an empty bundle. A payload that is
    // not a zip at all decodes to an empty archive rather than throwing, and
    // publishing that would cache a complete-looking bundle that serves nothing
    // and is never retried. The CLI only ever uploads a bundle that has assets.
    if (written <= 0) {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      return null;
    }

    // Marker inside staging, then one rename: the published directory is
    // complete from the instant it exists under its real name.
    File(p.join(stagingPath, _completeMarker)).writeAsStringSync('');
    if (target.existsSync()) target.deleteSync(recursive: true);
    staging.renameSync(target.path);
    return target;
  }

  /// Deletes every cached bundle except [patchNumber]'s.
  ///
  /// This is the rollback guarantee. Serving a bundle from a patch that is no
  /// longer running pairs new assets with old code — exactly the mismatch the
  /// updater's own rollback exists to prevent.
  void _evictAllExcept(int? patchNumber) {
    if (!rootDirectory.existsSync()) return;
    final keep = patchNumber == null ? null : '$patchNumber';
    for (final entry in rootDirectory.listSync()) {
      if (entry is! Directory) continue;
      if (p.basename(entry.path) == keep) continue;
      try {
        entry.deleteSync(recursive: true);
      } on Object {
        // A bundle we cannot delete is not worth failing over; it is simply
        // never served, because serving is gated on the running patch number.
      }
    }
  }

  /// Drops every cached bundle. Used when no patch is running at all, so the
  /// app is back on its built-in assets.
  void evictAll() => _evictAllExcept(null);
}

class _BundleDescriptor {
  const _BundleDescriptor({required this.url, required this.hash});
  final Uri url;
  final String? hash;
}
