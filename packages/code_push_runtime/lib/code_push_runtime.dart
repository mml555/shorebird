/// App-side runtime for a self-hosted Shorebird control plane: serves the
/// assets attached to the running patch, and reports Dart crashes for
/// server-side symbolication.
library;

export 'src/code_push_runtime.dart' show CodePushRuntime, ReleaseVersionReader;
export 'src/crash_reporter.dart' show CrashReporter;
export 'src/engine_asset_overlay.dart' show EngineAssetOverlay;
export 'src/environment.dart' show DeviceAbi, ShorebirdEnvironment;
export 'src/patch_asset_bundle.dart' show PatchAssetBundle;
export 'src/patch_asset_store.dart' show PatchAssetStore;
