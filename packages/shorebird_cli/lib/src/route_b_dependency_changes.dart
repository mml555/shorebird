import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_coverage.dart';

/// The `--include` prefix of the dependency pass: every package library, on
/// both sides.
///
/// A Route B patch replaces functions of the app's own libraries only: the
/// release's census, interface and target manifest are all cut at
/// `package:<app>/` (see [routeBAppIncludePrefixes]). An edit anywhere else (a
/// path dependency, a git dependency, a hosted package at another version,
/// generated localizations) is invisible to the app's analysis, so without a
/// second look the patch is published without it and says nothing.
///
/// One prefix rather than one per package, so a package the release compiled
/// and the patch no longer does (dropped, or renamed) is compared too: its
/// members read as removed. It is also one argument, however many packages
/// the app has.
const routeBDependencyIncludePrefixes = ['package:'];

/// Where a package came from, read from the patch build's package config.
enum RouteBPackageSource {
  /// A `path:` dependency (or override): source the developer edits.
  path,

  /// A package from a pub server, at the version `pubspec.lock` names.
  hosted,

  /// A `git:` dependency, at the commit `pubspec.lock` names.
  git,

  /// Localizations `flutter gen-l10n` generates from `.arb` files.
  generated,

  /// Not in the patch build's package config: the release had it.
  absent,
}

/// One package of the patch build, from `.dart_tool/package_config.json`.
class RouteBPackage {
  /// A package [name] from [source], whose root is [root].
  const RouteBPackage({
    required this.name,
    required this.source,
    this.root,
    this.version,
  });

  /// The package name, as in `package:<name>/`.
  final String name;

  /// Where it came from.
  final RouteBPackageSource source;

  /// Its root: relative to the project when it lies inside it, else
  /// absolute, else the root URI as written when that is not a `file:` URI.
  final String? root;

  /// A hosted package's version, from its pub cache directory name.
  final String? version;

  /// How the refusal names it.
  String describe() => switch (source) {
    RouteBPackageSource.path => '$name (path package at ${root ?? '?'})',
    RouteBPackageSource.hosted =>
      '$name (hosted${version == null ? '' : ', $version in this build'})',
    RouteBPackageSource.git => '$name (git dependency at ${root ?? '?'})',
    RouteBPackageSource.generated =>
      '$name (localizations generated from your .arb files)',
    RouteBPackageSource.absent =>
      "$name (in the release, not in this build's dependencies)",
  };
}

/// The packages of a patch build, and which of them the Flutter SDK provides.
class RouteBPackages {
  /// The [packages] by name, and the names in [flutterSdk].
  const RouteBPackages({required this.packages, required this.flutterSdk});

  /// Every package but the Flutter SDK's, by name.
  final Map<String, RouteBPackage> packages;

  /// Packages whose root lies inside the Flutter checkout. They come from the
  /// Flutter revision, which a patch shares with its release, so a difference
  /// in them is tree shaking (measured: an app's new call into `collection`
  /// changed two `TextStyle` getters), not an edit. A path package placed
  /// inside the Flutter checkout is counted here too, by design.
  final Set<String> flutterSdk;

  /// [name], or an [RouteBPackageSource.absent] entry for a package this build
  /// does not have.
  RouteBPackage operator [](String name) =>
      packages[name] ??
      RouteBPackage(name: name, source: RouteBPackageSource.absent);
}

/// Reads [packageConfig], the patch build's `.dart_tool/package_config.json`.
///
/// Throws [FormatException] when it cannot be read, so a caller refuses
/// rather than skipping the check.
RouteBPackages readRouteBPackages({
  required File packageConfig,
  required Directory projectRoot,
  required Directory flutterRoot,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(packageConfig.readAsStringSync());
  } on Object catch (error) {
    throw FormatException('could not read ${packageConfig.path}: $error');
  }
  final entries = decoded is Map<String, dynamic> ? decoded['packages'] : null;
  if (entries is! List) {
    throw FormatException('${packageConfig.path} lists no packages');
  }
  final flutter = p.normalize(p.absolute(flutterRoot.path));
  final project = p.normalize(p.absolute(projectRoot.path));
  final generatedRoot = p.join(project, '.dart_tool', 'flutter_gen');
  final packages = <String, RouteBPackage>{};
  final flutterSdk = <String>{};
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) continue;
    final name = entry['name'];
    final rootUri = entry['rootUri'];
    if (name is! String || name.isEmpty || rootUri is! String) continue;
    final uri = packageConfig.absolute.uri.resolve(rootUri);
    if (uri.scheme != 'file') {
      // Not on disk here, so not under the Flutter checkout either: compared,
      // and named by its URI.
      packages[name] = RouteBPackage(
        name: name,
        source: RouteBPackageSource.path,
        root: rootUri,
      );
      continue;
    }
    final root = p.normalize(uri.toFilePath());
    if (root == flutter || p.isWithin(flutter, root)) {
      flutterSdk.add(name);
      continue;
    }
    final parts = p.split(root);
    final RouteBPackageSource source;
    String? version;
    if (name == 'flutter_gen' ||
        root == generatedRoot ||
        p.isWithin(generatedRoot, root)) {
      source = RouteBPackageSource.generated;
    } else if (parts.contains('hosted')) {
      source = RouteBPackageSource.hosted;
      final directory = p.basename(root);
      if (directory.startsWith('$name-')) {
        version = directory.substring(name.length + 1);
      }
    } else if (parts.contains('git') && parts.contains('.pub-cache')) {
      source = RouteBPackageSource.git;
    } else {
      source = RouteBPackageSource.path;
    }
    packages[name] = RouteBPackage(
      name: name,
      source: source,
      root: p.isWithin(project, root) ? p.relative(root, from: project) : root,
      version: version,
    );
  }
  return RouteBPackages(packages: packages, flutterSdk: flutterSdk);
}

