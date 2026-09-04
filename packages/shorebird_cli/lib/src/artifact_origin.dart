import 'package:shorebird_cli/src/platform.dart';

/// {@template artifact_origin}
/// THE SINGLE AUTHORITY for where artifact bytes come from.
///
/// Every origin the CLI fetches artifacts from resolves here, and every default
/// literal lives here. That is the point: before this existed the origins were
/// assigned in four places under two differently-named environment variables,
/// so a self-hoster had to know both names and a newly added download path
/// could quietly escape the configuration entirely.
///
/// ## Two halves, and why they are not the same URL
///
/// * **Flutter/engine artifacts** — the engine zips `flutter precache` and
///   `flutter build` pull. Fetched by the Flutter child process, so the origin
///   is handed to it in the environment as `FLUTTER_STORAGE_BASE_URL`, which is
///   Flutter's own standard knob. Paths look like
///   `<origin>/flutter_infra_release/flutter/<engine>/…`.
/// * **Shorebird artifacts** — the CLI's own downloads: `aot-tools.dill`, the
///   `patch` executable, `bundletool`, and **the Route B compiler cell bundle
///   and its v2 descriptor**. Fetched by the CLI itself, and composed as
///   `<base>/<bucket>/shorebird/<engine>/…` — a base plus a bucket segment,
///   which is why it cannot simply reuse the Flutter origin's value.
///
/// The cell bundle sitting in the second half is the reason a single authority
/// matters rather than being a convenience: a deployment that pointed only
/// `FLUTTER_STORAGE_BASE_URL` at its own CDN would still fetch the bytes that
/// DEFINE its compiler cell from Shorebird's.
///
/// ## Precedence
///
/// For each value: its own specific variable, then [originKey], then the
/// upstream default. So a deployment sets ONE variable for the common case and
/// can still override either half individually, and with nothing set the
/// resolved values are byte-identical to upstream Shorebird's.
///
/// ## What this deliberately does not do
///
/// It does not touch the control-plane URL (`SHOREBIRD_HOSTED_URL`) or anything
/// else about endpoints. This is artifact STORAGE authority only.
///
/// It also does not touch
/// `RouteBCompiler`'s `_compilerMember`, which contains the same hostname as a
/// literal. That string is a **manifest member name** — part of the preimage a
/// cell address is computed over — not a URL that is ever fetched. Rewriting it
/// would change cell addresses. See the allowlist in
/// `test/src/artifact_origin_test.dart`.
/// {@endtemplate}
abstract final class ArtifactOrigin {
  /// The one variable a self-hosted deployment normally sets. When present it
  /// supplies the default for BOTH halves above.
  static const String originKey = 'SHOREBIRD_ARTIFACT_ORIGIN';

  /// Flutter's own standard knob, and the more specific authority for
  /// Flutter/engine artifacts. Also the name handed to the child process.
  static const String flutterStorageKey = 'FLUTTER_STORAGE_BASE_URL';

  /// The more specific authority for the base of Shorebird's own artifacts.
  static const String shorebirdStorageKey = 'SHOREBIRD_STORAGE_BASE_URL';

  /// The more specific authority for the bucket segment of Shorebird's own
  /// artifacts. Left alone by [originKey]: the self-host CDN mirrors upstream's
  /// `<bucket>/shorebird/<engine>/…` path shape, so only the base moves.
  static const String shorebirdBucketKey = 'SHOREBIRD_STORAGE_BUCKET';

  /// Upstream's Flutter/engine artifact origin.
  static const String upstreamFlutterStorageBaseUrl =
      'https://download.shorebird.dev';

  /// Upstream's base for Shorebird's own artifacts.
  static const String upstreamShorebirdStorageBaseUrl =
      'https://storage.googleapis.com';

  /// Upstream's bucket segment for Shorebird's own artifacts.
  static const String upstreamShorebirdStorageBucket = 'download.shorebird.dev';

  /// Where the Flutter child process fetches engine artifacts from.
  static String flutterStorageBaseUrl() =>
      _resolve(flutterStorageKey) ?? upstreamFlutterStorageBaseUrl;

  /// The base for Shorebird's own artifact downloads.
  static String shorebirdStorageBaseUrl() =>
      _resolve(shorebirdStorageKey) ?? upstreamShorebirdStorageBaseUrl;

  /// The bucket segment for Shorebird's own artifact downloads.
  ///
  /// Deliberately NOT defaulted from [originKey] — see [shorebirdBucketKey].
  static String shorebirdStorageBucket() =>
      _nonEmpty(platform.environment[shorebirdBucketKey]) ??
      upstreamShorebirdStorageBucket;

  /// Whether a self-hosted origin is configured at all, by any of the three
  /// variables. Used to report the resolved configuration rather than leaving
  /// an operator to guess which knob took effect.
  static bool get isOverridden =>
      _nonEmpty(platform.environment[originKey]) != null ||
      _nonEmpty(platform.environment[flutterStorageKey]) != null ||
      _nonEmpty(platform.environment[shorebirdStorageKey]) != null ||
      _nonEmpty(platform.environment[shorebirdBucketKey]) != null;

  /// A one-line description of the resolved origins, for `--verbose` and for
  /// the doctor.
  static String describe() =>
      'flutter=${flutterStorageBaseUrl()} '
      'shorebird=${shorebirdStorageBaseUrl()}/${shorebirdStorageBucket()}';

  /// [key]'s value, else [originKey]'s, else null. Trailing slashes are
  /// trimmed so callers can always join with a single `/`.
  static String? _resolve(String key) {
    final specific = _nonEmpty(platform.environment[key]);
    if (specific != null) return specific;
    return _nonEmpty(platform.environment[originKey]);
  }

  /// An environment variable set to the empty string is treated as ABSENT.
  ///
  /// Not pedantry: `FLUTTER_STORAGE_BASE_URL=` in a shell profile or a CI job
  /// would otherwise resolve the origin to the empty string and every artifact
  /// URL would become a path with no host — a failure that looks like a network
  /// fault rather than a configuration one.
  static String? _nonEmpty(String? value) {
    if (value == null) return null;
    final trimmed = value.trim().replaceAll(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? null : trimmed;
  }
}
