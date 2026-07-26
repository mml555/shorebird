import 'package:code_push_server/src/db.dart';

/// Event-derived analytics for the self-hosted control plane.
///
/// Every method runs read-only SQL over the append-only `events` table and
/// returns plain `Map`/`List` structures whose JSON shape matches the
/// corresponding Shorebird protocol response DTO exactly (snake_case keys).
/// This is wire-parity glue: the shapes mirror
/// `package:shorebird_code_push_protocol` even where our single-node event
/// store cannot supply every field the hosted product does. Wherever the
/// events table lacks a field a DTO wants, the value degrades to 0/empty/null
/// and a `// NOTE:` explains the gap rather than inventing data.
///
/// Design notes that apply throughout:
///   * `ts` is unix seconds (BIGINT). Time filters compare against integer
///     epoch bounds (`ts >= @s AND ts < @e`) — half-open `[start, end)`,
///     matching `MetricsRange` (start inclusive, end exclusive).
///   * Time buckets use `date_trunc(unit, timezone('UTC', to_timestamp(ts)))`
///     so bucketing is always in UTC regardless of the server session's
///     timezone. The resulting naive timestamp's wall-clock fields ARE the
///     UTC instant; [_isoUtc] re-stamps them as UTC before serializing.
///   * Distinct-device counts use `COUNT(DISTINCT client_id)`.
///     NOTE: the hosted product uses HyperLogLog sketches; exact distinct
///     counts here are correct but not HLL — `time_series` buckets therefore
///     genuinely do not sum to the window total (same caveat the DTO states).
class Analytics {
  /// Creates an [Analytics] backed by [db]. Date bucketing is expressed through
  /// [Db.truncPeriod]/[Db.extractDow]/[Db.extractHour], so the same queries run
  /// on both backends — analytics works in single-container (SQLite) mode and
  /// the Postgres scale profile alike.
  Analytics(this._db);

  final Db _db;

  static const _downloadType = '__patch_download__';
  static const _installType = '__patch_install__';

  // ---- low-level helpers ----

  Future<List<Map<String, dynamic>>> _rows(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    final rows = await _db.query(sql, params);
    return rows.map(Map<String, dynamic>.from).toList();
  }

  /// Re-stamps a value coming back from `timezone('UTC', ...)` /
  /// `date_trunc(...)` (a naive timestamp whose fields are the UTC instant)
  /// as an ISO-8601 UTC string.
  static String _isoUtc(Object? v) {
    if (v is DateTime) {
      return DateTime.utc(
        v.year,
        v.month,
        v.day,
        v.hour,
        v.minute,
        v.second,
        v.millisecond,
        v.microsecond,
      ).toIso8601String();
    }
    return v.toString();
  }

  static String _epochIso(int epochSeconds) =>
      DateTime.fromMillisecondsSinceEpoch(
        epochSeconds * 1000,
        isUtc: true,
      ).toIso8601String();

  static Map<String, Object?> _range(int startEpoch, int endEpoch) => {
    'start': _epochIso(startEpoch),
    'end': _epochIso(endEpoch),
  };

  static int _asInt(Object? v) => (v as num?)?.toInt() ?? 0;

  /// Validates a granularity string against the protocol's enum
  /// (`hour`/`day`/`week`); anything else (including null) yields null,
  /// meaning "no time series requested".
  static String? _bucketUnit(String? granularity) {
    switch (granularity) {
      case 'hour':
      case 'day':
      case 'week':
        return granularity;
      default:
        return null;
    }
  }

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  static int _nowEpoch() =>
      DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

  /// Earliest event `ts` for the app (the "data floor"), or null when the
  /// app has no events. Used to decide whether a `previous` comparison
  /// window predates recorded history.
  Future<int?> _floorEpoch(String appId) async {
    final rows = await _rows(
      'SELECT MIN(ts) AS m FROM events WHERE app_id = @a',
      {'a': appId},
    );
    final m = rows.isEmpty ? null : rows.first['m'];
    return m == null ? null : _asInt(m);
  }

  // ---- patch adoption over time ----

