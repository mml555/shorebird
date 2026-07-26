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
}
