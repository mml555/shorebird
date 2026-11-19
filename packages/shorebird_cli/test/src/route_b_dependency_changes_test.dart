import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_dependency_changes.dart';
import 'package:test/test.dart';

void main() {
  group('routeBDependencyIncludePrefixes', () {
    late Directory root;
    late Directory flutter;
    late File config;

    setUp(() {
      root = Directory.systemTemp.createTempSync('dep_changes');
      flutter = Directory(p.join(root.path, 'flutter'))..createSync();
      config = File(
        p.join(root.path, 'app', '.dart_tool', 'package_config.json'),
      )..createSync(recursive: true);
    });

    tearDown(() => root.deleteSync(recursive: true));

    void write(Object json) => config.writeAsStringSync(jsonEncode(json));

    test('lists every package but the app and the Flutter SDK', () {
      write({
        'configVersion': 2,
        'packages': [
          {'name': 'app', 'rootUri': '../'},
          {'name': 'tally', 'rootUri': '../../packages/tally'},
          {
            'name': 'collection',
            'rootUri': 'file:///pub-cache/hosted/collection-1.19.1',
          },
          {
            'name': 'flutter',
            'rootUri': p
                .toUri(p.join(flutter.path, 'packages', 'flutter'))
                .toString(),
          },
          {'name': 'sky_engine', 'rootUri': p.toUri(flutter.path).toString()},
        ],
      });
      expect(
        routeBDependencyIncludePrefixes(
          packageConfig: config,
          appPackageName: 'app',
          flutterRoot: flutter,
        ),
        ['package:collection/', 'package:tally/'],
      );
    });

    test('a relative root under the Flutter SDK is the SDK too', () {
      // .dart_tool/../../flutter/packages/flutter_test
      write({
        'packages': [
          {'name': 'flutter_test', 'rootUri': '../../flutter/packages/test'},
        ],
      });
      expect(
        routeBDependencyIncludePrefixes(
          packageConfig: config,
          appPackageName: 'app',
          flutterRoot: flutter,
        ),
        isEmpty,
      );
    });

    test('throws on a missing or malformed config', () {
      List<String> prefixes() => routeBDependencyIncludePrefixes(
        packageConfig: config,
        appPackageName: 'app',
        flutterRoot: flutter,
      );
      config.deleteSync();
      expect(prefixes, throwsFormatException);
      config.writeAsStringSync('{"configVersion": 2}');
      expect(prefixes, throwsFormatException);
    });
  });

  group('routeBDependencyChanges', () {
    RouteBCoverage coverage({
      List<String> changed = const [],
      List<Map<String, Object>> rejections = const [],
    }) => RouteBCoverage.fromJson(
      jsonEncode({
        'analysisVersion': 14,
        'verdict': 'accept',
        'changed': changed,
        'added': <String>[],
        'removed': <String>[],
        'patchable': <String>[],
        'conditional': <String>[],
        'rejections': rejections,
        'refusalSummary': null,
      }),
    );

    test('changed members and declarations outside the app, sorted', () {
      expect(
        routeBDependencyChanges(
          coverage(
            changed: [
              'package:tally/tally.dart#tallyLabel',
              'package:app/main.dart#build',
            ],
            rejections: [
              {
                'target': 'package:tally/tally.dart#kPrefix',
                'category': 'declaration',
                'reason': 'const changed',
              },
              {
                'target': 'package:tally/tally.dart#unused',
                'category': 'unreachable',
                'reason': 'not kept',
              },
            ],
          ),
          appPrefixes: ['package:app/'],
        ),
        [
          'package:tally/tally.dart#kPrefix',
          'package:tally/tally.dart#tallyLabel',
        ],
      );
    });

    test('nothing changed is nothing', () {
      expect(
        routeBDependencyChanges(coverage(), appPrefixes: ['package:app/']),
        isEmpty,
      );
    });
  });
}
