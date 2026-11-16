// Route B (selfhost) P4.1: does the release still contain a call site for the
// member a patch is about to replace?
//
// The failure this closes is the quietest one in the system. A patch whose
// target was CONSTANT-FOLDED out of the release compiles, uploads, downloads,
// validates, resolves, attaches, and reports `applied 1/1 targets` -- and
// changes nothing, because no surviving call site reads
// `Function.entry_point_`. Nothing in the runtime report distinguishes that
// from a patch that worked, which is why it has to be decided before
// publication, against the exact release artifact.
//
// OWNERSHIP. The cell owns the byte-level fact; this file owns the
// publication decision. The producer never parses a snapshot profile: it asks
// the probe that shipped with the release's own compiler, because
// profile-schema knowledge is a property of the gen_snapshot that emitted it.
// See selfhost/engine/route_b/P41_RELEASE_PROBE_SPEC.md.
//
// WHAT A GREEN RESULT MEANS, EXACTLY. That a supported invocation site survived
// compilation. NOT that execution reaches it. A branch that is never taken
// has a surviving call site and is reported green, deliberately: the
// alternative is a
// gate that claims reachability it cannot establish, and that claim would be
// wrong in the direction that hides bugs.
import 'dart:convert';
import 'dart:io';

import 'package:shorebird_cli/src/route_b.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';

/// The probe revision this CLI writes into a release's profile binding.
///
/// The release records which probe revision its evidence was written for, and
/// the probe refuses a binding written for another. That is what stops a
/// profile emitted under one classification from being read under a different
/// one -- the bytes would still parse, and the answer could still be wrong.
///
/// This is the revision of a release built without
/// `--route_b_untabled_overrides`; see [routeBReleaseProbeRevisionFor].
const routeBReleaseProbeRevision = 1;

/// The probe revision a release built with `--route_b_untabled_overrides`
/// writes.
///
/// Only such a release has selectors with no dispatch-table row, and only for
/// those is a switchable call naming the selector evidence that a call reaches
/// the patched body. The probe counts switchable sites for a binding of this
/// revision alone, so a release built without the flag cannot pass on an
/// unrelated call of the same name, and a revision-1 probe refuses the binding
/// instead of reading it without that category.
const routeBUntabledReleaseProbeRevision = 2;

/// The probe revision to bind a release built with [buildArgs] to.
///
/// gen_snapshot applies its options in order, so the last mention of the flag
/// decides, as it does for gen_snapshot.
int routeBReleaseProbeRevisionFor(List<String> buildArgs) {
  const prefix = '--extra-gen-snapshot-options=';
  const flag = '--$routeBUntabledOverridesFlag';
  var untabled = false;
  for (final arg in buildArgs) {
    if (!arg.startsWith(prefix)) continue;
    for (final option in arg.substring(prefix.length).split(',')) {
      if (option == flag || option == '$flag=true') {
        untabled = true;
      } else if (option == '--no-$routeBUntabledOverridesFlag' ||
          option == '$flag=false') {
        untabled = false;
      }
    }
  }
  return untabled
      ? routeBUntabledReleaseProbeRevision
      : routeBReleaseProbeRevision;
}

/// The three answers the publication decision is allowed to see.
enum RouteBSurvival {
  /// At least one qualifying caller-owned call site survived compilation.
  survivingCallsite,

  /// The target exists in the release and NO qualifying call site survived.
  /// Authoritative absence: a patch would attach and change nothing.
  noSurvivingCallsite,

  /// The question could not be answered. Not absence -- the instrument could
  /// not establish the fact, which is a different thing and has a different
  /// remediation.
  unknown,
}

/// One target's verdict, with the instrument's own finer result kept so a
/// refusal can say WHY rather than just that it refused.
class RouteBSurvivalVerdict {
  /// {@macro route_b_survival_verdict}
  const RouteBSurvivalVerdict({
    required this.survival,
    required this.instrumentResult,
    this.detail,
    this.evidence = const {},
    this.inlinedInto,
  });

  /// The product-level answer.
  final RouteBSurvival survival;

  /// The probe's internal result, e.g. `ZERO_QUALIFYING_CALLSITES`,
  /// `TARGET_NOT_FOUND`, `ARTIFACT_BINDING_MISMATCH`. Four distinct instrument
  /// results collapse to [RouteBSurvival.unknown]; collapsing them in the
  /// MESSAGE too would tell an operator to fix the wrong thing.
  final String instrumentResult;

