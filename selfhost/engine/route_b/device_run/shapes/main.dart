// Shapes app: one release carrying the code shapes an ordinary Flutter app is
// made of. It drives itself at launch (no taps) and logs `shape:<name>=<value>`
// for every shape, so one launch shows which version of each body ran.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tally/tally.dart';

void log(String shape, Object? value) => debugPrint('shape:$shape=$value');

const kTitle = 'KT1';

final navKey = GlobalKey<NavigatorState>();

enum Level { low, high }

sealed class Result {
  const Result();
}

class Ok extends Result {
  const Ok(this.value);
  final int value;
}

class Err extends Result {
  const Err();
}

abstract class Shape {
  String describe();
}

class Circle extends Shape {
  @override
  String describe() => 'circle1';
}

class Square extends Shape {
  @override
  String describe() => 'square1';
}

extension Stars on int {
  String get stars => '*' * this;
}

class Util {
  static String tag() => 'S1';
}

T firstOr<T>(List<T> xs, T fallback) => xs.isEmpty ? fallback : xs.first;

String levelName(Level l) {
  switch (l) {
    case Level.low:
      return 'lo1';
    case Level.high:
      return 'hi1';
  }
}

String describeResult(Result r) => switch (r) {
  Ok(:final value) => 'ok $value',
  Err() => 'err',
};

String formatStamp(DateTime t) => DateFormat('yyyy-MM-dd').format(t);

Future<String> loadGreeting() async {
  await Future<void>.delayed(const Duration(milliseconds: 200));
  return 'G1';
}

Stream<String> ticker(int n) async* {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    yield 'T$i';
  }
}

Route<void>? routeFor(RouteSettings settings) {
  log('route', 'R1 ${settings.name}');
  switch (settings.name) {
    case '/detail':
      return MaterialPageRoute<void>(
        builder: (_) => const DetailPage(),
        settings: settings,
      );
  }
  return null;
}

void main() => runApp(const ShapesApp());

class ShapesApp extends StatelessWidget {
  const ShapesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navKey,
      onGenerateRoute: routeFor,
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _count = 0;
  String _greeting = '...';
  final List<String> _events = <String>[];

  String get mood => 'M1';

  @override
  void initState() {
    super.initState();
    log('init', 'I1');
    unawaited(_start());
  }

  Future<void> _start() async {
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _increment();
    }
    final greeting = await loadGreeting();
    setState(() => _greeting = greeting);
    log('greeting', greeting);
    await for (final v in ticker(3)) {
      log('stream', v);
    }
    final shapes = <Shape>[Circle(), Square()];
    for (final s in shapes) {
      log('poly', s.describe());
    }
    log('mood', mood);
    log('const', kTitle);
    log('level', levelName(Level.high));
    log('result', describeResult(const Ok(7)));
    log('stars', 3.stars);
    log('static', Util.tag());
    log('generic', firstOr<String>(<String>[], 'F1'));
    log('stamp', formatStamp(DateTime(2026, 11, 15)));
    log('tally', tallyLabel(_count));
    log('events', _events.length);
    log('done', 'START-DONE');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(navKey.currentState!.pushNamed('/detail'));
    });
    // A post-frame callback does not ask for a frame. Without this, the push
    // waits for something else to rebuild: a patch whose loadGreeting
    // finishes at once (t254, `await TickerFuture.complete()`) never opened
    // /detail on Android, though the patch itself was correct.
    WidgetsBinding.instance.scheduleFrame();
  }

  void _increment() {
    setState(() {
      _count += 1;
    });
    log('count', _count);
  }

  @override
  Widget build(BuildContext context) {
    log('home-build', 'H1 $_count');
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('H1 $_count', style: const TextStyle(fontSize: 32)),
            Text(_greeting),
            FutureBuilder<String>(
              future: loadGreeting(),
              builder: (context, snap) {
                log('future-builder', 'FB1 ${snap.data}');
                return Text('FB1 ${snap.data}');
              },
            ),
            const Label(),
          ],
        ),
      ),
    );
  }
}

class Label extends StatelessWidget {
  const Label({super.key});

  @override
  Widget build(BuildContext context) {
    log('label', 'L1');
    return const Text('L1');
  }
}

class DetailPage extends StatelessWidget {
  const DetailPage({super.key});

  @override
  Widget build(BuildContext context) {
    log('detail', 'D1');
    return const Scaffold(
      body: Center(child: Text('D1', style: TextStyle(fontSize: 48))),
    );
  }
}
