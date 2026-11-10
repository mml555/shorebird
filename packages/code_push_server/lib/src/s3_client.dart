import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A failed S3 request: an unexpected status, or a transport error.
class S3Exception implements Exception {
  S3Exception(this.operation, this.statusCode, this.body, {this.attempts = 1});

  /// Short description of the call, such as `PUT patch/1/abc`.
  final String operation;

  /// HTTP status, or 0 when no response arrived.
  final int statusCode;

  /// Response body (the S3 XML error document), truncated.
  final String body;

  /// How many times the call was tried before it failed.
  final int attempts;

  @override
  String toString() =>
      'S3Exception: $operation failed ($statusCode)'
      '${attempts > 1 ? ' after $attempts attempts' : ''}'
      '${body.isEmpty ? '' : ': $body'}';
}

/// The object does not exist (HTTP 404).
class S3NotFoundException extends S3Exception {
  S3NotFoundException(String operation) : super(operation, 404, '');
}

/// A minimal S3 client: exactly the calls [S3ArtifactStore] needs, signed with
/// AWS Signature Version 4 over `dart:io`, with no other dependencies.
///
/// Works against any S3-compatible server (AWS S3, Cloudflare R2, SeaweedFS,
/// Garage, RustFS) by [endpoint], [region] and [pathStyle]. Requests are signed
/// with the real payload hash, so they are accepted over plain HTTP and HTTPS
/// alike.
class S3Client {
  S3Client({
    required this.endpoint,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    required this.bucket,
    this.pathStyle = true,
    this.responseTimeout = const Duration(seconds: 60),
    this.maxAttempts = 4,
    this.retryBaseDelay = const Duration(milliseconds: 200),
    this.retryMaxDelay = const Duration(seconds: 5),
    this.retryDeadline,
    this.onRetry,
    HttpClient? httpClient,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
    Random? random,
  }) : _http = (httpClient ?? HttpClient())
         ..connectionTimeout = const Duration(seconds: 10)
         // dart:io would otherwise ask for gzip and inflate what comes back,
         // which breaks ranged offsets and the size from [statObject].
         ..autoUncompress = false,
       _clock = clock ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed,
       _random = random ?? Random();

  /// Base URL of the store, such as `http://seaweedfs:8333`. A path in it is
  /// not supported.
  final Uri endpoint;
  final String region;
  final String accessKey;
  final String secretKey;
  final String bucket;

  /// `true`: `https://host/bucket/key`. `false`: `https://bucket.host/key`.
  final bool pathStyle;

  /// How long to wait for the response headers after the request is sent. A
  /// store that accepts the connection and then stalls fails the call instead
  /// of hanging it. The body of a response is not covered.
  final Duration responseTimeout;

  /// How many times a call is tried in all (1 turns retries off). Only
  /// transient failures are retried: a connection error, a timeout, HTTP 408,
  /// 429, 500, 502, 503 or 504, and the S3 error codes SlowDown,
  /// RequestTimeout and InternalError. Other 4xx answers fail at once.
  ///
  /// Every request body here is a byte list held in memory, so each attempt
  /// sends it again, with a fresh signature. A response is only retried
  /// before it is handed to the caller: a [getObject] stream that fails midway
  /// has been consumed and is not retried.
  final int maxAttempts;

  /// The wait before the first retry. Each later wait doubles, up to
  /// [retryMaxDelay], and each is a random share of that ("full jitter"). Zero
  /// means no wait.
  final Duration retryBaseDelay;
  final Duration retryMaxDelay;

  /// No new attempt starts once a call has run this long. Null means twice
  /// [responseTimeout], so a store that stalls is tried at most twice, and the
  /// worst case for one call is about the deadline plus one more attempt, not
  /// [maxAttempts] times [responseTimeout].
  final Duration? retryDeadline;

  /// Called with a one-line description before each retry is waited for.
  final void Function(String message)? onRetry;

  final HttpClient _http;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;
  final Random _random;

  void close() => _http.close(force: true);

  /// Whether the bucket exists. Any answer other than 200 or 404 throws.
  ///
  /// Pass `retry: false` for a probe that has its own short deadline, such as
  /// the readiness check.
  Future<bool> bucketExists({bool retry = true}) async {
    final res = await _send('HEAD', null, retry: retry);
    await res.drain<void>();
    if (res.statusCode == 200) return true;
    if (res.statusCode == 404) return false;
    throw S3Exception('HEAD bucket $bucket', res.statusCode, '');
  }

