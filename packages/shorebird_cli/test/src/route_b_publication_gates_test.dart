import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_binding.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:shorebird_cli/src/route_b_survival.dart';
import 'package:test/test.dart';

import 'mocks.dart';

/// P4.5 — THE PUBLICATION SAFETY GATE MATRIX.
///
/// The invariant this file enforces:
///
///   A safety check is not considered present unless DISABLING it changes an
///   end-to-end publication outcome.
///
/// Every mandatory gate declares three arms, and all three must be exercised:
///
///   positive  a patch that must PUBLISH, so the gate is not simply "refuse
///             everything" wearing a reason
///   negative  a patch that must be REFUSED, with the gate's own code
///   mutation  the same negative input with the gate's evidence removed, which
///             must PUBLISH -- the proof that the refusal came from this gate
///             and not from something else along the way
///
/// The last arm is the one this project needed. Its history is full of checks
/// that were present, passing, and inert: a grep compared to itself, a pipeline
/// whose SIGPIPE turned a match into a failure, a stale platform dill, a stamp
/// asserting what a cache did not contain. A green suite proved none of them.
///
/// Adding a row to [_gates] without wiring its arms fails the completeness test
/// at the bottom, so the matrix cannot rot into a list of intentions.
class _Gate {
  const _Gate(this.id, this.what, {this.mandatory = true, this.ownedBy});
  final String id;
  final String what;
  final bool mandatory;

  /// A gate whose arms cannot run in THIS harness, with the test that owns it.
  ///
  /// The matrix drives `RouteBProducer.produce`, and one mandatory gate lives in
  /// the patcher instead. Declaring that is honest; declaring it without saying
  /// where would be a silent skip. So the pointer is CHECKED: the completeness
  /// test reads the named file and fails if the named test is not in it.
  final ({String file, String test})? ownedBy;
}

const _gates = <_Gate>[
  _Gate('P4.1', 'a surviving invocation site in the exact release artifact'),
  _Gate('P4.2', "the target member's own capability grant"),
  _Gate('P4.3', 'the replacement ABI shape'),
  _Gate('P4.4', "the member's signature, and the release binding"),
  // P5. The build-semantics authority is RouteBBuildConfig, measured in
  // evidence/p5_build_identity_matrix.md to already own every input shown to
  // alter patch-relevant compiler semantics. Its arms run here because the
  // comparison is a pure function; the REFUSAL that consumes it is in the
  // patcher.
  _Gate('P5.CONFIG', 'the effective build configuration'),
  _Gate(
    'P5.EVIDENCE',
    'a release with no comparable build configuration',
    ownedBy: (
      file: 'test/src/commands/patch/ios_patcher_test.dart',
      test: 'P5.1: refuses a release with no build configuration',
    ),
  ),
];

