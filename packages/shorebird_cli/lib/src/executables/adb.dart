import 'dart:async';
import 'dart:io';

import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/android_sdk.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';

/// A reference to a [Adb] instance.
final adbRef = create(Adb.new);

/// The [Adb] instance available in the current zone.
Adb get adb => read(adbRef);

/// {@template clear_app_data_exception}
/// Thrown when `adb shell pm clear` fails.
/// {@endtemplate}
class ClearAppDataException implements Exception {
  /// {@macro clear_app_data_exception}
  ClearAppDataException({required this.stderr});

  /// The stderr output of the failed `pm clear` invocation.
  final String stderr;

  /// Whether the failure was the device refusing the operation rather than,
  /// say, the package not being installed.
  ///
  /// Several vendor ROMs (Xiaomi/POCO, OPPO/OnePlus among them) deny
  /// `CLEAR_APP_USER_DATA` to the adb shell user even with USB debugging on, so
  /// this is a property of the device, not of the app or of Shorebird.
  bool get isPermissionDenied =>
      stderr.contains('CLEAR_APP_USER_DATA') ||
      stderr.contains('SecurityException');

  @override
  String toString() => 'Unable to clear app data: $stderr';
}

/// A wrapper around the `adb` command.
class Adb {
  Future<ShorebirdProcessResult> _exec(String command) async {
    final adbPath = androidSdk.adbPath;
    if (adbPath == null) throw Exception('Unable to locate adb.');

    return process.run(adbPath, command.split(' '));
  }

  Future<Process> _stream(String command) async {
    final adbPath = androidSdk.adbPath;
    if (adbPath == null) throw Exception('Unable to locate adb.');

    return process.start(adbPath, command.split(' '));
  }

  /// Clears the app data for the given [package] name.
  Future<void> clearAppData({required String package, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'shell',
      'pm',
      'clear',
      package,
    ];
    final result = await _exec(args.join(' '));
    if (result.exitCode != 0) {
      throw ClearAppDataException(stderr: '${result.stderr}');
    }
  }

  /// Starts the app with the given [package] name.
  Future<void> startApp({required String package, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'shell',
      'monkey',
      // Adjust percentage of "system" key events to 0.
      // This is needed to support Android systems with no hardware keys.
      '--pct-syskeys 0',
      '-p $package',
      '1',
    ];
    final result = await _exec(args.join(' '));
    if (result.exitCode != 0) {
      throw Exception('Unable to start app: ${result.stderr}');
    }
  }

  /// Runs `adb logcat`.
  Future<Process> logcat({String? filter, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'logcat',
      // This arg prevents old logs from being displayed.
      ...['-T', '1'],
      if (filter != null) ...['-s', filter],
    ];
    return _stream(args.join(' '));
  }
}