  /// Cumulative patch adoption for a single release, shaped as
  /// `GetPatchAdoptionResponse`.
  ///
  /// Route: `GET /api/v1/apps/{appId}/analytics/patch-adoption`
  ///        `?release_version=<v>&granularity=<hour|day|week>`
  ///        `&start=<iso>&end=<iso>`
  ///
  /// For each patch of the release, `devices` counts distinct devices running
  /// patch `>= patch_number` (cumulative) and `target` counts distinct
  /// devices on the release restricted to that patch's target platform(s);
  /// `adoption_pct = devices / target`.
  Future<Map<String, Object?>> patchAdoption(
    String appId, {
    String? releaseVersion,
    String? granularity,
    DateTime? start,
    DateTime? end,
  }) async {
    final unit = _bucketUnit(granularity);
    final asOf = _nowIso();

    // Resolve the release: explicit param, else the most-recently-seen one.
    var isLatest = false;
    var release = releaseVersion;
    if (release == null) {
      final rows = await _rows(
        '''SELECT release_version FROM events
             WHERE app_id = @a AND release_version IS NOT NULL
             GROUP BY release_version
             ORDER BY MAX(ts) DESC
             LIMIT 1''',
        {'a': appId},
      );
      isLatest = true;
      release = rows.isEmpty ? '' : rows.first['release_version'] as String;
    }

    // Effective window: any explicit bound wins; unspecified bounds fall back
    // to the release's own observed [min, max+1) span (as_of when no events).
    int startEpoch;
    int endEpoch;
    final bounds = await _rows(
      '''SELECT MIN(ts) AS lo, MAX(ts) AS hi FROM events
           WHERE app_id = @a AND release_version = @rv''',
      {'a': appId, 'rv': release},
    );
    final lo = bounds.isEmpty ? null : bounds.first['lo'];
    final hi = bounds.isEmpty ? null : bounds.first['hi'];
    if (start != null) {
      startEpoch = start.toUtc().millisecondsSinceEpoch ~/ 1000;
    } else {
      startEpoch = lo == null ? _nowEpoch() : _asInt(lo);
    }
    if (end != null) {
      endEpoch = end.toUtc().millisecondsSinceEpoch ~/ 1000;
    } else {
      endEpoch = hi == null ? startEpoch : _asInt(hi) + 1;
    }

    // Distinct patch numbers observed for the release.
    final patchRows = await _rows(
      '''SELECT DISTINCT patch_number FROM events
           WHERE app_id = @a AND release_version = @rv
             AND patch_number IS NOT NULL
           ORDER BY patch_number''',
      {'a': appId, 'rv': release},
    );

    final patches = <Map<String, Object?>>[];
    for (final pr in patchRows) {
      final patchNumber = _asInt(pr['patch_number']);

      // Target platforms are derived from the platforms the patch's events
      // were reported on.
      // NOTE: the hosted product derives target platforms from the patch's
      // uploaded artifacts; the events table has no artifact linkage, so we
      // approximate from observed event platforms.
      final platRows = await _rows(
        '''SELECT DISTINCT platform FROM events
             WHERE app_id = @a AND release_version = @rv
               AND patch_number = @p AND platform IS NOT NULL
             ORDER BY platform''',
        {'a': appId, 'rv': release, 'p': patchNumber},
      );
      final targetPlatforms = [
        for (final row in platRows) row['platform'] as String,
      ];

      // Restrict the denominator to the patch's target platform(s) via a
      // correlated subquery (no array parameter needed). Empty => no filter.
      final platCond = targetPlatforms.isEmpty
          ? ''
          : ' AND platform IN (SELECT DISTINCT platform FROM events '
                'WHERE app_id = @a AND release_version = @rv '
                'AND patch_number = @p AND platform IS NOT NULL)';

      final params = <String, Object?>{
        'a': appId,
        'rv': release,
        'p': patchNumber,
        's': startEpoch,
        'e': endEpoch,
      };

      final series = <Map<String, Object?>>[];
      if (unit == null) {
        // Single full-window point (period: null).
        final rows = await _rows('''SELECT
               COUNT(DISTINCT client_id) FILTER (WHERE patch_number >= @p)
                 AS devices,
               COUNT(DISTINCT client_id) AS target
             FROM events
             WHERE app_id = @a AND release_version = @rv
               AND client_id IS NOT NULL
               AND ts >= @s AND ts < @e$platCond''', params);
        final devices = rows.isEmpty ? 0 : _asInt(rows.first['devices']);
        final target = rows.isEmpty ? 0 : _asInt(rows.first['target']);
        series.add({
          'period': null,
          'devices': devices,
          'target': target,
          'adoption_pct': target == 0 ? 0.0 : devices / target,
        });
      } else {
        final rows = await _rows('''SELECT ${_db.truncPeriod(unit, 'ts')}
                 AS period,
               COUNT(DISTINCT client_id) FILTER (WHERE patch_number >= @p)
                 AS devices,
               COUNT(DISTINCT client_id) AS target
             FROM events
             WHERE app_id = @a AND release_version = @rv
               AND client_id IS NOT NULL
               AND ts >= @s AND ts < @e$platCond
             GROUP BY period
             ORDER BY period''', params);
        for (final row in rows) {
          final devices = _asInt(row['devices']);
          final target = _asInt(row['target']);
          series.add({
            'period': _isoUtc(row['period']),
            'devices': devices,
            'target': target,
            'adoption_pct': target == 0 ? 0.0 : devices / target,
          });
        }
      }

      patches.add({
        'patch_number': patchNumber,
        'target_platforms': targetPlatforms,
        // NOTE: the events table records no rollback state; a rolled-back
        // patch is indistinguishable from a live one here.
        'is_rolled_back': false,
        'series': series,
      });
    }

    return {
      'release_version': release,
      'is_latest': isLatest,
      'granularity': unit,
      'range': _range(startEpoch, endEpoch),
      'as_of': asOf,
      'patches': patches,
    };
  }

