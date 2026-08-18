// cspell:ignore Zvbw WRVJTSU VVFRF
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/dart_define_from_file.dart';
import 'package:test/test.dart';

// G4.1. The rules here are Flutter's, not ours, and none of them is guessed:
// each traces to `flutter_command.dart` in the pinned checkout
// (c15ef6379403a0a55531a058bdb2c8e55bc05c98), and the whole set is measured
// against Flutter ITSELF by selfhost/engine/route_b/probes/g41b_define_from_file.sh,
// which runs `flutter build ios --config-only` and reads back the DART_DEFINES
// Flutter wrote.
//
// So these tests pin the port; the probe is what says the port is right. Neither
// is sufficient alone: a unit test can only agree with its author.
void main() {
  late Directory tempDir;

  setUp(
    () => tempDir = Directory.systemTemp.createTempSync('define_from_file'),
  );
  tearDown(() => tempDir.deleteSync(recursive: true));

  void write(String name, String contents) =>
      File(p.join(tempDir.path, name)).writeAsStringSync(contents);

  DartDefineFromFileExpansion expand(List<String> args) =>
      DartDefineFromFileExpansion.expand(args, workingDirectory: tempDir.path);

  group('DartDefineFromFileExpansion', () {
    test('no option is a resolved empty set, not a failure', () {
      // The distinction the whole class exists for. "The user passed no files"
      // is a known configuration; "a file could not be read" is not.
      final expansion = expand(['--dart-define=A=1']);
      expect(expansion.ok, isTrue);
      expect(expansion.defines, isEmpty);
    });

    test('a missing file fails and names the path', () {
      final expansion = expand(['--dart-define-from-file=absent.json']);
      expect(expansion.ok, isFalse);
      expect(expansion.failureReason, contains('absent.json'));
      expect(expansion.defines, isEmpty);
    });

    group('json', () {
      test('non-string values become their Dart toString', () {
        // `extractDartDefines` writes `'$key=$value'` over the decoded JSON, so
        // a number, a bool and a nested object all reach the compiler
        // stringified — the nested case being the one nobody would guess.
        write('d.json', '{"S":"s","N":7,"B":true,"NIL":null,"O":{"b":1}}');
        expect(expand(['--dart-define-from-file=d.json']).defines, {
          'S': 's',
          'N': '7',
          'B': 'true',
          'NIL': 'null',
          'O': '{b: 1}',
        });
      });

      test('malformed json fails rather than yielding a partial set', () {
        write('d.json', '{"K": ');
        final expansion = expand(['--dart-define-from-file=d.json']);
        expect(expansion.ok, isFalse);
        expect(expansion.defines, isEmpty);
      });

      test('later files win, per key', () {
        write('a.json', '{"DUP":"first","A":"1"}');
        write('b.json', '{"DUP":"second","B":"2"}');
        expect(
          expand([
            '--dart-define-from-file=a.json',
            '--dart-define-from-file=b.json',
          ]).defines,
          {'DUP': 'second', 'A': '1', 'B': '2'},
        );
      });
    });

    group('.env', () {
      test('quoting and comments follow DotEnvRegex', () {
        // Every line here is a rule that a plain `split('=')` gets wrong.
        write('d.env', '''
# a comment line
PLAIN=value # trailing comment
QUOTED="foo#bar=baz"
SINGLE='sq value'
BACKTICK=`bq value`
EMPTY=
SPACED = spaced
''');
        expect(expand(['--dart-define-from-file=d.env']).defines, {
          'PLAIN': 'value',
          'QUOTED': 'foo#bar=baz',
          'SINGLE': 'sq value',
          'BACKTICK': 'bq value',
          'EMPTY': '',
          'SPACED': 'spaced',
        });
      });

      test('a multi-line value fails, as Flutter refuses it too', () {
        write('d.env', 'K="""\nstill going\n"""');
        final expansion = expand(['--dart-define-from-file=d.env']);
        expect(expansion.ok, isFalse);
        expect(expansion.failureReason, contains('multi-line'));
      });

      test('a line that is not a property fails', () {
        write('d.env', 'this is not a property');
        expect(expand(['--dart-define-from-file=d.env']).ok, isFalse);
      });

      test('a leading { selects json, even in a .env file', () {
        // Flutter's discriminator is the first character after trimming, not
        // the extension. Reproducing that keeps a misnamed file behaving the
        // way the build behaved.
        write('d.env', '{"K":"json-after-all"}');
        expect(expand(['--dart-define-from-file=d.env']).defines, {
          'K': 'json-after-all',
        });
      });
    });

    group('pathsIn', () {
      test('finds both spellings, in order, and nothing else', () {
        expect(
          DartDefineFromFileExpansion.pathsIn([
            '--dart-define=A=1',
            '--dart-define-from-file=one.json',
            '--dart-define-from-file',
            'two.env',
            '--obfuscate',
          ]),
          ['one.json', 'two.env'],
        );
      });
    });

    group('decodeGeneratedXcconfig', () {
      File xcconfig(String contents) =>
          File(p.join(tempDir.path, 'Generated.xcconfig'))
            ..writeAsStringSync(contents);

      test('decodes the base64 csv Flutter writes', () {
        // The exact bytes of the flavored fixture's own line, so this test
        // fails if Flutter's encoding ever changes under us.
        final file = xcconfig(
          'FLUTTER_ROOT=/x\n'
          'DART_DEFINES=RkxVVFRFUl9BUFBfRkxBVk9SPWZvbw==,'
          'RkxVVFRFUl9WRVJTSU9OPTMuNDQuOA==\n'
          'FLAVOR=foo\n',
        );
        expect(DartDefineFromFileExpansion.decodeGeneratedXcconfig(file), {
          'FLUTTER_APP_FLAVOR': 'foo',
          'FLUTTER_VERSION': '3.44.8',
        });
      });

      test('no DART_DEFINES line is null, not an empty map', () {
        // Flutter omits the line entirely when there are no defines
        // (`if (dartDefines.isNotEmpty)`), and "Flutter said nothing" must not
        // read as "Flutter said there are none" — the caller declines on null.
        expect(
          DartDefineFromFileExpansion.decodeGeneratedXcconfig(
            xcconfig('FLUTTER_ROOT=/x\n'),
          ),
          isNull,
        );
      });

      test('an absent or undecodable file is null', () {
        expect(
          DartDefineFromFileExpansion.decodeGeneratedXcconfig(
            File(p.join(tempDir.path, 'nope.xcconfig')),
          ),
          isNull,
        );
        expect(
          DartDefineFromFileExpansion.decodeGeneratedXcconfig(
            xcconfig('DART_DEFINES=!!!not-base64!!!\n'),
          ),
          isNull,
        );
      });
    });

    group('disagreementWith', () {
      test('agreement is empty, disagreement names the keys', () {
        write('d.json', '{"A":"1","B":"2"}');
        final expansion = expand(['--dart-define-from-file=d.json']);
        expect(expansion.disagreementWith({'A': '1', 'B': '2'}), isEmpty);
        expect(expansion.disagreementWith({'A': '1', 'B': 'other'}), ['B']);
        // A key we claim and Flutter never resolved is a disagreement too:
        // silence is not agreement.
        expect(expansion.disagreementWith({'A': '1'}), ['B']);
      });

      test('keys only Flutter has are NOT a disagreement', () {
        // Flutter injects FLUTTER_VERSION and its siblings into every build.
        // This expansion is only answerable for what the files said.
        write('d.json', '{"A":"1"}');
        expect(
          expand([
            '--dart-define-from-file=d.json',
          ]).disagreementWith({'A': '1', 'FLUTTER_VERSION': '3.44.8'}),
          isEmpty,
        );
      });

      test('exempt keys are skipped even when they differ', () {
        // FLUTTER_APP_FLAVOR is exempt on measured grounds: the xcconfig holds
        // the CLI token while the shipped kernel gets the Xcode scheme's
        // casing. Exempting it is a decision, so it is stated at the call site
        // and tested here rather than hidden in the comparator.
        write('d.json', '{"FLUTTER_APP_FLAVOR":"Foo"}');
        final expansion = expand(['--dart-define-from-file=d.json']);
        expect(expansion.disagreementWith({'FLUTTER_APP_FLAVOR': 'foo'}), [
          'FLUTTER_APP_FLAVOR',
        ]);
        expect(
          expansion.disagreementWith(
            {'FLUTTER_APP_FLAVOR': 'foo'},
            exempt: const {'FLUTTER_APP_FLAVOR'},
          ),
          isEmpty,
        );
      });
    });
  });
}
