import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Signs and validates short-lived download URLs with an HMAC-SHA256 over
/// `"<token>.<exp>"`. The signature makes a `download_url` tamper-proof and
/// time-bounded without the object store needing to be device-reachable.
class UrlSigner {
  UrlSigner(this._secret);

  final String _secret;

  String _hmac(String msg) =>
      Hmac(sha256, utf8.encode(_secret)).convert(utf8.encode(msg)).toString();

  /// Returns the `exp` (unix seconds) and `sig` for [token] valid until [expiry].
  ({int exp, String sig}) sign(String token, DateTime expiry) {
    final exp = expiry.millisecondsSinceEpoch ~/ 1000;
    return (exp: exp, sig: _hmac('$token.$exp'));
  }

  /// Validates a signed URL's [exp]/[sig] for [token]. [now] is injectable for
  /// tests. Constant-time signature comparison.
  bool valid(String token, String? exp, String? sig, {DateTime? now}) {
    if (exp == null || sig == null) return false;
    final e = int.tryParse(exp);
    if (e == null) return false;
    final nowSec = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    if (nowSec > e) return false;
    return _constTimeEq(sig, _hmac('$token.$exp'));
  }

  static bool _constTimeEq(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
