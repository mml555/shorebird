import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A failed S3 request: an unexpected status, or a transport error.
class S3Exception implements Exception {
  S3Exception(this.operation, this.statusCode, this.body);

  /// Short description of the call, such as `PUT patch/1/abc`.
  final String operation;

  /// HTTP status, or 0 when no response arrived.
  final int statusCode;

  /// Response body (the S3 XML error document), truncated.
  final String body;

  @override
  String toString() =>
      'S3Exception: $operation failed ($statusCode)'
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
    HttpClient? httpClient,
    DateTime Function()? clock,
  }) : _http = (httpClient ?? HttpClient())
         ..connectionTimeout = const Duration(seconds: 10),
       _clock = clock ?? DateTime.now;

  /// Base URL of the store, such as `http://seaweedfs:8333`. A path in it is
  /// not supported.
  final Uri endpoint;
  final String region;
  final String accessKey;
  final String secretKey;
  final String bucket;

  /// `true`: `https://host/bucket/key`. `false`: `https://bucket.host/key`.
  final bool pathStyle;

  final HttpClient _http;
  final DateTime Function() _clock;

  void close() => _http.close(force: true);

  /// Whether the bucket exists. Any answer other than 200 or 404 throws.
  Future<bool> bucketExists() async {
    final res = await _send('HEAD', null);
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
  Future<Stream<List<int>>> getObject(
    String key, {
    int? offset,
    int? length,
  }) async {
    final range = offset == null
        ? null
        : 'bytes=$offset-${length == null ? '' : offset + length - 1}';
    final res = await _send(
      'GET',
      key,
      headers: {if (range != null) 'range': range},
    );
    if (res.statusCode == 404) {
      await res.drain<void>();
      throw S3NotFoundException('GET $key');
    }
    if (res.statusCode != 200 && res.statusCode != 206) {
      throw S3Exception('GET $key', res.statusCode, await _readText(res));
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

  Future<String> _readText(HttpClientResponse res) async {
    final bytes = await res.fold<BytesBuilder>(
      BytesBuilder(),
      (b, chunk) => b..add(chunk),
    );
    final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    return text.length > 500 ? text.substring(0, 500) : text;
  }

  Future<HttpClientResponse> _send(
    String method,
    String? key, {
    List<int> body = const [],
    Map<String, String> headers = const {},
  }) async {
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
    final op = '$method ${key ?? 'bucket $bucket'}';
    try {
      final req = await _http.openUrl(method, url);
      // Headers set above the signature are the ones signed, so send exactly
      // those, and let dart:io add only Host, which is part of the signature.
      signed.forEach(req.headers.set);
      req.contentLength = body.length;
      if (body.isNotEmpty) req.add(body);
      return await req.close();
    } on SocketException catch (e) {
      throw S3Exception(op, 0, e.message);
    } on HttpException catch (e) {
      throw S3Exception(op, 0, e.message);
    } on TimeoutException {
      throw S3Exception(op, 0, 'timed out');
    }
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
