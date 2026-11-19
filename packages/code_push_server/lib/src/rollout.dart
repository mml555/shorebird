import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Deterministic rollout bucket in [0, 10000) for a client, derived from a
/// stable hash of (app, channel, patch, client). The same client always lands
/// in the same bucket for a given promotion, so a partial rollout is consistent
/// across requests.
int rolloutBucket(String appId, int channelId, int patchId, String clientId) {
  final d = sha256
      .convert(utf8.encode('$appId:$channelId:$patchId:$clientId'))
      .bytes;
  final n = (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3];
  return (n & 0x7fffffff) % 10000;
}

/// Whether a client is eligible for a patch at [rollout] percent (0..100).
/// Fails closed: a partial rollout with no stable [clientId] is never eligible.
bool eligibleForRollout({
  required String appId,
  required int channelId,
  required int patchId,
  required int rollout,
  required String? clientId,
}) => eligibleForRolloutBps(
  appId: appId,
  channelId: channelId,
  patchId: patchId,
  rolloutBps: rollout * 100,
  clientId: clientId,
);

/// Whether a client is eligible for a patch rolled out to [rolloutBps] basis
/// points (hundredths of a percent, 0 to 10000) of a channel's devices.
///
/// The bucket is already in basis points, so a rollout of `p` percent is
/// `bucket < p * 100` exactly as before; fractional percentages such as 12.5
/// only add resolution. Raising a rollout never removes a device: the buckets
/// below the old threshold are below the new one.
bool eligibleForRolloutBps({
  required String appId,
  required int channelId,
  required int patchId,
  required int rolloutBps,
  required String? clientId,
}) {
  if (rolloutBps >= 10000) return true;
  if (rolloutBps <= 0) return false;
  if (clientId == null || clientId.isEmpty) return false;
  return rolloutBucket(appId, channelId, patchId, clientId) < rolloutBps;
}

/// The clock rollout schedules are read against. Tests replace it.
DateTime Function() rolloutClock = DateTime.now;

/// The rollout of a `channel_patches` row, in basis points, as of now.
///
/// A row with a `rollout_schedule` (a timed rollout) is on the step the
/// schedule has reached at [rolloutClock]: nothing advances it in the
/// background, so no cron has to run, and every pod computes the same answer
/// from the stored schedule. Raising never removes a device, because a
/// schedule only ever steps up.
///
/// Otherwise `rollout_bps` is the truth, written together with `rollout`
/// (whole percent, rounded down). A row whose `rollout_bps` is missing, or
/// disagrees with `rollout`, was written by a server that predates the column
/// during a rolling upgrade (an old pod still running), and `rollout` is then
/// the one that was kept current. A downgrade of the binary is not a case: a
/// database at this schema makes an older server refuse to boot
/// (`SchemaTooNewException`).
int effectiveRolloutBps(Map<String, Object?> row) {
  final schedule = RolloutSchedule.tryParse(row['rollout_schedule']);
  if (schedule != null) return schedule.positionAt(rolloutClock()).bps;
  final whole = (row['rollout'] as num).toInt();
  final bps = row['rollout_bps'];
  if (bps is num && bps.toInt() ~/ 100 == whole) return bps.toInt();
  return whole * 100;
}

/// [bps] as a percentage in the JSON a client reads: an integer when it is a
/// whole percentage, so what the API sent before fractional rollouts reads the
/// same, and a double otherwise.
num percentageOf(int bps) => bps % 100 == 0 ? bps ~/ 100 : bps / 100;

/// Parses a rollout percentage from a request body: a number from 0.01 to 100
/// that is a multiple of 0.01, as the CLI's `--rollout` is. Returns basis
/// points. Throws [FormatException] naming the problem.
int parseRolloutPercentage(Object? value, {required String field}) {
  if (value is! num || !value.isFinite) {
    throw FormatException('$field must be a number');
  }
  // Before any arithmetic: `1e308 * 100` is infinite, and `.round()` of that
  // throws, which would be a 500 rather than a 400.
  if (value < 0.01 - 1e-9 || value > 100) {
    throw FormatException('$field must be between 0.01 and 100');
  }
  final bps = (value * 100).round();
  if ((value * 100 - bps).abs() > 1e-6) {
    throw FormatException('$field must be a multiple of 0.01');
  }
  return bps;
}

