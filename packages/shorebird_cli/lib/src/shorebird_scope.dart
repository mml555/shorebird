// The dependency scope every `shorebird` invocation runs inside.
//
// Extracted from `bin/shorebird.dart` so a test can prove the set is COMPLETE
// rather than merely present. A ref that is created but never registered here
// throws only when something first reads it, which for a rarely-taken branch
// means on a user's machine: the Route B refs were injected by every one of
// their unit tests and by nothing else, and `read` threw the first time a real
// iOS release reached the import-kernel step — after the build had already run.
//
// Tests inject their own doubles and therefore cannot notice the omission. This
// file is what makes the omission testable.
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/abi.dart';
import 'package:shorebird_cli/src/android_sdk.dart';
import 'package:shorebird_cli/src/android_studio.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_builder/build_trace_session.dart';
import 'package:shorebird_cli/src/artifact_builder/shorebird_tracer.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/auth/auth.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/checksum_checker.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/code_signer.dart';
import 'package:shorebird_cli/src/dart_sdk_compatibility.dart';
import 'package:shorebird_cli/src/dd_support.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/engine_config.dart';
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/gen_snapshot_probe.dart';
import 'package:shorebird_cli/src/http_client/http_client.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/network_checker.dart';
import 'package:shorebird_cli/src/os/os.dart';
import 'package:shorebird_cli/src/patch_diff_checker.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/pubspec_editor.dart';
import 'package:shorebird_cli/src/route_b_compiler_cache.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:shorebird_cli/src/route_b_release_kernels.dart';
import 'package:shorebird_cli/src/shorebird_android_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/shorebird_version.dart';
import 'package:shorebird_cli/src/toolchain_coherence.dart';

/// Every ref `shorebird` registers, with [commandStartedAt] fixing the build
/// trace's start.
Set<ScopedRef<dynamic>> shorebirdScope({
  required DateTime commandStartedAt,
}) => {
  abiRef,
  adbRef,
  androidSdkRef,
  androidStudioRef,
  aotToolsRef,
  appleRef,
  artifactBuilderRef,
  artifactManagerRef,
  buildTraceSessionRef.overrideWith(
    () => BuildTraceSession(commandStartedAt: commandStartedAt),
  ),
  authRef,
  bundletoolRef,
  cacheRef,
  checksumCheckerRef,
  codePushClientWrapperRef,
  codeSignerRef,
  dartSdkCompatibilityRef,
  ddSupportRef,
  devicectlRef,
  diffRef,
  dittoRef,
  doctorRef,
  engineConfigRef,
  // Read by the obfuscated-PATCH path (patch_command.dart), which no unit
  // test can catch: tests inject every ref they use, so an unregistered
  // ref only throws on a real obfuscated patch. It did, on 2026-08-26.
  genSnapshotProbeRef,
  gitRef,
  gradlewRef,
  httpClientRef,
  idevicesyslogRef,
  iosDeployRef,
  javaRef,
  linuxRef,
  loggerRef,
  networkCheckerRef,
  openRef,
  osInterfaceRef,
  patchExecutableRef,
  patchDiffCheckerRef,
  platformRef,
  powershellRef,
  processRef,
  pubspecEditorRef,
  // Route B (selfhost). Registered here or `read` throws at the moment
  // a Route B release or patch needs them — which unit tests cannot
  // catch, because they inject every ref they use.
  routeBCompilerResolverRef,
  routeBCoverageAnalyzerRef,
  routeBProducerRef,
  routeBReleaseKernelBuilderRef,
  shorebirdAndroidArtifactsRef,
  shorebirdArtifactsRef,
  shorebirdEnvRef,
  shorebirdFlutterRef,
  shorebirdTracerRef,
  shorebirdToolsRef,
  shorebirdValidatorRef,
  toolchainCoherenceRef,
  shorebirdVersionRef,
  windowsRef,
  xcodeBuildRef,
};
