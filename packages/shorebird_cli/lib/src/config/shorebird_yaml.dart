import 'package:json_annotation/json_annotation.dart';

part 'shorebird_yaml.g.dart';

/// The patch verification mode for the app.
@JsonEnum(fieldRename: FieldRename.snake)
enum PatchVerification {
  /// Verify the patch signature and hash before installing and loading.
  strict,

  /// Verify the patch signature and hash before installing, but not when
  /// loading from cache.
  installOnly,
}

/// {@template shorebird_yaml}
/// A Shorebird configuration file which contains metadata about the app.
/// {@endtemplate}
@JsonSerializable(anyMap: true, disallowUnrecognizedKeys: true)
class ShorebirdYaml {
  /// {@macro shorebird_yaml}
  const ShorebirdYaml({
    required this.appId,
    this.flavors,
    this.baseUrl,
    this.autoUpdate,
    this.patchVerification,
    this.channel,
  });

  /// Creates a [ShorebirdYaml] from a JSON map.
  factory ShorebirdYaml.fromJson(Map<dynamic, dynamic> json) =>
      _$ShorebirdYamlFromJson(json);

  /// Converts this [ShorebirdYaml] to a JSON map.
  Map<String, dynamic> toJson() => _$ShorebirdYamlToJson(this);

  /// The base app id.
  ///
  /// Example:
  /// `"8d3155a8-a048-4820-acca-824d26c29b71"`
  final String appId;

  /// A map of flavor names to app ids.
  ///
  /// Will be `null` for apps with no flavors.
  ///
  /// Example:
  /// ```json
  /// {
  ///   "development": "8d3155a8-a048-4820-acca-824d26c29b71",
  ///   "production": "d458e87a-7362-4386-9eeb-629db2af413a"
  /// }
  /// ```
  final Map<String, String>? flavors;

  /// The base url used to check for updates.
  final String? baseUrl;

  /// Whether or not to automatically update the app.
  final bool? autoUpdate;

  /// The patch verification mode for the app.
  final PatchVerification? patchVerification;

  /// The default update track used by automatic updates.
  ///
  /// `null` means the updater's own default, which is `stable`
  /// (`vendor/updater/library/src/yaml.rs`: *"Update channel name. Defaults to
  /// \"stable\" if not set."*).
  ///
  /// WHY THIS FIELD EXISTS. The native updater has always read `channel:` from
  /// the bundled `shorebird.yaml`, but this model did not declare it, and the
  /// generated parser is `disallowUnrecognizedKeys`. So an app that wrote the
  /// documented key got an `UnrecognizedKeysException` from the CLI, leaving no
  /// supported configuration path onto a non-stable track — the manual
  /// `update(track:)` API was the only way. Certified in
  /// `selfhost/evidence/p6-tracks/VERDICT.md`, which records it as a product
  /// defect rather than working around it.
  ///
  /// It also made the CLI inconsistent with itself: `shorebird preview
  /// --track=NAME` writes `channel:` into `shorebird.yaml`
  /// (`preview_command.dart:_maybeSetChannelInShorebirdYaml`), so running
  /// preview once could leave a config the CLI then refused to read.
  ///
  /// NAMED `channel`, NOT `track`. The updater, the protocol and the server all
  /// speak `channel`; a second `track:` key would only add an alias with
  /// precedence questions. User-facing text may still call it a track.
  final String? channel;
}

/// Extension on [ShorebirdYaml] to get the app id for a specific flavor.
extension AppIdExtension on ShorebirdYaml {
  /// Returns the app id for the given flavor.
  String getAppId({String? flavor}) {
    if (flavor == null || flavors == null) return appId;
    return flavors![flavor] ?? appId;
  }
}
