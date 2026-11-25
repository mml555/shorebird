// SELFHOST TEST INSTRUMENT. Not part of the shipping CLI.
//
// Publishes a deliberately PARTIAL Route B iOS patch, so an iPhone run can show
// the engine's all-or-nothing rollback (engine c9a5421c: when any target fails
// to activate, the targets this launch attached are put back and the log reads
// `rolled back N/N attached targets, main runs the release code`).
//
// It takes the container `shorebird patch` produced, keeps its real target
// first, appends one target whose selector does not exist in the release,
// signs the new bytes the way the CLI does, and publishes the result as a NEW
// patch on the same release. The CLI refuses such a patch before upload, by
// design; this tool is the only way one reaches the server, and it must never
// be wired into the shipping CLI.
//
// Usage: see selfhost/engine/route_b/device_run/README.md ("Forced partial
// patch").
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/code_signer.dart';
import 'package:shorebird_cli/src/route_b_container.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// Why the tool refuses to forge or sign.
class ForgeException implements Exception {
  /// Creates an exception carrying [message].
  ForgeException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => message;
}

/// The acknowledgement flag. The tool refuses to run without it.
const acknowledgeFlag = 'i-know-this-is-a-test-patch';

/// The selector of the appended target when none is given. Clearly fake, and
/// absent from any release.
const defaultBogusSelector = 'selfhost_forged_partial_patch_no_such_selector';

/// Returns [container]'s bytes with one target appended: a copy of the first
/// target's library and payload under [bogusSelector]. The real targets keep
/// their order and the release build id is unchanged.
///
/// Throws [FormatException] if [container] is not a container, and
/// [ForgeException] if it has no target to copy the payload from.
Uint8List forgePartialContainer(
  Uint8List container, {
  String bogusSelector = defaultBogusSelector,
}) {
  final parsed = RouteBContainer.parse(container);
  if (parsed.targets.isEmpty) {
    throw ForgeException('the container has no real target to keep first');
  }
  if (parsed.targets.any((t) => t.selector == bogusSelector)) {
    throw ForgeException(
      'the container already has a target named $bogusSelector; pick another '
      '--bogus-selector so the appended one is the one that fails',
    );
  }
  final real = parsed.targets.first;
  return writeRouteBContainer(
    releaseBuildId: parsed.releaseBuildId,
    targets: [
      ...parsed.targets,
      RouteBPatchTarget(
        library: real.library,
        selector: bogusSelector,
        bytecode: real.bytecode,
      ),
    ],
  );
}

/// The hash the CLI signs for a patch artifact: the lowercase hex sha256 of
/// the container bytes (see `Patcher.signHash` and
/// `IosPatcher._bundleRouteBContainer`).
String containerHash(Uint8List container) =>
    sha256.convert(container).toString();

/// Signs [container] as the CLI does: RSA PKCS#1 v1.5 with SHA-256 over the
/// UTF-8 bytes of the hex hash string (`CodeSigner.sign`, the equivalent of
/// `openssl dgst -sha256 -sign`), base64 encoded. Then checks the signature
/// against [publicKeyPem] before returning it; throws [ForgeException] if it
/// does not verify.
String signAndVerify(
  Uint8List container, {
  required File privateKeyFile,
  required String publicKeyPem,
}) {
  final signer = CodeSigner();
  final hash = containerHash(container);
  final signature = signer.sign(
    message: hash,
    privateKeyPemFile: privateKeyFile,
  );
  final ok = signer.verify(
    message: hash,
    signature: signature,
    publicKeyPem: publicKeyPem,
  );
  if (!ok) {
    throw ForgeException(
      'the signature does not verify against the public key: the private '
      'and public key are not a pair',
    );
  }
  return signature;
}