/// A step of a timed rollout: hold at [bps] for [minutes], then advance.
/// The last step (100%) has no duration.
class RolloutStepSpec {
  const RolloutStepSpec(this.bps, this.minutes);
  final int bps;
  final int? minutes;
}

/// Where a schedule stands at an instant.
typedef RolloutPosition = ({
  int index,
  int bps,

  /// When the next step applies; null on the final step.
  DateTime? nextStepAt,
});

/// A timed rollout schedule: 2 to 10 strictly increasing steps ending at 100,
/// each held for its duration, advancing from [startedAt]. With
/// [pauseWeekends] the clock of a step stops on Saturday and Sunday in
/// [timezone], and no step is applied then.
///
/// Stored as JSON in `channel_patches.rollout_schedule` and evaluated against
/// the clock whenever the rollout is read, so it needs no background job.
class RolloutSchedule {
  RolloutSchedule({
    required this.steps,
    required this.pauseWeekends,
    required this.timezone,
    required this.startedAt,
  });

  static const maxSteps = 10;
  static const minSteps = 2;

  /// A year; the longest a single step may be held.
  static const maxStepMinutes = 525600;

  final List<RolloutStepSpec> steps;
  final bool pauseWeekends;
  final String timezone;
  final DateTime startedAt;

  /// Basis points of the first step, which applies at once.
  int get initialBps => steps.first.bps;

  /// Parses a request's `rollout_steps`, `rollout_pause_weekends` and
  /// `rollout_timezone`. Throws [FormatException] naming the problem.
  factory RolloutSchedule.fromRequest(
    Map<String, Object?> body, {
    required DateTime now,
  }) {
    final raw = body['rollout_steps'];
    if (raw is! List) {
      throw const FormatException('rollout_steps must be a list');
    }
    if (raw.length < minSteps || raw.length > maxSteps) {
      throw const FormatException(
        'rollout_steps must have $minSteps to $maxSteps steps',
      );
    }
    final steps = <RolloutStepSpec>[];
    var previous = 0;
    for (final (i, e) in raw.indexed) {
      if (e is! Map) {
        throw FormatException('rollout_steps[$i] must be an object');
      }
      final bps = parseRolloutPercentage(
        e['percentage'],
        field: 'rollout_steps[$i].percentage',
      );
      if (bps <= previous) {
        throw const FormatException(
          'rollout_steps percentages must strictly increase',
        );
      }
      previous = bps;
      final last = i == raw.length - 1;
      final d = e['duration_minutes'];
      if (last) {
        if (bps != 10000) {
          throw const FormatException('rollout_steps must end at 100');
        }
        if (d != null) {
          throw const FormatException(
            'the final rollout step (100) takes no duration_minutes',
          );
        }
        steps.add(RolloutStepSpec(bps, null));
      } else {
        if (d is! int || d < 1 || d > maxStepMinutes) {
          throw FormatException(
            'rollout_steps[$i].duration_minutes must be a whole number of '
            'minutes from 1 to $maxStepMinutes',
          );
        }
        steps.add(RolloutStepSpec(bps, d));
      }
    }
    final pause = body['rollout_pause_weekends'];
    if (pause != null && pause is! bool) {
      throw const FormatException('rollout_pause_weekends must be a boolean');
    }
    final zone = body['rollout_timezone'];
    if (zone != null && zone is! String) {
      throw const FormatException('rollout_timezone must be a string');
    }
    final name = (zone as String?)?.trim();
    final timezone = name == null || name.isEmpty ? 'UTC' : name;
    if (_location(timezone) == null) {
      throw FormatException(
        'rollout_timezone "$timezone" is not an IANA time zone name '
        '(such as "America/New_York")',
      );
    }
    return RolloutSchedule(
      steps: steps,
      pauseWeekends: pause == true,
      timezone: timezone,
      startedAt: now.toUtc(),
    );
  }

