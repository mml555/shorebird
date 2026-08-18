import 'dart:io';

import 'package:artifact_proxy/artifact_proxy.dart';
import 'package:checked_yaml/checked_yaml.dart';
import 'package:http/http.dart' as http;
import 'package:quiver/collection.dart';

/// {@template artifact_manifest_client}
/// A client that fetches [ArtifactsManifest]s from the shorebird storage bucket
/// and caches them in memory.
/// {@endtemplate}
class ArtifactManifestClient {
  /// {@macro artifact_manifest_client}
  ArtifactManifestClient({http.Client? httpClient, String? manifestBaseUrl})
    : _httpClient = httpClient ?? http.Client(),
      _manifestBaseUrl =
          manifestBaseUrl ??
          'https://storage.googleapis.com/download.shorebird.dev';

  final http.Client _httpClient;

  /// Where `shorebird/<revision>/artifacts_manifest.yaml` lives. This fetch
  /// is server-side (it never passes through the CDN cache in front of this
  /// proxy), so a self-hosted deployment must point it at its own mirror via
  /// `MANIFEST_BASE_URL` to operate with upstream unreachable.
  final String _manifestBaseUrl;

  final _cache = LruMap<String, ArtifactsManifest>(maximumSize: 1000);

  /// Fetches the [ArtifactsManifest] for the provided [revision] from the
  /// shorebird storage bucket.
  Future<ArtifactsManifest> getManifest(String revision) async {
    if (_cache.containsKey(revision)) return _cache[revision]!;
    final manifest = await _fetchManifest(revision);
    _cache[revision] = manifest;
    return manifest;
  }

  Future<ArtifactsManifest> _fetchManifest(String revision) async {
    final url = Uri.parse(
      '$_manifestBaseUrl/shorebird/$revision/artifacts_manifest.yaml',
    );
    final response = await _httpClient.get(url);
    if (response.statusCode != HttpStatus.ok) {
      throw Exception('''
Failed to fetch artifacts manifest for revision $revision.
${response.statusCode} ${response.reasonPhrase}''');
    }

    return checkedYamlDecode(
      response.body,
      (m) => ArtifactsManifest.fromJson(m!),
    );
  }
}