ArgParser _parser() => ArgParser()
  ..addFlag(
    acknowledgeFlag,
    negatable: false,
    help:
        'Required. Acknowledges this publishes a patch that is meant to fail.',
  )
  ..addOption(
    'container',
    help:
        'The container `shorebird patch` produced, normally '
        '<app>/build/route_b/patch.sbrbptch.',
  )
  ..addOption(
    'bogus-selector',
    defaultsTo: defaultBogusSelector,
    help:
        'Selector of the appended target, which must not exist in the release.',
  )
  ..addOption('private-key', help: "The release's patch private key (PEM).")
  ..addOption('public-key', help: "The release's patch public key (PEM).")
  ..addOption('app-id', help: 'The app id (shorebird.yaml app_id).')
  ..addOption('release-version', help: 'Release version, e.g. 1.0.0+33.')
  ..addOption('channel', defaultsTo: 'stable', help: 'Channel to promote to.')
  ..addOption(
    'patch-tool',
    help:
        'The `patch` diff executable. Default: '
        r'$CLI/bin/cache/artifacts/patch/patch, '
        'else ~/.shorebird/bin/cache/artifacts/patch/patch.',
  )
  ..addOption(
    'podfile-lock-hash',
    help: "Sent with the artifact when given (the CLI sends the app's own).",
  )
  ..addOption(
    'out',
    help:
        'Where --dry-run writes the forged container. Default: '
        '<container>.partial',
  )
  ..addFlag(
    'dry-run',
    negatable: false,
    help: 'Forge, sign and verify, write the file, publish nothing.',
  )
  ..addFlag('help', abbr: 'h', negatable: false);

/// Adds `Authorization: Bearer $SHOREBIRD_TOKEN`, the API-key auth the CLI
/// uses for `SHOREBIRD_TOKEN` (`ApiKeySource`).
class _BearerClient extends http.BaseClient {
  _BearerClient(this._token);
  final String _token;
  final _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer $_token';
    return _inner.send(request);
  }
}

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(64);
}

String _need(ArgResults r, String name) {
  final v = r[name] as String?;
  if (v == null || v.isEmpty) _fail('--$name is required.');
  return v;
}

