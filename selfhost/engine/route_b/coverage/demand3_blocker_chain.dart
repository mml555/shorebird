// cspell:words cand
// D-DEMAND-3. The FULL blocker chain for one changed method, measured through
// the shipping producer.
//
// `demand_replay_refusal.dart` (the frozen D-DEMAND-1/2 control) answers "does
// the producer refuse this target?" and stops at the first reason. That is the
// right question for a compatibility percentage and the wrong one for choosing
// a feature: a target whose load-bearing refusal is `method_tearoff` is only a
// candidate unlock if removing THAT construct does not land immediately on a
// second refusal.
//
// So this tool asks repeatedly. Each round it records the refusal, applies the
// one RELAXATION that corresponds to that refusal class, and asks again —
// until the producer admits the target or until the refusal is one no
// relaxation models.
//
// WHAT A RELAXATION IS, and what it is not. Every relaxation edits the INPUT
// DOCUMENTS this harness feeds the producer. None of them edits the product,
// and none of them disables a gate: after `constructs` is relaxed the
// capability gate, the reachability gate, the signature gate and the super
// gates all still run and still refuse. A relaxation is the question "suppose
// the analyzer/lowering had been able to carry this shape — what would refuse
// next?", asked of the real producer.
//
// WHAT THIS DOES NOT ESTABLISH. An admitted target is not a compiled one: no
// cell is supplied (deliberately — D-PRODUCER-DEMAND-2 recorded that compiling
// against a mismatched platform dill produces mass `exit 254` that measures the
// mismatch), and release binding/signature evidence and the survival oracle are
// absent for a historical commit. Every count this produces is therefore an
// UPPER BOUND on real unlocks.
//
// WHY THIS LIVES OUTSIDE `packages/shorebird_cli`. It imports that package's
// libraries and was first written under its `tool/`, which is the obvious home
// — but `SUPPORTED_STATE.yaml` freezes that package's git TREE object, and
// `verify_supported_state.sh` then failed with a product-tree drift whose
// entire content was this one harness file. Restamping a qualification record
// to accommodate a measurement tool would blunt the one check that catches real
// product drift, so the tool moved. Run it from the repo root:
//
//     dart --packages=.dart_tool/package_config.json run \
//       selfhost/engine/route_b/coverage/demand3_blocker_chain.dart …
import 'dart:convert';
import 'dart:io';

import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';

/// The relaxations this tool can model, in the order the producer's gates run.
///
/// `constructs` covers every `lowering.unsupported` entry, because that is one
/// gate in the product (`_lower` refuses on the whole list at once) even though
/// the census names its cases separately — `method_tearoff` and `this_escape`
/// are both the unconsumed-`this` case, split by AST parent kind.
enum Relaxation {
  /// Suppose the lowering could carry every shape the analyzer flagged.
  constructs,

  /// Suppose the release had retained every private member the body names.
  /// Models a RETENTION POLICY change, not a permission grant at patch time.
  capability,
}

/// The producer's private-identifier TEXT BACKSTOP, and why this tool stops
/// there instead of modelling past it.
///
/// The backstop (`_lower`, the `for (final name in _privateIdentifiers(text))`
/// loop) refuses a private name that appears in the emitted text but never
/// arrived as a structured access — `granted` is built only from
/// `lowering.accesses` entries carrying a private target, so RETENTION alone
/// cannot clear it: there is no key to grant.
///
/// An earlier version of this tool modelled resolution by injecting a synthetic
/// access. That was wrong and it reported a false unlock: accesses drive TEXT
/// EDITS BY OFFSET (`edits.add((access.offset, 0, …))`, then
/// `text.replaceRange(offset - span.start, …)`), so the synthetic offset of 0
/// produced a negative index, a `RangeError`, and the tool's catch-all counted
/// that crash as PAST_ADMISSION. Injecting a real offset would instead corrupt
/// the emitted text and could raise or suppress a refusal on its own.
///
/// It does not need modelling, because the backstop is the LAST admission gate:
/// `_lower` returns `_Lowered(...)` immediately after that loop, and everything
/// after it is compilation. So a chain whose final refusal is the backstop has
/// no further admission gate to hit, and that is a fact about the code rather
/// than a simulation. The report marks such a chain `BACKSTOP_FINAL true`.

