import 'dart:async';
import 'dart:io';

import 'package:code_push_server/src/config.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:sqlite3/sqlite3.dart' as sq;

/// Which SQL engine backs the repository. `sqlite` is the single-container
/// default (embedded, file-backed); `postgres` is the scale/production backend.
enum Dialect { postgres, sqlite }

/// A thing you can run parameterized SQL against — a connection or a
/// transaction. SQL is written in the Postgres flavor with `@name` parameters;
/// the SQLite adapter translates it (see [SqliteDb]).
abstract class DbSession {
  Future<List<Map<String, Object?>>> query(
    String sql, [
    Map<String, Object?> params = const {},
  ]);
}

/// A database connection. Repository/Analytics depend only on this, so the same
/// SQL runs against Postgres or SQLite unchanged.
abstract class Db implements DbSession {
  Dialect get dialect;
  Future<T> tx<T>(Future<T> Function(DbSession s) body);
  Future<bool> ping();
  Future<void> close();

  // ---- Dialect-specific date expressions (for Analytics) ----
  // These build SQL fragments from a unix-epoch column so the same analytics
  // query runs on either backend. [unit] must be pre-validated (hour|day|week).

  /// Truncates epoch column [tsCol] to [unit], as an ISO-8601 UTC string.
  String truncPeriod(String unit, String tsCol);

  /// UTC day-of-week of epoch column [tsCol], 0=Sunday..6=Saturday (int).
  String extractDow(String tsCol);

  /// UTC hour-of-day of epoch column [tsCol], 0..23 (int).
  String extractHour(String tsCol);

  /// Opens the backend selected by [cfg].
  static Future<Db> open(Config cfg) =>
      cfg.dbBackend == 'sqlite' ? SqliteDb.open(cfg) : PgDb.open(cfg);
}

// ---------------------------------------------------------------------------
// Postgres
// ---------------------------------------------------------------------------

class PgDb implements Db {
  PgDb(this._pool);

  static Future<PgDb> open(Config cfg) async {
    final pool = pg.Pool.withEndpoints(
      [
        pg.Endpoint(
          host: cfg.dbHost,
          port: cfg.dbPort,
          database: cfg.dbName,
          username: cfg.dbUser,
          password: cfg.dbPassword,
        ),
      ],
      settings: pg.PoolSettings(
        maxConnectionCount: 8,
        // `Config.validate` rejects anything outside this set at boot, so the
        // default arm is unreachable in practice. It throws rather than
        // falling back to `disable`, which would turn a future typo here into
        // silently unencrypted credentials.
        sslMode: switch (cfg.dbSslMode) {
          'disable' => pg.SslMode.disable,
          'require' => pg.SslMode.require,
          'verify-full' => pg.SslMode.verifyFull,
          _ => throw ArgumentError.value(
            cfg.dbSslMode,
            'DB_SSL_MODE',
            'must be one of ${Config.dbSslModes.join(', ')}',
          ),
        },
      ),
    );
    return PgDb(pool);
  }

  final pg.Pool _pool;

  @override
  Dialect get dialect => Dialect.postgres;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    final r = await _pool.execute(pg.Sql.named(sql), parameters: params);
    return r.map((row) => row.toColumnMap()).toList();
  }

  @override
  Future<T> tx<T>(Future<T> Function(DbSession s) body) =>
      _pool.runTx((s) => body(_PgTx(s)));

  @override
  Future<bool> ping() async {
    try {
      await _pool.execute('SELECT 1');
      return true;
    } on Exception {
      return false;
    }
  }

  @override
  String truncPeriod(String unit, String c) {
    final fmt = unit == 'hour'
        ? 'YYYY-MM-DD"T"HH24":00:00Z"'
        : 'YYYY-MM-DD"T00:00:00Z"';
    return "to_char(date_trunc('$unit', timezone('UTC', to_timestamp($c))), '$fmt')";
  }

  @override
  String extractDow(String c) =>
      "extract(dow from timezone('UTC', to_timestamp($c)))::int";

  @override
  String extractHour(String c) =>
      "extract(hour from timezone('UTC', to_timestamp($c)))::int";

  @override
  Future<void> close() => _pool.close();
}

