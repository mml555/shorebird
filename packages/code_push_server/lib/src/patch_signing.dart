// cspell:words rsassa spki pubout
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:jose/jose.dart';

/// Managed patch signing: Shorebird-style RSA keys the server generates and
/// signs patch hashes with, for releases built in `managed` signing mode.
///
/// What is signed, confirmed against the updater (`vendor/updater/library/src/
/// cache/signing.rs`, `RSA_PKCS1_2048_8192_SHA256`) and the upstream CLI
/// (`code_signer.dart`, `Signer('SHA-256/RSA')`): RSASSA-PKCS1-v1_5 with
/// SHA-256 over the UTF-8 bytes of the patch's lowercase-hex SHA-256 string
/// (not over the patch file), base64 (standard alphabet) encoded.
class PatchSigner {
  PatchSigner(String secret)
    : _ceks = {currentKeyVersion: _deriveKey(secret, currentKeyVersion)};

  /// The key-encryption-key version written to every new key's JWE protected
  /// header as `kid`. A future rotation adds `v2` to [_ceks] (derived from a
  /// new secret) and keeps `v1` decrypting existing keys, so rotating never
  /// strands a stored key the way replacing the one secret would.
  static const currentKeyVersion = 'v1';

  /// Upstream accepts RSA keys of 2048 to 8192 bits; the smallest is generated
  /// because every device verifies each patch with it.
  static const int keyBits = 2048;

  final Map<String, JsonWebKey> _ceks;

  static JsonWebKey _deriveKey(String secret, String kid) {
    // Domain-separated, so the same secret used elsewhere (URL signing) never
    // yields the same key.
    final k = Hmac(
      sha256,
      utf8.encode(secret),
    ).convert(utf8.encode('code_push_server/patch-signing-key/v1')).bytes;
    return JsonWebKey.fromJson({
      'kty': 'oct',
      'kid': kid,
      'k': base64Url.encode(k),
    });
  }

  /// A freshly generated key pair. [privateKeyEncrypted] is a compact JWE
  /// (`dir` + `A256GCM`) of the private JWK: the only form that is ever
  /// stored. [publicKeyPem] is the `BEGIN PUBLIC KEY` (SPKI) PEM that
  /// `GET /apps/{app}/signing-key` returns and the CLI embeds.
  ({String publicKeyPem, String privateKeyEncrypted}) generate() {
    final key = JsonWebKey.generate('RS256', keyBitLength: keyBits);
    final jwk = key.toJson();
    final pem = publicKeyPemFromJwk(jwk);
    final builder = JsonWebEncryptionBuilder()
      ..stringContent = jsonEncode(jwk)
      ..encryptionAlgorithm = 'A256GCM'
      ..setProtectedHeader('kid', currentKeyVersion)
      ..addRecipient(_ceks[currentKeyVersion]!, algorithm: 'dir');
    return (
      publicKeyPem: pem,
      privateKeyEncrypted: builder.build().toCompactSerialization(),
    );
  }

  Future<JsonWebKey> _decrypt(String privateKeyEncrypted) async {
    final jwe = JsonWebEncryption.fromCompactSerialization(privateKeyEncrypted);
    // A key stored before `kid` existed was wrapped under what is now `v1`.
    final kid = jwe.commonProtectedHeader.keyId ?? currentKeyVersion;
    final cek = _ceks[kid];
    if (cek == null) {
      throw StateError('Signing key is wrapped under unknown key version $kid');
    }
    final payload = await jwe.getPayload(JsonWebKeyStore()..addKey(cek));
    return JsonWebKey.fromJson(
      jsonDecode(payload.stringContent) as Map<String, dynamic>,
    );
  }

  /// Whether [privateKeyEncrypted] decrypts under the configured secret.
  /// Used at boot, so a wrong or missing `PATCH_SIGNING_KEY_SECRET` is caught
  /// before the first patch fails to sign.
  Future<bool> canDecrypt(String privateKeyEncrypted) async {
    try {
      await _decrypt(privateKeyEncrypted);
      return true;
      // Any failure (bad tag, malformed JWE, unknown kid) means unusable.
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      return false;
    }
  }

  /// Signs [hash] (the patch's hex SHA-256 string) and returns the base64
  /// signature the updater verifies.
  Future<String> signHash(String privateKeyEncrypted, String hash) async {
    final key = await _decrypt(privateKeyEncrypted);
    return base64.encode(key.sign(utf8.encode(hash), algorithm: 'RS256'));
  }

  /// Encodes the RSA public half of [jwk] as an SPKI PEM, identical in form to
  /// `openssl rsa -pubout`.
  static String publicKeyPemFromJwk(Map<String, dynamic> jwk) {
    final n = _b64uToUnsigned(jwk['n'] as String);
    final e = _b64uToUnsigned(jwk['e'] as String);
    final rsaPublicKey = _der(0x30, [..._derInteger(n), ..._derInteger(e)]);
    // AlgorithmIdentifier { rsaEncryption (1.2.840.113549.1.1.1), NULL }.
    const algorithm = <int>[
      0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, //
      0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
    ];
    final spki = _der(0x30, [
      ...algorithm,
      ..._der(0x03, [0x00, ...rsaPublicKey]),
    ]);
    final b64 = base64.encode(spki);
    final lines = [
      for (var i = 0; i < b64.length; i += 64)
        b64.substring(i, i + 64 > b64.length ? b64.length : i + 64),
    ];
    return '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n'
        '-----END PUBLIC KEY-----\n';
  }

  static Uint8List _b64uToUnsigned(String s) =>
      Uint8List.fromList(base64Url.decode(base64Url.normalize(s)));

  static List<int> _derLength(int len) {
    if (len < 0x80) return [len];
    final bytes = <int>[];
    for (var v = len; v > 0; v >>= 8) {
      bytes.insert(0, v & 0xff);
    }
    return [0x80 | bytes.length, ...bytes];
  }

  static List<int> _der(int tag, List<int> content) => [
    tag,
    ..._derLength(content.length),
    ...content,
  ];

  /// DER INTEGER from big-endian unsigned [bytes]: leading zeros trimmed, and
  /// one added back when the high bit is set so the value stays positive.
  static List<int> _derInteger(List<int> bytes) {
    var start = 0;
    while (start < bytes.length - 1 && bytes[start] == 0) {
      start++;
    }
    final v = bytes.sublist(start);
    return _der(0x02, [if (v.first & 0x80 != 0) 0x00, ...v]);
  }
}