  // ---- unique users (windowed current/previous envelope) ----

  /// Distinct active devices over a trailing window with a period-over-period
  /// comparison, shaped as `GetUniqueUsersResponse`.
  ///
  /// Route: `GET /api/v1/apps/{appId}/analytics/unique-users`
  ///        `?window_days=<n>&granularity=<hour|day|week>`
  ///        `&group_by=<platform|release_version>`
  Future<Map<String, Object?>> uniqueUsers(
    String appId, {
    int windowDays = 30,
    String? granularity,
    String? groupBy,
  }) async {
    final unit = _bucketUnit(granularity);
    final asOf = _nowIso();
    final now = _nowEpoch();
    final windowSecs = windowDays * 86400;
    final curStart = now - windowSecs;
    final curEnd = now;
    final prevStart = curStart - windowSecs;
    final prevEnd = curStart;
    final floor = await _floorEpoch(appId);

    final current = await _uniqueUsersWindow(
      appId,
      curStart,
      curEnd,
      unit,
      groupBy: groupBy,
    );

    // `previous` is null only when the prior window predates the data floor
    // (no comparison data exists).
    Map<String, Object?>? previous;
    if (floor != null && prevStart >= floor) {
      previous = await _uniqueUsersWindow(appId, prevStart, prevEnd, unit);
    }

    return {
      'as_of': asOf,
      'granularity': unit,
      'current': current,
      'previous': previous,
    };
  }

