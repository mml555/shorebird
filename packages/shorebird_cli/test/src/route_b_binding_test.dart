import 'package:shorebird_cli/src/route_b_binding.dart';
import 'package:test/test.dart';

void main() {
  // P4.4. The point of these is that every cross-binding fails INDEPENDENTLY.
  // A single MISMATCH would tell an operator that something is wrong and send
  // them to guess which of six things it was.
  // Not `const`: `'a' * 64` is not a constant expression.
  final artifact = 'a' * 64;
  final profile = 'b' * 64;
  final manifest = 'c' * 64;

  RouteBReleaseEvidence evidence({
    String buildId = 'release-1',
    String engine = 'cell-1',
    int revision = routeBCompatibilityRevision,
    String? artifactSha,
    String? profileSha,
    String? manifestSha,
    bool clearArtifact = false,
    bool clearProfile = false,
    bool clearManifest = false,
    String? defines = 'defines-1',
  }) => RouteBReleaseEvidence(
    releaseBuildId: buildId,
    engineRevision: engine,
    compatibilityRevision: revision,
    releaseArtifactSha256: clearArtifact ? null : artifactSha ?? artifact,
    snapshotProfileSha256: clearProfile ? null : profileSha ?? profile,
    capabilityManifestSha256: clearManifest ? null : manifestSha ?? manifest,
    defineFingerprint: defines,
  );

  RouteBTargetReceipt receipt({
    String library = 'package:app/main.dart',
    String? className = '_FooState',
    String member = 'value',
    String? releaseSignature = '<0>()->String',
    String? replacementSignature = '<0>()->String',
    String? measuredAgainst,
    bool clearMeasuredAgainst = false,
  }) => RouteBTargetReceipt(
    library: library,
    className: className,
    member: member,
    releaseSignature: releaseSignature,
    replacementSignature: replacementSignature,
    survivalResult: 'ONE_OR_MORE_QUALIFYING_CALLSITES',
    measuredAgainstArtifactSha256:
        clearMeasuredAgainst ? null : measuredAgainst ?? artifact,
  );

  List<RouteBBindingProblem> problems({
    RouteBReleaseEvidence? bound,
    RouteBReleaseEvidence? live,
    List<RouteBTargetReceipt>? receipts,
  }) => verifyRouteBBinding(
    binding: RouteBPatchBinding(
      evidence: bound ?? evidence(),
      receipts: receipts ?? [receipt()],
    ),
    live: live ?? evidence(),
  ).map((r) => r.problem).toList();

  test('a patch bound to the release it is published against passes', () {
    // The positive control. Without it every row below would also pass on a
    // verifier that refused everything.
    expect(problems(), isEmpty);
  });

  group('every cross-binding refuses on its own', () {
    test('right target, wrong release', () {
      expect(
        problems(live: evidence(buildId: 'release-2')),
        contains(RouteBBindingProblem.releaseIdentity),
      );
    });

    test('right release, wrong cell', () {
      expect(
        problems(live: evidence(engine: 'cell-2')),
        contains(RouteBBindingProblem.cell),
      );
    });

    test('right artifact, wrong profile digest', () {
      expect(
        problems(live: evidence(profileSha: 'd' * 64)),
        contains(RouteBBindingProblem.profileDigest),
      );
    });

    test('right target, wrong capability manifest', () {
      expect(
        problems(live: evidence(manifestSha: 'e' * 64)),
        contains(RouteBBindingProblem.capabilityManifestDigest),
      );
    });

    test('wrong release artifact digest', () {
      expect(
        problems(live: evidence(artifactSha: 'f' * 64)),
        contains(RouteBBindingProblem.artifactDigest),
      );
    });

    test('changed build/define fingerprint', () {
      expect(
        problems(live: evidence(defines: 'defines-2')),
        contains(RouteBBindingProblem.defineFingerprint),
      );
    });

    test('different Route B contract revision', () {
      expect(
        problems(live: evidence(revision: routeBCompatibilityRevision + 1)),
        contains(RouteBBindingProblem.compatibilityRevision),
      );
    });
  });

  group('target identity is structured, not a selector string', () {
    test('same member, changed signature: refused', () {
      // `_FooState.value` as text is identical on both sides here. Only the
      // shape moved, and the release's compiled call sites carry the release's
      // own argument descriptor.
      expect(
        problems(
          receipts: [receipt(replacementSignature: '<0>(String)->String')],
        ),
        contains(RouteBBindingProblem.signatureChanged),
      );
    });

    test('an unestablished signature is refused, not assumed unchanged', () {
      // A cell that does not report signatures leaves this unknowable. Treating
      // null as "same" would make the gate skippable by omission.
      expect(
        problems(receipts: [receipt(releaseSignature: null)]),
        contains(RouteBBindingProblem.signatureNotEstablished),
      );
      expect(
        problems(receipts: [receipt(replacementSignature: null)]),
        contains(RouteBBindingProblem.signatureNotEstablished),
      );
    });

    test('a verdict measured against another artifact is refused', () {
      // The receipt is green and honest, about a different program.
      expect(
        problems(receipts: [receipt(measuredAgainst: 'f' * 64)]),
        contains(RouteBBindingProblem.artifactDigest),
      );
    });

    test('the same selector in a different library is a different target', () {
      // Two libraries can each hold a `_FooState.value`. The receipt records
      // the library, so the identity survives the collision -- and the message
      // must NAME the target rather than reporting a bare mismatch.
      final refusals = verifyRouteBBinding(
        binding: RouteBPatchBinding(
          evidence: evidence(),
          receipts: [
            receipt(library: 'package:app/a.dart', measuredAgainst: 'f' * 64),
            receipt(library: 'package:app/b.dart'),
          ],
        ),
        live: evidence(),
      );
      expect(refusals, hasLength(1));
      expect(refusals.single.target, 'package:app/a.dart#_FooState.value');
    });
  });

  group('absent evidence', () {
    test('a release that recorded no digest cannot vouch for one', () {
      // Null must not mean "matches anything", or every gate here is skippable
      // by omitting a field.
      expect(
        problems(live: evidence(clearArtifact: true)),
        contains(RouteBBindingProblem.evidenceAbsent),
      );
      expect(
        problems(bound: evidence(clearProfile: true)),
        contains(RouteBBindingProblem.evidenceAbsent),
      );
    });
  });

  test('reports EVERY failure, not the first', () {
    // An operator fixing one mismatch should not discover the next one on the
    // following run.
    final found = problems(
      live: evidence(buildId: 'release-2', engine: 'cell-2', defines: 'x'),
    );
    expect(found, containsAll(<RouteBBindingProblem>[
      RouteBBindingProblem.releaseIdentity,
      RouteBBindingProblem.cell,
      RouteBBindingProblem.defineFingerprint,
    ]));
  });

  test('survives a round trip through the container header', () {
    // The publication path re-reads the binding from the container BYTES rather
    // than trusting the objects that produced them, so the encoding has to be
    // lossless for the fields the checks depend on.
    final original = RouteBPatchBinding(
      evidence: evidence(),
      receipts: [receipt(), receipt(className: null, member: 'topLevel')],
    );
    final round = RouteBPatchBinding.fromJson(original.toJson());
    expect(
      verifyRouteBBinding(binding: round, live: evidence()),
      isEmpty,
      reason: 'a lossless round trip must still verify',
    );
    expect(round.receipts.map((r) => r.target), [
      'package:app/main.dart#_FooState.value',
      'package:app/main.dart#topLevel',
    ]);
  });

  test('the refusal text names each problem separately', () {
    final text = describeRouteBBindingRefusals(
      verifyRouteBBinding(
        binding: RouteBPatchBinding(
          evidence: evidence(),
          receipts: [receipt(replacementSignature: '<0>(int)->String')],
        ),
        live: evidence(engine: 'cell-2'),
      ),
    );
    expect(text, contains('CELL_MISMATCH'));
    expect(text, contains('TARGET_SIGNATURE_CHANGED'));
    expect(text, contains('package:app/main.dart#_FooState.value'));
    expect(text, contains('Nothing was uploaded'));
  });
}
