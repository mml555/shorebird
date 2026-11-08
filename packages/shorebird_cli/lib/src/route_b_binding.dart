// Route B (selfhost) P4.4: what a patch is bound to, stated explicitly.
//
// THE FAILURE CLASS. Every check in this system is correct about SOMETHING.
// What made them collectively weak is that the things they were correct about
// were tied together by names: a selector string, a version number, a filename
// that happened to match. So a patch could pass the capability gate against one
// manifest, the survival gate against one profile, and be published against a
// release that supplied neither -- with every individual check green.
//
// THREE LAYERS, deliberately not one blob:
//
//   1. RELEASE-BOUND EVIDENCE. Immutable, recorded by the release about itself.
//      The release cannot know which member someone will patch later, so
//      nothing target-shaped belongs here.
//   2. PER-TARGET RECEIPT. One per replaced member, recorded by the producer:
//      what was replaced, what shape it had, what capabilities it consumed, and
//      which artifact the survival verdict was measured against.
//   3. THE BINDING. Carried by the published patch, tying 1 and 2 together, so
//      nothing important rests on two names matching.
//
// Every cross-binding can be refused independently, and each has its own code:
// "wrong cell" and "wrong profile" have different remediations, and a single
// MISMATCH would send an operator to fix the wrong thing.
import 'dart:convert';

/// The revision of the whole Route B contract.
///
/// Not a file format version. It moves when any part of the publication
/// contract moves -- the analysis version, the container format, the probe
/// revision, the capability model -- because a patch is only interpretable
/// against one whole contract. A release records the revision it was cut under
/// and a patch built under another is refused rather than reconciled.
const routeBCompatibilityRevision = 1;

/// Why a binding was refused. Each is a different remediation.
enum RouteBBindingProblem {
  /// The patch was built against a different release.
  releaseIdentity('RELEASE_IDENTITY_MISMATCH'),

  /// The release artifact's bytes are not the ones the patch was built for.
  artifactDigest('ARTIFACT_DIGEST_MISMATCH'),

  /// A different compiler cell.
  cell('CELL_MISMATCH'),

  /// The survival evidence describes a different compilation.
  profileDigest('PROFILE_DIGEST_MISMATCH'),

  /// The grants the patch relied on came from a different manifest.
  capabilityManifestDigest('CAPABILITY_MANIFEST_MISMATCH'),

  /// Release and patch were built under different Route B contracts.
  compatibilityRevision('COMPATIBILITY_REVISION_MISMATCH'),

  /// The effective define set differs, so compile-time constants would differ.
  defineFingerprint('DEFINE_FINGERPRINT_MISMATCH'),

  /// The same selector, resolved in a different library.
  targetLibrary('TARGET_LIBRARY_MISMATCH'),

  /// The member's shape changed, so the release's call sites cannot call it.
  signatureChanged('TARGET_SIGNATURE_CHANGED'),

  /// Whether the shape changed could not be established. Not "unchanged".
  signatureNotEstablished('TARGET_SIGNATURE_NOT_ESTABLISHED'),

  /// A binding could not be compared at all, because one side recorded nothing.
  evidenceAbsent('BINDING_EVIDENCE_ABSENT');

  const RouteBBindingProblem(this.wire);

  /// The stable token. Safe to match on.
  final String wire;
}

/// One refused binding.
class RouteBBindingRefusal {
  /// {@macro route_b_binding_refusal}
  const RouteBBindingRefusal(this.problem, this.detail, {this.target});

  /// Which binding failed.
  final RouteBBindingProblem problem;

  /// What was expected and what was found, in that order.
  final String detail;

  /// The target this concerns, for per-receipt problems.
  final String? target;

  @override
  String toString() =>
      '${problem.wire}${target == null ? '' : ' [$target]'}: $detail';
}

/// LAYER 1 — what the release recorded about itself.
class RouteBReleaseEvidence {
  /// {@macro route_b_release_evidence}
  const RouteBReleaseEvidence({
    required this.releaseBuildId,
    required this.engineRevision,
    required this.compatibilityRevision,
    this.releaseArtifactSha256,
    this.snapshotProfileSha256,
    this.capabilityManifestSha256,
    this.defineFingerprint,
  });

  /// Parses layer 1 out of a binding document.
  factory RouteBReleaseEvidence.fromJson(Map<String, Object?> json) {
    return RouteBReleaseEvidence(
      releaseBuildId: '${json['releaseBuildId']}',
      engineRevision: '${json['engineRevision']}',
      compatibilityRevision:
          (json['compatibilityRevision'] as num?)?.toInt() ?? -1,
      releaseArtifactSha256: json['releaseArtifactSha256'] as String?,
      snapshotProfileSha256: json['snapshotProfileSha256'] as String?,
      capabilityManifestSha256: json['capabilityManifestSha256'] as String?,
      defineFingerprint: json['defineFingerprint'] as String?,
    );
  }

  /// The release's own build id, read out of its shipped bytes.
  final String releaseBuildId;

