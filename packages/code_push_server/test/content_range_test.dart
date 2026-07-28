import 'package:code_push_server/src/content_range.dart';
import 'package:test/test.dart';

void main() {
  group('parseContentRange', () {
    test('parses a chunk range', () {
      final r = parseContentRange('bytes 0-4/10')!;
      expect(r.start, 0);
      expect(r.end, 4);
      expect(r.total, 10);
      expect(r.isQuery, isFalse);
    });

    test('parses a non-zero-offset chunk', () {
      final r = parseContentRange('bytes 5-9/10')!;
      expect(r.start, 5);
      expect(r.end, 9);
      expect(r.total, 10);
      expect(r.isQuery, isFalse);
    });

    test('parses the query form (bytes */TOTAL)', () {
      final r = parseContentRange('bytes */10')!;
      expect(r.isQuery, isTrue);
      expect(r.total, 10);
    });

    test('returns null for absent/malformed headers', () {
      expect(parseContentRange(null), isNull);
      expect(parseContentRange(''), isNull);
      expect(parseContentRange('0-4/10'), isNull); // missing "bytes "
      expect(parseContentRange('bytes 0-4'), isNull); // missing /total
      expect(parseContentRange('bytes abc/10'), isNull); // non-numeric range
      expect(parseContentRange('bytes 0-4/xyz'), isNull); // non-numeric total
    });
  });

  group('parseByteRange', () {
    // Every case here is reachable by anyone holding a valid signed download
    // URL — i.e. every device that has been offered a patch.
    (int, int, int) resolved(String header, int total) {
      final p = parseByteRange(header, total);
      expect(p.outcome, RangeOutcome.partial, reason: header);
      final r = p.range!;
      return (r.start, r.end, r.length);
    }

    void expectOutcome(String header, int total, RangeOutcome outcome) =>
        expect(parseByteRange(header, total).outcome, outcome, reason: header);

    test('parses a closed range', () {
      expect(resolved('bytes=2-5', 10), (2, 5, 4));
    });

    test('an open-ended range runs to the last byte', () {
      expect(resolved('bytes=4-', 10), (4, 9, 6));
    });

    test('a suffix range means the LAST n bytes', () {
      // WAS: `bytes=-3` parsed as start 0 / end 3, serving the first four
      // bytes — the opposite of what the client asked for.
      expect(resolved('bytes=-3', 10), (7, 9, 3));
      // A suffix longer than the file is the whole file, not an error.
      expect(resolved('bytes=-99', 10), (0, 9, 10));
    });

    test('an end past the resource is clamped, not echoed back', () {
      // WAS: `Content-Length: 100000000000` with a 3-byte body, so the client
      // blocked waiting for bytes that were never coming.
      expect(resolved('bytes=0-99999999999', 3), (0, 2, 3));
    });

    test('an inverted range is ignored, not a negative read', () {
      // WAS: len = -49 -> File.openRead(100, 51) threw -> 500 + logged stack.
      //
      // Ignored rather than 416: RFC 7233 §2.1 makes last-byte-pos <
      // first-byte-pos an *invalid* byte-range-spec, and §3.1 says an invalid
      // Range is ignored — 200 with the full body. 416 is for a syntactically
      // valid range that falls outside the resource (the next test). Matters
      // because a client that sends a malformed header still gets its
      // artifact, the same way an unsupported multi-range does.
      expectOutcome('bytes=100-50', 200, RangeOutcome.ignore);
    });

    test('a start at or past the end is unsatisfiable', () {
      expectOutcome('bytes=10-12', 10, RangeOutcome.unsatisfiable);
      expectOutcome('bytes=3-', 3, RangeOutcome.unsatisfiable);
    });

    test('an empty resource has no satisfiable range', () {
      expectOutcome('bytes=0-0', 0, RangeOutcome.unsatisfiable);
      expectOutcome('bytes=-1', 0, RangeOutcome.unsatisfiable);
    });

    test('unparseable or unsupported forms are IGNORED, not rejected', () {
      // RFC 7233 §3.1: a Range the server can't parse must be ignored and the
      // full representation served. Answering 416 instead turns a legal
      // multi-range request from a CDN into a hard download failure.
      for (final header in [
        'bytes=abc-def',
        'bytes=',
        'bytes=-',
        'items=0-1',
        'bytes=0-1,4-5', // multi-range: legal, but we serve no multipart body
        // Beyond 64 bits, so int.tryParse gives up rather than wrapping.
        'bytes=0-99999999999999999999999',
        'bytes=99999999999999999999999-',
      ]) {
        expectOutcome(header, 10, RangeOutcome.ignore);
      }
    });

    test('a zero-length suffix is unsatisfiable, not ignored', () {
      // `bytes=-0` parses fine, it just selects nothing.
      expectOutcome('bytes=-0', 10, RangeOutcome.unsatisfiable);
    });
  });
}