  /// Creates the bucket. One that already exists and is ours is not an error.
  Future<void> createBucket() async {
    // Outside us-east-1, AWS requires the location in the body; the other
    // stores ignore it.
    final body = region == 'us-east-1' || region == 'auto'
        ? Uint8List(0)
        : Uint8List.fromList(
            utf8.encode(
              '<CreateBucketConfiguration '
              'xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
              '<LocationConstraint>$region</LocationConstraint>'
              '</CreateBucketConfiguration>',
            ),
          );
    final res = await _send('PUT', null, body: body);
    final text = await _readText(res);
    if (res.statusCode == 200 || text.contains('BucketAlreadyOwnedByYou')) {
      return;
    }
    // Some stores answer BucketAlreadyExists, not BucketAlreadyOwnedByYou, to
    // the owner, so two servers booting together race on create. It is safe to
    // accept when a HEAD with our own credentials then succeeds: on AWS a
    // bucket owned by someone else answers that HEAD with 403, which still
    // fails. Anything else (a 403 or 5xx from PUT) is not retried this way.
    if (res.statusCode == 409 && text.contains('BucketAlreadyExists')) {
      try {
        if (await bucketExists()) return;
      } on S3Exception {
        // Not ours or unreachable: report the original error below.
      }
    }
    throw S3Exception('PUT bucket $bucket', res.statusCode, text);
  }

  Future<void> putObject(String key, List<int> bytes) async {
    final res = await _send('PUT', key, body: bytes);
    final text = await _readText(res);
    if (res.statusCode != 200) {
      throw S3Exception('PUT $key', res.statusCode, text);
    }
  }

  /// Size in bytes. Throws [S3NotFoundException] when the object is missing.
  Future<int> statObject(String key) async {
    final res = await _send('HEAD', key);
    await res.drain<void>();
    if (res.statusCode == 404) throw S3NotFoundException('HEAD $key');
    if (res.statusCode != 200) {
      throw S3Exception('HEAD $key', res.statusCode, '');
    }
    return res.contentLength < 0 ? 0 : res.contentLength;
  }