Future<void> main(List<String> args) async {
  final parser = _parser();
  final ArgResults r;
  try {
    r = parser.parse(args);
  } on FormatException catch (e) {
    _fail('${e.message}\n${parser.usage}');
  }
  stdout.writeln(
    'route_b_forge_partial_patch: SELFHOST TEST INSTRUMENT. It publishes a '
    'patch that is built to fail.',
  );
  if (r['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }
  if (!(r[acknowledgeFlag] as bool)) {
    _fail('refusing to run without --$acknowledgeFlag.\n${parser.usage}');
  }

  final containerPath = _need(r, 'container');
  final privateKey = File(_need(r, 'private-key'));
  final publicKeyFile = File(_need(r, 'public-key'));
  final dryRun = r['dry-run'] as bool;
  final bogus = r['bogus-selector'] as String;
  for (final f in [File(containerPath), privateKey, publicKeyFile]) {
    if (!f.existsSync()) _fail('${f.path} does not exist.');
  }

  final original = File(containerPath).readAsBytesSync();
  final Uint8List forged;
  final String signature;
  try {
    forged = forgePartialContainer(original, bogusSelector: bogus);
    signature = signAndVerify(
      forged,
      privateKeyFile: privateKey,
      publicKeyPem: publicKeyFile.readAsStringSync(),
    );
  } on FormatException catch (e) {
    _fail('${File(containerPath).path}: ${e.message}');
  } on ForgeException catch (e) {
    _fail(e.message);
  }
  final parsed = RouteBContainer.parse(forged);
  final hash = containerHash(forged);
  const bogusMark = '   <- bogus, must fail';

  final out = (r['out'] as String?) ?? '$containerPath.partial';
  File(out).writeAsBytesSync(forged);

  stdout
    ..writeln('container:   $containerPath (${original.length} bytes)')
    ..writeln('forged:      $out (${forged.length} bytes)')
    ..writeln('release id:  ${parsed.releaseBuildId}')
    ..writeln('targets:')
    ..writeln(
      [
        for (var i = 0; i < parsed.targets.length; i++)
          _describe(i, parsed.targets, bogusMark),
      ].join('\n'),
    )
    ..writeln('sha256:      $hash')
    ..writeln('signature:   verified against ${publicKeyFile.path}');

  if (dryRun) {
    stdout.writeln('dry run: nothing published.');
    return;
  }

  final appId = _need(r, 'app-id');
  final version = _need(r, 'release-version');
  final channelName = r['channel'] as String;
  final token = Platform.environment['SHOREBIRD_TOKEN'];
  final hosted = Platform.environment['SHOREBIRD_HOSTED_URL'];
  if (token == null || token.isEmpty || hosted == null || hosted.isEmpty) {
    _fail('set SHOREBIRD_TOKEN and SHOREBIRD_HOSTED_URL (as for the CLI).');
  }
  final patchTool = _patchTool(r['patch-tool'] as String?);
  if (patchTool == null) {
    _fail('no `patch` tool found; pass --patch-tool.');
  }

  stdout
    ..writeln('will publish to $hosted:')
    ..writeln('  app $appId, release $version, channel $channelName')
    ..writeln(
      '  1. create patch  2. create ios/aarch64 artifact (hash, '
      'hash_signature) and upload  3. promote to $channelName',
    );

  final client = CodePushClient(
    httpClient: _BearerClient(token),
    hostedUri: Uri.parse(hosted),
  );
  final tmp = Directory.systemTemp.createTempSync('forge_partial_');
  try {
    final diff = _diffAgainstSyntheticBase(patchTool, out, tmp);
    final id = await publish(
      client,
      appId: appId,
      releaseVersion: version,
      channelName: channelName,
      artifactPath: diff,
      hash: hash,
      hashSignature: signature,
      podfileLockHash: r['podfile-lock-hash'] as String?,
    );
    stdout.writeln('published patch $id and promoted it to $channelName.');
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

String? _patchTool(String? flag) {
  if (flag != null) return flag;
  final cli = Platform.environment['CLI'];
  final home = Platform.environment['HOME'];
  for (final base in [?cli, if (home != null) p.join(home, '.shorebird')]) {
    final f = p.join(base, 'bin', 'cache', 'artifacts', 'patch', 'patch');
    if (File(f).existsSync()) return f;
  }
  return null;
}

/// The artifact is what `IosPatcher._bundleRouteBContainer` uploads: the
/// container diffed against a one-byte zero base, so it inflates to exactly
/// the container on any device.
String _diffAgainstSyntheticBase(String tool, String container, Directory tmp) {
  final base = File(p.join(tmp.path, 'route_b_base'))
    ..writeAsBytesSync(Uint8List(1));
  final diff = p.join(tmp.path, 'diff.patch');
  final result = Process.runSync(tool, [base.path, container, diff]);
  if (result.exitCode != 0) {
    _fail('patch tool failed (${result.exitCode}): ${result.stderr}');
  }
  return diff;
}

/// The thin, untested publish layer: the calls `shorebird patch` makes, in its
/// order. Returns the new patch id.
Future<int> publish(
  CodePushClient client, {
  required String appId,
  required String releaseVersion,
  required String channelName,
  required String artifactPath,
  required String hash,
  required String hashSignature,
  String? podfileLockHash,
}) async {
  final releases = await client.getReleases(appId: appId);
  final release = releases
      .where((e) => e.version == releaseVersion)
      .firstOrNull;
  if (release == null) {
    throw ForgeException('no release $releaseVersion for $appId');
  }
  final channels = await client.getChannels(appId: appId);
  final channel =
      channels.where((c) => c.name == channelName).firstOrNull ??
      await client.createChannel(appId: appId, channel: channelName);

  final patch = await client.createPatch(
    appId: appId,
    releaseId: release.id,
    metadata: {'selfhost_forged_partial_patch': true, 'is_signed': true},
  );
  await client.createPatchArtifact(
    appId: appId,
    patchId: patch.id,
    artifactPath: artifactPath,
    arch: 'aarch64',
    platform: ReleasePlatform.ios,
    hash: hash,
    hashSignature: hashSignature,
    podfileLockHash: podfileLockHash,
  );
  await client.promotePatch(
    appId: appId,
    patchId: patch.id,
    channelId: channel.id,
  );
  return patch.id;
}

String _describe(int i, List<RouteBPatchTarget> targets, String mark) {
  final t = targets[i];
  final suffix = i == targets.length - 1 ? mark : '';
  return '  ${i + 1}. ${t.library} :: ${t.selector}$suffix';
}