  Future<Map<String, Object?>> _uniqueUsersWindow(
    String appId,
    int startEpoch,
    int endEpoch,
    String? unit, {
    String? groupBy,
  }) async {
    final params = <String, Object?>{
      'a': appId,
      's': startEpoch,
      'e': endEpoch,
    };

    final totalRows = await _rows(
      '''SELECT COUNT(DISTINCT client_id) AS c FROM events
           WHERE app_id = @a AND client_id IS NOT NULL
             AND ts >= @s AND ts < @e''',
      params,
    );
    final uniqueUsers = totalRows.isEmpty ? 0 : _asInt(totalRows.first['c']);

    final window = <String, Object?>{
      'unique_users': uniqueUsers,
      'range': _range(startEpoch, endEpoch),
    };

    if (unit != null) {
      final seriesRows = await _rows('''SELECT ${_db.truncPeriod(unit, 'ts')}
               AS period,
             COUNT(DISTINCT client_id) AS c
           FROM events
           WHERE app_id = @a AND client_id IS NOT NULL
             AND ts >= @s AND ts < @e
           GROUP BY period
           ORDER BY period''', params);
      window['time_series'] = [
        for (final row in seriesRows)
          {'period': _isoUtc(row['period']), 'unique_users': _asInt(row['c'])},
      ];
    }

    // Breakdown only decorates the `current` window (groupBy != null).
    final col = _uniqueUsersGroupColumn(groupBy);
    if (col != null) {
      final breakRows = await _rows('''SELECT COALESCE($col, '') AS g,
             COUNT(DISTINCT client_id) AS c
           FROM events
           WHERE app_id = @a AND client_id IS NOT NULL
             AND ts >= @s AND ts < @e
           GROUP BY g
           ORDER BY c DESC, g ASC''', params);

      // Per-group time series, when a granularity was also requested.
      final groupSeries = <String, List<Map<String, Object?>>>{};
      if (unit != null) {
        final gsRows = await _rows('''SELECT COALESCE($col, '') AS g,
               ${_db.truncPeriod(unit, 'ts')} AS period,
               COUNT(DISTINCT client_id) AS c
             FROM events
             WHERE app_id = @a AND client_id IS NOT NULL
               AND ts >= @s AND ts < @e
             GROUP BY g, period
             ORDER BY g, period''', params);
        for (final row in gsRows) {
          (groupSeries[row['g'] as String] ??= []).add({
            'period': _isoUtc(row['period']),
            'unique_users': _asInt(row['c']),
          });
        }
      }

      window['breakdown'] = [
        for (final row in breakRows)
          {
            'group_by': groupBy,
            'group_value': row['g'] as String,
            'unique_users': _asInt(row['c']),
            if (unit != null) 'time_series': groupSeries[row['g']] ?? const [],
          },
      ];
    }

    return window;
  }

  static String? _uniqueUsersGroupColumn(String? groupBy) {
    switch (groupBy) {
      case 'platform':
        return 'platform';
      case 'release_version':
        return 'release_version';
      default:
        return null;
    }
  }

  // ---- version distribution ----

  /// Exact distinct-device counts per release version among currently-active
  /// devices, shaped as `GetVersionDistributionResponse`.
  ///
  /// Route: `GET /api/v1/apps/{appId}/analytics/version-distribution`
  ///        `?active_window_days=<n>`
  ///
  /// NOTE: a device active on more than one release version within the window
  /// is counted under each; `total_devices` is therefore the sum of the entry
  /// counts (matching the DTO contract), not the distinct device population.
  Future<Map<String, Object?>> versionDistribution(
    String appId, {
    int activeWindowDays = 30,
  }) async {
    final asOf = _nowIso();
    final now = _nowEpoch();
    final start = now - activeWindowDays * 86400;

    final rows = await _rows(
      '''SELECT release_version, COUNT(DISTINCT client_id) AS c
           FROM events
           WHERE app_id = @a AND client_id IS NOT NULL
             AND ts >= @s AND ts < @e
           GROUP BY release_version
           ORDER BY c DESC, release_version ASC NULLS LAST''',
      {'a': appId, 's': start, 'e': now},
    );

    final counts = [for (final row in rows) _asInt(row['c'])];
    final total = counts.fold<int>(0, (a, b) => a + b);

    final entries = <Map<String, Object?>>[];
    for (var i = 0; i < rows.length; i++) {
      final count = counts[i];
      entries.add({
        'release_version': rows[i]['release_version'] as String?,
        'device_count': count,
        'percentage': total == 0 ? 0.0 : count / total,
      });
    }

    return {
      'entries': entries,
      'total_devices': total,
      'active_window_days': activeWindowDays,
      'as_of': asOf,
    };
  }

  // ---- activity heatmap (7 x 24 UTC weekday-hour grid) ----