class _PgTx implements DbSession {
  _PgTx(this._s);
  final pg.TxSession _s;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    final r = await _s.execute(pg.Sql.named(sql), parameters: params);
    return r.map((row) => row.toColumnMap()).toList();
  }
}

// ---------------------------------------------------------------------------
// SQLite (embedded, single-container default)
// ---------------------------------------------------------------------------

/// SQLite adapter. sqlite3 is synchronous; calls are wrapped in Futures so the
/// [Db] surface is identical to Postgres. Incoming SQL is the Postgres flavor;
/// [_translate] rewrites the handful of constructs that differ (types, `now()`,
/// intervals) and converts `@name` params to positional `?`.
///
/// Every access is serialized through [_serialize]. SQLite has a single
/// connection and no nested transactions, but [tx] awaits an async body — so
/// without a lock a second request could interleave into an open transaction,
/// see its `BEGIN` fail, and then `ROLLBACK` the *first* request's work. The
/// lock makes a transaction atomic with respect to every other database call.
class SqliteDb implements Db {
  SqliteDb(this._db);

  static Future<SqliteDb> open(Config cfg) async {
    Directory(cfg.dataDir).createSync(recursive: true);
    final db = sq.sqlite3.open('${cfg.dataDir}/code_push.db');
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA busy_timeout = 5000');
    return SqliteDb(db);
  }

  final sq.Database _db;

  /// Tail of the serialization chain; each queued operation runs after it.
  Future<void> _lock = Future.value();

  @override
  Dialect get dialect => Dialect.sqlite;

