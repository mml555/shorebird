import 'package:code_push_server/src/signing.dart';
import 'package:test/test.dart';

void main() {
  group('UrlSigner', () {
    late UrlSigner signer;
    const token = 'artifacts/app/patch/1/aarch64';

    setUp(() {
      signer = UrlSigner('super-secret');
    });

    test('sign then valid round-trips true', () {
      final expiry = DateTime.now().add(const Duration(minutes: 5));
      final signed = signer.sign(token, expiry);
      expect(signer.valid(token, '${signed.exp}', signed.sig), isTrue);
    });

    test('valid is false for a tampered signature', () {
      final expiry = DateTime.now().add(const Duration(minutes: 5));
      final signed = signer.sign(token, expiry);
      final tampered =
          '${signed.sig.substring(0, signed.sig.length - 1)}'
          '${signed.sig.endsWith('0') ? '1' : '0'}';
      expect(signer.valid(token, '${signed.exp}', tampered), isFalse);
    });

    test('valid is false for a tampered token', () {
      final expiry = DateTime.now().add(const Duration(minutes: 5));
      final signed = signer.sign(token, expiry);
      expect(
        signer.valid('$token-tampered', '${signed.exp}', signed.sig),
        isFalse,
      );
    });

    test('valid is false for a tampered exp', () {
      final expiry = DateTime.now().add(const Duration(minutes: 5));
      final signed = signer.sign(token, expiry);
      expect(signer.valid(token, '${signed.exp + 1}', signed.sig), isFalse);
    });

    test('valid is false when signed with a different secret', () {
      final expiry = DateTime.now().add(const Duration(minutes: 5));
      final signed = signer.sign(token, expiry);
      final otherSigner = UrlSigner('a-different-secret');
      expect(otherSigner.valid(token, '${signed.exp}', signed.sig), isFalse);
    });

    test('valid is false when exp is missing', () {
      final expiry = DateTime.now().add(const Duration(minutes: 5));
      final signed = signer.sign(token, expiry);
      expect(signer.valid(token, null, signed.sig), isFalse);
    });

    test('valid is false when sig is missing', () {
      final expiry = DateTime.now().add(const Duration(minutes: 5));
      final signed = signer.sign(token, expiry);
      expect(signer.valid(token, '${signed.exp}', null), isFalse);
    });

    test('valid is false when exp is not a number', () {
      final expiry = DateTime.now().add(const Duration(minutes: 5));
      final signed = signer.sign(token, expiry);
      expect(signer.valid(token, 'not-a-number', signed.sig), isFalse);
    });

    test('valid is false once now is past the expiry', () {
      final expiry = DateTime.now().add(const Duration(minutes: 5));
      final signed = signer.sign(token, expiry);
      final afterExpiry = expiry.add(const Duration(seconds: 1));
      expect(
        signer.valid(token, '${signed.exp}', signed.sig, now: afterExpiry),
        isFalse,
      );
    });

    test('valid is true right at the expiry boundary', () {
      final expiry = DateTime.now().add(const Duration(minutes: 5));
      final signed = signer.sign(token, expiry);
      // nowSec == exp is still valid (only nowSec > exp fails).
      final atExpiry = DateTime.fromMillisecondsSinceEpoch(signed.exp * 1000);
      expect(
        signer.valid(token, '${signed.exp}', signed.sig, now: atExpiry),
        isTrue,
      );
    });
  });
}
