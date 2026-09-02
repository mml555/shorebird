// D-DEMAND-1 control 3. Replays a REAL historical refusal through the actual
// producer, far enough to show that the census's reason is the production
// reason and not just a parallel opinion.
//
// It deliberately does NOT stub the refusal path. `RouteBCoverage.fromJson` is
// the shipping parser and `RouteBProducer.produce` the shipping producer; the
// refusal fires while it walks the changed members, before any artifact is
// needed, which is why this can run without a release container.
import 'dart:io';

import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';

/// One writer, so consecutive report lines are not a receiver duplicated
/// a dozen times.
void say(String message) => stdout.writeln(message);

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: demand_replay_refusal.dart <pair.json> [target]');
    exit(64);
  }
  final doc = File(args[0]);
  if (!doc.existsSync()) {
    stderr.writeln('no document at ${args[0]}');
    exit(66);
  }

  final grant = args.contains('--grant');
  // The REAL manifest the release itself would have published, generated from
  // that release's own kernels by `route_b_gen_dynamic_interface`. Granting
  // from the candidate's source instead would manufacture permission the
  // release never gave, which is the one thing this replay must not do.
  final manifestArg = args.indexOf('--manifest');
  final manifestPath = manifestArg >= 0 && manifestArg + 1 < args.length
      ? args[manifestArg + 1]
      : null;
  final enumerate = args.contains('--enumerate');
  final importArg = args.indexOf('--release-import');
  final importPath = importArg >= 0 && importArg + 1 < args.length
      ? args[importArg + 1]
      : null;
  final coverage = RouteBCoverage.fromJson(doc.readAsStringSync());
  say('document  : ${args[0].split('/').last}');
  say('verdict   : ${coverage.verdict}');
  say('changed   : ${coverage.changed.length}');
  say('rejections: ${coverage.rejections.length}');
  for (final r in coverage.rejections) {
    say('  [${r.category}] ${r.target.split('#').last}');
  }

  // What the SHIPPING parser says each changed member's lowering carries. The
  // census reads the same field, so a disagreement here would mean the census
  // and the product are reading different documents.
  say('lowering keys: ${coverage.lowering.length}');
  final wanted = args.length > 1 ? args[1] : null;
  for (final entry in coverage.lowering.entries) {
    if (wanted != null && !entry.key.contains(wanted)) continue;
    final low = entry.value;
    say('  ${entry.key.split('#').last}');
    say('    unsupported      : ${low.unsupported}');
    say('    superInvocations : ${low.superInvocations.length}');
    say(
      '    releaseSuperTargets present: '
      '${low.releaseSuperTargets != null}',
    );
  }

  // Now the producer itself. Every refusal is enumerated rather than only the
  // first: `produce` stops at the first problem, so a document with several
  // refusable targets would otherwise report one and hide the rest. Each
  // iteration removes the target that just refused from the CHANGED set and
  // asks again. Nothing else is altered -- `rejections` and `verdict` stay as
  // the analyzer wrote them, because rewriting a verdict to make the replay
  // proceed would be fabricating the document.
  final capabilities = manifestPath != null
      ? RouteBCapabilities.fromJson(File(manifestPath).readAsStringSync())
      : (grant ? _grantFromDocument(coverage) : null);
  if (manifestPath != null) {
    say('capabilities: REAL manifest from ${manifestPath.split('/').last}');
  }

  var current = coverage;
  final refused = <String, String>{};
  var passed = false;
  var rounds = 0;
  final tmp = Directory.systemTemp.createTempSync('demand_replay');
  try {
    while (rounds++ < 200) {
      try {
        const RouteBProducer().produce(
          compiler: _unusableCompiler(),
          coverage: current,
          capabilities: capabilities,
          releaseImportKernel: File(importPath ?? '${tmp.path}/absent.dill'),
          releaseBuildId: 'demand-replay',
          workingDirectory: Directory('${tmp.path}/work'),
          projectRoot: tmp,
        );
        passed = true;
        break;
      } on RouteBUnsupportedTarget catch (e) {
        refused[e.target] = e.reason;
        if (!enumerate) break;
        current = _without(current, e.target);
        if (current.changed.isEmpty && current.conditional.isEmpty) break;
      } on Object catch (e) {
        // Reached the compiler (or something past admission). That is an
        // ADMISSION PASS for every target still in the document, and is
        // reported as such rather than counted as a refusal.
        say('PAST ADMISSION (${e.runtimeType})');
        passed = true;
        break;
      }
    }
  } finally {
    tmp.deleteSync(recursive: true);
  }

  say('PRODUCER RESULT');
  say('  refused targets: ${refused.length}');
  refused.forEach((target, reason) {
    say('  REFUSE\t$target\t$reason');
  });
  say('  admission passed for the remainder: $passed');
}

/// The coverage document without [target] in the sets the producer walks.
///
/// `rejections` and `verdict` are untouched: they are the analyzer's statement
/// about this pair, and editing them to keep the replay going would change what
/// the document says.
RouteBCoverage _without(RouteBCoverage c, String target) => RouteBCoverage(
  verdict: c.verdict,
  changed: c.changed.where((t) => t != target).toList(),
  added: c.added,
  removed: c.removed,
  representable: c.representable.where((t) => t != target).toList(),
  conditional: c.conditional.where((t) => t != target).toList(),
  rejections: c.rejections,
  refusalSummary: c.refusalSummary,
  signatures: c.signatures,
  sources: c.sources,
  lowering: c.lowering,
);

/// A REAL [RouteBCompiler], pointing at paths that do not exist.
///
/// Not a mock: the producer must refuse during admission, before it needs any
/// of these. If it ever reaches one, the failure is a missing file rather than
/// a refusal, and main() reports that distinctly instead of counting it as
/// agreement.
RouteBCompiler _unusableCompiler() {
  final absent = File('/nonexistent/route-b-demand-replay');
  return RouteBCompiler(
    runtime: absent,
    compilerSnapshot: absent,
    platformDill: absent,
    analyzer: absent,
    frontend: absent,
    interfaceGenerator: absent,
    releaseProbe: absent,
    flutterPlatformDill: absent,
    provenance: 'demand-replay: deliberately unusable',
  );
}

/// A capability manifest granting EXACTLY the private members this document
/// says the release would have had to grant, keyed the way
/// `refuseInstanceMember` checks them.
///
/// Not a permissive stub. Without it, any changed method that touches a private
/// member refuses on "this release published no capability manifest" — which is
/// a property of the harness supplying none, not of the change. Granting the
/// document's own reported keys isolates the question this control asks: does
/// the CONSTRUCT gate admit a change the census called admissible.
RouteBCapabilities _grantFromDocument(RouteBCoverage coverage) {
  final keys = <String>{};
  for (final entry in coverage.lowering.entries) {
    final origin = entry.value.origin;
    if (origin != null) {
      keys.add('${origin.library}#${origin.className}#${origin.member}');
    }
    for (final access in entry.value.accesses) {
      final t = access.privateTarget;
      if (t != null) keys.add('${t.library}#${t.className}#${t.name}');
    }
  }
  return RouteBCapabilities(
    policy: "demand-replay: granted from the document's own reported keys",
    topLevelCallable: const {},
    staticsCallable: const {},
    instanceCallable: keys,
    classesConstructible: const {},
    skipped: const {},
  );
}
