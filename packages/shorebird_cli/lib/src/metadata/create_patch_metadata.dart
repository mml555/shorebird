import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:shorebird_cli/src/metadata/build_environment_metadata.dart';
import 'package:shorebird_cli/src/metadata/create_patch_platform_metadata.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

part 'create_patch_metadata.g.dart';

/// {@template create_patch_metadata}
/// Information about a patch, used for debugging purposes.
///
/// Collection of this information is done to help Shorebird users debug any
/// later failures in their builds.
///
/// A patch is not platform-scoped: `--platforms=android,ios` publishes one
/// patch carrying artifacts for both. Fields describing the invocation or the
/// build machine live here; anything derived from building or diffing a
/// specific platform lives in [platforms].
///
/// We do not collect Personally Identifying Information (e.g. no paths,
/// argument lists, etc.) in accordance with our privacy policy:
/// https://shorebird.dev/privacy/
/// {@endtemplate}
@JsonSerializable()
class CreatePatchMetadata extends Equatable {
  /// {@macro create_patch_metadata}
  const CreatePatchMetadata({
    required this.platforms,
    required this.usedIgnoreAssetChangesFlag,
    required this.usedIgnoreNativeChangesFlag,
    required this.inferredReleaseVersion,
    required this.environment,
    required this.isSigned,
  });

  // coverage:ignore-start
  /// Creates a [CreatePatchMetadata] with overridable default values for
  /// testing purposes.
  factory CreatePatchMetadata.forTest({
    Map<ReleasePlatform, CreatePatchPlatformMetadata>? platforms,
    bool usedIgnoreAssetChangesFlag = false,
    bool usedIgnoreNativeChangesFlag = false,
    bool inferredReleaseVersion = false,
    bool isSigned = false,
    BuildEnvironmentMetadata? environment,
  }) => CreatePatchMetadata(
    platforms:
        platforms ??
        {ReleasePlatform.android: CreatePatchPlatformMetadata.forTest()},
    usedIgnoreAssetChangesFlag: usedIgnoreAssetChangesFlag,
    usedIgnoreNativeChangesFlag: usedIgnoreNativeChangesFlag,
    isSigned: isSigned,
    inferredReleaseVersion: inferredReleaseVersion,
    environment: environment ?? BuildEnvironmentMetadata.forTest(),
  );
  // coverage:ignore-end

  /// Converts a `Map<String, dynamic>` to a [CreatePatchMetadata]
  factory CreatePatchMetadata.fromJson(Map<String, dynamic> json) =>
      _$CreatePatchMetadataFromJson(json);

  /// Converts a [CreatePatchMetadata] to a `Map<String, dynamic>`
  Map<String, dynamic> toJson() => _$CreatePatchMetadataToJson(this);

  /// Returns a copy of this [CreatePatchMetadata] with the given fields
  /// replaced by the new values.
  CreatePatchMetadata copyWith({
    Map<ReleasePlatform, CreatePatchPlatformMetadata>? platforms,
    bool? usedIgnoreAssetChangesFlag,
    bool? usedIgnoreNativeChangesFlag,
    bool? inferredReleaseVersion,
    bool? isSigned,
    BuildEnvironmentMetadata? environment,
  }) => CreatePatchMetadata(
    platforms: platforms ?? this.platforms,
    usedIgnoreAssetChangesFlag:
        usedIgnoreAssetChangesFlag ?? this.usedIgnoreAssetChangesFlag,
    usedIgnoreNativeChangesFlag:
        usedIgnoreNativeChangesFlag ?? this.usedIgnoreNativeChangesFlag,
    inferredReleaseVersion:
        inferredReleaseVersion ?? this.inferredReleaseVersion,
    isSigned: isSigned ?? this.isSigned,
    environment: environment ?? this.environment,
  );

  /// Returns a copy of this [CreatePatchMetadata] with [platform]'s entry
  /// replaced by [metadata].
  CreatePatchMetadata withPlatform(
    ReleasePlatform platform,
    CreatePatchPlatformMetadata metadata,
  ) => copyWith(platforms: {...platforms, platform: metadata});

  /// Per-platform patch details, keyed by the platform the patch carries
  /// artifacts for. Always has at least one entry.
  ///
  /// Serialized as an object keyed by [ReleasePlatform.value] rather than
  /// relying on json_serializable's enum-key handling, which would key on the
  /// Dart identifier and silently diverge if a platform's wire value ever
  /// stops matching its enum name.
  @JsonKey(toJson: _platformsToJson, fromJson: _platformsFromJson)
  final Map<ReleasePlatform, CreatePatchPlatformMetadata> platforms;

  /// Whether the `--allow-asset-diffs` flag was used.
  ///
  /// Reason: this helps us understand how often prevalent the need to ignore
  /// asset changes is.
  final bool usedIgnoreAssetChangesFlag;

  /// Whether the `--allow-native-diffs` flag was used.
  ///
  /// Reason: this helps us understand how often prevalent the need to ignore
  /// native code changes is.
  final bool usedIgnoreNativeChangesFlag;

  /// Whether the release version had to be inferred by Shorebird because
  /// it was not explicitly specified via the --release-version flag.
  final bool inferredReleaseVersion;

  /// Whether the patch was signed.
  ///
  /// Reason: this helps us understand how often users are signing their
  /// patches, and helps us provide better support for users who encounter
  /// issues.
  final bool isSigned;

  /// Properties about the environment in which the patch was created.
  ///
  /// Shared across platforms: one invocation builds every platform on one
  /// machine, so the OS, Flutter revision and Xcode version describe the run
  /// rather than any single platform.
  ///
  /// Reason: see [BuildEnvironmentMetadata].
  final BuildEnvironmentMetadata environment;

  @override
  List<Object?> get props => [
    platforms,
    usedIgnoreAssetChangesFlag,
    usedIgnoreNativeChangesFlag,
    inferredReleaseVersion,
    isSigned,
    environment,
  ];
}

Map<String, dynamic> _platformsToJson(
  Map<ReleasePlatform, CreatePatchPlatformMetadata> platforms,
) => {
  for (final MapEntry(key: platform, value: metadata) in platforms.entries)
    platform.value: metadata.toJson(),
};

Map<ReleasePlatform, CreatePatchPlatformMetadata> _platformsFromJson(
  Map<String, dynamic> json,
) => {
  for (final MapEntry(:key, :value) in json.entries)
    ReleasePlatform.fromJson(key): CreatePatchPlatformMetadata.fromJson(
      value as Map<String, dynamic>,
    ),
};
