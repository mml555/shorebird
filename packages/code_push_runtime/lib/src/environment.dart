import 'dart:ffi' show Abi;

import 'package:flutter/services.dart';
import 'package:yaml/yaml.dart';

/// Which app this is, and which control plane it talks to.
///
/// Read from the `shorebird.yaml` that `shorebird init` bundles as an asset, so
/// an app that already talks to a self-hosted control plane needs no second
/// place to configure one. `base_url` is the same value compiled into the
/// updater, which is what makes "the assets for the patch I am running" resolve
/// against the same server that served the patch.
class ShorebirdEnvironment {
  /// Creates an environment describing [appId] and [baseUrl].
  const ShorebirdEnvironment({required this.appId, required this.baseUrl});

  /// The app's Shorebird id.
  final String appId;

  /// The control plane's base URL.
  final Uri baseUrl;

  /// Where `shorebird init` writes the config, relative to the asset root.
  static const asset = 'shorebird.yaml';

  /// Loads the environment from the bundled `shorebird.yaml`, or returns `null`
  /// if it is absent, unparseable, or has no `base_url`.
  ///
  /// A missing `base_url` means the app points at Shorebird's hosted service
  /// rather than a self-hosted control plane. Neither endpoint this package
  /// uses exists there, so returning null — and staying inert — is correct
  /// rather than an error.
  static Future<ShorebirdEnvironment?> load({AssetBundle? bundle}) async {
    final String raw;
    try {
      raw = await (bundle ?? rootBundle).loadString(asset);
    } on Object {
      return null;
    }

    try {
      final yaml = loadYaml(raw);
      if (yaml is! Map) return null;
      final appId = yaml['app_id'];
      final baseUrl = yaml['base_url'];
      if (appId is! String || appId.isEmpty) return null;
      if (baseUrl is! String || baseUrl.isEmpty) return null;
      final uri = Uri.tryParse(baseUrl);
      if (uri == null || !uri.hasScheme) return null;
      return ShorebirdEnvironment(appId: appId, baseUrl: uri);
    } on Object {
      return null;
    }
  }
}

/// The platform and architecture tokens this control plane expects.
///
/// Both are derived from [Abi], which the VM reports for the running binary.
/// That avoids a plugin dependency and, more importantly, is exact: the
/// architecture decides which retained symbol file a crash is resolved
/// against, and getting it wrong resolves every frame to a wrong address.
class DeviceAbi {
  /// Creates a descriptor for [platform] and [arch].
  const DeviceAbi({required this.platform, required this.arch});

  /// Describes the currently running binary.
  factory DeviceAbi.current() => DeviceAbi.fromAbi(Abi.current());

  /// Describes [abi]. Split out from [DeviceAbi.current] so tests can cover
  /// every platform from any host.
  factory DeviceAbi.fromAbi(Abi abi) {
    // Abi.toString() is `<os>_<arch>`, e.g. `android_arm64`, `macos_arm64`.
    final parts = abi.toString().split('_');
    final os = parts.first;
    final arch = parts.length > 1 ? parts.sublist(1).join('_') : null;
    return DeviceAbi(
      // Dart spells Apple desktop `macos`, and Abi already agrees; iOS is
      // `ios`. Mapped explicitly so a future Abi rename is a visible failure
      // rather than a platform string the server silently does not match.
      platform: os,
      arch: switch (arch) {
        'arm64' => 'arm64',
        'arm' => 'arm',
        'x64' => 'x64',
        // Anything else (ia32, riscv…) is left null rather than guessed: the
        // server would rather skip symbolication than resolve wrongly.
        _ => null,
      },
    );
  }

  /// The running platform: `android`, `ios`, `macos`, `windows`, or `linux`.
  final String platform;

  /// The running architecture, spelled the way the control plane's symbol
  /// matching expects (`arm64`, `arm`, `x64`).
  final String? arch;
}
