import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_survival.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  useTempWorkingDirectory();
  group('survivalForInstrumentResult', () {
    test('maps the instrument model onto the three product answers', () {
      expect(
        survivalForInstrumentResult('ONE_OR_MORE_QUALIFYING_CALLSITES'),
        RouteBSurvival.survivingCallsite,
      );
      expect(
        survivalForInstrumentResult('ZERO_QUALIFYING_CALLSITES'),
        RouteBSurvival.noSurvivingCallsite,
      );
      for (final unknown in const [
        'TARGET_NOT_FOUND',
        'TARGET_AMBIGUOUS',
        'PROFILE_INVALID',
        'ARTIFACT_BINDING_MISMATCH',
      ]) {
        expect(
          survivalForInstrumentResult(unknown),
          RouteBSurvival.unknown,
          reason: '$unknown must refuse, and must not read as absence',
        );
      }
    });

    test('an unrecognised result is UNKNOWN, never a pass', () {
      // A future probe revision could add a result this CLI has never seen. It
      // must refuse rather than fall into either bucket.
      expect(
        survivalForInstrumentResult('SOMETHING_NEW'),
        RouteBSurvival.unknown,
      );
    });
  });

  group('cellSurvivalOracle', () {
    late Directory tmp;
    late RouteBCompiler compiler;

    RouteBCompiler cell(Directory dir) => RouteBCompiler(
      runtime: File(p.join(dir.path, 'dartaotruntime')),
      compilerSnapshot: File(p.join(dir.path, 'dart2bytecode.aot')),
      platformDill: File(p.join(dir.path, 'vm_platform.dill')),
      analyzer: File(p.join(dir.path, 'route_b_analyze.aot')),
      frontend: File(p.join(dir.path, 'route_b_gen_kernel.aot')),
      interfaceGenerator: File(
        p.join(dir.path, 'route_b_gen_dynamic_interface.aot'),
      ),
      releaseProbe: File(p.join(dir.path, 'route_b_release_probe.aot')),
      flutterPlatformDill: File(
        p.join(dir.path, 'flutter_platform_strong.dill'),
      ),
      provenance: '',
    );

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('survival');
      compiler = cell(tmp);
    });

    ProcessResult Function(String, List<String>) emitting(
      Object? stdout, {
      int exitCode = 0,
      String stderr = '',
    }) {
      return (_, _) => ProcessResult(
        0,
        exitCode,
        stdout is String ? stdout : jsonEncode(stdout),
        stderr,
      );
    }

    RouteBSurvivalOracle oracleOver(
      ProcessResult Function(String, List<String>) run,
    ) => cellSurvivalOracle(
      compiler: compiler,
      profile: File(p.join(tmp.path, 'profile.json')),
      binding: File(p.join(tmp.path, 'binding.json')),
      releaseArtifactSha256: 'a' * 64,
      run: run,
    );

    test('passes the artifact digest and every target to the probe', () {
      late List<String> seen;
      final oracle = cellSurvivalOracle(
        compiler: compiler,
        profile: File(p.join(tmp.path, 'profile.json')),
        binding: File(p.join(tmp.path, 'binding.json')),
        releaseArtifactSha256: 'b' * 64,
        cellId: 'cafe',
        run: (_, args) {
          seen = args;
          return ProcessResult(0, 0, jsonEncode({'targets': <Object>[]}), '');
        },
      );
      oracle(['lib#a', 'lib#b']);

      expect(seen, contains('--artifact-sha256'));
      expect(seen, contains('b' * 64));
      expect(seen, containsAllInOrder(['--cell-id', 'cafe']));
      expect(seen.where((a) => a == '--target').length, 2);
      expect(seen, contains('lib#a'));
      expect(seen, contains('lib#b'));
      // The producer must never be handed the profile to parse itself.
      expect(seen, contains(compiler.releaseProbe.path));
    });

    test('asks nothing when there are no targets', () {
      var called = false;
      final oracle = cellSurvivalOracle(
        compiler: compiler,
        profile: File(p.join(tmp.path, 'profile.json')),
        binding: File(p.join(tmp.path, 'binding.json')),
        releaseArtifactSha256: 'a' * 64,
        run: (_, _) {
          called = true;
          return ProcessResult(0, 0, '{}', '');
        },
      );
      expect(oracle(const []), isEmpty);
      expect(called, isFalse);
    });

    test('translates a green verdict', () {
      final verdicts = oracleOver(
        emitting({
          'targets': [
            {
              'target': 'lib#a',
              'result': 'ONE_OR_MORE_QUALIFYING_CALLSITES',
              'evidence': {'caller_owned_pools': 1},
            },
          ],
        }),
      )(['lib#a']);

      expect(verdicts['lib#a']!.survival, RouteBSurvival.survivingCallsite);
      expect(verdicts['lib#a']!.permitsPublication, isTrue);
      expect(verdicts['lib#a']!.evidence['caller_owned_pools'], 1);
    });

    test('reads the members holding an inlined copy', () {
      final verdicts = oracleOver(
        emitting({
          'targets': [
            {
              'target': 'lib#a',
              'result': 'ZERO_QUALIFYING_CALLSITES',
              'evidence': {
                'inlined_into': ['lib#b', 'lib#C.c'],
              },
            },
            {'target': 'lib#d', 'result': 'ZERO_QUALIFYING_CALLSITES'},
          ],
        }),
      )(['lib#a', 'lib#d']);

      expect(verdicts['lib#a']!.inlinedInto, {'lib#b', 'lib#C.c'});
      // Absent is "not established", never "none".
      expect(verdicts['lib#d']!.inlinedInto, isNull);
    });

    test('a probe that could not run is UNKNOWN for every target', () {
      // An instrument that failed to execute has said NOTHING about the code,
      // which is the one thing this must not be confused with "no call site".
      final verdicts = oracleOver(
        emitting('', exitCode: 2, stderr: 'boom'),
      )(['lib#a', 'lib#b']);

      for (final v in verdicts.values) {
        expect(v.survival, RouteBSurvival.unknown);
        expect(v.instrumentResult, 'PROBE_FAILED');
        expect(v.detail, contains('boom'));
      }
    });

    test('unreadable probe output is UNKNOWN, not a pass', () {
      final verdicts = oracleOver(emitting('not json'))(['lib#a']);
      expect(verdicts['lib#a']!.survival, RouteBSurvival.unknown);
      expect(verdicts['lib#a']!.instrumentResult, 'PROBE_OUTPUT_UNREADABLE');
    });

    test('output with no targets array is UNKNOWN', () {
      final verdicts = oracleOver(emitting({'probe_revision': 1}))(['lib#a']);
      expect(verdicts['lib#a']!.survival, RouteBSurvival.unknown);
    });

    test('a target the probe skipped is UNKNOWN, not assumed green', () {
      // The shape a silently partial answer takes. Asked about two, told about
      // one: the other must not inherit the first one's verdict.
      final verdicts = oracleOver(
        emitting({
          'targets': [
            {
              'target': 'lib#a',
              'result': 'ONE_OR_MORE_QUALIFYING_CALLSITES',
            },
          ],
        }),
      )(['lib#a', 'lib#b']);

      expect(verdicts['lib#a']!.survival, RouteBSurvival.survivingCallsite);
      expect(verdicts['lib#b']!.survival, RouteBSurvival.unknown);
      expect(verdicts['lib#b']!.instrumentResult, 'NO_VERDICT');
    });
  });

  group('routeBCompanionsFor', () {
    RouteBSurvivalVerdict verdict(
      RouteBSurvival survival, [
      Set<String>? inlinedInto,
    ]) => RouteBSurvivalVerdict(
      survival: survival,
      instrumentResult: '',
      inlinedInto: inlinedInto,
    );

    test('without inlining evidence, decides as before', () {
      expect(
        routeBCompanionsFor(verdict(RouteBSurvival.survivingCallsite)),
        isEmpty,
      );
      expect(
        routeBCompanionsFor(
          verdict(RouteBSurvival.noSurvivingCallsite),
          callers: ['lib#b'],
        ),
        isNull,
      );
    });

    test('a surviving call site still needs its inlined copies', () {
      expect(
        routeBCompanionsFor(
          verdict(RouteBSurvival.survivingCallsite, {'lib#b'}),
        ),
        {'lib#b'},
      );
    });

    test('no call site: the inlined copies, else the kernel callers', () {
      expect(
        routeBCompanionsFor(
          verdict(RouteBSurvival.noSurvivingCallsite, {'lib#b'}),
          callers: ['lib#c'],
        ),
        {'lib#b'},
      );
      expect(
        routeBCompanionsFor(
          verdict(RouteBSurvival.noSurvivingCallsite, {}),
          callers: ['lib#c'],
        ),
        {'lib#c'},
      );
    });

    test('no call site, no copy and no caller: nothing can help', () {
      expect(
        routeBCompanionsFor(
          verdict(RouteBSurvival.noSurvivingCallsite, {}),
          callers: [],
        ),
        isNull,
      );
    });

    test('UNKNOWN is never helped by carrying', () {
      expect(
        routeBCompanionsFor(
          verdict(RouteBSurvival.unknown, {}),
          callers: ['x'],
        ),
        isNull,
      );
    });
  });

  group('describeRouteBMissingCompanions', () {
    test('names every member and says when the cell is why', () {
      final old = describeRouteBMissingCompanions([
        'lib#b',
        'lib#c',
      ], canCarry: false);
      expect(old, contains('inside lib#b, lib#c'));
      expect(old, contains('does not replace them'));
      expect(old, contains('version 14 or later'));

      final current = describeRouteBMissingCompanions([
        'lib#b',
      ], canCarry: true);
      expect(current, contains('does not replace it.'));
      expect(current, isNot(contains('version 14')));
    });
  });

  group('describeRouteBSurvivalRefusal', () {
    test('absence names the release as the cause', () {
      final text = describeRouteBSurvivalRefusal(
        'lib#a',
        const RouteBSurvivalVerdict(
          survival: RouteBSurvival.noSurvivingCallsite,
          instrumentResult: 'ZERO_QUALIFYING_CALLSITES',
        ),
      );
      expect(text, contains('no surviving call site'));
      expect(text, contains('attach and change nothing'));
      expect(text, contains('remediation is a new release'));
    });

    test('UNKNOWN is explicitly not absence', () {
      final text = describeRouteBSurvivalRefusal(
        'lib#a',
        const RouteBSurvivalVerdict(
          survival: RouteBSurvival.unknown,
          instrumentResult: 'PROFILE_INVALID',
          detail: 'edges array has 3 bytes left over',
        ),
      );
      expect(text, contains('could not be established'));
      expect(text, contains('PROFILE_INVALID'));
      expect(text, contains('edges array has 3 bytes left over'));
      expect(text, contains('NOT a finding that the call site is absent'));
      // The two refusals must not be able to read as each other.
      expect(text, isNot(contains('attach and change nothing')));
    });

    test('never calls a green result reachability', () {
      // Semantic overclaim is this project's recurring failure mode, so the
      // wording gets a test like anything else.
      final text = describeRouteBSurvivalRefusal(
        'lib#a',
        const RouteBSurvivalVerdict(
          survival: RouteBSurvival.survivingCallsite,
          instrumentResult: 'ONE_OR_MORE_QUALIFYING_CALLSITES',
        ),
      );
      expect(text.toLowerCase(), isNot(contains('reachab')));
      expect(text, contains('not a refusal'));
    });
  });

  group('routeBReleaseProbeRevisionFor', () {
    test('binds a release built without the flag to revision 1', () {
      expect(
        routeBReleaseProbeRevisionFor([
          '--extra-gen-snapshot-options=--patchable_static_calls',
        ]),
        routeBReleaseProbeRevision,
      );
    });

    test('binds a release built with the flag to revision 2', () {
      expect(
        routeBReleaseProbeRevisionFor([
          '--extra-gen-snapshot-options=--patchable_static_calls',
          '--extra-gen-snapshot-options=--route_b_untabled_overrides',
        ]),
        routeBUntabledReleaseProbeRevision,
      );
    });

    test('finds the flag among comma-separated options', () {
      expect(
        routeBReleaseProbeRevisionFor([
          '--extra-gen-snapshot-options=--a,--route_b_untabled_overrides=true',
        ]),
        routeBUntabledReleaseProbeRevision,
      );
    });

    test('reads a negated or disabled flag as off', () {
      for (final arg in [
        '--extra-gen-snapshot-options=--no-route_b_untabled_overrides',
        '--extra-gen-snapshot-options=--route_b_untabled_overrides=false',
        // Not a gen_snapshot option at all.
        '--route_b_untabled_overrides',
      ]) {
        expect(
          routeBReleaseProbeRevisionFor([arg]),
          routeBReleaseProbeRevision,
          reason: arg,
        );
      }
    });

    test('lets the last mention of the flag decide, as gen_snapshot does', () {
      expect(
        routeBReleaseProbeRevisionFor([
          '--extra-gen-snapshot-options=--route_b_untabled_overrides',
          '--extra-gen-snapshot-options=--no-route_b_untabled_overrides',
        ]),
        routeBReleaseProbeRevision,
      );
      expect(
        routeBReleaseProbeRevisionFor([
          [
            '--extra-gen-snapshot-options=--route_b_untabled_overrides=false',
            '--route_b_untabled_overrides',
          ].join(','),
        ]),
        routeBUntabledReleaseProbeRevision,
      );
    });
  });
}
