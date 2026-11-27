// SELFHOST TEST INSTRUMENT. Not part of the shipping CLI.
//
// Publishes a deliberately PARTIAL Route B iOS patch, so an iPhone run can show
// the engine's all-or-nothing rollback (engines from c9a5421c: when any target
// fails to activate, the targets this launch attached are put back and the log
// reads `rolled back N/N attached targets, main runs the release code`).
//
// It takes the container `shorebird patch` produced, keeps its real target
// first, and makes the last target fail: by default it appends one target whose
// selector does not exist in the release; --retarget-last renames the last real
// target to such a selector, so the forged patch has one real target fewer than
// the one built; --reuse-first-payload gives the last real target the first
// target's payload; --bad-format-last changes the bytecode format version of
// the last real target's payload; --unresolve-last renames a library URI the
// last payload references to one no release has. It signs the new bytes the
// way the CLI does and publishes the result as a NEW patch on the same
// release. The CLI refuses such a patch before upload, by design; this tool is
// the only way one reaches the server, and it must never be wired into the
// shipping CLI.
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

/// Required, in addition to `--channel stable`, to promote to `stable`.
const allowStableFlag = 'allow-stable';

/// The library URI `--unresolve-last` renames when none is given: every
/// release has it.
const defaultUnresolveUri = 'dart:core';

/// The selector of the appended target when none is given. Clearly fake, and
/// absent from any release.
const defaultBogusSelector = 'selfhost_forged_partial_patch_no_such_selector';

/// The bytecode format version word written by `--bad-format-last`: no VM
/// reads it (the VM reads 3, `KernelBytecode::kBytecodeFormatVersion`).
const badBytecodeFormatVersion = 0xFFFFFFFF;

