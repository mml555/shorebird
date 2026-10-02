import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/route_b_compiler_cache.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:shorebird_cli/src/route_b_release_kernels.dart';
import 'package:shorebird_cli/src/shorebird_scope.dart';
import 'package:test/test.dart';

void main() {
  group('shorebirdScope', () {
    /// The scope `bin/shorebird.dart` actually runs commands inside.
    R runWithProductionScope<R>(R Function() body) => runScoped(
      body,
      values: shorebirdScope(commandStartedAt: DateTime(2026, 8, 11)),
    );

    // A ref that is created but never registered throws only when something
    // first READS it. Every unit test injects its own doubles, so no unit test
    // can notice the omission — the Route B refs were missing from the
    // production scope until a real iOS release reached the import-kernel step
    // on a device, after the build had already run and verified 7,109 patchable
    // call sites.
    //
    // These read through the real accessors, which is the operation that threw.
    group('resolves the Route B refs', () {
      test('the compiler-cell resolver', () {
        expect(
          () => runWithProductionScope(() => routeBCompilerResolver),
          returnsNormally,
        );
      });

      test('the coverage analyzer', () {
        expect(
          () => runWithProductionScope(() => routeBCoverageAnalyzer),
          returnsNormally,
        );
      });

      test('the producer', () {
        expect(
          () => runWithProductionScope(() => routeBProducer),
          returnsNormally,
        );
      });

      test('the release kernel builder', () {
        expect(
          () => runWithProductionScope(() => routeBReleaseKernelBuilder),
          returnsNormally,
        );
      });
    });

    test('registers every ref exactly once', () {
      // A duplicated ref is a silent last-one-wins, and the set literal makes
      // that easy to introduce while merging.
      final refs = shorebirdScope(commandStartedAt: DateTime(2026, 8, 11));
      expect(refs.length, refs.toSet().length);
    });
  });
}
