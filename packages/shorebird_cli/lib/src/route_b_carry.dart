// Route B (selfhost): carrying the members that hold a copy of a changed one.
//
// A release can run a member's body without calling it. The AOT compiler
// INLINES small members into their callers, and type-flow analysis FOLDS a
// member's result into them. Replacing that member then changes nothing on
// those paths, because nothing on them reads the member's entry point. The
// callers have to be replaced too, unchanged: their replacements are compiled
// from the patched kernel and so call the member for real.
//
// The release probe names the members holding an inlined copy; the coverage
// analysis names the members that call a member in the patched kernel. This
// file turns those facts into the set of members a patch must replace, and
// grows the analysis until it holds them. The producer applies the same rule,
// [routeBCompanionsFor], so a patch this loop could not complete is refused
// there with the members it lacks.
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_survival.dart';

/// Re-analyzes with ever more members carried until every target's companions
/// (see [routeBCompanionsFor]) are in the patch, or nothing more can be added.
///
/// [analyze] runs the coverage analyzer with the given members carried. It is
/// called only when [initial] says the analyzer can carry, so an older cell is
/// never handed `--carry`. The result is the last analysis: one that still
/// lacks a companion is the producer's to refuse, and one the analyzer refused
/// is the patcher's.
RouteBCoverage carryRouteBCompanions({
  required RouteBCoverage initial,
  required RouteBSurvivalOracle survival,
  required RouteBCoverage Function(Set<String> carry) analyze,
  void Function(String message)? log,
  int maxRounds = 8,
}) {
  var coverage = initial;
  final carry = <String>{};
  for (var round = 0; round < maxRounds; round++) {
    if (coverage.verdict != RouteBVerdict.accept || !coverage.canCarry) break;
    final selectors = {...coverage.representable, ...coverage.conditional};
    final verdicts = survival(selectors.toList()..sort());
    final need = <String>{};
    for (final key in selectors) {
      final verdict = verdicts[key];
      if (verdict == null) continue;
      final companions = routeBCompanionsFor(
        verdict,
        callers: coverage.releaseCallersOf(key),
      );
      if (companions == null) continue;
      need.addAll(companions.difference(selectors));
    }
    // A member asked for before and still absent is one the analyzer will not
    // carry (not an app member, or gone from one side). Asking again would
    // never end; the producer names it instead.
    need.removeAll(carry);
    if (need.isEmpty) break;
    log?.call(
      '[route-b] carrying ${need.length} unchanged member(s) that hold a copy '
      'of a changed one: ${(need.toList()..sort()).join(', ')}',
    );
    carry.addAll(need);
    coverage = analyze(carry);
  }
  return coverage;
}

/// [oracle], asking about each target once however many times it is asked.
///
/// The probe decodes the whole release profile per invocation, and the carry
/// loop asks again each round with the previous round's targets included.
RouteBSurvivalOracle memoizeRouteBSurvival(RouteBSurvivalOracle oracle) {
  final known = <String, RouteBSurvivalVerdict>{};
  return (targets) {
    final missing = [
      for (final t in targets)
        if (!known.containsKey(t)) t,
    ];
    if (missing.isNotEmpty) known.addAll(oracle(missing));
    return {
      for (final t in targets) t: ?known[t],
    };
  };
}