  /// The probe's explanation, when it gave one.
  final String? detail;

  /// The raw referrer categories, carried verbatim for the log.
  final Map<String, Object?> evidence;

  /// The members whose release code holds an INLINED copy of the target, in
  /// `library#selector` form.
  ///
  /// Null when the probe did not say, which a probe from before inlining
  /// evidence existed never does. Null is "not established", never "none":
  /// the producer then decides exactly as it did before this field existed.
  final Set<String>? inlinedInto;

  /// Whether publication may continue for this target.
  bool get permitsPublication => survival == RouteBSurvival.survivingCallsite;
}

/// Asks about a batch of targets at once. Injected so the producer's decision
/// can be tested without a cell, a release, or a snapshot profile.
typedef RouteBSurvivalOracle =
    Map<String, RouteBSurvivalVerdict> Function(List<String> targets);

/// Maps the probe's internal result model to the product's three answers.
///
/// Deliberately explicit rather than a default case: a NEW instrument result
/// must not silently fall into either bucket. An unrecognised result is
/// [RouteBSurvival.unknown], which refuses.
RouteBSurvival survivalForInstrumentResult(String result) {
  switch (result) {
    case 'ONE_OR_MORE_QUALIFYING_CALLSITES':
      return RouteBSurvival.survivingCallsite;
    case 'ZERO_QUALIFYING_CALLSITES':
      return RouteBSurvival.noSurvivingCallsite;
    case 'TARGET_NOT_FOUND':
    case 'TARGET_AMBIGUOUS':
    case 'PROFILE_INVALID':
    case 'ARTIFACT_BINDING_MISMATCH':
      return RouteBSurvival.unknown;
    default:
      return RouteBSurvival.unknown;
  }
}

