// Route B step 7, frame-time half: measure the tax the patchable call form
// imposes on NORMAL AOT execution.
//
// WHAT IS BEING MEASURED, precisely. Not "how slow is interpreted Dart" -- we
// expect interpreted patched code to be slower, and that cost is paid only by
// the functions a patch actually replaces. The product question is what
// --patchable_static_calls costs the 99% of execution that is never patched,
// because every static call in the program pays it whether or not a patch
// exists.
//
// The A/B is one variable: the same engine, the same app, the same device, the
// same workload, NO patch applied. Only the gen_snapshot flag differs.
// Comparing against the shipping engine instead would mix in
// dart_dynamic_modules, engine and SDK differences, and answer a different
// question.
//
// WHY A WORKLOAD HAD TO BE ADDED. The fixture's own screen is a static column
// of Text: it paints once and then produces no frames, so it cannot measure
// frame time at all. This drives continuous rebuilds of a moderately deep tree
// so the framework's own static calls -- which are what the flag taxes -- are
// exercised thousands of times per second.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Frames discarded before collection starts.
///
/// First frames include shader warmup, image decode, lazy initialisation and
/// the first GC, none of which are the steady-state cost under test. Reporting
/// them would let startup noise dominate a measurement of per-call overhead.
const int kWarmupFrames = 180;

/// Frames collected after warmup.
const int kSampleFrames = 600;

class FrameBench extends StatefulWidget {
  const FrameBench({super.key});

  @override
  State<FrameBench> createState() => FrameBenchState();
}

class FrameBenchState extends State<FrameBench>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final List<FrameTiming> _timings = <FrameTiming>[];
  int _seen = 0;
  String _result = 'warming up…';
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    if (_done) return;
    for (final t in timings) {
      _seen++;
      if (_seen <= kWarmupFrames) continue;
      _timings.add(t);
      if (_timings.length >= kSampleFrames) {
        _done = true;
        _controller.stop();
        SchedulerBinding.instance.removeTimingsCallback(_onTimings);
        _report();
        return;
      }
    }
  }

  void _report() {
    // Microseconds throughout: milliseconds would round away exactly the
    // differences this is trying to detect.
    final build = _timings.map((t) => t.buildDuration.inMicroseconds).toList()
      ..sort();
    final raster = _timings.map((t) => t.rasterDuration.inMicroseconds).toList()
      ..sort();
    final total = _timings.map((t) => t.totalSpan.inMicroseconds).toList()
      ..sort();
    int pct(List<int> xs, double p) => xs[(xs.length * p).clamp(0, xs.length - 1).floor()];

    // 16667us = one 60Hz frame budget. A frame whose total span exceeds it is
    // a dropped/janky frame from the user's point of view.
    final janky = total.where((t) => t > 16667).length;

    final line = <String>[
        'n=${_timings.length}',
        'build p50=${pct(build, 0.50)} p95=${pct(build, 0.95)}',
        'raster p50=${pct(raster, 0.50)} p95=${pct(raster, 0.95)}',
        'total p50=${pct(total, 0.50)} p95=${pct(total, 0.95)}',
        'janky=$janky',
    ].join(' ');
    // Emitted to the device log as well as the screen: the on-screen result can
    // fall below the fold on a small display, and a benchmark you cannot read
    // is not a measurement. This line is also machine-greppable.
    // ignore: avoid_print
    print('FRAMEBENCH $line');
    setState(() => _result = line);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: 160,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (BuildContext context, Widget? _) => _Load(t: _controller.value),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            _result,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}

/// A tree rebuilt every frame, deep enough that the framework's own static
/// calls dominate — which is the code path the flag actually taxes.
class _Load extends StatelessWidget {
  const _Load({required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    const int rows = 12;
    const int cols = 8;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: List<Widget>.generate(rows, (int r) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List<Widget>.generate(cols, (int c) {
            // Real arithmetic per cell so the frame does Dart work rather than
            // only widget allocation.
            final double phase = (t * 2 * math.pi) + (r + c) * 0.3;
            final double v = (math.sin(phase) + 1) / 2;
            return Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.all(1),
              color: Color.lerp(Colors.indigo, Colors.teal, v),
            );
          }),
        );
      }),
    );
  }
}