  /// The engine cell the release was built by. `cell_id` elsewhere.
  final String engineRevision;

  /// The contract revision the release was cut under.
  final int compatibilityRevision;

  /// sha256 of the App binary. Null for a release that recorded none.
  final String? releaseArtifactSha256;

  /// sha256 of the release's v8 snapshot profile.
  final String? snapshotProfileSha256;

  /// sha256 of the capability manifest the release published.
  final String? capabilityManifestSha256;

  /// The release's effective define set, fingerprinted.
  final String? defineFingerprint;

  /// Layer 1 as it appears in the binding document.
  Map<String, Object?> toJson() => {
    'releaseBuildId': releaseBuildId,
    'engineRevision': engineRevision,
    'compatibilityRevision': compatibilityRevision,
    if (releaseArtifactSha256 != null)
      'releaseArtifactSha256': releaseArtifactSha256,
    if (snapshotProfileSha256 != null)
      'snapshotProfileSha256': snapshotProfileSha256,
    if (capabilityManifestSha256 != null)
      'capabilityManifestSha256': capabilityManifestSha256,
    if (defineFingerprint != null) 'defineFingerprint': defineFingerprint,
  };
}

/// LAYER 2 — one replaced member.
class RouteBTargetReceipt {
  /// {@macro route_b_target_receipt}
  const RouteBTargetReceipt({
    required this.library,
    required this.member,
    required this.survivalResult,
    this.className,
    this.releaseSignature,
    this.replacementSignature,
    this.capabilitiesConsumed = const [],
    this.measuredAgainstArtifactSha256,
  });

  /// Parses one receipt.
  factory RouteBTargetReceipt.fromJson(Map<String, Object?> json) {
    return RouteBTargetReceipt(
      library: '${json['library']}',
      className: json['class'] as String?,
      member: '${json['member']}',
      releaseSignature: json['releaseSignature'] as String?,
      replacementSignature: json['replacementSignature'] as String?,
      capabilitiesConsumed: [
        for (final c in (json['capabilitiesConsumed'] as List? ?? const []))
          '$c',
      ],
      survivalResult: '${json['survivalResult']}',
      measuredAgainstArtifactSha256:
          json['measuredAgainstArtifactSha256'] as String?,
    );
  }

  /// STRUCTURED IDENTITY, not a selector string.
  ///
  /// `_FooState.value` as text is not an identity: two libraries can each hold
  /// a `_FooState`, and the same member name can survive a signature change.
  /// The library, the owning class and the member are separate fields, and the
  /// signature is carried beside them.
  final String library;

  /// The owning class, or null for a top-level member.
  final String? className;

  /// The member, in VM form (`get:x` / `set:x` for accessors).
  final String member;

  /// The signature the RELEASE has for this member.
  final String? releaseSignature;

  /// The signature the replacement has.
  final String? replacementSignature;

  /// The capability grants this replacement relied on.
  final List<String> capabilitiesConsumed;

  /// The survival probe's instrument result for this target.
  final String survivalResult;

  /// The artifact digest the survival verdict was measured against.
  ///
  /// Recorded per target rather than once, because a verdict is only about the
  /// artifact it was measured on, and pairing it with the wrong one is exactly
  /// the mistake this layer exists to make impossible.
  final String? measuredAgainstArtifactSha256;

  /// `library#Class.member`, for messages only.
  String get target =>
      '$library#${className == null ? member : '$className.$member'}';

  /// One receipt as it appears in the binding document.
  Map<String, Object?> toJson() => {
    'library': library,
    if (className != null) 'class': className,
    'member': member,
    if (releaseSignature != null) 'releaseSignature': releaseSignature,
    if (replacementSignature != null)
      'replacementSignature': replacementSignature,
    if (capabilitiesConsumed.isNotEmpty)
      'capabilitiesConsumed': capabilitiesConsumed,
    'survivalResult': survivalResult,
    if (measuredAgainstArtifactSha256 != null)
      'measuredAgainstArtifactSha256': measuredAgainstArtifactSha256,
  };
}

/// LAYER 3 — what the published patch binds.
class RouteBPatchBinding {
  /// {@macro route_b_patch_binding}
  const RouteBPatchBinding({required this.evidence, required this.receipts});

  /// Parses a binding out of a container header.
  factory RouteBPatchBinding.fromJson(Map<String, Object?> json) {
    return RouteBPatchBinding(
      evidence: RouteBReleaseEvidence.fromJson(
        (json['release'] as Map?)?.cast<String, Object?>() ?? const {},
      ),
      receipts: [
        for (final r in (json['receipts'] as List? ?? const []))
          if (r is Map) RouteBTargetReceipt.fromJson(r.cast<String, Object?>()),
      ],
    );
  }

  /// Layer 1.
  final RouteBReleaseEvidence evidence;

  /// Layer 2, one per replaced member.
  final List<RouteBTargetReceipt> receipts;

  /// The whole binding document.
  Map<String, Object?> toJson() => {
    'release': evidence.toJson(),
    'receipts': [for (final r in receipts) r.toJson()],
  };