  /// Average active devices per (UTC weekday, UTC hour) cell over a lookback
  /// window, shaped as `GetActivityHeatmapResponse`. 168 zero-filled cells,
  /// ordered by `day_of_week_utc` (1-7, 1=Sunday) then `hour_utc` (0-23).
  ///
  /// Route: `GET /api/v1/apps/{appId}/analytics/activity-heatmap`
  ///        `?lookback_days=<n>`
  Future<Map<String, Object?>> activityHeatmap(
    String appId, {
    int lookbackDays = 28,
  }) async {
    final asOf = _nowIso();
    final now = _nowEpoch();
    final start = now - lookbackDays * 86400;
    final startDate = DateTime.fromMillisecondsSinceEpoch(
      start * 1000,
      isUtc: true,
    );
    final endDate = DateTime.fromMillisecondsSinceEpoch(
      now * 1000,
      isUtc: true,
    );

    // Distinct devices per (weekday, hour, calendar-day). Averaging happens in
    // Dart so we can divide by the true number of occurrences of each weekday
    // in the window (zero-activity occurrences included).
    // extract(dow) is 0=Sunday..6=Saturday; the DTO wants 1=Sunday..7=Saturday.
    final rows = await _rows(
      '''SELECT
           ${_db.extractDow('ts')}  AS dow,
           ${_db.extractHour('ts')}  AS hr,
           ${_db.truncPeriod('day', 'ts')}       AS day,
           COUNT(DISTINCT client_id) AS devices
         FROM events
         WHERE app_id = @a AND client_id IS NOT NULL
           AND ts >= @s AND ts < @e
         GROUP BY dow, hr, day''',
      {'a': appId, 's': start, 'e': now},
    );

    // Sum device counts per (dow, hour) across the window's days.
    final sums = <int, Map<int, int>>{};
    for (final row in rows) {
      final dow = _asInt(row['dow']); // 0..6, 0=Sunday
      final hr = _asInt(row['hr']); // 0..23
      final devices = _asInt(row['devices']);
      (sums[dow] ??= {})[hr] = (sums[dow]?[hr] ?? 0) + devices;
    }

    // Count occurrences of each weekday (0..6) within [startDate, endDate).
    final occurrences = List<int>.filled(7, 0);
    var cursor = DateTime.utc(startDate.year, startDate.month, startDate.day);
    while (cursor.isBefore(endDate)) {
      occurrences[cursor.weekday % 7]++; // DateTime.weekday: Mon=1..Sun=7
      cursor = cursor.add(const Duration(days: 1));
    }

    final cells = <Map<String, Object?>>[];
    int? busiestDow;
    int? busiestHour;
    var busiestAvg = -1.0;
    // Emit ordered by DTO's day_of_week_utc (1..7) then hour (0..23).
    for (var dtoDay = 1; dtoDay <= 7; dtoDay++) {
      final pgDow = dtoDay - 1; // 0=Sunday..6=Saturday
      final occ = occurrences[pgDow];
      for (var hr = 0; hr < 24; hr++) {
        final sum = sums[pgDow]?[hr] ?? 0;
        final avg = occ == 0 ? 0.0 : sum / occ;
        if (avg > busiestAvg) {
          busiestAvg = avg;
          busiestDow = dtoDay;
          busiestHour = hr;
        }
        cells.add({
          'day_of_week_utc': dtoDay,
          'hour_utc': hr,
          'average_active_devices': avg,
        });
      }
    }

    final hasData = rows.isNotEmpty && busiestAvg > 0;
    return {
      'cells': cells,
      'busiest_day_of_week_utc': hasData ? busiestDow : null,
      'busiest_hour_utc': hasData ? busiestHour : null,
      'lookback_days': lookbackDays,
      'as_of': asOf,
    };
  }

  // ---- active hours (24-hour UTC activity profile) ----

