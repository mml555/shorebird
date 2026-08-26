// Every ref reachable through a top-level getter must be registered in the
// production scope.
//
// THE FAILURE THIS CATCHES. `shorebird_scope.dart`'s own comment says it:
// "Registered here or `read` throws at the moment a Route B release or patch
// needs them — which unit tests cannot catch, because they inject every ref
// they use." On 2026-08-26 an obfuscated iOS patch died with
//
//   Bad state: read(ScopedRef<GenSnapshotProbe>) was called in a scope which
//   does not contain a corresponding value for the provided ref
//
// because `genSnapshotProbeRef` was never added to the list. Every unit test
// passed, because each injects the refs it needs.
//
// So this is a SOURCE-LEVEL check rather than a behavioural one: it derives the
// set of refs that have a top-level `read(...)` getter and requires each to
// appear in the scope. Deriving it is the point — a hand-maintained list here
// would drift exactly the way the scope did.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('every ref with a top-level getter is in shorebirdScopeValues', () {
    final lib = Directory('lib/src');
    expect(lib.existsSync(), isTrue, reason: 'run from packages/shorebird_cli');

    final scope = File(
      'lib/src/shorebird_scope.dart',
    ).readAsStringSync();

    // A ref is "reachable through a top-level getter" when a file declares
    // `<name>Ref = create(` AND reads it outside a class, i.e. the pattern
    // `=> read(<name>Ref)`. That second half matters: refs read only inside a
    // class that already received them are not scope-dependent.
    final needed = <String, String>{};
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final text = entity.readAsStringSync();
      for (final m in RegExp(
        r'=>\s*read\((\w+Ref)\)',
      ).allMatches(text)) {
        final ref = m.group(1)!;
        // Only refs DECLARED in lib/src count; a ref from a package we depend
        // on is that package's business.
        if (RegExp('final\\s+$ref\\s*=').hasMatch(text)) {
          needed[ref] = entity.path;
        }
      }
    }

    expect(
      needed,
      isNotEmpty,
      reason: 'the derivation found nothing, which would make this vacuous',
    );

    // A ref is SATISFIED if it is in the production scope -- either as a bare
    // entry or via `.overrideWith(...)`, both of which appear there -- or if it
    // is provided by some nested `runScoped` elsewhere in lib/. The last case is
    // legitimate and real: `isJsonModeRef` is supplied per-invocation by the
    // command runner, and requiring it globally would be wrong.
    //
    // A first version of this test checked only for a bare entry and flagged two
    // refs that were fine. Over-collecting is as useless as not checking: a test
    // that cries wolf gets deleted.
    final provided = StringBuffer(scope);
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        provided.write(entity.readAsStringSync());
      }
    }
    final everything = provided.toString();

    final missing = <String>[];
    for (final entry in needed.entries) {
      final bare = RegExp(
        '^\\s*${entry.key},\\s*\$',
        multiLine: true,
      ).hasMatch(scope);
      final overridden = everything.contains('${entry.key}.overrideWith');
      if (!bare && !overridden) {
        missing.add('${entry.key}  (declared in ${entry.value})');
      }
    }

    expect(
      missing,
      isEmpty,
      reason:
          'these refs have a top-level getter but are NOT in '
          'shorebirdScopeValues, so `read` will throw the first time a real '
          'command needs them:\n  ${missing.join('\n  ')}',
    );
  });
}
