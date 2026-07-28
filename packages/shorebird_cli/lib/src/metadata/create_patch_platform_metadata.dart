import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:shorebird_cli/src/metadata/create_patch_metadata.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

part 'create_patch_platform_metadata.g.dart';

/// {@template create_patch_platform_metadata}
/// The slice of [CreatePatchMetadata] that varies per platform.
///
/// A single patch can cover several platforms (`--platforms=android,ios`
/// publishes one patch carrying artifacts for both). Anything measured by
/// building or diffing a specific platform's artifact belongs here; anything
/// describing the invocation or the machine stays on [CreatePatchMetadata].
/// {@endtemplate}
@JsonSerializable()
class CreatePatchPlatformMetadata extends Equatable {
  /// {@macro create_patch_platform_metadata}
  const CreatePatchPlatformMetadata({
    required this.hasAssetChanges,
    required this.hasNativeChanges,
    this.linkPercentage,
    this.linkMetadata,
    this.buildTraceSummary,
  });

  // coverage:ignore-start
  /// Creates a [CreatePatchPlatformMetadata] with overridable default values
  /// for testing purposes.
  factory CreatePatchPlatformMetadata.forTest({
    bool hasAssetChanges = false,
    bool hasNativeChanges = false,
    double? linkPercentage,
    Json? linkMetadata,
    Json? buildTraceSummary,
  }) => CreatePatchPlatformMetadata(
    hasAssetChanges: hasAssetChanges,
    hasNativeChanges: hasNativeChanges,
    linkPercentage: linkPercentage,
    linkMetadata: linkMetadata,
    buildTraceSummary: buildTraceSummary,
  );
  // coverage:ignore-end

  /// Converts a `Map<String, dynamic>` to a [CreatePatchPlatformMetadata].
  factory CreatePatchPlatformMetadata.fromJson(Map<String, dynamic> json) =>
      _$CreatePatchPlatformMetadataFromJson(json);

  /// Converts a [CreatePatchPlatformMetadata] to a `Map<String, dynamic>`.
  Map<String, dynamic> toJson() => _$CreatePatchPlatformMetadataToJson(this);

  /// Returns a copy of this [CreatePatchPlatformMetadata] with the given
  /// fields replaced by the new values.
  CreatePatchPlatformMetadata copyWith({
    bool? hasAssetChanges,
    bool? hasNativeChanges,
    double? linkPercentage,
    Json? linkMetadata,
    Json? buildTraceSummary,
  }) => CreatePatchPlatformMetadata(
    hasAssetChanges: hasAssetChanges ?? this.hasAssetChanges,
    hasNativeChanges: hasNativeChanges ?? this.hasNativeChanges,
    linkPercentage: linkPercentage ?? this.linkPercentage,
    linkMetadata: linkMetadata ?? this.linkMetadata,
    buildTraceSummary: buildTraceSummary ?? this.buildTraceSummary,
  );

  /// Whether asset changes were detected in the patch for this platform.
  ///
  /// Reason: shorebird does not support asset changes in patches, and knowing
  /// that asset changes were detected can help explain unexpected behavior in
  /// a patch.
  final bool hasAssetChanges;

  /// Whether native code changes were detected in the patch for this platform.
  ///
  /// Reason: shorebird does not support native code changes in patches, and
  /// knowing that native code changes were detected can help explain
  /// unexpected behavior in a patch.
  final bool hasNativeChanges;

  /// The percentage of code that was linked in the patch.
  /// Generally, the higher the percentage, the better the patch performance
  /// since more code will be run on the CPU as opposed to the simulator.
  /// Note: link percentage is currently only available for iOS patches.
  final double? linkPercentage;

  /// Metadata from the linker, if available.
  final Json? linkMetadata;

  /// Privacy-safe aggregate timings from the Flutter build, produced by
  /// `BuildTraceSummary.toJson()`. Shape: integer millisecond counters +
  /// small categorical fields; see `BuildTraceSummary` for the schema.
  /// Null when no trace was captured (older Flutter pin, user opted out,
  /// trace file malformed). Stored as [Json] here to avoid this class
  /// having a compile-time dep on `BuildTraceSummary`'s type — the
  /// server consumes the blob as-is.
  ///
  /// Per-platform because each platform runs its own Flutter build.
  final Json? buildTraceSummary;

  @override
  List<Object?> get props => [
    hasAssetChanges,
    hasNativeChanges,
    linkPercentage,
    linkMetadata,
    buildTraceSummary,
  ];
}