  /// Average active devices per UTC hour-of-day and a recommended
  /// low-activity release window, shaped as `GetActiveHoursResponse`.
  ///
  /// Route: `GET /api/v1/apps/{appId}/analytics/active-hours`
  ///        `?lookback_days=<n>`
  Future<Map<String, Object?>> activeHours(
    String appId, {
    int lookbackDays = 28,
  }) async {
    const windowLengthHours = 2; // Fixed at 2 in v1 per the DTO.
    final asOf = _nowIso();
    final now = _nowEpoch();
    final start = now - lookbackDays * 86400;

    // Distinct devices per (hour, calendar-day); average over lookbackDays in
    // Dart so zero-activity days are included in the denominator.
    final rows = await _rows(
      '''SELECT
           ${_db.extractHour('ts')} AS hr,
           ${_db.truncPeriod('day', 'ts')}      AS day,
           COUNT(DISTINCT client_id) AS devices
         FROM events
         WHERE app_id = @a AND client_id IS NOT NULL
           AND ts >= @s AND ts < @e
         GROUP BY hr, day''',
      {'a': appId, 's': start, 'e': now},
    );

    final sums = List<int>.filled(24, 0);
    for (final row in rows) {
      sums[_asInt(row['hr'])] += _asInt(row['devices']);
    }
    final denom = lookbackDays <= 0 ? 1 : lookbackDays;
    final averages = [for (final s in sums) s / denom];

    final hourly = <Map<String, Object?>>[
      for (var hr = 0; hr < 24; hr++)
        {'hour_utc': hr, 'average_active_devices': averages[hr]},
    ];

    final hasData = rows.isNotEmpty;

    // Busiest hour.
    int? busiestHour;
    if (hasData) {
      var best = -1.0;
      for (var hr = 0; hr < 24; hr++) {
        if (averages[hr] > best) {
          best = averages[hr];
          busiestHour = hr;
        }
      }
    }

    // Recommended window: the consecutive `windowLengthHours` block (wrapping
    // past midnight) with the lowest total activity. Requires >= 7 days of
    // data per the DTO.
    int? recommendedStart;
    if (hasData && lookbackDays >= 7) {
      var best = double.infinity;
      for (var startHr = 0; startHr < 24; startHr++) {
        var windowSum = 0.0;
        for (var offset = 0; offset < windowLengthHours; offset++) {
          windowSum += averages[(startHr + offset) % 24];
        }
        if (windowSum < best) {
          best = windowSum;
          recommendedStart = startHr;
        }
      }
    }

    return {
      'hourly': hourly,
      'recommended_window_start_utc': recommendedStart,
      'recommended_window_length_hours': windowLengthHours,
      'busiest_hour_utc': busiestHour,
      'lookback_days': lookbackDays,
      'as_of': asOf,
    };
  }

  // ---- new devices over time ----

  /// Devices first seen in the trailing window with a period-over-period
  /// comparison, shaped as `GetNewDevicesResponse`. "First seen" is a device's
  /// earliest event `ts`. An exact (non-HLL) count.
  ///
  /// Route: `GET /api/v1/apps/{appId}/analytics/new-devices`
  ///        `?window_days=<n>`
  Future<Map<String, Object?>> newDevices(
    String appId, {
    int windowDays = 30,
  }) async {
    final asOf = _nowIso();
    final now = _nowEpoch();
    final windowSecs = windowDays * 86400;
    final curStart = now - windowSecs;
    final prevStart = curStart - windowSecs;
    final floor = await _floorEpoch(appId);

    final rows = await _rows(
      '''WITH firsts AS (
           SELECT client_id, MIN(ts) AS f FROM events
             WHERE app_id = @a AND client_id IS NOT NULL
             GROUP BY client_id
         )
         SELECT
           COUNT(*) FILTER (WHERE f >= @cs AND f < @ce) AS cur,
           COUNT(*) FILTER (WHERE f >= @ps AND f < @pe) AS prev
         FROM firsts''',
      {'a': appId, 'cs': curStart, 'ce': now, 'ps': prevStart, 'pe': curStart},
    );

    final current = rows.isEmpty ? 0 : _asInt(rows.first['cur']);
    // `previous` is null when the prior window would begin before the data
    // floor (comparing against partially-recorded history is misleading).
    final int? previous = (floor != null && prevStart >= floor)
        ? (rows.isEmpty ? 0 : _asInt(rows.first['prev']))
        : null;

    return {
      'current': current,
      'previous': previous,
      'window_days': windowDays,
      'as_of': asOf,
    };
  }

  // ---- per-patch metric (installs / downloads) ----

