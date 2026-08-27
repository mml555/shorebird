// Signing Arm A: the Dart -> Rust cryptographic seam.
//
// WHAT WAS MISSING. The existing Dart signing tests sign and verify with Dart,
// and the Rust tests verify hand-generated constants. Neither crosses the
// boundary that matters in production:
//
//   Dart CodeSigner                Rust cache::signing::check_signature
//     sign()          -> b64 sig  ->  b64 decode -> ring RSA_PKCS1_SHA256
//     base64PublicKey -> b64 DER  ->  b64 decode -> UnparsedPublicKey
//
// A key-encoding or signature-format disagreement between those two sides would
// pass every existing test and fail on a device.
//
// THE VERIFIER HERE IS THE PRODUCTION ONE. It is reached through
// `shorebird_test_check_signature` in `library_test_hooks`, which is a thin
// wrapper over `updater::testing_check_signature`, which is a thin passthrough
// to `cache::signing::check_signature`. Nothing is reimplemented, no production
// C symbol was added, and `cache::signing` was widened only to `pub(crate)`.
//
// The command-backed arm shells out to real OpenSSL rather than calling back
// into Dart, so it exercises an actually foreign signer.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/code_signer.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:test/test.dart';

import 'mocks.dart';

// Both named for readability at the lookup and call sites; the lint would
// rather they were inlined, but a bare three-pointer function type reads as
// noise in a lookupFunction call.
// ignore: avoid_private_typedef_functions
typedef _CheckSignatureNative =
    Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _CheckSignature =
    int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

/// Drives the production Rust verifier. Returns true when it ACCEPTS.
bool _rustAccepts(
  _CheckSignature check, {
  required String message,
  required String signature,
  required String base64Der,
}) {
  final m = message.toNativeUtf8();
  final s = signature.toNativeUtf8();
  final k = base64Der.toNativeUtf8();
  try {
    return check(m, s, k) == 0;
  } finally {
    calloc
      ..free(m)
      ..free(s)
      ..free(k);
  }
}

String _sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

/// Runs [body] with the REAL process runner. The logger is mocked only to keep
/// the transcript quiet; nothing about the crypto path is stubbed.
Future<T> _withRealProcess<T>(Future<T> Function() body) => runScoped(
  body,
  values: {
    loggerRef.overrideWith(MockShorebirdLogger.new),
    processRef.overrideWith(ShorebirdProcess.new),
  },
);

