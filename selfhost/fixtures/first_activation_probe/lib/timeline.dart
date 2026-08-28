import 'dart:io';

/// An append-only, immediately-flushed durable timeline for ONE process.
///
/// WHY THIS EXISTS. Three app disappearances have been observed, all on the
/// first launch that activates a newly installed patch, and not one produced a
/// crash report. The captured occurrence showed the process reach patched Dart
/// and bank launch success before vanishing — so the question is not *whether*
/// it got that far, it is *what happened next*. Nothing on the device answers
/// that today: syslog drops lines and can stall, and a crash report that is
/// never written cannot be read.
///
/// SO THE DESIGN CONSTRAINT IS SURVIVAL, NOT TIDINESS. Every entry is opened,
/// appended and flushed individually. That is deliberately wasteful: a buffered
/// writer would lose exactly the last few entries, which are the only ones that
/// matter when a process dies without warning.
///
/// WHAT THIS DOES NOT DO, and must never do. It records; it does not
/// participate. It never calls into the updater, never reports launch
/// success/failure, never touches boot attribution, retry accounting or the
/// ambiguity definition. Those are frozen while Epoch B collects
/// (`selfhost/NEXT_LANES.md`), and a fix that moved them would close Epoch B
/// and open Epoch C. `selfhost/reliability/verify_frozen_surfaces.sh` enforces
/// that by bytes rather than by trust.
///
/// Success is OBSERVED, not relocated: the updater already writes
/// `success_diag.log` with the pid, so the harness correlates this timeline to
/// that record by pid instead of this fixture duplicating — or worse, moving —
/// the success boundary.
class Timeline {
  Timeline._();

  /// Monotonic since as early in `main` as we can get. Wall-clock alone is not
  /// enough: it can step, and the intervals here are milliseconds.
  static final Stopwatch _mono = Stopwatch()..start();

  static File? _file;
  static int _seq = 0;

  /// The last resolution/write failure, or null. RENDERED BY THE UI.
  ///
  /// This field exists because the first version of this file swallowed its
  /// errors completely, and that hid a real bug: the path was derived from
  /// `Platform.environment['HOME']`, which a Flutter iOS app does not populate,
  /// so every Dart entry silently failed while the native half wrote fine. The
  /// timeline looked like "Dart never ran" when Dart had run perfectly.
  ///
  /// A silent instrument is the same failure this whole project keeps paying
  /// for: absence that means nothing is indistinguishable from absence that
  /// means something. So failures are now loud in three places — this field, a
  /// `print` that reaches syslog, and a banner on screen.
  static String? lastError;

  /// Lives in `Documents/`, which `ios-deploy --download` retrieves whole. A
  /// path inside the app's cache directory would be eligible for eviction, and
  /// evidence the OS may delete is not evidence.
  ///
  /// Derived from `Directory.systemTemp`, which on iOS is `<container>/tmp`, so
  /// its parent is the container itself. That avoids taking a `path_provider`
  /// dependency for one path, and — unlike `HOME` — it is actually populated.
  /// The native half independently resolves the same directory through
  /// `NSSearchPathForDirectoriesInDomains`, and the two agreeing is itself a
  /// check.
  static File get _target {
    final f = _file;
    if (f != null) return f;
    final container = Directory.systemTemp.parent.path;
    final created = File('$container/Documents/first_activation_timeline.log');
    _file = created;
    return created;
  }

  /// Records `event`, with an optional short `detail`.
  ///
  /// Catches its own IO errors so it can never crash the process it is
  /// measuring — an instrument that can kill its subject manufactures the very
  /// failure class under investigation. But it does NOT hide them: see
  /// [lastError].
  static void mark(String event, [String? detail]) {
    try {
      final line = StringBuffer()
        ..write('seq=${_seq++} ')
        ..write('mono_us=${_mono.elapsedMicroseconds} ')
        ..write('wall=${DateTime.now().toUtc().toIso8601String()} ')
        ..write('pid=$pid ')
        ..write('event=$event');
      if (detail != null) line.write(' detail=$detail');
      _target.writeAsStringSync(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (e) {
      // NOT silent. It must not crash the process it is measuring, but a failed
      // instrument has to announce itself: `print` reaches syslog, `lastError`
      // reaches the screen.
      lastError = '$e';
      // ignore: avoid_print
      print('TIMELINE_FAULT event=$event error=$e');
    }
  }

  /// Opens a fresh section for this process.
  ///
  /// The file is NOT truncated: comparing a disappearing launch with the clean
  /// launch that follows it is the whole method, so both must survive in one
  /// file. Runs are separated by pid and by this banner.
  static void begin(String phase) {
    mark('PROCESS_BEGIN', 'phase=$phase');
  }

  /// Post-success heartbeats, started AFTER the existing success boundary.
  ///
  /// The offsets are chosen to bracket what the one captured occurrence looked
  /// like: it lived at least ~1.2s past activation. If a disappearance lands
  /// between two heartbeats, that interval is the answer to "when", which is
  /// the first thing needed to ask "why".
  static const heartbeatOffsets = <int>[0, 100, 250, 500, 1000, 2000, 5000];
}