  /// The binding as it appears in a container header.
  String encode() => jsonEncode(toJson());
}

/// Checks a binding against the facts measured from the release in hand.
///
/// Returns EVERY refusal, not the first: an operator fixing one mismatch should
/// not discover the next one on the following run. An empty list means every
/// cross-binding held.
///
/// [live] must be built from the artifacts the patcher actually has -- digests
/// recomputed from bytes, not copied from what the release said about itself.
/// Comparing a document to itself is the failure this layer exists against.
List<RouteBBindingRefusal> verifyRouteBBinding({
  required RouteBPatchBinding binding,
  required RouteBReleaseEvidence live,
}) {
  final refusals = <RouteBBindingRefusal>[];
  void check(
    RouteBBindingProblem problem,
    String what,
    String? want,
    String? got, {
    String? target,
  }) {
    // An absent expectation is NOT a pass. A release that recorded no digest
    // cannot vouch for one, and treating null as "matches anything" would make
    // every one of these gates skippable by omission.
    if (want == null || got == null) {
      refusals.add(
        RouteBBindingRefusal(
          RouteBBindingProblem.evidenceAbsent,
          '$what could not be compared: the release '
          '${want == null ? 'recorded none' : 'recorded $want'} and the patch '
          '${got == null ? 'carries none' : 'carries $got'}',
          target: target,
        ),
      );
      return;
    }
    if (want.toLowerCase() != got.toLowerCase()) {
      refusals.add(
        RouteBBindingRefusal(
          problem,
          '$what: the release has $want, the patch was built against $got',
          target: target,
        ),
      );
    }
  }

  final b = binding.evidence;
  check(
    RouteBBindingProblem.releaseIdentity,
    'release build id',
    live.releaseBuildId,
    b.releaseBuildId,
  );
  check(
    RouteBBindingProblem.cell,
    'engine cell',
    live.engineRevision,
    b.engineRevision,
  );
  check(
    RouteBBindingProblem.artifactDigest,
    'release artifact digest',
    live.releaseArtifactSha256,
    b.releaseArtifactSha256,
  );
  check(
    RouteBBindingProblem.profileDigest,
    'snapshot profile digest',
    live.snapshotProfileSha256,
    b.snapshotProfileSha256,
  );
  check(
    RouteBBindingProblem.capabilityManifestDigest,
    'capability manifest digest',
    live.capabilityManifestSha256,
    b.capabilityManifestSha256,
  );
  check(
    RouteBBindingProblem.defineFingerprint,
    'define fingerprint',
    live.defineFingerprint,
    b.defineFingerprint,
  );
  if (live.compatibilityRevision != b.compatibilityRevision) {
    refusals.add(
      RouteBBindingRefusal(
        RouteBBindingProblem.compatibilityRevision,
        'Route B contract revision: the release was cut under '
        '${live.compatibilityRevision}, the patch was built under '
        '${b.compatibilityRevision}',
      ),
    );
  }

  for (final receipt in binding.receipts) {
    // The verdict must have been measured against THIS artifact. A green
    // verdict measured elsewhere is a statement about another program.
    check(
      RouteBBindingProblem.artifactDigest,
      'the artifact its survival verdict was measured against',
      live.releaseArtifactSha256,
      receipt.measuredAgainstArtifactSha256,
      target: receipt.target,
    );
    if (receipt.releaseSignature == null ||
        receipt.replacementSignature == null) {
      // Not established is not unchanged. A cell that does not report
      // signatures leaves this unknowable, and unknowable refuses.
      refusals.add(
        RouteBBindingRefusal(
          RouteBBindingProblem.signatureNotEstablished,
          'no signature was recorded for it on one or both sides, so whether '
          'the shape changed could not be established',
          target: receipt.target,
        ),
      );
    } else if (receipt.releaseSignature != receipt.replacementSignature) {
      refusals.add(
        RouteBBindingRefusal(
          RouteBBindingProblem.signatureChanged,
          'the release has ${receipt.releaseSignature} and the replacement is '
          '${receipt.replacementSignature}. The compiled call sites in the '
          'release carry that release own argument descriptor, so a '
          'replacement with a different shape cannot be called correctly',
          target: receipt.target,
        ),
      );
    }
  }
  return refusals;
}

/// The user-facing refusal for a failed binding.
String describeRouteBBindingRefusals(List<RouteBBindingRefusal> refusals) {
  final buffer = StringBuffer()
    ..writeln(
      'This patch is not bound to the release it would be published against: '
      '${refusals.length} check(s) failed.',
    )
    ..writeln();
  for (final r in refusals) {
    buffer.writeln('  ${r.problem.wire}');
    if (r.target != null) buffer.writeln('      target: ${r.target}');
    buffer.writeln('      ${r.detail}');
  }
  buffer
    ..writeln()
    ..write(
      'Nothing was uploaded. Each of these is a different problem with a '
      'different fix, which is why they are named separately rather than '
      'reported as one mismatch.',
    );
  return buffer.toString();
}
