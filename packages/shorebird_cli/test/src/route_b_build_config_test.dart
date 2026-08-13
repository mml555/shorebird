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

    group('unfingerprintable options', () {
      test('--dart-define-from-file yields null, not an empty config', () {
        // "Cannot be determined" must not collapse into "no defines": an empty
        // configuration is a real one that a patch can legitimately match.
        expect(
          RouteBBuildConfig.fromBuildArgs(['--dart-define-from-file=x.env']),
          isNull,
        );
        expect(
          RouteBBuildConfig.fromBuildArgs(['--dart-define-from-file', 'x.env']),
          isNull,
        );
        expect(RouteBBuildConfig.fromBuildArgs([]), isNotNull);
      });

      test('agrees with the kernel builder about what cannot be carried', () {
        // Two lists, one meaning. If they drift, a release could be
        // fingerprintable but unpatchable, or worse the reverse.
        expect(routeBUnfingerprintableOptions, routeBUnforwardableOptions);
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
