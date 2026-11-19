import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_coverage.dart';

/// The `--include` prefixes of every package a patch build compiled that is
/// neither the app's own package nor part of the Flutter SDK.
///
/// A Route B patch replaces functions of the app's own libraries only: the
/// release's census, interface and target manifest are all cut at
/// `package:<app>/` (see [routeBAppIncludePrefixes]). An edit anywhere else (a
/// path dependency, a git dependency, a hosted package at another version)
/// is invisible to the app's analysis, so without a separate look the patch
/// is published without it and says nothing. These prefixes are that look.
///
/// Packages under [flutterRoot] are left out: they come from the Flutter
/// revision, which a patch shares with its release.
///
/// Throws [FormatException] when [packageConfig] cannot be read, so a caller
/// refuses rather than skipping the check.
List<String> routeBDependencyIncludePrefixes({
  required File packageConfig,
  required String appPackageName,
  required Directory flutterRoot,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(packageConfig.readAsStringSync());
  } on Object catch (error) {
    throw FormatException('could not read ${packageConfig.path}: $error');
  }
  final packages = decoded is Map<String, dynamic> ? decoded['packages'] : null;
  if (packages is! List) {
    throw FormatException('${packageConfig.path} lists no packages');
  }
  final flutter = p.normalize(p.absolute(flutterRoot.path));
  final prefixes = <String>[];
  for (final entry in packages) {
    if (entry is! Map<String, dynamic>) continue;
    final name = entry['name'];
    final rootUri = entry['rootUri'];
    if (name is! String || name.isEmpty || name == appPackageName) continue;
    if (rootUri is String) {
      final root = packageConfig.absolute.uri.resolve(rootUri);
      if (root.scheme == 'file') {
        final path = p.normalize(root.toFilePath());
        if (path == flutter || p.isWithin(flutter, path)) continue;
      }
    }
    prefixes.add('package:$name/');
  }
  return prefixes..sort();
}

/// The members and declarations outside the app's own package that differ
/// between the release and the patch, from an analysis run with
/// [routeBDependencyIncludePrefixes].
///
/// Changed members, and changed or new fields, constants, constructors and
/// class headers. New members are left to the retention check: a new
/// dependency function the app now calls is refused there as one the release
/// never kept, and one nothing calls changes nothing. Removed members are
/// never fatal, as for the app.
///
/// Keys under any of [appPrefixes] are ignored, so an analysis that also
/// covered the app's own libraries reports only the rest.
List<String> routeBDependencyChanges(
  RouteBCoverage coverage, {
  required List<String> appPrefixes,
}) {
  bool outsideApp(String key) => !appPrefixes.any(key.startsWith);
  return {
    ...coverage.changed.where(outsideApp),
    for (final rejection in coverage.rejections)
      if (rejection.category == RouteBRepresentability.declaration &&
          outsideApp(rejection.target))
        rejection.target,
  }.toList()..sort();
}
