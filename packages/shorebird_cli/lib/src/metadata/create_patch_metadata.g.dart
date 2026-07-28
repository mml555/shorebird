// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: implicit_dynamic_parameter, require_trailing_commas, cast_nullable_to_non_nullable, lines_longer_than_80_chars, strict_raw_type, unnecessary_lambdas

part of 'create_patch_metadata.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

CreatePatchMetadata _$CreatePatchMetadataFromJson(Map<String, dynamic> json) =>
    $checkedCreate(
      'CreatePatchMetadata',
      json,
      ($checkedConvert) {
        final val = CreatePatchMetadata(
          platforms: $checkedConvert(
            'platforms',
            (v) => _platformsFromJson(v as Map<String, dynamic>),
          ),
          usedIgnoreAssetChangesFlag: $checkedConvert(
            'used_ignore_asset_changes_flag',
            (v) => v as bool,
          ),
          usedIgnoreNativeChangesFlag: $checkedConvert(
            'used_ignore_native_changes_flag',
            (v) => v as bool,
          ),
          inferredReleaseVersion: $checkedConvert(
            'inferred_release_version',
            (v) => v as bool,
          ),
          environment: $checkedConvert(
            'environment',
            (v) => BuildEnvironmentMetadata.fromJson(v as Map<String, dynamic>),
          ),
          isSigned: $checkedConvert('is_signed', (v) => v as bool),
        );
        return val;
      },
      fieldKeyMap: const {
        'usedIgnoreAssetChangesFlag': 'used_ignore_asset_changes_flag',
        'usedIgnoreNativeChangesFlag': 'used_ignore_native_changes_flag',
        'inferredReleaseVersion': 'inferred_release_version',
        'isSigned': 'is_signed',
      },
    );

Map<String, dynamic> _$CreatePatchMetadataToJson(
  CreatePatchMetadata instance,
) => <String, dynamic>{
  'platforms': _platformsToJson(instance.platforms),
  'used_ignore_asset_changes_flag': instance.usedIgnoreAssetChangesFlag,
  'used_ignore_native_changes_flag': instance.usedIgnoreNativeChangesFlag,
  'inferred_release_version': instance.inferredReleaseVersion,
  'is_signed': instance.isSigned,
  'environment': instance.environment.toJson(),
};
