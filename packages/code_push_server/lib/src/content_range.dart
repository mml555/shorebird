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
