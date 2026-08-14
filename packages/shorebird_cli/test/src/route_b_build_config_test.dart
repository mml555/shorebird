import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/route_b_release_kernels.dart';
import 'package:test/test.dart';

// G4.1. The matrix here is the release→patch acceptance table, and every row's
// expectation traces to a MEASURED semantic rather than an assumed one — see
// selfhost/engine/route_b/probes/g41_define_semantics.sh, which compiles through
// the release's own gen_kernel path:
//
//   1 duplicates are last-wins        -> the effective set is a map
//   2 key order is byte-irrelevant    -> compare sorted
//   3 -Dk= is a defined empty string  -> absent != empty
void main() {
  RouteBBuildConfig config(List<String> args) =>
      RouteBBuildConfig.fromBuildArgs(args)!;

  group('RouteBBuildConfig', () {
    test('the two representations stay separate', () {
      final c = config(['--release', '--dart-define=A=1']);
      // rawArgs keeps everything, including args that are not defines: it is for
      // audit, and throwing away context would defeat that.
      expect(c.rawArgs, ['--release', '--dart-define=A=1']);
      // effectiveDefines carries only what the compiler received as defines.
      expect(c.effectiveDefines, {'A': '1'});
    });

    group('the acceptance matrix', () {
      test('no defines / no defines -> agrees', () {
        expect(config([]).agreesWith(config([])), isTrue);
      });

      test('A=1 / A=1 -> agrees', () {
        expect(
          config([
            '--dart-define=A=1',
          ]).agreesWith(config(['--dart-define=A=1'])),
          isTrue,
        );
      });

      test('A=1 / A=2 -> disagrees, naming the key', () {
        final release = config(['--dart-define=A=1']);
        final patch = config(['--dart-define=A=2']);
        expect(release.agreesWith(patch), isFalse);
        expect(
          release.describeDifference(patch),
          contains('A: "1" in the release, "2" in this patch'),
        );
      });

      test('A=1 / none -> disagrees', () {
        final release = config(['--dart-define=A=1']);
        final patch = config([]);
        expect(release.agreesWith(patch), isFalse);
        expect(
          release.describeDifference(patch),
          contains('A: "1" in the release, absent in this patch'),
        );
      });

      test('none / A=1 -> disagrees', () {
        final release = config([]);
        final patch = config(['--dart-define=A=1']);
        expect(release.agreesWith(patch), isFalse);
        expect(
          release.describeDifference(patch),
          contains('A: absent in the release, "1" in this patch'),
        );
      });

      test('redundant duplicates with the same EFFECTIVE set -> agrees', () {
        // Probe rule 1: last-wins. So specifying A twice, ending at the same
        // value, is the same configuration and must not be refused.
        expect(
          config([
            '--dart-define=A=0',
            '--dart-define=A=1',
          ]).agreesWith(config(['--dart-define=A=1'])),
          isTrue,
        );
      });

      test('duplicates ending at a DIFFERENT value -> disagrees', () {
        expect(
          config([
            '--dart-define=A=1',
            '--dart-define=A=2',
          ]).agreesWith(config(['--dart-define=A=1'])),
          isFalse,
        );
      });

      test('changed order, same values -> agrees', () {
        // Probe rule 2: the two orders produce byte-identical kernels, so
        // refusing this pair would refuse a patch with nothing wrong with it.
        expect(
          config([
            '--dart-define=a=1',
            '--dart-define=b=2',
          ]).agreesWith(config(['--dart-define=b=2', '--dart-define=a=1'])),
          isTrue,
        );
      });
    });

    group('G4.3: obfuscation is effective, its symbol path is not', () {
      // Every expectation here traces to probes/g43_obfuscation_semantics.sh,
      // which compiles one kernel through gen_snapshot five ways:
      //   --obfuscate            changes the STRIPPED program  -> semantic
      //   --split-debug-info     changes the ELF, not the program -> output only
      //   path A vs path B       changes the ELF, not the program -> not semantic
      test('false / false -> agrees', () {
        expect(config([]).agreesWith(config([])), isTrue);
      });

      test('true / true -> agrees', () {
        expect(
          config(['--obfuscate']).agreesWith(config(['--obfuscate'])),
          isTrue,
        );
      });

      test('true / false -> refuses, naming obfuscation', () {
        final release = config(['--obfuscate']);
        final patch = config([]);
        expect(release.agreesWith(patch), isFalse);
        expect(
          release.describeDifference(patch),
          contains('--obfuscate: on in the release, off in this patch'),
        );
      });

      test('false / true -> refuses', () {
        final release = config([]);
        final patch = config(['--obfuscate']);
        expect(release.agreesWith(patch), isFalse);
        expect(
          release.describeDifference(patch),
          contains('--obfuscate: off in the release, on in this patch'),
        );
      });

      test('same obfuscation, DIFFERENT symbol paths -> agrees', () {
        // The case that would break if the path were fingerprinted: two machines
        // emitting the byte-identical program would become incompatible purely
        // because their filesystem layouts differ.
        final a = config([
          '--obfuscate',
          '--split-debug-info=/builds/machine-a/symbols',
        ]);
        final b = config([
          '--obfuscate',
          '--split-debug-info=/Users/someone/other/symbols',
        ]);
        expect(a.agreesWith(b), isTrue);
        expect(a.describeDifference(b), isEmpty);
      });

      test('same obfuscation, one side with NO symbol path -> agrees', () {
        expect(
          config([
            '--obfuscate',
            '--split-debug-info=/tmp/syms',
          ]).agreesWith(config(['--obfuscate'])),
          isTrue,
        );
      });

      test('the path is still RECORDED, in both spellings', () {
        // Excluded from compatibility, not thrown away: a reader debugging a
        // release needs to know where the symbols went.
        expect(
          config(['--split-debug-info=/tmp/syms']).splitDebugInfoPath,
          '/tmp/syms',
        );
        expect(
          config(['--split-debug-info', '/tmp/syms']).splitDebugInfoPath,
          '/tmp/syms',
        );
      });

      test('the path is absent from the canonical form', () {
        // Asserted directly, so a later change that folds it in fails here rather
        // than in the field.
        expect(
          config([
            '--obfuscate',
            '--split-debug-info=/tmp/syms',
          ]).canonicalForm,
          isNot(contains('/tmp/syms')),
        );
      });

      test('obfuscation survives the json round trip', () {
        final c = config(['--obfuscate', '--split-debug-info=/tmp/syms']);
        final back = RouteBBuildConfig.fromJson(c.toJson());
        expect(back.obfuscate, isTrue);
        expect(back.splitDebugInfoPath, '/tmp/syms');
        expect(back.agreesWith(c), isTrue);
      });

      test('obfuscation and defines are independent', () {
        expect(
          config([
            '--obfuscate',
            '--dart-define=A=1',
          ]).agreesWith(config(['--dart-define=A=1'])),
          isFalse,
        );
        expect(
          config([
            '--obfuscate',
            '--dart-define=A=1',
          ]).agreesWith(config(['--obfuscate', '--dart-define=A=1'])),
          isTrue,
        );
      });
    });

    group('empty and absent are different configurations', () {
      test('A= is defined-empty, not absent', () {
        // Probe rule 3. A "drop empty values" canonicaliser would call these
        // equal, and they compile differently.
        expect(
          config(['--dart-define=A=']).agreesWith(config([])),
          isFalse,
        );
        expect(config(['--dart-define=A=']).effectiveDefines, {'A': ''});
      });

      test('a bare --dart-define=A is the same as A=', () {
        expect(
          config(['--dart-define=A']).agreesWith(config(['--dart-define=A='])),
          isTrue,
        );
      });
    });

    group('G4.2: flavor is one define, resolved the way Flutter does', () {
      // Measured in probes/g42_flavor_flow.sh: --flavor becomes exactly
      // dartDefines += FLUTTER_APP_FLAVOR=<flavor> (flutter_command.dart:1517),
      // a user cannot supply that define themselves (:1511, :1508), and
      // resolution is cliFlavor ?? default-flavor (:1505).
      RouteBBuildConfig flavored(String? cli, {String? manifest}) =>
          RouteBBuildConfig.fromBuildArgs(
            [],
            flavor: RouteBBuildConfig.resolveFlavor(
              cliFlavor: cli,
              pubspecFlutterSection: manifest == null
                  ? null
                  : {'default-flavor': manifest},
            ),
          )!;

      test('no flavor / no flavor -> agrees', () {
        expect(flavored(null).agreesWith(flavored(null)), isTrue);
        expect(flavored(null).effectiveDefines, isEmpty);
      });

      test('foo / foo -> agrees', () {
        expect(flavored('foo').agreesWith(flavored('foo')), isTrue);
      });

      test('foo / bar -> refuses, naming the define', () {
        final release = flavored('foo');
        final patch = flavored('bar');
        expect(release.agreesWith(patch), isFalse);
        expect(
          release.describeDifference(patch),
          contains('FLUTTER_APP_FLAVOR: "foo" in the release, "bar" in this'),
        );
      });

      test('foo / omitted -> refuses', () {
        expect(flavored('foo').agreesWith(flavored(null)), isFalse);
      });

      test('omitted / foo -> refuses', () {
        expect(flavored(null).agreesWith(flavored('foo')), isFalse);
      });

      test('the flavor becomes a define, not a second field', () {
        final c = flavored('foo');
        expect(c.effectiveDefines, {'FLUTTER_APP_FLAVOR': 'foo'});
        // Recorded for audit, and NOT compared separately: one compiler fact must
        // have one compatibility input or the two can drift.
        expect(c.flavor, 'foo');
      });

      test(
        'REGRESSION: default-flavor alone equals an explicit CLI flavor',
        () {
          // The path most likely to regress, because there is no command-line
          // token to notice. A release flavored only by pubspec must produce the
          // SAME effective Route B configuration as one flavored by the flag.
          final viaManifest = flavored(null, manifest: 'foo');
          final viaFlag = flavored('foo');
          expect(viaManifest.effectiveDefines, {'FLUTTER_APP_FLAVOR': 'foo'});
          expect(viaManifest.agreesWith(viaFlag), isTrue);
          expect(viaManifest.fingerprint, viaFlag.fingerprint);
        },
      );

      test('the CLI flavor wins over the manifest default', () {
        // flutter_command.dart:1505 — cliFlavor ?? defaultFlavor.
        expect(
          RouteBBuildConfig.resolveFlavor(
            cliFlavor: 'cli',
            pubspecFlutterSection: {'default-flavor': 'manifest'},
          ),
          'cli',
        );
      });

      test('an empty or absent manifest default resolves to no flavor', () {
        expect(
          RouteBBuildConfig.resolveFlavor(pubspecFlutterSection: {}),
          isNull,
        );
        expect(
          RouteBBuildConfig.resolveFlavor(
            pubspecFlutterSection: {'default-flavor': ''},
          ),
          isNull,
        );
        expect(
          RouteBBuildConfig.resolveFlavor(
            pubspecFlutterSection: {'default-flavor': 42},
          ),
          isNull,
        );
      });

      test('the flavor wins over a same-named define already present', () {
        // Mirrors Flutter's xcodebuild-stage removeWhere-then-add
        // (flutter/issues/169598): the fingerprint must represent the FINAL value
        // reaching the compiler. Such an invocation is a tool error upstream, so
        // this is defence in depth rather than a supported input.
        final c = RouteBBuildConfig.fromBuildArgs(
          ['--dart-define=FLUTTER_APP_FLAVOR=stale'],
          flavor: 'fresh',
        )!;
        expect(c.effectiveDefines['FLUTTER_APP_FLAVOR'], 'fresh');
      });

      test('survives the json round trip', () {
        final c = flavored('foo');
        final back = RouteBBuildConfig.fromJson(c.toJson());
        expect(back.flavor, 'foo');
        expect(back.agreesWith(c), isTrue);
      });
    });

    group('canonical form', () {
      test('is order-independent and duplicate-collapsed', () {
        expect(
          config(['--dart-define=b=2', '--dart-define=a=1']).canonicalForm,
          config(['--dart-define=a=1', '--dart-define=b=2']).canonicalForm,
        );
      });

      test('cannot be confused by values containing separators', () {
        // Length-prefixing exists for this: without it, {a: 'b;c'} and
        // {a: 'b', c: ''} could serialise to the same text and compare equal.
        final a = config(['--dart-define=a=b;c']);
        final b = config(['--dart-define=a=b', '--dart-define=c=']);
        expect(a.canonicalForm, isNot(b.canonicalForm));
        expect(a.agreesWith(b), isFalse);
      });

      test('a value containing = keeps everything after the first one', () {
        expect(config(['--dart-define=A=x=y']).effectiveDefines, {'A': 'x=y'});
      });

      test('fingerprint follows the canonical form, not the raw args', () {
        expect(
          config(['--dart-define=b=2', '--dart-define=a=1']).fingerprint,
          config(['--dart-define=a=1', '--dart-define=b=2']).fingerprint,
        );
      });
    });

    group('--dart-define-from-file', () {
      late Directory tempDir;

      setUp(
        () => tempDir = Directory.systemTemp.createTempSync('define_from_file'),
      );
      tearDown(() => tempDir.deleteSync(recursive: true));

      void write(String name, String contents) =>
          File(p.join(tempDir.path, name)).writeAsStringSync(contents);

      test('a file that EXISTS is now fingerprinted, not declined', () {
        // THE ROW THIS CLOSES. Until the expansion landed this returned null and
        // the release was permanently not comparable. The whole value of the
        // assertion is that the file exists — see the next test for why that is
        // not a detail.
        write('defines.json', '{"API":"https://x","N":7}');
        final c = RouteBBuildConfig.fromBuildArgs(
          ['--dart-define-from-file=defines.json'],
          workingDirectory: tempDir.path,
        );
        expect(c, isNotNull);
        expect(c!.effectiveDefines, {'API': 'https://x', 'N': '7'});
      });

      test('a MISSING file still yields null — a different claim now', () {
        // Before the expansion, `--dart-define-from-file=x.env` returned null
        // because the OPTION was declined. It still returns null here, and a
        // test that never puts a real file on disk cannot tell those two reasons
        // apart — it would keep passing against an implementation that had
        // reverted. That is precisely what the previous version of this group
        // did, and why the test above writes the file.
        expect(
          RouteBBuildConfig.fromBuildArgs(
            ['--dart-define-from-file=absent.env'],
            workingDirectory: tempDir.path,
          ),
          isNull,
        );
        expect(RouteBBuildConfig.fromBuildArgs([]), isNotNull);
      });

      test('both spellings of the option are expanded', () {
        write('d.env', 'K=v');
        for (final args in [
          ['--dart-define-from-file=d.env'],
          ['--dart-define-from-file', 'd.env'],
        ]) {
          final c = RouteBBuildConfig.fromBuildArgs(
            args,
            workingDirectory: tempDir.path,
          );
          expect(c?.effectiveDefines, {'K': 'v'}, reason: '$args');
        }
      });

      test('--dart-define wins over a file entry with the same key', () {
        // Flutter's own precedence: `extractDartDefines` emits every file entry
        // before every `--dart-define`, and the last write wins (probe rule 1).
        // Measured against Flutter itself in g41b_define_from_file.sh arm 3.
        write('d.json', '{"K":"from-file","ONLY_FILE":"f"}');
        final c = RouteBBuildConfig.fromBuildArgs(
          ['--dart-define-from-file=d.json', '--dart-define=K=from-cli'],
          workingDirectory: tempDir.path,
        );
        expect(c!.effectiveDefines, {'K': 'from-cli', 'ONLY_FILE': 'f'});
      });

      test('two configurations differing only inside the file disagree', () {
        // The discriminating case for the whole feature. If the expansion were
        // dropped, both sides would fingerprint as "no defines" and a patch
        // compiled with a different constant would be accepted as matching.
        write('a.json', '{"K":"a"}');
        write('b.json', '{"K":"b"}');
        final a = RouteBBuildConfig.fromBuildArgs(
          ['--dart-define-from-file=a.json'],
          workingDirectory: tempDir.path,
        )!;
        final b = RouteBBuildConfig.fromBuildArgs(
          ['--dart-define-from-file=b.json'],
          workingDirectory: tempDir.path,
        )!;
        expect(a.agreesWith(b), isFalse);
        expect(a.fingerprint, isNot(b.fingerprint));
      });
    });

    group('unfingerprintable options', () {
      test('agrees with the kernel builder about what cannot be carried', () {
        // Two lists, one meaning. If they drift, a release could be
        // fingerprintable but unpatchable, or worse the reverse. Both are empty
        // today, so this alone would also pass on two unrelated empty lists —
        // the test below is what keeps the mechanism itself honest.
        expect(routeBUnfingerprintableOptions, routeBUnforwardableOptions);
      });

      test('the decline mechanism still works, on an injected option', () {
        // THE LIST IS EMPTY, WHICH WOULD MAKE ITS READER UNREACHABLE. A branch
        // no test can enter is a check that cannot fail, so the predicate takes
        // its list as a parameter and this exercises it directly. Whatever
        // option next proves unfingerprintable inherits working code.
        const injected = ['--some-future-option'];
        expect(
          isUnfingerprintable('--some-future-option', options: injected),
          isTrue,
        );
        expect(
          isUnfingerprintable('--some-future-option=x', options: injected),
          isTrue,
        );
        expect(
          isUnfingerprintable('--dart-define=A=1', options: injected),
          isFalse,
        );
        expect(
          isUnforwardable('--some-future-option', options: injected),
          isTrue,
        );
      });
    });

    group('round trip', () {
      test('survives json', () {
        final c = config(['--dart-define=b=2', '--dart-define=a=1']);
        final back = RouteBBuildConfig.fromJson(c.toJson());
        expect(back.agreesWith(c), isTrue);
        expect(back.effectiveDefines, c.effectiveDefines);
        expect(back.rawArgs, c.rawArgs);
      });

      test('serialises defines in sorted order for byte stability', () {
        final one = config(['--dart-define=b=2', '--dart-define=a=1']).toJson();
        final two = config(['--dart-define=a=1', '--dart-define=b=2']).toJson();
        expect(
          (one['effectiveDefines']! as Map).keys.toList(),
          (two['effectiveDefines']! as Map).keys.toList(),
        );
      });

      test('malformed json throws rather than returning an empty config', () {
        expect(
          () => RouteBBuildConfig.fromJson({'rawArgs': 'not-a-list'}),
          throwsFormatException,
        );
      });
    });

    test('compilerArgs reproduce the configuration deterministically', () {
      expect(
        config(['--dart-define=b=2', '--dart-define=a=1']).compilerArgs,
        ['-Da=1', '-Db=2'],
      );
    });
  });
}
