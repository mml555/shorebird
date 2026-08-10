import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/release/apple_releaser_mixin.dart';
import 'package:shorebird_cli/src/commands/release/releaser.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/flutter_version_constraints.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform/apple/apple.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/route_b.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/validators/validators.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// {@template ios_releaser}
/// Functions to build and publish an iOS release.
/// {@endtemplate}
class IosReleaser extends Releaser with AppleReleaserMixin {
  /// {@macro ios_releaser}
  IosReleaser({
    required super.argResults,
    required super.flavor,
    required super.target,
  });

  /// Whether to codesign the release.
  bool get codesign => argResults['codesign'] == true;

  @override
  ReleaseType get releaseType => ReleaseType.ios;

  @override
  String get supplementPlatformSubdir => 'ios';

  @override
  String get supplementArtifactArch => 'ios_supplement';

  @override
  String get artifactDisplayName => 'iOS app';

  @override
  List<Validator> get applePlatformValidators => doctor.iosCommandValidators;

  @override
  Future<void> assertArgsAreValid() async {
    assertReleaseVersionFlagNotProvided();

    await assertObfuscationIsSupported();

    final exportOptionsPlistFile = argResults.file(
      CommonArguments.exportOptionsPlistArg.name,
    );
    if (exportOptionsPlistFile != null) {
      try {
        assertValidExportOptionsPlist(exportOptionsPlistFile);
      } on InvalidExportOptionsPlistException catch (error) {
        logger.err(error.message);
        throw ProcessExit(ExitCode.usage.code);
      }
    }
  }

  @override
  Version? get minimumFlutterVersion => minimumSupportedIosFlutterVersion;

