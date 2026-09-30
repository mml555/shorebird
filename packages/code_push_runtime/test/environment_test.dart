import 'dart:convert';
import 'dart:ffi' show Abi;

import 'package:code_push_runtime/code_push_runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bundle serving a single `shorebird.yaml`, or failing if [yaml] is null.
class _YamlBundle extends CachingAssetBundle {
  _YamlBundle(this.yaml);

  final String? yaml;

  @override
  Future<ByteData> load(String key) async {
    final value = yaml;
    if (value == null || key != ShorebirdEnvironment.asset) {
      throw Exception('missing: $key');
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(value)));
  }
}

void main() {
  group(ShorebirdEnvironment, () {
    Future<ShorebirdEnvironment?> load(String? yaml) =>
        ShorebirdEnvironment.load(bundle: _YamlBundle(yaml));

    test('reads app_id and base_url from the bundled config', () async {
      final env = await load('''
app_id: abc-123
base_url: https://cps.example.com
''');

      expect(env, isNotNull);
      expect(env!.appId, equals('abc-123'));
      expect(env.baseUrl, equals(Uri.parse('https://cps.example.com')));
    });

    test('is null without a base_url', () async {
      // No base_url means the app points at Shorebird's hosted service, which
      // offers neither endpoint this package uses. Staying inert is correct.
      await expectLater(load('app_id: abc-123'), completion(isNull));
    });

    test('is null without an app_id', () async {
      await expectLater(
        load('base_url: https://cps.example.com'),
        completion(isNull),
      );
    });

    test('is null when the asset is absent', () async {
      await expectLater(load(null), completion(isNull));
    });

    test('is null on unparseable yaml', () async {
      await expectLater(load(':\n  - ['), completion(isNull));
    });

    test('is null when base_url has no scheme', () async {
      await expectLater(
        load('app_id: abc\nbase_url: cps.example.com'),
        completion(isNull),
      );
    });
  });

  group(DeviceAbi, () {
    test('maps platform and arch the way the server matches on', () {
      // arch decides which retained symbol file a crash resolves against, so
      // these strings have to line up with the server's symbol matching.
      const cases = {
        Abi.androidArm64: ('android', 'arm64'),
        Abi.androidArm: ('android', 'arm'),
        Abi.androidX64: ('android', 'x64'),
        Abi.iosArm64: ('ios', 'arm64'),
        Abi.macosArm64: ('macos', 'arm64'),
        Abi.linuxX64: ('linux', 'x64'),
        Abi.windowsX64: ('windows', 'x64'),
      };

      for (final MapEntry(key: abi, value: (platform, arch)) in cases.entries) {
        final resolved = DeviceAbi.fromAbi(abi);
        expect(resolved.platform, equals(platform), reason: '$abi');
        expect(resolved.arch, equals(arch), reason: '$abi');
      }
    });

    test('leaves an unrecognized arch null rather than guessing', () {
      // The server skips symbolication on a null arch; a wrong guess would
      // resolve every frame to a wrong address instead.
      expect(DeviceAbi.fromAbi(Abi.androidIA32).arch, isNull);
      expect(DeviceAbi.fromAbi(Abi.androidIA32).platform, equals('android'));
    });

    test('describes the running binary', () {
      expect(DeviceAbi.current().platform, isNotEmpty);
    });
  });
}