  /// Queues [body] behind any in-flight database work. Failures of one queued
  /// operation never block the next.
  Future<T> _serialize<T>(Future<T> Function() body) {
    final done = Completer<T>();
    final previous = _lock;
    _lock = done.future.then<void>((_) {}, onError: (_) {});
    previous.whenComplete(() async {
      try {
        done.complete(await body());
      } on Object catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    Map<String, Object?> params = const {},
  ]) => _serialize(() async => _run(sql, params));

  List<Map<String, Object?>> _run(String sql, Map<String, Object?> params) {
    final ordered = <Object?>[];
    final translated = _translate(sql, params, ordered);
    final stmt = _db.prepare(translated);
    try {
      final rs = stmt.select(ordered.map(_bind).toList());
      return rs.map((row) => Map<String, Object?>.from(row)).toList();
    } finally {
      stmt.dispose();
    }
  }

  @override
  Future<T> tx<T>(Future<T> Function(DbSession s) body) => _serialize(() async {
    // The body runs against an unlocked session: the lock is already held by
    // this transaction, so re-acquiring it per statement would deadlock.
    _db.execute('BEGIN');
    try {
      final r = await body(_SqliteTx(this));
      _db.execute('COMMIT');
      return r;
    } on Object {
      // Only this call's own transaction is open, so this can never discard
      // another request's work. Rollback failures must not mask the original.
      try {
        _db.execute('ROLLBACK');
      } on Object {
        // ignore: the original error below is the one worth reporting.
      }
      rethrow;
    }
  });

  @override
  Future<bool> ping() async {
    try {
      _db.execute('SELECT 1');
      return true;
    } on Object {
      return false;
    }
  }

  @override
  String truncPeriod(String unit, String c) {
    switch (unit) {
      case 'hour':
        return "strftime('%Y-%m-%dT%H:00:00Z', $c, 'unixepoch')";
      case 'week':
        // Monday of the week (matches Postgres date_trunc('week')): the Monday
        // on/before this date = next-Sunday minus 6 days.
        return "strftime('%Y-%m-%dT00:00:00Z', $c, 'unixepoch', 'weekday 0', '-6 days')";
      case 'day':
      default:
        return "strftime('%Y-%m-%dT00:00:00Z', $c, 'unixepoch')";
    }
  }

  @override
  String extractDow(String c) =>
      "cast(strftime('%w', $c, 'unixepoch') as integer)";

  @override
  String extractHour(String c) =>
      "cast(strftime('%H', $c, 'unixepoch') as integer)";

  @override
  Future<void> close() async => _db.dispose();

  // ISO-8601 UTC with millis; used everywhere a timestamp is written, so string
  // comparisons (`expires_at > <now>`) stay chronological.
  static const _tsFmt = "strftime('%Y-%m-%dT%H:%M:%fZ','now')";

  static String _translate(
    String sql,
    Map<String, Object?> params,
    List<Object?> ordered,
  ) {
    var s = sql
        // DDL default: must be wrapped in parens in SQLite.
        .replaceAll('DEFAULT now()', 'DEFAULT ($_tsFmt)')
        // now() ± interval 'N days'  ->  strftime(..., '±N days')
        .replaceAllMapped(
          RegExp(r"now\(\)\s*([-+])\s*interval\s*'(\d+)\s*days?'"),
          (m) => "strftime('%Y-%m-%dT%H:%M:%fZ','now','${m[1]}${m[2]} days')",
        )
        // bare now()
        .replaceAll('now()', _tsFmt)
        // types / boolean literals
        .replaceAll('SERIAL PRIMARY KEY', 'INTEGER PRIMARY KEY AUTOINCREMENT')
        .replaceAll('TIMESTAMPTZ', 'TEXT')
        .replaceAll('BIGINT', 'INTEGER')
        .replaceAll('BOOLEAN', 'INTEGER')
        .replaceAll('DEFAULT true', 'DEFAULT 1')
        .replaceAll('DEFAULT false', 'DEFAULT 0');
    // @name -> positional ?, but NOT inside single-quoted string literals (e.g.
    // the seeded email 'owner@self-host.local' must stay intact).
    return _bindNamed(s, params, ordered);
  }

  static final _paramRe = RegExp(r'@(\w+)');

  static String _bindNamed(
    String sql,
    Map<String, Object?> params,
    List<Object?> ordered,
  ) {
    final out = StringBuffer();
    var i = 0;
    while (i < sql.length) {
      final ch = sql[i];
      if (ch == "'") {
        // Copy a string literal verbatim, honoring '' escapes.
        out.write(ch);
        i++;
        while (i < sql.length) {
          out.write(sql[i]);
          if (sql[i] == "'") {
            if (i + 1 < sql.length && sql[i + 1] == "'") {
              out.write("'");
              i += 2;
              continue;
            }
            i++;
            break;
          }
          i++;
        }
      } else if (ch == '@') {
        final m = _paramRe.matchAsPrefix(sql, i);
        if (m != null) {
          ordered.add(params[m.group(1)]);
          out.write('?');
          i = m.end;
        } else {
          out.write(ch);
          i++;
        }
      } else {
        out.write(ch);
        i++;
      }
    }
    return out.toString();
  }

  static Object? _bind(Object? v) {
    if (v is bool) return v ? 1 : 0;
    if (v is DateTime) return v.toUtc().toIso8601String();
    return v; // int / double / String / Uint8List / null
  }
}

/// Statements issued inside [SqliteDb.tx], which already holds the lock.
class _SqliteTx implements DbSession {
  _SqliteTx(this._db);
  final SqliteDb _db;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async => _db._run(sql, params);
}

/// Coerces a boolean-ish column value across backends: Postgres returns `bool`,
/// SQLite returns `int` (0/1).
bool asDbBool(Object? v) {
  if (v is bool) return v;
  if (v is int) return v != 0;
  final s = v?.toString();
  return s == 'true' || s == '1' || s == 't';
}
