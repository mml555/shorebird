import 'dart:convert';
import 'dart:io';

/// Process-wide log format, configured once at startup so every emitter — the
/// request pipeline, migrations, the server lifecycle — agrees. When true, logs
/// are one JSON object per line; otherwise human-readable text.
bool _json = false;

/// Sets the process-wide log format. Call once at startup (before anything
/// logs). Defaults to text until called.
void configureLogging({required bool json}) => _json = json;

/// Whether JSON logging is currently active.
bool get jsonLogging => _json;

void _emit(Map<String, Object?> obj) => stdout.writeln(jsonEncode(obj));

/// A structured info line (server lifecycle, migrations, housekeeping). In text
/// mode [message] is printed verbatim, with any [fields] appended as `k=v`.
void logInfo(String message, [Map<String, Object?> fields = const {}]) {
  if (_json) {
    _emit({'level': 'info', 'msg': message, ...fields});
  } else if (fields.isEmpty) {
    stdout.writeln(message);
  } else {
    final extra = fields.entries.map((e) => '${e.key}=${e.value}').join(' ');
    stdout.writeln('$message $extra');
  }
}

/// A structured error line. The stack trace goes to stderr in both modes.
void logError(String message, Object error, StackTrace st) {
  if (_json) {
    _emit({'level': 'error', 'msg': message, 'error': '$error'});
  } else {
    stdout.writeln('  [error] $message: $error');
  }
  stderr.writeln(st);
}

/// Records + logs completed requests, and owns the metrics rendered at
/// `GET /metrics`.
///
/// Metrics use the Prometheus text exposition format. Labels are kept
/// low-cardinality (method + status class only — never the raw path) so they
/// neither leak app ids nor explode the series count.
class Observability {
  Observability({required bool json}) {
    configureLogging(json: json);
  }

  final Metrics metrics = Metrics();

  /// Records + logs a completed request. Health/metrics probes are recorded but
  /// not logged (they'd otherwise flood the log at the scrape interval).
  void request(String method, String path, int status, int durationMs) {
    metrics.record(method, status, durationMs);
    if (_isProbe(path)) return;
    if (_json) {
      _emit({
        'level': status >= 500 ? 'error' : 'info',
        'msg': 'request',
        'method': method,
        'path': '/$path',
        'status': status,
        'duration_ms': durationMs,
      });
    } else {
      stdout.writeln('$method /$path -> $status (${durationMs}ms)');
    }
  }

  void error(String message, Object err, StackTrace st) =>
      logError(message, err, st);

  /// A structured info line (delegates to the top-level [logInfo]).
  void info(String message, [Map<String, Object?> fields = const {}]) =>
      logInfo(message, fields);

  static bool _isProbe(String path) =>
      path == 'healthz' || path == 'readyz' || path == 'metrics';
}

/// In-memory counters/histogram rendered in the Prometheus text format.
class Metrics {
  Metrics() : _start = DateTime.now();

  final DateTime _start;

  // method|statusClass -> count, e.g. "GET|2xx".
  final Map<String, int> _requests = {};

  // Cumulative-friendly duration histogram (seconds).
  static const List<double> _le = [
    0.005,
    0.01,
    0.025,
    0.05,
    0.1,
    0.25,
    0.5,
    1,
    2.5,
    5,
    10,
  ];
  final List<int> _bucket = List<int>.filled(_le.length, 0);
  int _durationCount = 0;
  double _durationSum = 0;

  int inFlight = 0;

  void record(String method, int status, int durationMs) {
    final key = '$method|${status ~/ 100}xx';
    _requests[key] = (_requests[key] ?? 0) + 1;
    final secs = durationMs / 1000.0;
    _durationSum += secs;
    _durationCount++;
    for (var i = 0; i < _le.length; i++) {
      if (secs <= _le[i]) _bucket[i]++;
    }
  }

  String render() {
    final b = StringBuffer();
    b.writeln('# HELP code_push_uptime_seconds Server uptime in seconds.');
    b.writeln('# TYPE code_push_uptime_seconds gauge');
    b.writeln(
      'code_push_uptime_seconds ${DateTime.now().difference(_start).inSeconds}',
    );
    b.writeln('# HELP code_push_requests_in_flight In-flight HTTP requests.');
    b.writeln('# TYPE code_push_requests_in_flight gauge');
    b.writeln('code_push_requests_in_flight $inFlight');
    b.writeln(
      '# HELP code_push_requests_total HTTP requests by method/status.',
    );
    b.writeln('# TYPE code_push_requests_total counter');
    _requests.forEach((k, v) {
      final p = k.split('|');
      b.writeln(
        'code_push_requests_total{method="${p[0]}",status="${p[1]}"} $v',
      );
    });
    b.writeln('# HELP code_push_request_duration_seconds Request duration.');
    b.writeln('# TYPE code_push_request_duration_seconds histogram');
    for (var i = 0; i < _le.length; i++) {
      b.writeln(
        'code_push_request_duration_seconds_bucket{le="${_le[i]}"} ${_bucket[i]}',
      );
    }
    b.writeln(
      'code_push_request_duration_seconds_bucket{le="+Inf"} $_durationCount',
    );
    b.writeln(
      'code_push_request_duration_seconds_sum ${_durationSum.toStringAsFixed(6)}',
    );
    b.writeln('code_push_request_duration_seconds_count $_durationCount');
    return b.toString();
  }
}
