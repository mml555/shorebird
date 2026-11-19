import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_dependency_changes.dart';
import 'package:shorebird_cli/src/route_b_retention.dart';
import 'package:test/test.dart';

RouteBCoverage _coverage({
  List<String> changed = const [],
  List<String> removed = const [],
  List<Map<String, Object>> rejections = const [],
}) => RouteBCoverage.fromJson(
  jsonEncode({
    'analysisVersion': supportedRouteBAnalysisVersion,
    'verdict': rejections.isEmpty ? 'accept' : 'reject',
    'changed': changed,
    'added': <String>[],
    'removed': removed,
    'patchable': changed,
    'conditional': <String>[],
    'rejections': rejections,
    'refusalSummary': null,
  }),
);

void main() {
  group('readRouteBPackages', () {
    late Directory root;
    late Directory flutter;
    late Directory project;
    late File config;

    setUp(() {
      root = Directory.systemTemp.createTempSync('dep_changes');
      flutter = Directory(p.join(root.path, 'flutter'))..createSync();
      project = Directory(p.join(root.path, 'app'))..createSync();
      config = File(p.join(project.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true);
    });

    tearDown(() => root.deleteSync(recursive: true));

    RouteBPackages read(List<Map<String, String>> packages) {
      config.writeAsStringSync(
        jsonEncode({'configVersion': 2, 'packages': packages}),
      );
      return readRouteBPackages(
        packageConfig: config,
        projectRoot: project,
        flutterRoot: flutter,
      );
    }

    String under(String path) => p.toUri(p.join(root.path, path)).toString();

    test('classifies each package by where it comes from', () {
      final packages = read([
        {'name': 'app', 'rootUri': '../'},
        {'name': 'local', 'rootUri': '../packages/local'},
        {'name': 'tally', 'rootUri': '../../packages/tally'},
        {
          'name': 'collection',
          'rootUri': under('.pub-cache/hosted/pub.dev/collection-1.19.1'),
        },
        {'name': 'forked', 'rootUri': under('.pub-cache/git/forked-0123abcd')},
        {'name': 'flutter_gen', 'rootUri': 'flutter_gen'},
        {'name': 'remote', 'rootUri': 'https://example.com/remote/'},
        {'name': 'flutter', 'rootUri': under('flutter/packages/flutter')},
        {'name': 'sky_engine', 'rootUri': under('flutter/bin/cache/pkg')},
      ]);

      expect(packages.flutterSdk, {'flutter', 'sky_engine'});
      expect(packages['local'].source, RouteBPackageSource.path);
      expect(packages['local'].root, p.join('packages', 'local'));
      expect(packages['tally'].source, RouteBPackageSource.path);
      expect(packages['tally'].root, p.join(root.path, 'packages', 'tally'));
      expect(packages['collection'].source, RouteBPackageSource.hosted);
      expect(packages['collection'].version, '1.19.1');
      expect(packages['forked'].source, RouteBPackageSource.git);
      expect(packages['flutter_gen'].source, RouteBPackageSource.generated);
      expect(packages['remote'].source, RouteBPackageSource.path);
      expect(packages['remote'].root, 'https://example.com/remote/');
      expect(packages['gone'].source, RouteBPackageSource.absent);
      expect(packages['app'].source, RouteBPackageSource.path);
    });

    test('a package under .dart_tool/flutter_gen is generated whatever its '
        'name', () {
      final packages = read([
        {'name': 'l10n', 'rootUri': 'flutter_gen/l10n'},
      ]);
      expect(packages['l10n'].source, RouteBPackageSource.generated);
    });

    test('throws FormatException on a config it cannot read', () {
      RouteBPackages readIt() => readRouteBPackages(
        packageConfig: config,
        projectRoot: project,
        flutterRoot: flutter,
      );
      config.writeAsStringSync('{not json');
      expect(readIt, throwsFormatException);
      config.writeAsStringSync(jsonEncode({'configVersion': 2}));
      expect(readIt, throwsFormatException);
      config.deleteSync();
      expect(readIt, throwsFormatException);
    });
  });

  group('routeBDependencyChanges', () {
    test('collects changed, declaration, removed and rejected-added members '
        'by package, outside the app and the Flutter SDK', () {
      final changes = routeBDependencyChanges(
        _coverage(
          changed: [
            'package:tally/tally.dart#tallyLabel',
            'package:app/main.dart#build',
            'package:flutter/src/painting/box.dart#Box.get:hashCode',
            'dart:core#print',
          ],
          removed: [
            'package:tally/tally.dart#Counter.toString',
            'package:old_name/old_name.dart#greet',
            'package:app/main.dart#gone',
          ],
          rejections: [
            {
              'target': 'package:tally/tally.dart#kPrefix',
              'category': 'declaration',
              'reason': 'a const changed',
            },
            {
              'target': 'package:tally/tally.dart#Counter.==',
              'category': 'added',
              'reason': 'a new override',
            },
            {
              'target': 'package:tally/tally.dart#tallyLabel',
              'category': 'unreachable',
              'reason': 'not reached',
            },
            {
              'target': 'package:app/main.dart#kValue',
              'category': 'declaration',
              'reason': 'a const changed',
            },
          ],
        ),
        appPackageName: 'app',
        flutterSdk: {'flutter'},
      );
      expect(changes.keys, ['old_name', 'tally']);
      expect(changes['old_name'], [
        (
          target: 'package:old_name/old_name.dart#greet',
          kind: RouteBDependencyChangeKind.removed,
        ),
      ]);
      expect(changes['tally'], [
        (
          target: 'package:tally/tally.dart#Counter.==',
          kind: RouteBDependencyChangeKind.added,
        ),
        (
          target: 'package:tally/tally.dart#Counter.toString',
          kind: RouteBDependencyChangeKind.removed,
        ),
        (
          target: 'package:tally/tally.dart#kPrefix',
          kind: RouteBDependencyChangeKind.declaration,
        ),
        (
          target: 'package:tally/tally.dart#tallyLabel',
          kind: RouteBDependencyChangeKind.changed,
        ),
      ]);
    });

    test('is empty when only the app changed', () {
      expect(
        routeBDependencyChanges(
          _coverage(changed: ['package:app/main.dart#build']),
          appPackageName: 'app',
        ),
        isEmpty,
      );
    });
  });

  group('describeRouteBDependencyChanges', () {
    const packages = RouteBPackages(
      packages: {
        'tally': RouteBPackage(
          name: 'tally',
          source: RouteBPackageSource.path,
          root: '../packages/tally',
        ),
        'collection': RouteBPackage(
          name: 'collection',
          source: RouteBPackageSource.hosted,
          version: '1.19.1',
        ),
        'flutter_gen': RouteBPackage(
          name: 'flutter_gen',
          source: RouteBPackageSource.generated,
        ),
      },
      flutterSdk: {},
    );

    Map<String, List<RouteBDependencyChange>> of(
      Map<String, List<String>> changed,
    ) => {
      for (final MapEntry(:key, :value) in changed.entries)
        key: [
          for (final target in value)
            (target: target, kind: RouteBDependencyChangeKind.changed),
        ],
    };

    test('names each package and its source, and how to get out', () {
      final message = describeRouteBDependencyChanges(
        of({
          'tally': ['package:tally/tally.dart#tallyLabel'],
        }),
        packages: packages,
        appPackageName: 'untab',
      );
      expect(
        message,
        allOf(
          contains("outside the app's own package (untab)"),
          contains('  tally (path package at ../packages/tally)\n'),
          contains('    changed     package:tally/tally.dart#tallyLabel\n'),
          contains('replaces functions of package:untab only'),
          contains('Revert them, or ship them in a new release.'),
        ),
      );
      expect(
        message,
        allOf(
          isNot(contains('pubspec.lock')),
          isNot(contains('.arb')),
          endsWith('\n\nNothing was uploaded.'),
        ),
      );
    });

    test('adds the hint for each kind of package', () {
      final message = describeRouteBDependencyChanges(
        of({
          'collection': ['package:collection/collection.dart#groupBy'],
          'flutter_gen': ['package:flutter_gen/gen_l10n/l.dart#L.get:title'],
          'gone': ['package:gone/gone.dart#f'],
        }),
        packages: packages,
        appPackageName: 'untab',
      );
      expect(
        message,
        allOf(
          contains('collection (hosted, 1.19.1 in this build)'),
          contains("restore the release's pubspec.lock"),
          contains('flutter_gen (localizations generated from your .arb'),
          contains('an .arb change needs a new release'),
          contains("gone (in the release, not in this build's dependencies)"),
          contains('(removed, or renamed) needs a new release'),
        ),
      );
    });

    test('lists at most the limit, across packages, then how many more', () {
      final message = describeRouteBDependencyChanges(
        of({
          'collection': [
            for (var i = 0; i < 3; i++) 'package:collection/c#c$i',
          ],
          'tally': [for (var i = 0; i < 4; i++) 'package:tally/t#t$i'],
        }),
        packages: packages,
        appPackageName: 'untab',
        limit: 5,
      );
      expect(message, contains('package:tally/t#t1'));
      expect(message, isNot(contains('package:tally/t#t2')));
      expect(message, contains('  ... and 2 more'));
    });
  });

  // The dependency pass leaves a NEW dependency member the app calls to
  // retention, which refuses it before the pass runs: the release's interface
  // names the dependency members its own code called, and nothing else.
  group('a call to a new dependency member', () {
    const interface = '''
callable:
  - library: 'package:app/main.dart'
  - library: 'package:tally/tally.dart'
    member: 'tallyLabel'
can-be-used-as-type:
  - library: 'dart:core'
    class: ['String']
''';
    const grants = '''
{
  "policy": "p2",
  "privateTopLevelCallable": [],
  "privateStaticsCallable": [],
  "privateInstanceCallable": [],
  "privateClassPublicMembers": [],
  "privateClassesConstructible": [],
  "refused": []
}
''';
    const target = 'package:app/main.dart#build';

    String? refusal(Map<String, Object?> reference) =>
        RouteBRetention.parse(
          interface,
          capabilities: RouteBCapabilities.fromJson(grants),
          skipKeptCheck: true,
        ).refusalForTarget(
          RouteBCoverage.fromJson(
            jsonEncode({
              'analysisVersion': 18,
              'verdict': 'accept',
              'changed': [target],
              'carried': <String>[],
              'callers': <String, Object>{},
              'added': <String>[],
              'helpers': <String>[],
              'unusedHelpers': <String>[],
              'removed': <String>[],
              'patchable': [target],
              'conditional': <String>[],
              'sources': <String, Object?>{},
              'externalReferences': {
                target: [reference],
              },
              'rejections': <Object>[],
              'refusalSummary': null,
            }),
          ),
          target,
        );

    Map<String, Object?> topLevel(String library, String member) => {
      'kind': 'top-level',
      'library': library,
      'class': null,
      'member': member,
      'private': false,
    };

    test('is refused by retention, in a library the release kept in part', () {
      expect(
        refusal(topLevel('package:tally/tally.dart', 'tallyNew')),
        allOf(contains('tallyNew'), contains('never used in its own code')),
      );
    });

    test('is refused by retention, in a package the release never had', () {
      expect(
        refusal(topLevel('package:fresh/fresh.dart', 'hello')),
        allOf(contains('hello'), contains('never used in its own code')),
      );
    });

    test('a member the release called is not', () {
      expect(
        refusal(topLevel('package:tally/tally.dart', 'tallyLabel')),
        isNull,
      );
    });
  });
}