/// Runs the cell's release probe and returns one verdict per requested target.
///
/// [releaseArtifactSha256] is the digest of the artifact this patch will be
/// applied to, computed from the bytes the patcher actually has. The probe
/// compares it against the digest the release recorded beside the profile, so a
/// profile of a different build cannot be read as evidence about this one --
/// matching versions, revisions, filenames and even target names do not make it
/// evidence.
RouteBSurvivalOracle cellSurvivalOracle({
  required RouteBCompiler compiler,
  required File profile,
  required File binding,
  required String releaseArtifactSha256,
  String? cellId,
  ProcessResult Function(String, List<String>) run = Process.runSync,
}) {
  return (targets) {
    if (targets.isEmpty) return {};
    final result = run(compiler.runtime.path, [
      compiler.releaseProbe.path,
      '--profile',
      profile.path,
      '--binding',
      binding.path,
      '--artifact-sha256',
      releaseArtifactSha256,
      if (cellId != null) ...['--cell-id', cellId],
      for (final t in targets) ...['--target', t],
    ]);

    if (result.exitCode != 0) {
      // The probe could not run at all. That is UNKNOWN for every target: an
      // instrument that failed to execute has said nothing about the code.
      return _allUnknown(
        targets,
        'PROBE_FAILED',
        'the release probe exited ${result.exitCode}: '
            '${'${result.stderr}'.trim()}',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode('${result.stdout}');
    } on FormatException catch (error) {
      return _allUnknown(
        targets,
        'PROBE_OUTPUT_UNREADABLE',
        'the release probe did not emit JSON: ${error.message}',
      );
    }
    if (decoded is! Map || decoded['targets'] is! List) {
      return _allUnknown(
        targets,
        'PROBE_OUTPUT_UNREADABLE',
        'the release probe emitted no targets array',
      );
    }

    final verdicts = <String, RouteBSurvivalVerdict>{};
    for (final entry in decoded['targets'] as List) {
      if (entry is! Map) continue;
      final target = entry['target'];
      final instrument = entry['result'];
      if (target is! String || instrument is! String) continue;
      final evidence = entry['evidence'] is Map
          ? (entry['evidence'] as Map).cast<String, Object?>()
          : const <String, Object?>{};
      final inlined = evidence['inlined_into'];
      verdicts[target] = RouteBSurvivalVerdict(
        survival: survivalForInstrumentResult(instrument),
        instrumentResult: instrument,
        detail: entry['detail'] as String?,
        evidence: evidence,
        inlinedInto: inlined is List
            ? inlined.whereType<String>().toSet()
            : null,
      );
    }
    // A target the probe did not answer about is UNKNOWN, never assumed green.
    for (final t in targets) {
      verdicts.putIfAbsent(
        t,
        () => const RouteBSurvivalVerdict(
          survival: RouteBSurvival.unknown,
          instrumentResult: 'NO_VERDICT',
          detail: 'the release probe returned no verdict for this target',
        ),
      );
    }
    return verdicts;
  };
}

Map<String, RouteBSurvivalVerdict> _allUnknown(
  List<String> targets,
  String instrumentResult,
  String detail,
) {
  return {
    for (final t in targets)
      t: RouteBSurvivalVerdict(
        survival: RouteBSurvival.unknown,
        instrumentResult: instrumentResult,
        detail: detail,
      ),
  };
}

/// The refusal text for a target that may not be published.
///
/// The three reasons are kept apart on purpose (spec §3): authoritative
/// absence, an instrument that could not find the target, and an instrument
/// that could not be trusted are different findings with different
/// remediations, and all three refuse.
String describeRouteBSurvivalRefusal(
  String target,
  RouteBSurvivalVerdict verdict,
) {
  final detail = verdict.detail == null ? '' : ' (${verdict.detail})';
  switch (verdict.survival) {
    case RouteBSurvival.noSurvivingCallsite:
      return '''
the release contains no surviving call site for it, so a patch would attach and change nothing.

The target IS present in the release, and every invocation of it was compiled away — constant-folded, or inlined and then folded. This is a fact about the release, not about the patch: cutting the patch differently will not help, and neither will retrying. The remediation is a new release in which the target is actually called${detail.isEmpty ? '' : detail}''';
    case RouteBSurvival.unknown:
      return '''
whether a call site for it survived compilation could not be established, and an unproven prerequisite is not a passing one.

The instrument reported ${verdict.instrumentResult}$detail. This is NOT a finding that the call site is absent — it is the absence of a finding, which refuses for a different reason and has a different remediation''';
    case RouteBSurvival.survivingCallsite:
      // Not a refusal. Kept exhaustive so a new enum value cannot slip through
      // as an accidental pass.
      return 'a surviving call site was found; this is not a refusal';
  }
}

/// The members a patch must ALSO replace for its replacement of a target to
/// take effect, or null when no set of replacements can.
///
/// [verdict] is the release probe's answer for the target, and [callers] the
/// analysis's app members that name it in the patched kernel (null when the
/// analysis predates callers).
///
/// - A target some release code INLINED runs its old body inside that code
///   whatever the patch attaches to the target itself, so that code must be
///   replaced too. This holds when call sites ALSO survived: replacing the
///   target alone would then change some paths and not others, which is worse
///   than refusing.
/// - A target with no surviving call site and no inlined copy was folded away
///   or is unreachable. Replacing the members that name it in the patched
///   kernel makes them call it again, from bytecode, which runs the patch's
///   body. With no such member, nothing can make the edit run, and that stays
///   a refusal.
/// - An unanswered question stays a refusal, as does an answer from a probe
///   that does not report inlining: for those the result is exactly the
///   decision this function predates, empty for a surviving call site and null
///   otherwise.
Set<String>? routeBCompanionsFor(
  RouteBSurvivalVerdict verdict, {
  List<String>? callers,
}) {
  final inlined = verdict.inlinedInto;
  if (inlined == null) return verdict.permitsPublication ? const {} : null;
  switch (verdict.survival) {
    case RouteBSurvival.survivingCallsite:
      return inlined;
    case RouteBSurvival.noSurvivingCallsite:
      if (inlined.isNotEmpty) return inlined;
      if (callers != null && callers.isNotEmpty) return callers.toSet();
      return null;
    case RouteBSurvival.unknown:
      return null;
  }
}

/// The refusal for a target whose copies elsewhere the patch does not replace.
///
/// [canCarry] is whether the coverage analyzer could have carried them: when
/// it could not, the cell is the reason, and saying so points at the fix.
String describeRouteBMissingCompanions(
  List<String> missing, {
  required bool canCarry,
}) {
  final which = missing.length == 1 ? 'it' : 'them';
  return 'the release runs a copy of it inside ${missing.join(', ')} '
      '(inlined or folded there), and this patch does not replace $which. '
      'Replacing the target alone would change some paths and leave the rest '
      "running the release's body.${canCarry ? '' : _carryUnsupported}";
}

const _carryUnsupported =
    " This release's compiler cell predates carrying such members into a "
    'patch; a cell whose coverage analyzer speaks version 15 or later does it '
    'automatically.';
