import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:code_push_runtime/src/environment.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Reports Dart-level crashes to the self-hosted control plane, so they can be
/// symbolicated there against the symbols retained for the running patch.
///
/// Dart-level on purpose. A release build's stack trace is a Dart trace, and
/// the symbols the CLI retains (`--split-debug-info`) resolve exactly that.
/// Native frames would need a crashpad-style collector in the engine, which is
/// a much larger and separate piece of work.
class CrashReporter {
  /// Creates a reporter posting to [environment]'s control plane.
  CrashReporter({
    required this.environment,
    required this.releaseVersion,
    required this.clientId,
    this.patchNumber,
    http.Client? httpClient,
    DeviceAbi? abi,
  }) : _http = httpClient ?? http.Client(),
       _abi = abi ?? DeviceAbi.current();

  /// The app and control plane to report to.
  final ShorebirdEnvironment environment;

  /// The release this build came from, e.g. `1.0.0+1`.
  final String releaseVersion;

  /// The patch running when the crash happened, or null on an unpatched
  /// release. Without it the server has no retained symbol set to resolve
  /// against, so the report is stored raw.
  final int? patchNumber;

  /// A stable per-install identifier, used only to group reports.
  final String clientId;

  final http.Client _http;
  final DeviceAbi _abi;

  /// The handlers this reporter replaced, so [uninstall] can restore them
  /// rather than leaving an app with its error handling silently removed.
  FlutterExceptionHandler? _previousOnError;
  ErrorCallback? _previousDispatcherOnError;
  bool _installed = false;

  /// Starts capturing errors.
  ///
  /// Chains rather than replaces: whatever was handling errors before still
  /// runs, because an app that installed Crashlytics or its own logger must not
  /// lose it by adding this. In debug, Flutter's default handler is what prints
  /// the red screen and the console trace — silencing that would make this
  /// package actively harmful to develop against.
  void install() {
    if (_installed) return;
    _installed = true;

    _previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      unawaited(
        report(
          kind: 'FlutterError',
          message: details.exceptionAsString(),
          stack: details.stack,
        ),
      );
      _previousOnError?.call(details);
    };

    // Covers errors outside the framework's own zone — async gaps, isolate
    // callbacks — which FlutterError.onError never sees.
    _previousDispatcherOnError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(
        report(
          kind: error.runtimeType.toString(),
          message: '$error',
          stack: stack,
        ),
      );
      // Preserve the previous verdict on whether the error was handled;
      // defaulting to `true` would swallow crashes an app expected to surface.
      return _previousDispatcherOnError?.call(error, stack) ?? false;
    };
  }

  /// Restores the handlers in place before [install].
  void uninstall() {
    if (!_installed) return;
    _installed = false;
    FlutterError.onError = _previousOnError;
    PlatformDispatcher.instance.onError = _previousDispatcherOnError;
  }

  /// Posts one report. Never throws and never rethrows.
  ///
  /// The caller is an app that is already failing; a reporter that can itself
  /// throw — or that awaits a slow network on the error path — turns one fault
  /// into two. The server side is deliberately unfailable for the same reason.
  Future<void> report({
    required String kind,
    required String message,
    StackTrace? stack,
  }) async {
    try {
      await _http.post(
        environment.baseUrl.resolve('crashes'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'app_id': environment.appId,
          'client_id': clientId,
          'release_version': releaseVersion,
          'patch_number': patchNumber,
          'platform': _abi.platform,
          'arch': _abi.arch,
          'kind': kind,
          'message': message,
          'stack': stack?.toString(),
          'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        }),
      );
    } on Object {
      // Swallowed on purpose. A dropped crash report is a lost diagnostic; a
      // thrown one from inside an error handler is a crash loop.
    }
  }
}