/// Replaces [uri] in [payload], a Dart bytecode binary, by a same-length URI
/// that no release has, and returns the new bytes; [payload] is not changed.
///
/// The binary is little-endian (`Reader::ReadUInt32` in
/// `runtime/vm/bytecode_reader.h`): uint32 magic `0x44424333`, uint32 format
/// version, uint32 stringTable.numItems, uint32 stringTable offset, and so on.
/// The string table at that offset is uint32 numOneByteStrings, uint32
/// numTwoByteStrings, one uint32 end offset per string (one-byte strings
/// first), then the contents concatenated without separators; a string
/// starts where the one before it ends. Library URIs are strings of that
/// table, and a bytecode string is named by its index, never by its
/// position, so changing the characters of one entry without changing its
/// length moves nothing.
///
/// Only a string that equals [uri] is changed, which is the only way to be
/// sure no other string changes: a scan of the raw bytes also hits the
/// neighbour that begins with [uri] (`dart:core_patch`), and two entries
/// that meet inside the concatenated contents. The tool refuses if no string
/// equals [uri], if any other string contains [uri], or if the replacement
/// is already a string of the table. The replacement is [uri] with its last
/// character replaced by `_` (`dart:core` becomes `dart:cor_`), or by `~`
/// if that character is already `_`.
///
/// Throws [ForgeException] if [payload] does not start with the bytecode
/// magic or its string table is not readable.
Uint8List unresolveLibraryUri(Uint8List payload, String uri) {
  _requireBytecodeMagic(payload);
  if (uri.isEmpty || uri.codeUnits.any((c) => c > 0x7f)) {
    throw ForgeException('--unresolve-uri must be a non-empty ASCII URI.');
  }
  final bytes = ByteData.sublistView(payload);
  int word(int offset) {
    if (offset < 0 || offset > payload.length - 4) {
      throw ForgeException(
        'the payload ends inside its header or string table: not a bytecode '
        'binary this tool understands.',
      );
    }
    return bytes.getUint32(offset, Endian.little);
  }

  final tableOffset = word(12);
  final oneByte = word(tableOffset);
  final twoByte = word(tableOffset + 4);
  final ends = tableOffset + 8;
  final contents = ends + (oneByte + twoByte) * 4;
  if (oneByte + twoByte > payload.length) {
    throw ForgeException('the payload string table is not readable.');
  }
  // [start, end) of every string, in file offsets.
  final spans = <(int, int)>[];
  var start = contents;
  for (var i = 0; i < oneByte + twoByte; i++) {
    final end = contents + word(ends + i * 4);
    if (end < start || end > payload.length) {
      throw ForgeException('the payload string table is not readable.');
    }
    spans.add((start, end));
    start = end;
  }

  final wanted = uri.codeUnits;
  final last = uri.codeUnitAt(uri.length - 1);
  final replacement = [
    ...wanted.take(wanted.length - 1),
    if (last == 0x5f) 0x7e else 0x5f,
  ];
  bool at(int from, List<int> text) {
    for (var i = 0; i < text.length; i++) {
      if (payload[from + i] != text[i]) return false;
    }
    return true;
  }

  bool contains((int, int) span, List<int> text, {required bool utf16}) {
    final step = utf16 ? 2 : 1;
    final width = text.length * step;
    for (var p = span.$1; p + width <= span.$2; p++) {
      var hit = true;
      for (var i = 0; i < text.length && hit; i++) {
        hit =
            payload[p + i * step] == text[i] &&
            (!utf16 || payload[p + i * step + 1] == 0);
      }
      if (hit) return true;
    }
    return false;
  }

  final exact = <int>[];
  for (var i = 0; i < spans.length; i++) {
    final span = spans[i];
    final isOneByte = i < oneByte;
    if (isOneByte &&
        span.$2 - span.$1 == wanted.length &&
        at(span.$1, wanted)) {
      exact.add(i);
    } else if (contains(span, wanted, utf16: !isOneByte)) {
      final shown = isOneByte
          ? String.fromCharCodes(payload.sublist(span.$1, span.$2))
          : '(a two-byte string)';
      throw ForgeException(
        'the payload has a longer string containing $uri, $shown: replacing '
        '$uri would risk changing a different string. Pick another '
        '--unresolve-uri.',
      );
    }
    if (isOneByte &&
        span.$2 - span.$1 == replacement.length &&
        at(span.$1, replacement)) {
      throw ForgeException(
        'the payload already has the string '
        '${String.fromCharCodes(replacement)}, the replacement for $uri.',
      );
    }
  }
  if (exact.isEmpty) {
    throw ForgeException(
      'the last payload does not reference $uri: no string of its table '
      'equals it. Pick a URI the payload has.',
    );
  }
  final forged = Uint8List.fromList(payload);
  for (final i in exact) {
    forged.setRange(spans[i].$1, spans[i].$2, replacement);
  }
  return forged;
}

void _requireBytecodeMagic(Uint8List payload) {
  if (payload.length < 16 ||
      ByteData.sublistView(payload).getUint32(0, Endian.little) != 0x44424333) {
    throw ForgeException(
      'the last payload does not start with the Dart bytecode magic '
      '(0x44424333, bytes 33 43 42 44): not a bytecode binary, so the tool '
      'will not forge it blind.',
    );
  }
}

/// [payload] with its bytecode format version word (the uint32 after the
/// magic, little-endian, bytes 4 to 7) set to [badBytecodeFormatVersion].
/// Throws [ForgeException] if [payload] does not start with the magic.
Uint8List badFormatPayload(Uint8List payload) {
  _requireBytecodeMagic(payload);
  final forged = Uint8List.fromList(payload);
  ByteData.sublistView(
    forged,
  ).setUint32(4, badBytecodeFormatVersion, Endian.little);
  return forged;
}