void main() {
  group('Dart signer -> Rust verifier', () {
    late Directory tmp;
    late File privateKey;
    late File publicKey;
    late CodeSigner codeSigner;
    late _CheckSignature check;

    /// The message shape production actually signs: a patch hash, which is a
    /// 64-character lowercase SHA-256 hex string.
    late String message;

    setUpAll(() async {
      // Refuse rather than skip when OpenSSL is unavailable: a silently skipped
      // crypto seam test is indistinguishable from a passing one.
      final openssl = await Process.run('openssl', ['version']);
      expect(
        openssl.exitCode,
        0,
        reason: 'openssl is required to generate the test key pair',
      );

      tmp = Directory.systemTemp.createTempSync('rust_seam');
      privateKey = File('${tmp.path}/private.pem');
      publicKey = File('${tmp.path}/public.pem');

      final gen = await Process.run('openssl', [
        'genrsa',
        '-out',
        privateKey.path,
        '2048',
      ]);
      expect(gen.exitCode, 0, reason: 'genrsa failed: ${gen.stderr}');
      final pub = await Process.run('openssl', [
        'rsa',
        '-in',
        privateKey.path,
        '-pubout',
        '-out',
        publicKey.path,
      ]);
      expect(pub.exitCode, 0, reason: 'rsa -pubout failed: ${pub.stderr}');

      codeSigner = CodeSigner();
      message = _sha256Of(utf8.encode('arm-a-patch-payload'));
      expect(message, matches(RegExp(r'^[0-9a-f]{64}$')));

      // Build and load the production verifier through the test-hooks cdylib.
      final workspace = Directory(
        '${Directory.current.parent.parent.path}/vendor/updater',
      );
      expect(
        workspace.existsSync(),
        isTrue,
        reason: 'updater workspace not found at ${workspace.path}',
      );
      final build = await Process.run(
        'cargo',
        const ['build', '-p', 'library_test_hooks'],
        workingDirectory: workspace.path,
      );
      expect(
        build.exitCode,
        0,
        reason: 'cargo build failed: ${build.stderr}',
      );
      final name = Platform.isMacOS
          ? 'libupdater_test_hooks.dylib'
          : 'libupdater_test_hooks.so';
      final artifact = File('${workspace.path}/target/debug/$name');
      expect(artifact.existsSync(), isTrue, reason: 'no ${artifact.path}');
      check = DynamicLibrary.open(artifact.path)
          .lookupFunction<_CheckSignatureNative, _CheckSignature>(
            'shorebird_test_check_signature',
          );
    });

    tearDownAll(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('the full matrix crosses the boundary', () async {
      // ---- file-backed: exactly what --public-key-path / --private-key-path do
      final sigFile = codeSigner.sign(
        message: message,
        privateKeyPemFile: privateKey,
      );
      final derFile = codeSigner.base64PublicKey(publicKey);

      // ---- command-backed: exactly what --public-key-cmd / --sign-cmd do,
      // with real OpenSSL on the other end rather than a callback into Dart.
      final pemFromCmd = await _withRealProcess(
        () => codeSigner.runPublicKeyCmd(
          'openssl rsa -in ${privateKey.path} -pubout',
        ),
      );
      final derCmd = codeSigner.base64PublicKeyFromPem(pemFromCmd);
      final sigCmd = await _withRealProcess(
        () => codeSigner.signWithCmd(
          data: message,
          command:
              'openssl dgst -sha256 -sign ${privateKey.path} '
              '| openssl base64 -A',
        ),
      );

      // ---- identities, printed as hashes; no private material is emitted
      final table = StringBuffer()
        ..writeln('  message                : $message')
        ..writeln(
          '  sha256(public PEM)     : '
          '${_sha256Of(publicKey.readAsBytesSync())}',
        )
        ..writeln(
          '  sha256(DER path)       : ${_sha256Of(base64.decode(derFile))}',
        )
        ..writeln(
          '  sha256(DER cmd)        : ${_sha256Of(base64.decode(derCmd))}',
        )
        ..writeln(
          '  sha256(sig file)       : ${_sha256Of(base64.decode(sigFile))}',
        )
        ..writeln(
          '  sha256(sig cmd)        : ${_sha256Of(base64.decode(sigCmd))}',
        );

      // ---- the two public-key surfaces must agree byte for byte
      expect(
        derFile,
        derCmd,
        reason: 'path- and command-sourced public keys must yield the same DER',
      );

      // ---- RSA PKCS#1 v1.5 SHA-256 is deterministic for a fixed key/message,
      // so an independent OpenSSL signer must produce the identical signature.
      // If this ever fails while both still verify, that is a real finding
      // about the padding or digest path and must be explained, not asserted
      // away.
      expect(
        sigFile,
        sigCmd,
        reason:
            'PKCS#1 v1.5 is deterministic: Dart and OpenSSL signatures must '
            'match for the same key and message',
      );

      // ---- POSITIVE: both paths accepted by the production verifier
      final fileAccepted = _rustAccepts(
        check,
        message: message,
        signature: sigFile,
        base64Der: derFile,
      );
      final cmdAccepted = _rustAccepts(
        check,
        message: message,
        signature: sigCmd,
        base64Der: derCmd,
      );

      // ---- NEGATIVE 1: one flipped byte in the decoded signature.
      final sigBytes = base64.decode(sigFile);
      sigBytes[sigBytes.length ~/ 2] ^= 0x01;
      final mutatedRejected = !_rustAccepts(
        check,
        message: message,
        signature: base64.encode(sigBytes),
        base64Der: derFile,
      );

      // ---- NEGATIVE 2: a valid signature against a DIFFERENT patch hash.
      // Proves the verifier binds to this message, not merely to a
      // well-formed signature.
      final otherMessage = _sha256Of(utf8.encode('a-different-payload'));
      expect(otherMessage, isNot(message));
      final wrongMessageRejected = !_rustAccepts(
        check,
        message: otherMessage,
        signature: sigFile,
        base64Der: derFile,
      );

      table
        ..writeln(
          '  rust: file-backed      : ${fileAccepted ? "ACCEPT" : "REJECT"}',
        )
        ..writeln(
          '  rust: command-backed   : ${cmdAccepted ? "ACCEPT" : "REJECT"}',
        )
        ..writeln(
          '  rust: mutated signature: '
          '${mutatedRejected ? "REJECT" : "ACCEPT"}',
        )
        ..writeln(
          '  rust: wrong message    : '
          '${wrongMessageRejected ? "REJECT" : "ACCEPT"}',
        );
      // Printed on purpose: this table IS the arm's evidence.
      // ignore: avoid_print
      print('ARM A IDENTITIES\n$table');

      expect(fileAccepted, isTrue, reason: 'file-backed signature rejected');
      expect(cmdAccepted, isTrue, reason: 'command-backed signature rejected');
      expect(
        mutatedRejected,
        isTrue,
        reason: 'a mutated signature was ACCEPTED',
      );
      expect(
        wrongMessageRejected,
        isTrue,
        reason: 'a signature for a different message was ACCEPTED',
      );
    });

    test('the production verifier still uses RSA PKCS#1 SHA-256', () {
      // Guards the algorithm itself: Arm A means nothing if the verifier were
      // silently switched to another scheme.
      final signing = File(
        '${Directory.current.parent.parent.path}/vendor/updater/library/src/cache/signing.rs',
      );
      expect(signing.existsSync(), isTrue);
      final source = signing.readAsStringSync();
      expect(source, contains('RSA_PKCS1_2048_8192_SHA256'));
      expect(source, contains('BASE64_STANDARD'));
    });
  });
}
