// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: implicit_dynamic_parameter, require_trailing_commas, cast_nullable_to_non_nullable, lines_longer_than_80_chars, strict_raw_type, unnecessary_lambdas

part of 'create_patch_platform_metadata.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

CreatePatchPlatformMetadata _$CreatePatchPlatformMetadataFromJson(
  Map<String, dynamic> json,
) => $checkedCreate(
  'CreatePatchPlatformMetadata',
  json,
  ($checkedConvert) {
    final val = CreatePatchPlatformMetadata(
      hasAssetChanges: $checkedConvert('has_asset_changes', (v) => v as bool),
      hasNativeChanges: $checkedConvert('has_native_changes', (v) => v as bool),
      linkPercentage: $checkedConvert(
        'link_percentage',
        (v) => (v as num?)?.toDouble(),
      ),
      linkMetadata: $checkedConvert(
        'link_metadata',
        (v) => v as Map<String, dynamic>?,
      ),
      buildTraceSummary: $checkedConvert(
        'build_trace_summary',
        (v) => v as Map<String, dynamic>?,
      ),
    );
    return val;
  },
  fieldKeyMap: const {
    'hasAssetChanges': 'has_asset_changes',
    'hasNativeChanges': 'has_native_changes',
    'linkPercentage': 'link_percentage',
    'linkMetadata': 'link_metadata',
    'buildTraceSummary': 'build_trace_summary',
  },
);

Map<String, dynamic> _$CreatePatchPlatformMetadataToJson(
  CreatePatchPlatformMetadata instance,
) => <String, dynamic>{
  'has_asset_changes': instance.hasAssetChanges,
  'has_native_changes': instance.hasNativeChanges,
  'link_percentage': instance.linkPercentage,
  'link_metadata': instance.linkMetadata,
  'build_trace_summary': instance.buildTraceSummary,
};