/// How a dependency member differs between the release and the patch.
enum RouteBDependencyChangeKind {
  /// Its body or signature changed.
  changed,

  /// A field, `const`, constructor or class header changed or is new.
  declaration,

  /// In the release, not in the patch. A deleted override would leave the
  /// release's running on the device.
  removed,

  /// New in the patch and rejected by the analysis: a new override changes
  /// what the release's call sites dispatch to.
  added,
}

/// One dependency member that differs, and how.
typedef RouteBDependencyChange = ({
  String target,
  RouteBDependencyChangeKind kind,
});

/// What differs outside the app's own package, by package name, from an
/// analysis run with [routeBDependencyIncludePrefixes].
///
/// Changed members; changed or new fields, constants, constructors and class
/// headers; members the release has and the patch does not; and new members
/// the analysis rejected. A new member that nothing rejected is one the patch
/// does not call, or one its app code calls, which the retention check
/// refuses first as a symbol the release never kept.
///
/// Only `package:` keys count. The app's own package is the app pass's, and
/// the [flutterSdk] packages are left out (see [RouteBPackages.flutterSdk]).
Map<String, List<RouteBDependencyChange>> routeBDependencyChanges(
  RouteBCoverage coverage, {
  required String appPackageName,
  Set<String> flutterSdk = const {},
}) {
  final out = <String, Map<String, RouteBDependencyChangeKind>>{};
  void add(String key, RouteBDependencyChangeKind kind) {
    if (!key.startsWith('package:')) return;
    final slash = key.indexOf('/');
    if (slash < 0) return;
    final package = key.substring('package:'.length, slash);
    if (package == appPackageName || flutterSdk.contains(package)) return;
    (out[package] ??= {}).putIfAbsent(key, () => kind);
  }

  for (final key in coverage.changed) {
    add(key, RouteBDependencyChangeKind.changed);
  }
  for (final rejection in coverage.rejections) {
    if (rejection.category == RouteBRepresentability.declaration) {
      add(rejection.target, RouteBDependencyChangeKind.declaration);
    } else if (rejection.category == RouteBRepresentability.added) {
      add(rejection.target, RouteBDependencyChangeKind.added);
    }
  }
  for (final key in coverage.removed) {
    add(key, RouteBDependencyChangeKind.removed);
  }
  return {
    for (final package in out.keys.toList()..sort())
      package: [
        for (final key in out[package]!.keys.toList()..sort())
          (target: key, kind: out[package]![key]!),
      ],
  };
}

/// The refusal for [changes], listing at most [limit] members.
String describeRouteBDependencyChanges(
  Map<String, List<RouteBDependencyChange>> changes, {
  required RouteBPackages packages,
  required String appPackageName,
  int limit = 20,
}) {
  final buffer = StringBuffer()
    ..writeln(
      "This patch changes code outside the app's own package "
      '($appPackageName), which an iOS patch cannot carry:',
    );
  var shown = 0;
  var hidden = 0;
  for (final MapEntry(key: name, value: members) in changes.entries) {
    if (shown >= limit) {
      hidden += members.length;
      continue;
    }
    buffer
      ..writeln()
      ..writeln('  ${packages[name].describe()}');
    for (final change in members) {
      if (shown >= limit) {
        hidden++;
        continue;
      }
      buffer.writeln('    ${change.kind.name.padRight(11)} ${change.target}');
      shown++;
    }
  }
  if (hidden > 0) buffer.writeln('  ... and $hidden more');
  final sources = {for (final name in changes.keys) packages[name].source};
  buffer
    ..writeln()
    ..writeln(
      'An iOS patch replaces functions of package:$appPackageName only, so the '
      "device would keep running the release's copy of these. Revert them, or "
      'ship them in a new release.',
    );
  if (sources.contains(RouteBPackageSource.hosted) ||
      sources.contains(RouteBPackageSource.git)) {
    buffer.writeln(
      'A hosted or git package changes when its version in pubspec.lock does: '
      "restore the release's pubspec.lock, or ship a new release.",
    );
  }
  if (sources.contains(RouteBPackageSource.generated)) {
    buffer.writeln(
      'flutter_gen is generated from your .arb files: an .arb change needs a '
      'new release.',
    );
  }
  if (sources.contains(RouteBPackageSource.absent)) {
    buffer.writeln(
      'A package the release had and this build does not (removed, or '
      'renamed) needs a new release.',
    );
  }
  buffer
    ..writeln()
    ..write('Nothing was uploaded.');
  return buffer.toString();
}
