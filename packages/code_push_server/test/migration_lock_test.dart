// cspell:words xact
import 'package:code_push_server/src/db.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:test/test.dart';

/// Records every statement and which transaction ran it. Reports no applied
/// migrations.
class _RecordingDb implements Db {
  _RecordingDb(this.dialect);

  @override
  final Dialect dialect;

  /// One list of statements per transaction, in order.
  final txs = <List<String>>[];

  Future<List<Map<String, Object?>>> _answer(
    String sql,
    Map<String, Object?> params,
  ) async {
    return [];
  }

  @override
  Future<T> tx<T>(Future<T> Function(DbSession s) body) async {
    final log = <String>[];
    txs.add(log);
    return body(_Session(log, _answer));
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    Map<String, Object?> params = const {},
  ]) => _answer(sql, params);

  @override
  Future<bool> ping() async => true;

  @override
  Future<void> close() async {}

  @override
  String truncPeriod(String unit, String tsCol) => throw UnimplementedError();

  @override
  String extractDow(String tsCol) => throw UnimplementedError();

  @override
  String extractHour(String tsCol) => throw UnimplementedError();
}

class _Session implements DbSession {
  _Session(this.log, this.answer);

  final List<String> log;
  final Future<List<Map<String, Object?>>> Function(
    String,
    Map<String, Object?>,
  )
  answer;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    Map<String, Object?> params = const {},
  ]) {
    log.add(sql);
    return answer(sql, params);
  }
}

const _lock = 'SELECT pg_advisory_xact_lock(@k)';

void main() {
  group('migration advisory lock', () {
    test(
      'postgres: every migration transaction takes the lock first',
      () async {
        final db = _RecordingDb(Dialect.postgres);
        await Repository(db).migrate();
        // One tx for schema_migrations plus one per migration.
        expect(db.txs.length, greaterThan(1));
        for (final tx in db.txs) {
          expect(tx.first, _lock);
        }
        // Each migration tx records its version.
        expect(
          db.txs
              .skip(1)
              .every(
                (tx) => tx.any(
                  (q) => q.startsWith('INSERT INTO schema_migrations'),
                ),
              ),
          isTrue,
        );
      },
    );

    test('postgres: a version applied while waiting is not re-run', () async {
      // The pre-lock read says nothing is applied (the other replica was still
      // running); the re-read under the lock says everything is.
      final db = _RecordingDb(Dialect.postgres);
      final racing = _RecordingDbDelegate(db);
      await Repository(racing).migrate();
      for (final tx in db.txs.skip(1)) {
        expect(tx, hasLength(2), reason: 'lock + re-check only: $tx');
        expect(tx.any((q) => q.startsWith('INSERT')), isFalse);
      }
    });

    test('sqlite: no advisory lock is issued', () async {
      final db = _RecordingDb(Dialect.sqlite);
      await Repository(db).migrate();
      expect(db.txs.expand((t) => t), isNot(contains(_lock)));
    });
  });
}

/// Reports an empty `applied` set to the top-level read but answers the
/// in-transaction re-check as if another replica had finished.
class _RecordingDbDelegate implements Db {
  _RecordingDbDelegate(this.inner);

  final _RecordingDb inner;

  @override
  Dialect get dialect => inner.dialect;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    Map<String, Object?> params = const {},
  ]) => inner.query(sql, params);

  @override
  Future<T> tx<T>(Future<T> Function(DbSession s) body) async {
    final log = <String>[];
    inner.txs.add(log);
    return body(
      _Session(log, (sql, params) async {
        if (sql.startsWith('SELECT 1 FROM schema_migrations WHERE')) {
          return [<String, Object?>{}];
        }
        return [];
      }),
    );
  }

  @override
  Future<bool> ping() => inner.ping();

  @override
  Future<void> close() => inner.close();

  @override
  String truncPeriod(String unit, String tsCol) =>
      inner.truncPeriod(unit, tsCol);

  @override
  String extractDow(String tsCol) => inner.extractDow(tsCol);

  @override
  String extractHour(String tsCol) => inner.extractHour(tsCol);
}
