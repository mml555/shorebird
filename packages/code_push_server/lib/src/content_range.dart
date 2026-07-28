/// A parsed `Content-Range` header from a GCS-style resumable upload.
class ContentRange {
  const ContentRange({
    required this.start,
    required this.end,
    required this.total,
    required this.isQuery,
  });

  final int start;
  final int end;
  final int total;

  /// True for a progress query (`bytes */TOTAL`, no chunk payload).
  final bool isQuery;
}

/// An inclusive byte range resolved against a known resource length.
class ByteRange {
  const ByteRange(this.start, this.end);

  /// First byte offset, always within `[0, total)`.
  final int start;

  /// Last byte offset, inclusive, always within `[start, total)`.
  final int end;

  int get length => end - start + 1;
}

/// What a caller should do with a `Range` request header.
enum RangeOutcome {
  /// Serve the whole representation with `200`. RFC 7233 §3.1 requires an
  /// unparseable — or, here, unsupported — `Range` to be *ignored* rather than
  /// rejected, so a caching proxy or CDN that asks for a multi-range still
  /// gets the artifact instead of a hard failure.
  ignore,

  /// Syntactically valid but outside the resource: answer `416` with
  /// `Content-Range: bytes */<total>` (§4.4).
  unsatisfiable,

  /// Serve `206` for [ParsedRange.range].
  partial,
}

/// The result of [parseByteRange]: an [outcome] and, when it is
/// [RangeOutcome.partial], the resolved [range].
class ParsedRange {
  const ParsedRange(this.outcome, [this.range]);

  final RangeOutcome outcome;
  final ByteRange? range;
}

/// Parses a `Range: bytes=…` request header against a resource of [total]
/// bytes, per RFC 7233.
///
/// Any returned range is clamped to the resource, and an inverted one is
/// rejected outright. Without that, `bytes=100-50` yields a negative read
/// length (an unhandled exception, so a 500 with a logged stack) and
/// `bytes=0-99999999999` advertises a `Content-Length` far larger than the
/// body, leaving the client blocked until it times out — both reachable by
/// anyone holding a valid signed download URL.
ParsedRange parseByteRange(String header, int total) {
  const ignore = ParsedRange(RangeOutcome.ignore);
  const unsatisfiable = ParsedRange(RangeOutcome.unsatisfiable);

  if (!header.startsWith('bytes=')) return ignore;
  final spec = header.substring('bytes='.length).trim();
  // A multi-range response needs a multipart/byteranges body, which we don't
  // build; serving the whole resource is the sanctioned alternative.
  if (spec.contains(',')) return ignore;
  final dash = spec.indexOf('-');
  if (dash == -1) return ignore;
  final firstText = spec.substring(0, dash).trim();
  final lastText = spec.substring(dash + 1).trim();

  if (firstText.isEmpty) {
    // Suffix form `bytes=-N`: the final N bytes.
    final n = int.tryParse(lastText);
    if (n == null || n < 0) return ignore;
    // `bytes=-0` asks for nothing, and an empty resource has no last byte.
    if (n == 0 || total <= 0) return unsatisfiable;
    return ParsedRange(
      RangeOutcome.partial,
      ByteRange(n >= total ? 0 : total - n, total - 1),
    );
  }

  final start = int.tryParse(firstText);
  if (start == null || start < 0) return ignore;
  // A start at or past the end is unsatisfiable, not an empty read.
  if (total <= 0 || start >= total) return unsatisfiable;
  if (lastText.isEmpty) {
    return ParsedRange(RangeOutcome.partial, ByteRange(start, total - 1));
  }
  final end = int.tryParse(lastText);
  if (end == null) return ignore;
  // `bytes=100-50` is an *invalid* byte-range-spec (RFC 7233 §2.1: last-byte-pos
  // must not precede first-byte-pos), not an unsatisfiable one — §3.1 says an
  // invalid Range is ignored, i.e. 200 with the full body. 416 would fail the
  // download outright for a client that sent a malformed header, where every
  // other unsupported form here degrades to serving the whole artifact.
  if (end < start) return ignore;
  return ParsedRange(
    RangeOutcome.partial,
    ByteRange(start, end >= total ? total - 1 : end),
  );
}

/// Parses `Content-Range: bytes START-END/TOTAL` or the query form
/// `bytes */TOTAL`. Returns null if absent or malformed.
ContentRange? parseContentRange(String? header) {
  if (header == null || !header.startsWith('bytes ')) return null;
  final spec = header.substring('bytes '.length);
  final slash = spec.indexOf('/');
  if (slash == -1) return null;
  final total = int.tryParse(spec.substring(slash + 1));
  if (total == null) return null;
  final rangePart = spec.substring(0, slash);
  if (rangePart == '*') {
    return ContentRange(start: 0, end: 0, total: total, isQuery: true);
  }
  final dash = rangePart.indexOf('-');
  if (dash == -1) return null;
  final start = int.tryParse(rangePart.substring(0, dash));
  final end = int.tryParse(rangePart.substring(dash + 1));
  if (start == null || end == null) return null;
  return ContentRange(start: start, end: end, total: total, isQuery: false);
}
