import 'dart:convert';
import 'dart:io';

import 'package:code_push_runtime/code_push_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group(CrashReporter, () {
    final environment = ShorebirdEnvironment(
      appId: 'app-1',
      baseUrl: Uri.parse('https://cps.test/'),
    );

    late List<Map<String, Object?>> posted;
    late CrashReporter reporter;

    CrashReporter build({
      int? patchNumber = 3,
      bool failRequests = false,
      DeviceAbi? abi,
    }) => CrashReporter(
      environment: environment,
      releaseVersion: '1.0.0+1',
      clientId: 'client-1',
      patchNumber: patchNumber,
      abi: abi ?? const DeviceAbi(platform: 'android', arch: 'arm64'),
      httpClient: MockClient((request) async {
        if (failRequests) throw const SocketException('offline');
        posted.add(jsonDecode(request.body) as Map<String, Object?>);
        return http.Response('{"stored":true}', HttpStatus.ok);
      }),
    );

    setUp(() {
      posted = [];
      reporter = build();
    });

    tearDown(() => reporter.uninstall());

    test('posts the tuple symbolication needs', () async {
      await reporter.report(
        kind: 'StateError',
        message: 'boom',
        stack: StackTrace.fromString('#0 main'),
      );

      final body = posted.single;
      // (app, release_version, patch_number, platform, arch) is exactly the
      // join the server uses to find the retained symbol set.
      expect(body['app_id'], equals('app-1'));
      expect(body['release_version'], equals('1.0.0+1'));
      expect(body['patch_number'], equals(3));
      expect(body['platform'], equals('android'));
      expect(body['arch'], equals('arm64'));
      expect(body['kind'], equals('StateError'));
      expect(body['message'], equals('boom'));
      expect(body['stack'], contains('#0 main'));
      expect(body['client_id'], equals('client-1'));
      expect(body['timestamp'], isA<int>());
    });

    test('reports an unpatched release with a null patch number', () async {
      reporter = build(patchNumber: null);

      await reporter.report(kind: 'StateError', message: 'boom');

      expect(posted.single['patch_number'], isNull);
    });

    test('never throws when the network fails', () async {
      // The caller is an app that is already failing; a reporter that throws
      // from inside an error handler turns one fault into a loop.
      reporter = build(failRequests: true);

      await expectLater(
        reporter.report(kind: 'StateError', message: 'boom'),
        completes,
      );
    });

    group('install', () {
      test('captures FlutterError and chains the previous handler', () async {
        var previousRan = false;
        final previous = FlutterError.onError;
        FlutterError.onError = (_) => previousRan = true;
        addTearDown(() => FlutterError.onError = previous);

        reporter.install();
        FlutterError.onError!(
          FlutterErrorDetails(exception: StateError('kaboom')),
        );
        await Future<void>.delayed(Duration.zero);

        expect(posted.single['kind'], equals('FlutterError'));
        expect(posted.single['message'], contains('kaboom'));
        // An app with Crashlytics or its own logger must not lose it, and in
        // debug the default handler is what prints the red screen.
        expect(previousRan, isTrue);
      });

      test('captures platform dispatcher errors', () async {
        final previous = PlatformDispatcher.instance.onError;
        addTearDown(() => PlatformDispatcher.instance.onError = previous);

        reporter.install();
        PlatformDispatcher.instance.onError!(
          StateError('async kaboom'),
          StackTrace.empty,
        );
        await Future<void>.delayed(Duration.zero);

        expect(posted.single['kind'], equals('StateError'));
        expect(posted.single['message'], contains('async kaboom'));
      });

      test('preserves the previous handled verdict', () async {
        final previous = PlatformDispatcher.instance.onError;
        PlatformDispatcher.instance.onError = (_, _) => true;
        addTearDown(() => PlatformDispatcher.instance.onError = previous);

        reporter.install();
        final handled = PlatformDispatcher.instance.onError!(
          StateError('x'),
          StackTrace.empty,
        );

        // Returning true unconditionally would swallow crashes the app expected
        // to surface; returning false would resurface ones it had handled.
        expect(handled, isTrue);
      });

      test('reports unhandled when nothing handled it before', () async {
        final previous = PlatformDispatcher.instance.onError;
        PlatformDispatcher.instance.onError = null;
        addTearDown(() => PlatformDispatcher.instance.onError = previous);

        reporter.install();
        final handled = PlatformDispatcher.instance.onError!(
          StateError('x'),
          StackTrace.empty,
        );

        expect(handled, isFalse);
      });

      test('installing twice does not double-report', () async {
        final previous = FlutterError.onError;
        addTearDown(() => FlutterError.onError = previous);

        reporter
          ..install()
          ..install();
        FlutterError.onError!(
          FlutterErrorDetails(exception: StateError('once')),
        );
        await Future<void>.delayed(Duration.zero);

        expect(posted, hasLength(1));
      });

      test('uninstall restores the handlers it replaced', () {
        final previous = FlutterError.onError;
        final previousDispatcher = PlatformDispatcher.instance.onError;

        reporter
          ..install()
          ..uninstall();

        expect(FlutterError.onError, same(previous));
        expect(PlatformDispatcher.instance.onError, same(previousDispatcher));
      });
    });
  });
}