  @override
  Future<FileSystemEntity> buildReleaseArtifacts() async {
    if (!codesign) {
      logger
        ..info(
          '''Building for device with codesigning disabled. You will have to manually codesign before deploying to device.''',
        )
        ..warn(
          '''shorebird preview will not work for releases created with "--no-codesign". However, you can still preview your app by signing the generated .xcarchive in Xcode.''',
        )
        ..warn(
          '''
When you distribute the .xcarchive in Xcode, you MUST uncheck "Manage Version and Build Number" in the Distribute App dialog.

If left checked, Xcode will rewrite the build number in the uploaded IPA, so the version that ships to App Store Connect will not match the version Shorebird recorded for this release. Patches will then fail to apply.''',
        );
    }

    // Delete the Shorebird supplement directory if it exists.
    // This is to ensure that we don't accidentally upload stale artifacts
    // when building with older versions of Flutter.
    final shorebirdSupplementDir = artifactManager
        .getIosReleaseSupplementDirectory();
    if (shorebirdSupplementDir?.existsSync() ?? false) {
      shorebirdSupplementDir!.deleteSync(recursive: true);
    }

    final base64PublicKey = await getEncodedPublicKey();

    final buildArgs = [...argResults.forwardedArgs];
    addSplitDebugInfoDefault(buildArgs);
    await addObfuscationMapArgs(buildArgs);
    final wantsPatchableCalls = _addPatchableCallArgs(buildArgs);

    await artifactBuilder.buildIpa(
      codesign: codesign,
      flavor: flavor,
      target: target,
      args: buildArgs,
      base64PublicKey: base64PublicKey,
      ddMaxBytes: ddMaxBytes,
    );

    verifyObfuscationMap();

    final xcarchiveDirectory = artifactManager.getXcarchiveDirectory();
    if (xcarchiveDirectory == null) {
      logger.err('Unable to find .xcarchive directory');
      throw ProcessExit(ExitCode.software.code);
    }

    final appDirectory = artifactManager.getIosAppDirectory(
      xcarchiveDirectory: xcarchiveDirectory,
    );

    if (appDirectory == null) {
      logger.err('Unable to find .app directory');
      throw ProcessExit(ExitCode.software.code);
    }

    if (wantsPatchableCalls) {
      _verifyPatchableRelease(appDirectory);
    }

    // When code signing is requested (the default), `flutter build ipa` is
    // expected to export a signed .ipa. Flutter treats the export step as
    // optional and exits 0 even when it fails (e.g. no signing certificate),
    // so we must verify the .ipa was actually produced. Otherwise we would
    // report a successful release and point the user at an .ipa that does not
    // exist. See https://github.com/shorebirdtech/shorebird/issues/3807.
    if (codesign && artifactManager.getIpa() == null) {
      logger.err(
        '''
Unable to find generated IPA. This usually means that the IPA export step of "flutter build ipa" failed (for example, due to a missing or invalid code signing certificate). Review the build output above for the underlying error.

If you do not need a signed IPA (for example, you will sign the .xcarchive in Xcode), re-run this command with --no-codesign.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    return xcarchiveDirectory;
  }

  /// Ask gen_snapshot for the patchable call form, on engines that can use it.
  ///
  /// Route B redirects a shipped AOT call site to attached bytecode by making
  /// the call dispatch through the callee's `Function`. That is off by default,
  /// so a release built without it CANNOT be patched -- and the failure is
  /// silent in the worst way: the patch installs, validates, resolves its
  /// target and attaches successfully, and the app's behaviour is unchanged,
  /// because AOT emitted a direct call that never reads
  /// `Function.entry_point_`.
  ///
  /// Only added for an engine that actually carries the interpreter. On a stock
  /// engine the flag would cost size (~+4.5% on the reference app) and buy
  /// nothing, since there is no `InterpretCall` for an attached function to
  /// enter through.
  ///
  /// Returns whether the release is expected to come out patchable, which is
  /// what [_verifyPatchableRelease] is then entitled to insist on.
  bool _addPatchableCallArgs(List<String> buildArgs) {
    final engine = File(
      p.join(
        shorebirdEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'ios-release',
        'Flutter.xcframework',
        'ios-arm64',
        'Flutter.framework',
        'Flutter',
      ),
    );
    if (!isRouteBEngine(engine)) return false;

    // Respect an explicit choice. Someone measuring the flag's cost, or
    // deliberately shipping a non-patchable build on a Route B engine, must be
    // able to; we just will not verify what they did not ask for.
    if (buildArgs.any((a) => a.contains('patchable_static_calls'))) {
      return false;
    }

    logger.info(
      '''This engine supports iOS Dart code push, so this release is being built with patchable call sites (~+4.5% app size). Without them a patch would install and change nothing.''',
    );
    buildArgs.add('--extra-gen-snapshot-options=--patchable_static_calls');
    return true;
  }

  /// Refuse to publish a release that cannot actually be patched.
  ///
  /// Passing the flag and the flag taking effect are different claims, and only
  /// the second is observable in the bytes that ship. Checking the built binary
  /// catches a stale artifact cache, an engine that ignored the option, and a
  /// future change to the call form -- none of which any log would report.
  void _verifyPatchableRelease(Directory appDirectory) {
    final appBinary = File(
      p.join(appDirectory.path, 'Frameworks', 'App.framework', 'App'),
    );
    if (!appBinary.existsSync()) {
      logger.warn(
        '''Could not find ${appBinary.path} to verify patchable call sites; this release may not be patchable.''',
      );
      return;
    }

    final result = countPatchableCallSites(appBinary);
    if (result.perMiB >= routeBPatchableSitesPerMiBThreshold) {
      logger.detail(
        '''Verified patchable call sites: ${result.sites} (${result.perMiB.round()}/MiB).''',
      );
      return;
    }

    logger.err(
      '''
This release was built with patchable call sites requested, but the compiled app does not contain them (${result.sites} sites, ${result.perMiB.round()}/MiB).

Publishing it would produce a release that accepts patches and ignores them: a patch would install, report success, and never change what the app does.

This usually means a stale engine artifact cache. Try:
  ${lightCyan.wrap('shorebird cache clean')}''',
    );
    throw ProcessExit(ExitCode.software.code);
  }

  @override
  Future<String> getReleaseVersion({
    required FileSystemEntity releaseArtifactRoot,
  }) async {
    final plistFile = File(p.join(releaseArtifactRoot.path, 'Info.plist'));
    if (!plistFile.existsSync()) {
      logger.err('No Info.plist file found at ${plistFile.path}');
      throw ProcessExit(ExitCode.software.code);
    }

    try {
      return Plist(file: plistFile).versionNumber;
    } on Exception catch (error) {
      logger.err(
        '''Failed to determine release version from ${plistFile.path}: $error''',
      );
      throw ProcessExit(ExitCode.software.code);
    }
  }

  @override
  Future<void> uploadReleaseArtifacts({
    required Release release,
    required String appId,
  }) async {
    final xcarchiveDirectory = artifactManager.getXcarchiveDirectory()!;
    await codePushClientWrapper.createIosReleaseArtifacts(
      appId: appId,
      releaseId: release.id,
      xcarchivePath: xcarchiveDirectory.path,
      runnerPath: artifactManager
          .getIosAppDirectory(xcarchiveDirectory: xcarchiveDirectory)!
          .path,
      isCodesigned: codesign,
      podfileLockHash: shorebirdEnv.iosPodfileLockHash,
    );

    await uploadSupplementArtifact(appId: appId, releaseId: release.id);
  }

  @override
  String get postReleaseInstructions {
    final relativeArchivePath = p.relative(
      artifactManager.getXcarchiveDirectory()!.path,
    );
    if (codesign) {
      const ipaSearchString = 'build/ios/ipa/*.ipa';
      return '''

Your next step is to upload your app to App Store Connect.

To upload to the App Store, do one of the following:
    1. Open ${lightCyan.wrap(relativeArchivePath)} in Xcode and use the "Distribute App" flow.
    2. Drag and drop the ${lightCyan.wrap(ipaSearchString)} bundle into the Apple Transporter macOS app (https://apps.apple.com/us/app/transporter/id1450874784).
    3. Run ${lightCyan.wrap('xcrun altool --upload-app --type ios -f $ipaSearchString --apiKey your_api_key --apiIssuer your_issuer_id')}.
       See "man altool" for details about how to authenticate with the App Store Connect API key.
''';
    } else {
      return '''

Your next step is to submit the archive at ${lightCyan.wrap(relativeArchivePath)} to the App Store using Xcode.

You can open the archive in Xcode by running:
    ${lightCyan.wrap('open $relativeArchivePath')}

${styleBold.wrap('Make sure to uncheck "Manage Version and Build Number" in the Distribute App dialog.')}
If left checked, Xcode will rewrite the build number in the uploaded IPA, so the version that ships will not match the one Shorebird recorded for this release, and patches will fail to apply.
''';
    }
  }
}