String? _arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

void main(List<String> args) {
  final docPath = args.isEmpty ? null : args.first;
  final target = _arg(args, '--target');
  final manifestPath = _arg(args, '--manifest');
  final importPath = _arg(args, '--release-import');
  // The CANDIDATE's kernel. Supplied because the producer refuses an admitted
  // `super.` site when it is absent — a property of the harness, not of the
  // change. Omitting it made a real A-class blocker look multi-blocked behind
  // a D-class one: exactly the "missing historical evidence read as a measured
  // negative" mistake this lane is required to avoid. A real `shorebird patch`
  // always has this kernel; the demand corpus has it too, as `dills/<cand>`.
  final patchedKernelPath = _arg(args, '--patched-kernel');
  // `_unusableCompiler` defaults `supportsDirectSuperDualKernel` to false,
  // which made every admitted `super.` site refuse with "this release resolves
  // a compiler cell that does not implement routeBDirectSuperDualKernelV1" —
  // a statement about this harness's fake compiler, not about the frozen
  // stack. Pass this only with a MEASURED basis: the frozen cell
  // cd848320… advertises `--patched-verification-dill`, checked by running its
  // own dart2bytecode `--help`. Off by default so the flag can never be a
  // silent assumption.
  final superCapable = args.contains('--super-capable');
  if (docPath == null || target == null) {
    stderr.writeln(
      'usage: demand_blocker_chain.dart <pair.json> --target <t> '
      '[--manifest <m>] [--release-import <i>] [--patched-kernel <k>] '
      '[--super-capable]',
    );
    exit(64);
  }

  final doc =
      jsonDecode(File(docPath).readAsStringSync()) as Map<String, dynamic>;
  final manifest = manifestPath == null
      ? null
      : jsonDecode(File(manifestPath).readAsStringSync())
            as Map<String, dynamic>;

  // Which of the analyzer's reachability sets this target was offered in.
  // Reported, because a target in NONE of them is refused for reachability and
  // the producer never walks it — a distinct fact from a lowering blocker.
  String reach() {
    for (final key in ['patchable', 'conditional', 'unreachable', 'unknown']) {
      final set = (doc[key] as List<dynamic>? ?? const []).cast<String>();
      if (set.contains(target)) return key;
    }
    return 'not_offered';
  }

  // THE TARGET MUST BE IN A SET THE PRODUCER ACTUALLY WALKS, or this probe
  // measures nothing: `produce` builds its selector list from
  // `representable + conditional` (the document's `patchable` + `conditional`)
  // and never looks at `changed`. Hand it a target that is only in `changed`
  // and it walks an EMPTY list, refuses nothing, and this tool reports
  // ADMITTED — a vacuous pass.
  //
  // This bit twice. First with a hand-typed target string that matched nothing
  // (the real one contains a `//`), and then, after the guard was written
  // against `changed` as well, for four observations that really are in
  // `changed` and NOT in either walked set. Those are refused for
  // REACHABILITY — the release cannot reach the member — which is a distinct
  // finding from a lowering blocker, and reporting it as an unlock would have
  // inflated exactly the number this lane exists to produce.
  final walked = ['patchable', 'conditional'].any(
    (k) => (doc[k] as List<dynamic>? ?? const []).cast<String>().contains(
      target,
    ),
  );
  if (!walked) {
    stdout
      ..writeln('TARGET\t$target')
      ..writeln('DOC\t${docPath.split('/').last}')
      ..writeln('REACH\t${reach()}')
      ..writeln('ADMITTED\tnot_walked')
      ..writeln(
        'TERMINAL\tNOT IN patchable/conditional — `produce` walks '
        'representable+conditional only, so this target is refused for '
        'reachability and the producer never gates it',
      );
    exit(3);
  }

  final applied = <Relaxation>{};
  final chain = <(String, String)>[]; // (reason, relaxation applied next)
  // Set when the chain ended on the text backstop, which is the final
  // admission gate — see [backstopIsFinalAdmissionGate].
  var backstop = false;
  var admitted = false;
  var terminal = '';

  final tmp = Directory.systemTemp.createTempSync('blocker_chain');
  try {
    for (var round = 0; round < 8; round++) {
      // Built first, so the capability relaxation grants keys from the
      // RELAXED document — including any synthetic access added for the text
      // backstop. Deriving them from the original would leave those ungranted
      // and the chain would loop on the same refusal.
      final relaxed = _isolate(doc, target, applied);
      final coverage = RouteBCoverage.fromJson(jsonEncode(relaxed));
      final capabilities = manifest == null
          ? null
          : RouteBCapabilities.fromJson(
              jsonEncode(
                applied.contains(Relaxation.capability)
                    ? _withRetention(manifest, relaxed, target)
                    : manifest,
              ),
            );
      try {
        runScoped(
          () => const RouteBProducer().produce(
            compiler: _unusableCompiler(superCapable: superCapable),
            coverage: coverage,
            capabilities: capabilities,
            releaseImportKernel: File(importPath ?? '${tmp.path}/absent.dill'),
            releaseBuildId: 'demand-blocker-chain',
            workingDirectory: Directory('${tmp.path}/work'),
            projectRoot: tmp,
            patchedVerificationKernel: patchedKernelPath == null
                ? null
                : File(patchedKernelPath),
          ),
          values: {loggerRef.overrideWith(ShorebirdLogger.new)},
        );
        admitted = true;
      } on RouteBUnsupportedTarget catch (e) {
        if (e.target != target) {
          // The isolated document holds one target, so this should be
          // unreachable. Reported rather than swallowed: silently attributing
          // another target's refusal to this one is the exact failure mode
          // this tool exists to avoid.
          terminal = 'OTHER_TARGET_REFUSED(${e.target}) ${e.reason}';
          break;
        }
        final next = _relaxationFor(e.reason, applied);
        chain.add((e.reason, next?.name ?? '-'));
        if (next == null) {
          terminal = 'no relaxation models this refusal';
          break;
        }
        applied.add(next);
        continue;
      } on Object catch (e) {
        // Past admission: the producer got as far as needing the (absent)
        // compiler or release artifacts. Admission is what this measures.
        admitted = true;
        terminal = 'PAST_ADMISSION(${e.runtimeType})';
      }
      break;
    }
  } finally {
    tmp.deleteSync(recursive: true);
  }

  stdout
    ..writeln('TARGET\t$target')
    ..writeln('DOC\t${docPath.split('/').last}')
    ..writeln('REACH\t${reach()}')
    ..writeln('UNSUPPORTED\t${jsonEncode(_unsupportedOf(doc, target))}')
    ..writeln('PRIVATE_KEYS\t${jsonEncode(_privateKeysOf(doc, target))}');
  for (var i = 0; i < chain.length; i++) {
    stdout.writeln('BLOCKER\t$i\t${chain[i].$2}\t${chain[i].$1}');
  }
  if (chain.isNotEmpty && backstopName(chain.last.$1) != null) {
    backstop = true;
    terminal =
        'PRIVATE_REFERENCE_TEXT_BACKSTOP(${backstopName(chain.last.$1)}) '
        'final admission gate — nothing else gates this target';
  }
  stdout
    ..writeln('RELAXED\t${applied.map((r) => r.name).join(',')}')
    ..writeln('ADMITTED\t$admitted')
    ..writeln('BACKSTOP_FINAL\t$backstop')
    ..writeln('TERMINAL\t$terminal');
}