/// Returns [container]'s bytes with its last target made to fail: the release
/// build id is unchanged and every target before the failing one keeps its
/// order, library and payload.
///
/// By default one target is appended: a copy of the first target's library
/// and payload under [bogusSelector]. Engines up to 64abe347 crash on that
/// container instead of rolling back: they load the copied payload before
/// looking up the selector, and the payload's library is already loaded.
///
/// With [retargetLast], the container's last target is renamed to
/// [bogusSelector] instead, keeping its own payload, which must differ from
/// every earlier target's (checked). Every engine refuses it as
/// `target-missing` and rolls back the targets before it. It needs a
/// container with at least two targets, and the forged patch has one real
/// target fewer than the one built.
///
/// With [reuseFirstPayload], the container's last target keeps its library
/// and selector, which exist in the release, but carries the first target's
/// payload. Engines from 88a7bf8c on resolve the target, find the payload's
/// library already loaded by the first target, refuse it as
/// `invalid-bytecode` and roll back the targets before it. Engines up to
/// 64abe347 crash on it, as on the default container. It needs a container
/// with at least two targets whose last payload differs from the first.
///
/// With [badFormatLast], the last target keeps its library, selector and
/// payload, except that the payload's bytecode format version word is set to
/// a value no VM reads ([badFormatPayload]). Engines up to 88a7bf8c abort
/// before main (`Unsupported Dart bytecode format version`); the engine that
/// follows refuses it as `invalid-bytecode` (`ROUTEB: payload does not load,
/// refused: REASON`) and rolls back the targets before it. It needs a
/// container with at least two targets whose last payload differs from the
/// first.
///
/// With [unresolveLast], the last target keeps its library and selector, and
/// its payload has every string equal to [unresolveUri] replaced by a
/// same-length URI no release has ([unresolveLibraryUri]); the binary's
/// structure and offsets are unchanged. Engines up to 88a7bf8c abort before
/// main (`Unable to find library ...`); the engine that follows refuses it
/// as `invalid-bytecode` and rolls back the targets before it. Same
/// container requirements as [badFormatLast].
///
/// At most one of [retargetLast], [reuseFirstPayload], [badFormatLast] and
/// [unresolveLast]. Every target before the last is kept byte for byte.
///
/// Throws [FormatException] if [container] is not a container, and
/// [ForgeException] if it has no target to keep first.
Uint8List forgePartialContainer(
  Uint8List container, {
  String bogusSelector = defaultBogusSelector,
  bool retargetLast = false,
  bool reuseFirstPayload = false,
  bool badFormatLast = false,
  bool unresolveLast = false,
  String unresolveUri = defaultUnresolveUri,
}) {
  final parsed = RouteBContainer.parse(container);
  if (parsed.targets.isEmpty) {
    throw ForgeException('the container has no real target to keep first');
  }
  final modes = [
    if (retargetLast) '--retarget-last',
    if (reuseFirstPayload) '--reuse-first-payload',
    if (badFormatLast) '--bad-format-last',
    if (unresolveLast) '--unresolve-last',
  ];
  if (modes.length > 1) {
    throw ForgeException(
      '${modes.join(', ')} each forge the last target; pick one.',
    );
  }
  if (badFormatLast || unresolveLast) {
    final flag = badFormatLast ? '--bad-format-last' : '--unresolve-last';
    if (parsed.targets.length < 2) {
      throw ForgeException(
        '$flag needs a container with at least two targets (this one has '
        '${parsed.targets.length}): the last is made to fail and the ones '
        'before it are what the engine rolls back. Build the patch from two '
        'edits in different functions.',
      );
    }
    final first = parsed.targets.first;
    final last = parsed.targets.last;
    if (last.sha256Hex == first.sha256Hex) {
      throw ForgeException(
        "the last target already carries the first target's payload, so $flag "
        'would also change the first target as the engine sees it. Build the '
        'patch from edits whose payloads differ.',
      );
    }
    return writeRouteBContainer(
      releaseBuildId: parsed.releaseBuildId,
      targets: [
        ...parsed.targets.take(parsed.targets.length - 1),
        RouteBPatchTarget(
          library: last.library,
          selector: last.selector,
          bytecode: badFormatLast
              ? badFormatPayload(last.bytecode)
              : unresolveLibraryUri(last.bytecode, unresolveUri),
        ),
      ],
    );
  }
  if (reuseFirstPayload) {
    if (parsed.targets.length < 2) {
      throw ForgeException(
        '--reuse-first-payload needs a container with at least two targets '
        '(this one has ${parsed.targets.length}): the last is given the '
        "first's payload and the ones before it are what the engine rolls "
        'back. Build the patch from two edits in different functions.',
      );
    }
    final first = parsed.targets.first;
    final last = parsed.targets.last;
    if (last.sha256Hex == first.sha256Hex) {
      throw ForgeException(
        "the last target already carries the first target's payload, so "
        'the forged container would equal the one built. Build the patch '
        'from edits whose payloads differ.',
      );
    }
    return writeRouteBContainer(
      releaseBuildId: parsed.releaseBuildId,
      targets: [
        ...parsed.targets.take(parsed.targets.length - 1),
        RouteBPatchTarget(
          library: last.library,
          selector: last.selector,
          bytecode: first.bytecode,
        ),
      ],
    );
  }
  if (parsed.targets.any((t) => t.selector == bogusSelector)) {
    throw ForgeException(
      'the container already has a target named $bogusSelector; pick another '
      '--bogus-selector so the forged one is the one that fails',
    );
  }
  if (retargetLast) {
    if (parsed.targets.length < 2) {
      throw ForgeException(
        '--retarget-last needs a container with at least two targets (this '
        'one has ${parsed.targets.length}): the last is renamed to fail and '
        'the ones before it are what the engine rolls back. Build the patch '
        'from two edits in different functions.',
      );
    }
    final last = parsed.targets.last;
    final earlier = parsed.targets.take(parsed.targets.length - 1);
    if (earlier.any((t) => t.sha256Hex == last.sha256Hex)) {
      throw ForgeException(
        'the last target carries the same payload as an earlier one, so the '
        'engine would load it twice; engines up to 64abe347 crash on that '
        'instead of rolling back. Build the patch from edits whose payloads '
        'differ.',
      );
    }
    return writeRouteBContainer(
      releaseBuildId: parsed.releaseBuildId,
      targets: [
        ...parsed.targets.take(parsed.targets.length - 1),
        RouteBPatchTarget(
          library: last.library,
          selector: bogusSelector,
          bytecode: last.bytecode,
        ),
      ],
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
    help: 'Selector of the forged target, which must not exist in the release.',
  )
  ..addFlag(
    'retarget-last',
    negatable: false,
    help:
        'Rename the last target to the bogus selector instead of appending a '
        'copy of the first. Needs two or more targets with distinct payloads. '
        'Safe on every engine; required on engines up to 64abe347, which '
        'crash on the appended copy.',
  )
  ..addFlag(
    'reuse-first-payload',
    negatable: false,
    help:
        "Give the last target the first target's payload, keeping its real "
        'selector. Needs two or more targets. Engines from 88a7bf8c on refuse '
        'it as invalid-bytecode (the payload library is already loaded) and '
        'roll back; engines up to 64abe347 crash on it.',
  )
  ..addFlag(
    'bad-format-last',
    negatable: false,
    help:
        "Set the last target's payload bytecode format version to a value no "
        'VM reads, keeping its library, selector and the rest of the payload. '
        'Needs two or more targets with distinct payloads. Engines up to '
        '88a7bf8c abort before main (Unsupported Dart bytecode format '
        'version); later ones refuse it as invalid-bytecode and roll back.',
  )
  ..addFlag(
    'unresolve-last',
    negatable: false,
    help:
        "Replace the library URI --unresolve-uri in the last target's payload "
        'by a same-length URI no release has. Needs two or more targets with '
        'distinct payloads. Engines up to 88a7bf8c abort before main (Unable '
        'to find library); later ones refuse it as invalid-bytecode and roll '
        'back.',
  )
  ..addOption(
    'unresolve-uri',
    defaultsTo: defaultUnresolveUri,
    help:
        'The library URI --unresolve-last renames; its last character becomes '
        "'_' (dart:core becomes dart:cor_). It must equal a string of the "
        'payload and no other string may contain it.',
  )
  ..addOption('private-key', help: "The release's patch private key (PEM).")
  ..addOption('public-key', help: "The release's patch public key (PEM).")
  ..addOption('app-id', help: 'The app id (shorebird.yaml app_id).')
  ..addOption('release-version', help: 'Release version, e.g. 1.0.0+33.')
  ..addOption(
    'channel',
    help: 'Required. An EXISTING channel to promote to; never created.',
  )
  ..addFlag(
    allowStableFlag,
    negatable: false,
    help: 'Required to promote to a channel named stable.',
  )
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
        'Where the forged container is written (always, also when '
        'publishing). Default: <container>.partial',
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

String _need(ArgResults r, String name) {
  final v = r[name] as String?;
  if (v == null || v.isEmpty) throw ForgeException('--$name is required.');
  return v;
}

Future<void> main(List<String> args) async {
  exit(await runForge(args));
}

/// Runs the tool and returns the process exit code. Every failure is a
/// one-line `error:` on [err] and a non-zero code, never a stack trace.
///
/// [clientFactory] builds the code push client from the hosted URL and token;
/// tests pass a fake. [environment] defaults to the process environment.
Future<int> runForge(
  List<String> args, {
  CodePushClient Function(Uri hosted, String token)? clientFactory,
  Map<String, String>? environment,
  StringSink? out,
  StringSink? err,
}) async {
  final o = out ?? stdout;
  final e = err ?? stderr;
  final env = environment ?? Platform.environment;
  final parser = _parser();
  try {
    final r = parser.parse(args);
    o.writeln(
      'route_b_forge_partial_patch: SELFHOST TEST INSTRUMENT. It publishes a '
      'patch that is built to fail.',
    );
    if (r['help'] as bool) {
      o.writeln(parser.usage);
      return 0;
    }
    if (!(r[acknowledgeFlag] as bool)) {
      throw ForgeException(
        'refusing to run without --$acknowledgeFlag.\n${parser.usage}',
      );
    }
    await _run(r, o, env, clientFactory);
    return 0;
  } on FormatException catch (x) {
    e.writeln('error: ${x.message}');
  } on ForgeException catch (x) {
    e.writeln('error: ${x.message}');
  } on CodePushException catch (x) {
    e.writeln('error: the server refused: ${x.message}');
  } on IOException catch (x) {
    e.writeln('error: $x');
  }
  return 64;
}

Future<void> _run(
  ArgResults r,
  StringSink o,
  Map<String, String> env,
  CodePushClient Function(Uri hosted, String token)? clientFactory,
) async {
  final containerPath = _need(r, 'container');
  final privateKey = File(_need(r, 'private-key'));
  final publicKeyFile = File(_need(r, 'public-key'));
  final channelName = _need(r, 'channel');
  final dryRun = r['dry-run'] as bool;
  if (channelName == 'stable' && !(r[allowStableFlag] as bool)) {
    throw ForgeException(
      'refusing to promote a patch built to fail to stable without '
      '--$allowStableFlag.',
    );
  }
  for (final f in [File(containerPath), privateKey, publicKeyFile]) {
    if (!f.existsSync()) throw ForgeException('${f.path} does not exist.');
  }

  for (final keeps in [
    'reuse-first-payload',
    'bad-format-last',
    'unresolve-last',
  ]) {
    if ((r[keeps] as bool) && r.wasParsed('bogus-selector')) {
      throw ForgeException(
        '--bogus-selector has no effect with --$keeps, which keeps the last '
        "target's real selector; drop one.",
      );
    }
  }
  if (r.wasParsed('unresolve-uri') && !(r['unresolve-last'] as bool)) {
    throw ForgeException('--unresolve-uri only applies with --unresolve-last.');
  }
  final original = File(containerPath).readAsBytesSync();
  final forged = forgePartialContainer(
    original,
    bogusSelector: r['bogus-selector'] as String,
    retargetLast: r['retarget-last'] as bool,
    reuseFirstPayload: r['reuse-first-payload'] as bool,
    badFormatLast: r['bad-format-last'] as bool,
    unresolveLast: r['unresolve-last'] as bool,
    unresolveUri: r['unresolve-uri'] as String,
  );
  final signature = signAndVerify(
    forged,
    privateKeyFile: privateKey,
    publicKeyPem: publicKeyFile.readAsStringSync(),
  );
  final parsed = RouteBContainer.parse(forged);
  final hash = containerHash(forged);
  final out = (r['out'] as String?) ?? '$containerPath.partial';
  File(out).writeAsBytesSync(forged);

  o
    ..writeln('container:   $containerPath (${original.length} bytes)')
    ..writeln('forged:      $out (${forged.length} bytes)')
    ..writeln('release id:  ${parsed.releaseBuildId}')
    ..writeln('targets:');
  for (var i = 0; i < parsed.targets.length; i++) {
    final t = parsed.targets[i];
    final mark = i != parsed.targets.length - 1
        ? ''
        : r['reuse-first-payload'] as bool
        ? "   <- carries target 1's payload, must fail"
        : r['bad-format-last'] as bool
        ? '   <- payload format version forged, must fail'
        : r['unresolve-last'] as bool
        ? '   <- payload library ${r['unresolve-uri']} renamed, must fail'
        : '   <- bogus, must fail';
    o.writeln('  ${i + 1}. ${t.library} :: ${t.selector}$mark');
  }
  o
    ..writeln('sha256:      $hash')
    ..writeln('signature:   verified against ${publicKeyFile.path}');

  if (dryRun) {
    o.writeln('dry run: nothing published.');
    return;
  }

  final appId = _need(r, 'app-id');
  final version = _need(r, 'release-version');
  final token = env['SHOREBIRD_TOKEN'];
  final hosted = env['SHOREBIRD_HOSTED_URL'];
  if (token == null || token.isEmpty || hosted == null || hosted.isEmpty) {
    throw ForgeException(
      'set SHOREBIRD_TOKEN and SHOREBIRD_HOSTED_URL (as for the CLI).',
    );
  }
  final patchTool = _patchTool(r['patch-tool'] as String?, env);
  if (patchTool == null) {
    throw ForgeException('no `patch` tool found; pass --patch-tool.');
  }

  o
    ..writeln('will publish to $hosted:')
    ..writeln(
      '  app $appId, release version $version, channel $channelName '
      '(must already exist)',
    )
    ..writeln(
      '  The server does not record a release build id, so CHECK THAT '
      '${parsed.releaseBuildId} is the build id of release $version: '
      'the tool cannot.',
    )
    ..writeln(
      '  1. create patch  2. create ios/aarch64 artifact (hash, '
      'hash_signature) and upload  3. promote to $channelName',
    );

  final hostedUri = Uri.parse(hosted);
  final client =
      clientFactory?.call(hostedUri, token) ??
      CodePushClient(httpClient: _BearerClient(token), hostedUri: hostedUri);
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
    o.writeln('published patch $id and promoted it to $channelName.');
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

String? _patchTool(String? flag, Map<String, String> env) {
  if (flag != null) return flag;
  final cli = env['CLI'];
  final home = env['HOME'];
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
    throw ForgeException(
      'patch tool failed (${result.exitCode}): ${result.stderr}',
    );
  }
  return diff;
}

/// The calls `shorebird patch` makes, in its order. Returns the new patch id.
/// The channel must already exist: it is never created. The patch metadata is
/// a two-key stub (the CLI sends platforms and environment too); the server
/// accepts any map and the updater ignores it.
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
  final channel = channels.where((c) => c.name == channelName).firstOrNull;
  if (channel == null) {
    throw ForgeException(
      'app $appId has no channel $channelName (this tool never creates one)',
    );
  }

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