  /// Summed install or download counts over a trailing window with a
  /// period-over-period comparison, shaped as `GetPatchMetricResponse`.
  ///
  /// Routes:
  ///   `GET /api/v1/apps/{appId}/analytics/patch-installs`
  ///   `GET /api/v1/apps/{appId}/analytics/patch-downloads`
  ///   `?window_days=<n>&granularity=<hour|day|week>&group_by=<release|patch>`
  ///   `&release_version=<v>&patch_number=<n>`
  ///
  /// [metric] is `installs` or `downloads`. Optional [releaseVersion] /
  /// [patchNumber] scope the counts (release scope groups by patch; app scope
  /// groups by release).
  Future<Map<String, Object?>> patchMetric(
    String appId, {
    required String metric,
    int windowDays = 30,
    String? granularity,
    String? groupBy,
    String? releaseVersion,
    int? patchNumber,
  }) async {
    final unit = _bucketUnit(granularity);
    final type = metric == 'downloads' ? _downloadType : _installType;
    final asOf = _nowIso();
    final now = _nowEpoch();
    final windowSecs = windowDays * 86400;
    final curStart = now - windowSecs;
    final prevStart = curStart - windowSecs;
    final floor = await _floorEpoch(appId);

    // Optional scope clause shared by every query in this method.
    final scope = StringBuffer();
    if (releaseVersion != null) scope.write(' AND release_version = @rv');
    if (patchNumber != null) scope.write(' AND patch_number = @pn');

    final current = await _patchMetricWindow(
      appId,
      type,
      curStart,
      now,
      unit,
      scope.toString(),
      releaseVersion,
      patchNumber,
      groupBy: groupBy,
    );

    Map<String, Object?>? previous;
    if (floor != null && prevStart >= floor) {
      previous = await _patchMetricWindow(
        appId,
        type,
        prevStart,
        curStart,
        unit,
        scope.toString(),
        releaseVersion,
        patchNumber,
      );
    }

    return {
      'as_of': asOf,
      'granularity': unit,
      'current': current,
      'previous': previous,
    };
  }

  Future<Map<String, Object?>> _patchMetricWindow(
    String appId,
    String type,
    int startEpoch,
    int endEpoch,
    String? unit,
    String scope,
    String? releaseVersion,
    int? patchNumber, {
    String? groupBy,
  }) async {
    final params = <String, Object?>{
      'a': appId,
      't': type,
      's': startEpoch,
      'e': endEpoch,
      if (releaseVersion != null) 'rv': releaseVersion,
      if (patchNumber != null) 'pn': patchNumber,
    };

    final totalRows = await _rows('''SELECT COUNT(*) AS c FROM events
           WHERE app_id = @a AND type = @t
             AND ts >= @s AND ts < @e$scope''', params);
    final count = totalRows.isEmpty ? 0 : _asInt(totalRows.first['c']);

    final window = <String, Object?>{
      'count': count,
      'range': _range(startEpoch, endEpoch),
    };

    if (unit != null) {
      final seriesRows = await _rows('''SELECT ${_db.truncPeriod(unit, 'ts')}
               AS period,
             COUNT(*) AS c
           FROM events
           WHERE app_id = @a AND type = @t
             AND ts >= @s AND ts < @e$scope
           GROUP BY period
           ORDER BY period''', params);
      window['time_series'] = [
        for (final row in seriesRows)
          {'period': _isoUtc(row['period']), 'count': _asInt(row['c'])},
      ];
    }

    // Breakdown decorates only the `current` window.
    final col = _patchMetricGroupColumn(groupBy);
    if (col != null) {
      final breakRows = await _rows(
        '''SELECT $col AS g, COUNT(*) AS c FROM events
             WHERE app_id = @a AND type = @t
               AND ts >= @s AND ts < @e AND $col IS NOT NULL$scope
             GROUP BY g
             ORDER BY c DESC, g ASC''',
        params,
      );

      final groupSeries = <String, List<Map<String, Object?>>>{};
      if (unit != null) {
        final gsRows = await _rows('''SELECT $col AS g,
               ${_db.truncPeriod(unit, 'ts')} AS period,
               COUNT(*) AS c
             FROM events
             WHERE app_id = @a AND type = @t
               AND ts >= @s AND ts < @e AND $col IS NOT NULL$scope
             GROUP BY g, period
             ORDER BY g, period''', params);
        for (final row in gsRows) {
          final key = row['g'].toString();
          (groupSeries[key] ??= []).add({
            'period': _isoUtc(row['period']),
            'count': _asInt(row['c']),
          });
        }
      }

      window['breakdown'] = [
        for (final row in breakRows)
          {
            'group_by': groupBy,
            'group_value': row['g'].toString(),
            'count': _asInt(row['c']),
            if (unit != null)
              'time_series': groupSeries[row['g'].toString()] ?? const [],
          },
      ];
    }

    return window;
  }

  static String? _patchMetricGroupColumn(String? groupBy) {
    switch (groupBy) {
      case 'release':
        return 'release_version';
      case 'patch':
        return 'patch_number';
      default:
        return null;
    }
  }
}