/// The relaxation that models [reason], or null when none does.
///
/// Matched on the producer's own text. Deliberately narrow: an unmatched reason
/// terminates the chain and is reported verbatim, so a refusal class this tool
/// has no model for shows up as itself rather than as a spurious unlock.
Relaxation? _relaxationFor(String reason, Set<Relaxation> applied) {
  final r = reason.toLowerCase();
  final isConstruct =
      r.contains('other than to read a member') ||
      r.contains('unsupported_parameter_shape') ||
      r.contains('named parameters') ||
      r.contains('optional positional') ||
      r.contains('unsupported_') ||
      r.contains('same offset') ||
      r.contains('compound');
  if (isConstruct && !applied.contains(Relaxation.constructs)) {
    return Relaxation.constructs;
  }
  // Ordered before the retention test: this refusal's text CONTAINS the
  // retention wording, but its cause is different — the identifier never
  // arrived as a structured access, so there is no key retention could grant.
  // Terminal by design; see [backstopIsFinalAdmissionGate].
  if (r.contains('a private identifier this analysis did not')) return null;
  final isCapability =
      r.contains('did not retain') ||
      r.contains('published no capability manifest') ||
      r.contains('was built to keep');
  if (isCapability && !applied.contains(Relaxation.capability)) {
    return Relaxation.capability;
  }
  return null;
}

