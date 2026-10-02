// Spike A medium program: async + collections + consts + closures + generics
// + enums across two libraries, so pool emission order has real material to
// shuffle. Deltas are applied by the driver via marked lines.
import 'dart:convert';

import 'package:spike_medium/support.dart';

class Pipeline {
  Pipeline(this.name) : _sink = BufferedSink<LogRecord>();
  final String name;
  final BufferedSink<LogRecord> _sink;
  final _counter = RingCounter(97);

  void log(Severity s, String message) {
    _sink.add(LogRecord(s, message, _counter.next()));
  }

  List<String> flush() => _sink.drain().map(describe).toList();
}

@pragma('vm:never-inline')
String stamp(String base) => 'stamp:$base'; // P1-EDIT

Map<String, Object?> summarize(List<LogRecord> records) {
  final bySeverity = <Severity, int>{};
  for (final r in records) {
    bySeverity[r.severity] = (bySeverity[r.severity] ?? 0) + 1;
  }
  return {
    'total': records.length,
    'severities': {
      for (final e in bySeverity.entries) e.key.name: e.value,
    },
    'tags': defaultTags.toList()..sort(),
    'anchor': anchorRecord.toJson(),
  };
}

Future<void> main() async {
  final p = Pipeline('main');
  final records = <LogRecord>[];
  final closures = <String Function()>[];

  for (final (i, f) in fib().take(20).indexed) {
    final sev = Severity.values[i % Severity.values.length];
    p.log(sev, 'fib[$i]=$f');
    records.add(LogRecord(sev, 'fib[$i]=$f', i));
    closures.add(() => '${sev.name}:$f');
  }

  final lengths = await Future.wait([
    for (final tag in defaultTags) slowLength(tag),
  ]);

  final flushed = p.flush();
  final summary = summarize(records);
  final rendered = closures.map((c) => c()).join(',');

  print(stamp(name));
  print('flushed=${flushed.length} lengths=$lengths');
  print(jsonEncode(summary));
  print('closures: $rendered');
  // P2-CALLSITE
}

String get name => 'medium-program';