  /// The object's bytes, or [length] bytes from [offset] (to the end when
  /// [length] is null). The status is checked before the stream is returned.
  ///
  /// A ranged read must be answered with 206 and a matching `Content-Range`: a
  /// store or proxy that ignores `Range` and sends the whole object with 200
  /// would otherwise be passed on as the slice. A [length] below 1 is an
  /// [ArgumentError] (AWS ignores `bytes=N-(N-1)` and sends everything).
  Future<Stream<List<int>>> getObject(
    String key, {
    int? offset,
    int? length,
  }) async {
    if (length != null && length < 1) {
      throw ArgumentError.value(length, 'length', 'must be at least 1');
    }
    if (offset != null && offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'must not be negative');
    }
    // `bytes=0-` is the whole object: send no Range, and expect a plain 200.
    final ranged = length != null || (offset != null && offset > 0);
    final start = offset ?? 0;
    final range = ranged
        ? 'bytes=$start-${length == null ? '' : start + length - 1}'
        : null;
    final res = await _send(
      'GET',
      key,
      headers: {if (range != null) 'range': range},
      label: 'GET $key ($range)',
    );
    if (res.statusCode == 404) {
      await res.drain<void>();
      throw S3NotFoundException('GET $key');
    }
    final expected = ranged ? 206 : 200;
    if (res.statusCode != expected) {
      final text = await _readText(res);
      throw S3Exception(
        'GET $key ($range)',
        res.statusCode,
        res.statusCode == 200 && ranged
            ? 'the store ignored the Range header'
            : text,
      );
    }
    final contentRange = res.headers.value('content-range');
    if (ranged &&
        contentRange != null &&
        !contentRange.startsWith('bytes $start-')) {
      await res.drain<void>();
      throw S3Exception(
        'GET $key ($range)',
        res.statusCode,
        'unexpected Content-Range: $contentRange',
      );
    }
    return res;
  }

  /// Deletes [key]. Deleting an object that is already gone is not an error.
  Future<void> deleteObject(String key) async {
    final res = await _send('DELETE', key);
    final text = await _readText(res);
    if (res.statusCode != 204 &&
        res.statusCode != 200 &&
        res.statusCode != 404) {
      throw S3Exception('DELETE $key', res.statusCode, text);
    }
  }

  /// Reads a response body (the first 500 characters of it are kept). A cut
  /// or stalled body is an [S3Exception] with status 0, which is retried.
  Future<String> _readText(HttpClientResponse res) async {
    try {
      final bytes = await res
          .fold<BytesBuilder>(BytesBuilder(), (b, chunk) => b..add(chunk))
          .timeout(responseTimeout);
      final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
      return text.length > 500 ? text.substring(0, 500) : text;
    } on SocketException catch (e) {
      throw S3Exception('read response', 0, e.message);
    } on HttpException catch (e) {
      throw S3Exception('read response', 0, e.message);
    } on TimeoutException {
      throw S3Exception('read response', 0, 'timed out reading the body');
    }
  }

  Future<HttpClientResponse> _send(
    String method,
    String? key, {
    List<int> body = const [],
    Map<String, String> headers = const {},
    String? label,
    bool retry = true,
  }) async {
    final op = label ?? '$method ${key ?? 'bucket $bucket'}';
    final attempts = retry ? maxAttempts : 1;
    final deadline = retryDeadline ?? responseTimeout * 2;
    final clock = Stopwatch()..start();
    for (var attempt = 1; ; attempt++) {
      // No new attempt after the last one, or once the deadline has passed.
      final last = attempt >= attempts || clock.elapsed >= deadline;
      try {
        final res = await _sendOnce(op, method, key, body, headers);
        if (_retryableStatus(res.statusCode)) {
          if (last) {
            throw S3Exception(
              op,
              res.statusCode,
              await _readText(res),
              attempts: attempt,
            );
          }
          // Only the status matters. A body that is cut or stalls throws a
          // status 0 S3Exception, which is retried below like the status.
          await _readText(res);
          _noteRetry(op, attempt, 'HTTP ${res.statusCode}');
        } else if (res.statusCode == 400 && method != 'HEAD') {
          // RequestTimeout is a 400: the code is in the body, so read it. Any
          // other 400 is final, and its body has been read, so fail here.
          final text = await _readText(res);
          if (last || !_retryableCode(text)) {
            throw S3Exception(op, 400, text, attempts: attempt);
          }
          _noteRetry(op, attempt, 'HTTP 400 ${text.trim()}');
        } else {
          return res;
        }
      } on S3Exception catch (e) {
        // Transport errors are statusCode 0; an HTTP answer thrown above is
        // final.
        if (e.statusCode != 0) rethrow;
        if (last) {
          throw S3Exception(op, 0, e.body, attempts: attempt);
        }
        _noteRetry(op, attempt, e.body);
      }
      await _sleep(_backoff(attempt));
    }
  }

  void _noteRetry(String op, int attempt, String why) =>
      onRetry?.call('$op failed ($why), retrying (attempt $attempt)');

  Future<HttpClientResponse> _sendOnce(
    String op,
    String method,
    String? key,
    List<int> body,
    Map<String, String> headers,
  ) async {
    final url = objectUrl(key);
    final signed = signRequest(
      method: method,
      url: url,
      headers: headers,
      payload: body,
      now: _clock(),
      accessKey: accessKey,
      secretKey: secretKey,
      region: region,
    );
    HttpClientRequest? req;
    try {
      req = await _http.openUrl(method, url);
      // Headers set above the signature are the ones signed, so send exactly
      // those, and let dart:io add only Host, which is part of the signature.
      signed.forEach(req.headers.set);
      req.contentLength = body.length;
      if (body.isNotEmpty) req.add(body);
      return await req.close().timeout(responseTimeout);
    } on SocketException catch (e) {
      throw S3Exception(op, 0, e.message);
    } on HttpException catch (e) {
      throw S3Exception(op, 0, e.message);
    } on TimeoutException {
      // Cut the connection so a PUT that is still in flight cannot land after
      // the retry, or after a later write of the same key.
      req?.abort();
      throw S3Exception(op, 0, 'timed out');
    }
  }

  static bool _retryableStatus(int status) =>
      status == 408 ||
      status == 429 ||
      status == 500 ||
      status == 502 ||
      status == 503 ||
      status == 504;

  static bool _retryableCode(String body) =>
      body.contains('<Code>SlowDown</Code>') ||
      body.contains('<Code>RequestTimeout</Code>') ||
      body.contains('<Code>InternalError</Code>');

  /// Full jitter: a random wait up to `retryBaseDelay * 2^(attempt - 1)`,
  /// capped at [retryMaxDelay].
  Duration _backoff(int attempt) {
    final ceiling = min(
      retryMaxDelay.inMicroseconds,
      retryBaseDelay.inMicroseconds * (1 << min(attempt - 1, 20)),
    );
    return Duration(microseconds: _random.nextInt(ceiling + 1));
  }

  /// URL of [key] (or of the bucket itself when null).
  Uri objectUrl(String? key) {
    final encodedKey = key == null ? '' : '/${uriEncode(key, slash: false)}';
    // Built from parts: Uri.replace(query: '') would leave a stray `?`.
    final port = endpoint.hasPort ? endpoint.port : null;
    if (pathStyle) {
      return Uri(
        scheme: endpoint.scheme,
        host: endpoint.host,
        port: port,
        path: '/${uriEncode(bucket, slash: false)}$encodedKey',
      );
    }
    return Uri(
      scheme: endpoint.scheme,
      host: '$bucket.${endpoint.host}',
      port: port,
      path: encodedKey.isEmpty ? '/' : encodedKey,
    );
  }
}