/// The identifier named by the producer's text-backstop refusal, if this
/// refusal is that one.
String? backstopName(String reason) =>
    RegExp('its body names `([^`]+)`').firstMatch(reason)?.group(1);

List<String> _unsupportedOf(Map<String, dynamic> doc, String target) {
  final low =
      (doc['lowering'] as Map<String, dynamic>?)?[target]
          as Map<String, dynamic>?;
  return ((low?['unsupported'] as List<dynamic>?) ?? const [])
      .map((e) => '$e')
      .toList();
}

/// Every private key this target's body needs the release to have retained.
List<String> _privateKeysOf(Map<String, dynamic> doc, String target) {
  final low =
      (doc['lowering'] as Map<String, dynamic>?)?[target]
          as Map<String, dynamic>?;
  final keys = <String>{};
  for (final a in (low?['accesses'] as List<dynamic>? ?? const [])) {
    final p = (a as Map<String, dynamic>)['private'] as Map<String, dynamic>?;
    if (p == null) continue;
    keys.add('${p['library']}#${p['class']}#${p['name']}');
  }
  return keys.toList()..sort();
}

/// The document with only [target] in the sets the producer walks, and with
/// the requested relaxations applied to that target alone.
///
/// Isolating one target is what makes the chain attributable: with the whole
/// changed set present, the producer's first refusal could belong to any of
/// them.
Map<String, dynamic> _isolate(
  Map<String, dynamic> doc,
  String target,
  Set<Relaxation> applied,
) {
  final out = Map<String, dynamic>.of(doc);
  for (final key in ['changed', 'patchable', 'conditional']) {
    final set = (doc[key] as List<dynamic>? ?? const []).cast<String>();
    out[key] = set.contains(target) ? [target] : <String>[];
  }
  // `added`/`removed` are pair-level facts the producer gates on; left as the
  // analyzer wrote them, because dropping them would relax a gate this tool
  // does not model.
  if (applied.contains(Relaxation.constructs)) {
    final lowering = Map<String, dynamic>.of(
      (doc['lowering'] as Map<String, dynamic>?) ?? {},
    );
    final low = lowering[target];
    if (low is Map<String, dynamic>) {
      lowering[target] = {...low, 'unsupported': <String>[]};
    }
    out['lowering'] = lowering;
  }
  return out;
}

/// The manifest, plus every private key [target]'s body names.
///
/// Models a release built under a retention policy that kept them. It does NOT
/// touch `refused`, so a member the release explicitly refused to retain still
/// reads as granted here only because this is a hypothetical — which is why the
/// report separates B-class unlocks from A-class ones.
Map<String, dynamic> _withRetention(
  Map<String, dynamic> manifest,
  Map<String, dynamic> doc,
  String target,
) {
  final out = Map<String, dynamic>.of(manifest);
  final keys = _privateKeysOf(doc, target);
  for (final field in [
    'privateInstanceCallable',
    'privateStaticsCallable',
    'privateTopLevelCallable',
    'privateClassPublicMembers',
  ]) {
    final existing = ((out[field] as List<dynamic>?) ?? const [])
        .map((e) => '$e')
        .toSet();
    out[field] = (existing..addAll(keys)).toList();
  }
  return out;
}

/// A real [RouteBCompiler] pointing at paths that do not exist, so reaching one
/// is a distinguishable event rather than a silent pass. Same device as the
/// frozen replay control.
RouteBCompiler _unusableCompiler({required bool superCapable}) {
  final absent = File('/nonexistent/route-b-demand-blocker-chain');
  return RouteBCompiler(
    supportsDirectSuperDualKernel: superCapable,
    runtime: absent,
    compilerSnapshot: absent,
    platformDill: absent,
    analyzer: absent,
    frontend: absent,
    interfaceGenerator: absent,
    releaseProbe: absent,
    flutterPlatformDill: absent,
    provenance: 'demand-blocker-chain: deliberately unusable',
  );
}
