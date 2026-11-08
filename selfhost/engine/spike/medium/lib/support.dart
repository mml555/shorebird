// Support library for the Spike A medium program — exists to create
// CROSS-LIBRARY pool-emission effects the single-file killgate target cannot.

enum Severity { debug, info, warning, error }

class LogRecord {
  const LogRecord(this.severity, this.message, this.sequence);
  final Severity severity;
  final String message;
  final int sequence;

  Map<String, Object?> toJson() => {
    'severity': severity.name,
    'message': message,
    'sequence': sequence,
  };
}

abstract class Sink2<T> {
  void add(T value);
  List<T> drain();
}

class BufferedSink<T> implements Sink2<T> {
  final _buffer = <T>[];
  @override
  void add(T value) => _buffer.add(value);
  @override
  List<T> drain() {
    final out = List<T>.of(_buffer);
    _buffer.clear();
    return out;
  }
}

class RingCounter {
  RingCounter(this.modulus);
  final int modulus;
  int _n = 0;
  int next() => _n = (_n + 1) % modulus;
}

const defaultTags = <String>{'alpha', 'beta', 'gamma'};

const anchorRecord = LogRecord(Severity.info, 'anchor', -1);

String describe(LogRecord r) =>
    '[${r.severity.name.toUpperCase()}] #${r.sequence}: ${r.message}';

Future<int> slowLength(String s) async {
  await Future<void>.delayed(Duration.zero);
  return s.length;
}

Iterable<int> fib() sync* {
  var a = 0, b = 1;
  while (true) {
    yield a;
    final t = a + b;
    a = b;
    b = t;
  }
}