  /// The schedule stored in [raw], or null when there is none (or it cannot
  /// be read, which leaves the row on its fixed `rollout_bps`).
  static RolloutSchedule? tryParse(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return RolloutSchedule(
        steps: [
          for (final e in j['steps'] as List)
            RolloutStepSpec((e as Map)['bps'] as int, e['minutes'] as int?),
        ],
        pauseWeekends: j['pause_weekends'] as bool,
        timezone: j['timezone'] as String,
        startedAt: DateTime.parse(j['started_at'] as String).toUtc(),
      );
    } on Object {
      return null;
    }
  }

  String toStored() => jsonEncode({
    'steps': [
      for (final s in steps) {'bps': s.bps, 'minutes': s.minutes},
    ],
    'pause_weekends': pauseWeekends,
    'timezone': timezone,
    'started_at': startedAt.toIso8601String(),
  });

  static bool _tzReady = false;

  static tz.Location? _location(String name) {
    if (!_tzReady) {
      tzdata.initializeTimeZones();
      _tzReady = true;
    }
    try {
      return tz.getLocation(name);
    } on Object {
      return null;
    }
  }

  /// When each step applies. Step 0 applies at [startedAt]; each later one
  /// after the previous step's duration, counting only time outside weekends
  /// when [pauseWeekends], and never inside one.
  List<DateTime> get _starts {
    final loc = pauseWeekends ? _location(timezone) : null;
    final out = <DateTime>[startedAt];
    for (var i = 0; i < steps.length - 1; i++) {
      final end = loc == null
          ? out.last.add(Duration(minutes: steps[i].minutes!))
          : _afterActiveMinutes(out.last, steps[i].minutes!, loc);
      out.add(loc == null ? end : _outOfWeekend(end, loc));
    }
    return out;
  }

  /// The step in force at [now], its percentage, and when the next applies.
  RolloutPosition positionAt(DateTime now) {
    final starts = _starts;
    var index = 0;
    for (var i = 1; i < starts.length; i++) {
      if (!now.isBefore(starts[i])) index = i;
    }
    return (
      index: index,
      bps: steps[index].bps,
      nextStepAt: index + 1 < starts.length ? starts[index + 1] : null,
    );
  }

  static bool _weekend(tz.TZDateTime t) =>
      t.weekday == DateTime.saturday || t.weekday == DateTime.sunday;

  /// Monday 00:00 local after a weekend instant; other instants unchanged.
  static DateTime _outOfWeekend(DateTime t, tz.Location loc) {
    final local = tz.TZDateTime.from(t, loc);
    if (!_weekend(local)) return t;
    final days = 8 - local.weekday;
    return tz.TZDateTime(loc, local.year, local.month, local.day + days);
  }

  /// The instant [minutes] of non-weekend time after [from].
  static DateTime _afterActiveMinutes(
    DateTime from,
    int minutes,
    tz.Location loc,
  ) {
    var cursor = tz.TZDateTime.from(from, loc);
    var remaining = minutes;
    while (remaining > 0) {
      if (_weekend(cursor)) {
        final days = 8 - cursor.weekday;
        cursor = tz.TZDateTime(
          loc,
          cursor.year,
          cursor.month,
          cursor.day + days,
        );
        continue;
      }
      final saturday = tz.TZDateTime(
        loc,
        cursor.year,
        cursor.month,
        cursor.day + (6 - cursor.weekday),
      );
      final room = saturday.difference(cursor).inMinutes;
      final take = remaining < room ? remaining : room;
      cursor = cursor.add(Duration(minutes: take));
      remaining -= take;
    }
    return cursor.toUtc();
  }
}