/// SigV4 URI encoding: everything but `A-Z a-z 0-9 - _ . ~` is percent-encoded,
/// and `/` too unless [slash] is false (object keys keep their separators).
String uriEncode(String input, {required bool slash}) {
  final out = StringBuffer();
  for (final byte in utf8.encode(input)) {
    final c = byte;
    final unreserved =
        (c >= 0x41 && c <= 0x5a) ||
        (c >= 0x61 && c <= 0x7a) ||
        (c >= 0x30 && c <= 0x39) ||
        c == 0x2d ||
        c == 0x5f ||
        c == 0x2e ||
        c == 0x7e;
    if (unreserved || (c == 0x2f && !slash)) {
      out.writeCharCode(c);
    } else {
      out
        ..write('%')
        ..write(c.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return out.toString();
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> _hmac(List<int> key, String data) =>
    Hmac(sha256, key).convert(utf8.encode(data)).bytes;

/// Returns the headers to send for a SigV4-signed S3 request: [headers] plus
/// `host`, `x-amz-date`, `x-amz-content-sha256` and `authorization`.
///
/// [url]'s path must already be encoded as [uriEncode] does (S3 signs the path
/// as sent, encoded once) and carry no query string.
Map<String, String> signRequest({
  required String method,
  required Uri url,
  required Map<String, String> headers,
  required List<int> payload,
  required DateTime now,
  required String accessKey,
  required String secretKey,
  required String region,
}) {
  final utc = now.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final date =
      '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}'
      '${two(utc.day)}';
  final amzDate =
      '${date}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  final payloadHash = sha256.convert(payload).toString();

  // dart:io writes Host as host[:port] with the port only when it is not the
  // scheme default, which is what S3 expects in the signature.
  final isDefaultPort =
      (url.scheme == 'http' && url.port == 80) ||
      (url.scheme == 'https' && url.port == 443);
  final host = isDefaultPort ? url.host : '${url.host}:${url.port}';

  final all = <String, String>{
    for (final e in headers.entries) e.key.toLowerCase(): e.value.trim(),
    'host': host,
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': amzDate,
  };
  final names = all.keys.toList()..sort();
  final canonicalHeaders = names.map((n) => '$n:${all[n]}\n').join();
  final signedHeaders = names.join(';');
  final canonicalRequest = [
    method,
    url.path.isEmpty ? '/' : url.path,
    '', // no query string
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join('\n');

  final scope = '$date/$region/s3/aws4_request';
  final stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    scope,
    sha256.convert(utf8.encode(canonicalRequest)).toString(),
  ].join('\n');
  var key = _hmac(utf8.encode('AWS4$secretKey'), date);
  key = _hmac(key, region);
  key = _hmac(key, 's3');
  key = _hmac(key, 'aws4_request');
  final signature = _hex(
    Hmac(sha256, key).convert(utf8.encode(stringToSign)).bytes,
  );

  return {
    ...all,
    'authorization':
        'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, '
        'SignedHeaders=$signedHeaders, Signature=$signature',
  };
}
