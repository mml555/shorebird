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

  // Now the producer itself. Everything it needs beyond the document is
  // deliberately absent, so it must refuse before touching an artifact; a
  // refusal that arrived later would not be evidence about the census reason.
  final tmp = Directory.systemTemp.createTempSync('demand_replay');
  try {
    const RouteBProducer().produce(
      compiler: _unusableCompiler(),
      coverage: coverage,
      capabilities: grant ? _grantFromDocument(coverage) : null,
      releaseImportKernel: File('${tmp.path}/absent.dill'),
      releaseBuildId: 'demand-replay',
      workingDirectory: Directory('${tmp.path}/work'),
      projectRoot: tmp,
    );
    say('PRODUCER: did NOT refuse (it got past admission)');
  } on RouteBUnsupportedTarget catch (e) {
    say('PRODUCER REFUSED');
    say('  target: ${e.target}');
    say('  reason: ${e.reason}');
  } on Object catch (e) {
    // Any other failure is reported verbatim rather than swallowed: it means
    // admission was passed and the producer failed later, which is a different
    // fact and must not be presented as a refusal.
    say('PRODUCER failed AFTER admission: ${e.runtimeType}');
    say('  ${e.toString().split('\n').first}');
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

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