void main() {
  /// Which gates actually ran all three arms. Filled in by the tests; asserted
  /// against [_gates] at the end.
  final exercised = <String, Set<String>>{};
  void record(String gate, String arm) =>
      (exercised[gate] ??= <String>{}).add(arm);

  group('publication gate matrix', () {
    late Directory cell;
    late Directory work;
    late Directory project;
    late File source;
    late ShorebirdLogger logger;

    const declaration = 'String value() => _secret;';

    RouteBCompiler compiler() => RouteBCompiler(
      runtime: File(p.join(cell.path, 'dartaotruntime')),
      compilerSnapshot: File(p.join(cell.path, 'dart2bytecode.aot')),
      platformDill: File(p.join(cell.path, 'vm_platform.dill')),
      analyzer: File(p.join(cell.path, 'route_b_analyze.aot')),
      frontend: File(p.join(cell.path, 'route_b_gen_kernel.aot')),
      interfaceGenerator: File(
        p.join(cell.path, 'route_b_gen_dynamic_interface.aot'),
      ),
      releaseProbe: File(p.join(cell.path, 'route_b_release_probe.aot')),
      flutterPlatformDill: File(
        p.join(cell.path, 'flutter_platform_strong.dill'),
      ),
      provenance: '',
    );

    const target = 'package:app/main.dart#_S.value';

    RouteBCoverage coverage({
      List<String> unsupported = const [],
      Map<String, Object?>? signature,
      bool withPrivateAccess = true,
    }) {
      final text = source.readAsStringSync();
      return RouteBCoverage.fromJson(
        jsonEncode({
          'analysisVersion': supportedRouteBAnalysisVersion,
          'verdict': 'accept',
          'changed': [target],
          'added': <String>[],
          'removed': <String>[],
          'patchable': <String>[],
          'conditional': [target],
          'sources': {
            target: {
              'fileUri': source.uri.toString(),
              'start': 0,
              'end': text.length,
            },
          },
          'lowering': {
            target: {
              'receiverType': '_S',
              'nameOffset': text.indexOf('value'),
              'accesses': [
                if (withPrivateAccess)
                  {
                    'offset': text.indexOf('_secret'),
                    'member': '_secret',
                    'kind': 'get',
                    'private': {
                      'library': 'package:app/main.dart',
                      'class': '_S',
                      'name': '_secret',
                    },
                  },
              ],
              'unsupported': unsupported,
            },
          },
          'signatures': {
            if (signature != null) target: signature,
          },
          'rejections': <Object>[],
          'refusalSummary': null,
        }),
      );
    }

    /// The release granted everything this replacement needs.
    RouteBCapabilities grants() => RouteBCapabilities.fromJson(
      jsonEncode({
        'policy': 'p2',
        'privateInstanceCallable': ['package:app/main.dart#_S#_secret'],
        'privateClassPublicMembers': ['package:app/main.dart#_S#value'],
      }),
    )!;

    RouteBSurvivalOracle survived({bool yes = true}) => (targets) => {
      for (final t in targets)
        t: RouteBSurvivalVerdict(
          survival: yes
              ? RouteBSurvival.survivingCallsite
              : RouteBSurvival.noSurvivingCallsite,
          instrumentResult: yes
              ? 'ONE_OR_MORE_QUALIFYING_CALLSITES'
              : 'ZERO_QUALIFYING_CALLSITES',
        ),
    };

    const sameShape = {
      'release': '<0>()->String',
      'patch': '<0>()->String',
      'changed': false,
    };
    const changedShape = {
      'release': '<0>()->String',
      'patch': '<0>(int)->String',
      'changed': true,
    };

    RouteBReleaseEvidence evidence() => RouteBReleaseEvidence(
      releaseBuildId: 'deadbeef',
      engineRevision: 'cell-1',
      compatibilityRevision: routeBCompatibilityRevision,
      releaseArtifactSha256: 'ab' * 32,
    );

    void publish({
      RouteBCoverage? cov,
      RouteBCapabilities? capabilities,
      RouteBSurvivalOracle? survival,
      RouteBReleaseEvidence? releaseEvidence,
    }) => runScoped(
      () => const RouteBProducer().produce(
        compiler: compiler(),
        coverage: cov ?? coverage(signature: sameShape),
        importKernel: File(p.join(cell.path, 'release_import.dill')),
        releaseBuildId: 'deadbeef',
        workingDirectory: work,
        projectRoot: project,
        capabilities: capabilities,
        survival: survival,
        releaseEvidence: releaseEvidence,
        run: (executable, arguments) {
          final out = arguments[arguments.indexOf('-o') + 1];
          File(out).writeAsStringSync('BYTECODE');
          return ProcessResult(0, 0, '', '');
        },
      ),
      values: {loggerRef.overrideWith(() => logger)},
    );

    setUp(() {
      cell = Directory.systemTemp.createTempSync('cell');
      work = Directory.systemTemp.createTempSync('work');
      project = Directory.systemTemp.createTempSync('project');
      logger = MockShorebirdLogger();
      source = File(p.join(project.path, 'main.dart'))
        ..writeAsStringSync(declaration);
    });

    Matcher refusedWith(String code) => throwsA(
      isA<RouteBUnsupportedTarget>().having(
        (e) => e.reason,
        'reason',
        contains(code),
      ),
    );

    // ---- P4.1 : a surviving invocation site --------------------------------
    group('P4.1 surviving invocation site', () {
      test('positive: a target with a surviving call site publishes', () {
        expect(
          () => publish(
            capabilities: grants(),
            survival: survived(),
            releaseEvidence: evidence(),
          ),
          returnsNormally,
        );
        record('P4.1', 'positive');
      });

      test('negative: a folded target is refused', () {
        expect(
          () => publish(
            capabilities: grants(),
            survival: survived(yes: false),
            releaseEvidence: evidence(),
          ),
          refusedWith('no surviving call site'),
        );
        record('P4.1', 'negative');
      });

      test('MUTATION: with the gate removed, the folded target publishes', () {
        // The oracle is the gate. Removing it must let the SAME inert patch
        // through, or the negative arm above was refused by something else.
        expect(
          () => publish(capabilities: grants(), releaseEvidence: evidence()),
          returnsNormally,
        );
        record('P4.1', 'mutation');
      });
    });

    // ---- P4.2 : the target's own grant -------------------------------------
    group('P4.2 target capability', () {
      test('positive: a granted private member publishes', () {
        expect(
          () => publish(
            capabilities: grants(),
            survival: survived(),
            releaseEvidence: evidence(),
          ),
          returnsNormally,
        );
        record('P4.2', 'positive');
      });

      test('negative: an ungranted private-class member is refused', () {
        final ungranted = RouteBCapabilities.fromJson(
          jsonEncode({
            'policy': 'p2',
            'privateInstanceCallable': <String>[],
            'privateClassPublicMembers': ['package:app/main.dart#_S#value'],
          }),
        )!;
        expect(
          () => publish(
            capabilities: ungranted,
            survival: survived(),
            releaseEvidence: evidence(),
          ),
          throwsA(isA<RouteBUnsupportedTarget>()),
        );
        record('P4.2', 'negative');
      });

      test('MUTATION: with no manifest at all the reference still refuses', () {
        // The one gate whose mutation must NOT publish. Absence of a manifest is
        // not permission, so "disable it" cannot mean "pass" here -- and that is
        // itself a property worth pinning, because the obvious implementation
        // (null means unrestricted) would be a silent widening.
        expect(
          () => publish(survival: survived(), releaseEvidence: evidence()),
          throwsA(isA<RouteBUnsupportedTarget>()),
        );
        record('P4.2', 'mutation');
      });
    });

    // ---- P4.3 : the replacement ABI ---------------------------------------
    group('P4.3 replacement ABI', () {
      test('positive: required positionals only publishes', () {
        expect(
          () => publish(
            capabilities: grants(),
            survival: survived(),
            releaseEvidence: evidence(),
          ),
          returnsNormally,
        );
        record('P4.3', 'positive');
      });

      test('negative: named parameters are refused, with the code', () {
        expect(
          () => publish(
            cov: coverage(
              unsupported: const ['the method takes named parameters'],
              signature: sameShape,
            ),
            capabilities: grants(),
            survival: survived(),
            releaseEvidence: evidence(),
          ),
          refusedWith('UNSUPPORTED_PARAMETER_SHAPE(named_parameters)'),
        );
        record('P4.3', 'negative');
      });

      test('MUTATION: with the reason removed, the same target publishes', () {
        expect(
          () => publish(
            cov: coverage(signature: sameShape),
            capabilities: grants(),
            survival: survived(),
            releaseEvidence: evidence(),
          ),
          returnsNormally,
        );
        record('P4.3', 'mutation');
      });
    });

    // ---- P4.4 : signature and binding -------------------------------------
    group('P4.4 signature and release binding', () {
      test('positive: an unchanged shape publishes', () {
        expect(
          () => publish(
            capabilities: grants(),
            survival: survived(),
            releaseEvidence: evidence(),
          ),
          returnsNormally,
        );
        record('P4.4', 'positive');
      });

      test('negative: a changed shape is refused', () {
        expect(
          () => publish(
            cov: coverage(signature: changedShape),
            capabilities: grants(),
            survival: survived(),
            releaseEvidence: evidence(),
          ),
          refusedWith(RouteBBindingProblem.signatureChanged.wire),
        );
        record('P4.4', 'negative');
      });

      test('negative: an unestablished shape is refused too', () {
        // Not established is not unchanged.
        expect(
          () => publish(
            cov: coverage(),
            capabilities: grants(),
            survival: survived(),
            releaseEvidence: evidence(),
          ),
          refusedWith(RouteBBindingProblem.signatureNotEstablished.wire),
        );
      });

      test('MUTATION: with no release evidence, a changed shape publishes', () {
        // The binding is the gate: without it the producer records nothing and
        // asks nothing, and a shape change sails through.
        expect(
          () => publish(
            cov: coverage(signature: changedShape),
            capabilities: grants(),
            survival: survived(),
          ),
          returnsNormally,
        );
        record('P4.4', 'mutation');
      });
    });

    // ---- P5.CONFIG : the effective build configuration ---------------------
    //
    // One comparison decides all three semantic classes -- `canonicalForm`
    // equality -- so each class gets a negative arm and a mutation showing that
    // EQUALISING that one dimension makes the same pair agree. That is what
    // "load-bearing" means here: the dimension is not decoration inside a
    // comparison that would have refused anyway.
    group('P5.CONFIG effective build configuration', () {
      RouteBBuildConfig config(List<String> args, {String? flavor}) =>
          RouteBBuildConfig.fromBuildArgs(args, flavor: flavor)!;

      test('positive: the same effective configuration agrees', () {
        // Spelling is not semantics: different order, a redundant repetition,
        // and last-wins all compile identically. Measured in
        // probes/g41_define_semantics.sh.
        expect(
          config([
            '--dart-define=B=2',
            '--dart-define=A=1',
          ]).agreesWith(config(['--dart-define=A=0', '--dart-define=A=1', '--dart-define=B=2'])),
          isTrue,
        );
        record('P5.CONFIG', 'positive');
      });

      test('negative: each semantic class disagrees on its own', () {
        // defines
        expect(
          config(['--dart-define=ENV=a']).agreesWith(
            config(['--dart-define=ENV=b']),
          ),
          isFalse,
          reason: 'dart defines',
        );
        // flavor, which reaches the compiler as an ordinary define
        expect(
          config([], flavor: 'foo').agreesWith(config([], flavor: 'bar')),
          isFalse,
          reason: 'flavor',
        );
        // obfuscation
        expect(
          config([]).agreesWith(config(['--obfuscate'])),
          isFalse,
          reason: 'obfuscation',
        );
        record('P5.CONFIG', 'negative');
      });

      test('MUTATION: equalising the one dimension makes the pair agree', () {
        // Same three pairs, with only the differing dimension equalised. If any
        // of these still disagreed, the row above would not be evidence that
        // the dimension is what refused.
        expect(
          config(['--dart-define=ENV=a']).agreesWith(
            config(['--dart-define=ENV=a']),
          ),
          isTrue,
        );
        expect(
          config([], flavor: 'foo').agreesWith(config([], flavor: 'foo')),
          isTrue,
        );
        expect(
          config(['--obfuscate']).agreesWith(config(['--obfuscate'])),
          isTrue,
        );
        record('P5.CONFIG', 'mutation');
      });

      test('a non-semantic option does NOT create a disagreement', () {
        // The tempting mistake, excluded on measured evidence: the
        // split-debug-info PATH changes the emitted ELF and not the stripped
        // program, so hashing it would make two machines that produce identical
        // programs incompatible over filesystem layout.
        expect(
          config(['--split-debug-info=/a']).agreesWith(
            config(['--split-debug-info=/b']),
          ),
          isTrue,
        );
      });

      test('--target is NOT represented, and that is recorded not claimed', () {
        // P5-TARGET OPEN. The differential matrix could not produce a patch
        // accepted against a release while differing in executable semantics
        // solely because a different target was used, so no target-identity gate
        // is claimed here. This test exists to make the absence deliberate: if
        // someone adds target to the canonical form, they must come here and
        // decide, rather than discovering it as a surprise.
        expect(
          config(['--target=lib/main.dart']).agreesWith(
            config(['--target=lib/alternate.dart']),
          ),
          isTrue,
          reason: 'no evidence yet that this admits a semantic mismatch',
        );
      });
    });

    // ---- the completeness rule --------------------------------------------
    tearDownAll(() {
      final missing = <String>[];
      for (final gate in _gates.where((g) => g.mandatory)) {
        if (gate.ownedBy case final owner?) {
          // A pointer is only honest if it is checked. Read the file and require
          // the named test to be in it, so a rename cannot leave this matrix
          // pointing at nothing while still reporting complete.
          final file = File(owner.file);
          if (!file.existsSync()) {
            missing.add('${gate.id}: ${owner.file} does not exist');
          } else if (!file.readAsStringSync().contains(owner.test)) {
            missing.add('${gate.id}: ${owner.file} has no "${owner.test}"');
          }
          continue;
        }
        final arms = exercised[gate.id] ?? const <String>{};
        for (final arm in const ['positive', 'negative', 'mutation']) {
          if (!arms.contains(arm)) missing.add('${gate.id} ${gate.what}: $arm');
        }
      }
      // Deliberately a hard failure. A mandatory gate without a mutation arm is
      // an unproven gate, and this project has shipped several of those.
      expect(
        missing,
        isEmpty,
        reason:
            'every mandatory publication gate needs positive, negative and '
            'mutation arms; missing: ${missing.join(', ')}',
      );
    });
  });
}
