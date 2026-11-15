import 'dart:convert';

import 'package:shorebird_cli/src/route_b_carry.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_survival.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  useTempWorkingDirectory();

  const lib = 'package:app/main.dart';
  const increment = '$lib#_HomeState._increment';
  const start = '$lib#_HomeState._start';
  const initState = '$lib#_HomeState.initState';

  RouteBCoverage analysis({
    List<String> changed = const [increment],
    List<String> carried = const [],
    Map<String, List<String>> callers = const {},
    int version = routeBCarryAnalysisVersion,
    String verdict = 'accept',
    List<Map<String, Object?>> rejections = const [],
  }) => RouteBCoverage.fromJson(
    jsonEncode({
      'analysisVersion': version,
      'verdict': verdict,
      'changed': changed,
      if (version >= routeBCarryAnalysisVersion) ...{
        'carried': carried,
        'callers': callers,
      },
      'added': <String>[],
      'removed': <String>[],
      'patchable': <String>[],
      'conditional': [...changed, ...carried],
      'rejections': rejections,
      'refusalSummary': null,
    }),
  );

  RouteBSurvivalVerdict green([Set<String>? inlinedInto = const {}]) =>
      RouteBSurvivalVerdict(
        survival: RouteBSurvival.survivingCallsite,
        instrumentResult: 'ONE_OR_MORE_QUALIFYING_CALLSITES',
        inlinedInto: inlinedInto,
      );

  RouteBSurvivalVerdict zero([Set<String>? inlinedInto = const {}]) =>
      RouteBSurvivalVerdict(
        survival: RouteBSurvival.noSurvivingCallsite,
        instrumentResult: 'ZERO_QUALIFYING_CALLSITES',
        inlinedInto: inlinedInto,
      );

  RouteBSurvivalOracle over(Map<String, RouteBSurvivalVerdict> verdicts) =>
      (targets) => {
        for (final t in targets) t: ?verdicts[t],
      };

  group('carryRouteBCompanions', () {
    test('carries the member a changed one was inlined into', () {
      // `_increment` is called only from `_start`, which inlined it: the shape
      // of a setState helper. Replacing `_increment` alone changes nothing.
      final carries = <Set<String>>[];
      final result = carryRouteBCompanions(
        initial: analysis(),
        survival: over({
          increment: zero({start}),
          start: green(),
        }),
        analyze: (carry) {
          carries.add({...carry});
          return analysis(carried: carry.toList());
        },
      );

      expect(carries, [
        {start},
      ]);
      expect(result.carried, [start]);
    });

    test(
      'carries inlined copies of a target whose call sites ALSO survived',
      () {
        // Replacing it alone would change the calls and not the inlined copy.
        final result = carryRouteBCompanions(
          initial: analysis(),
          survival: over({
            increment: green({start}),
            start: green(),
          }),
          analyze: (carry) => analysis(carried: carry.toList()),
        );

        expect(result.carried, [start]);
      },
    );

    test('carries kernel callers of a folded target with no inlined copy', () {
      final result = carryRouteBCompanions(
        initial: analysis(
          callers: {
            increment: [start],
          },
        ),
        survival: over({
          increment: zero(),
          start: green(),
        }),
        analyze: (carry) => analysis(carried: carry.toList()),
      );

      expect(result.carried, [start]);
    });

    test('follows a carried member that was itself inlined', () {
      final carries = <Set<String>>[];
      carryRouteBCompanions(
        initial: analysis(),
        survival: over({
          increment: zero({start}),
          start: zero({initState}),
          initState: green(),
        }),
        analyze: (carry) {
          carries.add({...carry});
          return analysis(carried: carry.toList());
        },
      );

      expect(carries, [
        {start},
        {start, initState},
      ]);
    });

    test('never hands --carry to an analyzer that does not take it', () {
      var analyzed = false;
      final result = carryRouteBCompanions(
        initial: analysis(version: 13),
        survival: over({
          increment: zero({start}),
        }),
        analyze: (_) {
          analyzed = true;
          return analysis();
        },
      );

      expect(analyzed, isFalse);
      expect(result.canCarry, isFalse);
    });

    test('does not ask again for a member the analyzer would not carry', () {
      // An inliner outside the app: the analyzer ignores the key, so it never
      // appears under `carried`. Asking again would never end.
      var rounds = 0;
      final result = carryRouteBCompanions(
        initial: analysis(),
        survival: over({
          increment: zero({'package:flutter/x.dart#f'}),
        }),
        analyze: (_) {
          rounds++;
          return analysis();
        },
      );

      expect(rounds, 1);
      expect(result.carried, isEmpty);
    });

    test('stops at a refusal, for the patcher to report', () {
      final result = carryRouteBCompanions(
        initial: analysis(),
        survival: over({
          increment: zero({start}),
        }),
        analyze: (carry) => analysis(
          verdict: 'reject',
          carried: carry.toList(),
          rejections: [
            {'target': start, 'category': 'unreachable', 'reason': 'x'},
          ],
        ),
      );

      expect(result.verdict, RouteBVerdict.reject);
    });

    test('carries nothing when a probe reports no inlining evidence', () {
      var analyzed = false;
      carryRouteBCompanions(
        initial: analysis(),
        survival: over({increment: zero(null)}),
        analyze: (_) {
          analyzed = true;
          return analysis();
        },
      );

      expect(analyzed, isFalse);
    });
  });

  group('memoizeRouteBSurvival', () {
    test('asks about each target once', () {
      final asked = <List<String>>[];
      final oracle = memoizeRouteBSurvival((targets) {
        asked.add(targets);
        return {for (final t in targets) t: green()};
      });

      oracle([increment]);
      final second = oracle([increment, start]);

      expect(asked, [
        [increment],
        [start],
      ]);
      expect(second.keys, unorderedEquals([increment, start]));
    });

    test('leaves out a target the oracle did not answer', () {
      final oracle = memoizeRouteBSurvival((_) => {});
      expect(oracle([increment]), isEmpty);
    });
  });
}
