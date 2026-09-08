// Copyright (c) 2026, the Shorebird self-host fork.
//
// predict_patchable.dart -- SEMANTIC-MAP-1 G5: per declaration, is it patchable?
//
//     predicted patchable  SUBSET-OF  mechanically demonstrated patchable
//
// An OVER-CLAIM -- one declaration predicted patchable that cannot be
// demonstrated -- is a FAIL_OPEN and fails the gate. An UNDER-CLAIM is safe
// degradation, reported as coverage. The asymmetry is the design: this refuses
// when unsure and never maximises a percentage.
//
// THIS FILE READS ONLY MAP ROWS AND RELEASE FACTS. It never reads the
// demonstrator, and the demonstrator never reads it; otherwise the subset check
// compares the model with itself.
//
// WHAT ROUND 1 GOT WRONG, all of it the same mistake in different places --
// asking a question ABOUT THE TARGET when the fact lives somewhere else:
//
//   * retention was "G4 measured this class" (`enforced_at_load.containsKey`),
//     which says nothing about whether THE EXACT RELEASE carries the entry;
//   * MISSING_CAN_BE_OVERRIDDEN read G4's REQUIREMENT list, which by
//     construction always contains it -- so the reason could never fire;
//   * PRIVATE_TYPE_REFERENCE used "a public member of a private class" as a
//     proxy for "this body names a private type". Different facts;
//   * PRIVATE_WRITE asked whether the TARGET has a collapsed write key, but the
//     dangerous write is one the patched BODY performs on another declaration;
//   * DEVIRTUALIZED_CALL_SITE and INLINED_BODY existed only as strings, with no
//     code able to emit them -- so two of #54's named arms silently defaulted
//     every declaration to patchable.
//
// ignore_for_file: avoid_print, implementation_imports
import 'dart:convert';
import 'dart:io';

Never _die(String m) {
  stderr.writeln('predict_patchable: $m');
  exit(2);
}

const refusalReasons = <String>[
  'DEVIRTUALIZED_CALL_SITE',
  'INLINED_BODY',
  'CALL_SITE_SHAPE_UNPROVEN',
  'ABI_SHAPE_UNSUPPORTED',
  'OWNER_ABI_SHAPE_UNSUPPORTED',
  'MISSING_CAN_BE_OVERRIDDEN',
  'PRIVATE_WRITE',
  'PRIVATE_TYPE_REFERENCE',
  'GENERATED_CODE',
  'RETENTION_UNPROVEN',
  'BODY_ENCODING_REFUSED',
  'BODY_REFERENCES_UNPROVEN',
  'NOT_RETAINED',
  'PRIVATE_REFERENCE_UNGRANTED',
  'PRIVATE_REFERENCE_UNRESOLVED',
  'RELEASE_IDENTITY_AMBIGUOUS',
  // RELEASE-LEVEL, and deliberately two reasons rather than one. "We could not
  // establish this release is patch-capable" is a different fact from "this
  // release is established as not patch-capable", and collapsing them would
  // turn a missing input into a positive claim about the artifact.
  'RELEASE_PATCHABILITY_UNPROVEN',
  'RELEASE_NOT_PATCHABLE_BUILD',
  // SM1-G5 DISPATCH. Two reasons, not one, for the same reason the release
  // pair above is two: "this declaration is reached by instance dispatch" and
  // "we cannot tell whether it is" are different facts, and merging them would
  // let a missing input read as a measurement.
  'NON_STATIC_DISPATCH_UNPROVEN',
  'STATIC_METADATA_UNUSABLE',
  // SM1-G5 PHASE B. The static-CALL path is closed by construction, but a
  // front-end transform can make a body stale without any call site being at
  // fault, and Route 2 cannot be shown to witness it.
  'FRONTEND_MATERIALIZATION_UNPROVEN',
];

/// The dynamic-interface entry a required retention class lowers to, as it
/// appears on the built release kernel. SM1-G4 established this mapping by
/// reading annotations off the artifact rather than the yaml.
const pragmaForClass = <String, String>{
  'callable': 'dyn-module:callable',
  'extendable': 'dyn-module:extendable',
  'can-be-used-as-type': 'dyn-module:can-be-used-as-type',
  'can-be-overridden': 'dyn-module:can-be-overridden',
};

void main(List<String> args) {
  String? g2Path, g3Path, g4Path, refsPath, releasePath, genPath;
  var outPath = 'predictions.json';
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String next() {
      if (i + 1 >= args.length) _die('$a needs a value');
      return args[++i];
    }

    switch (a) {
      case '--g2':
        g2Path = next();
      case '--g3':
        g3Path = next();
      case '--g4':
        g4Path = next();
      case '--refs':
        refsPath = next();
      case '--release-contract':
        releasePath = next();
      case '--generated':
        genPath = next();
      case '--out':
        outPath = next();
      default:
        _die('unknown argument: $a');
    }
  }
  if (g2Path == null || g3Path == null || g4Path == null) {
    _die('--g2, --g3 and --g4 row files are all required');
  }
  if (refsPath == null) {
    _die('--refs is required: private writes and private type references are '
        'facts about the BODY, and without them the predictor would be using '
        'target ownership as a proxy for what a body does');
  }
  if (releasePath == null) {
    // SM1-G4's carried-forward rule is that every required retention entry must
    // be PROVEN present in the exact release. With no release to inspect there
    // is no proof, and unproven refuses.
    _die('--release-contract is required: retention must be proven present in '
        'THE EXACT RELEASE, and "G4 measured this class" is not that proof');
  }

  Map<String, Object?> load(String p) =>
      jsonDecode(File(p).readAsStringSync()) as Map<String, Object?>;

  final g2 = load(g2Path);
  final g3 = load(g3Path);
  final g4 = load(g4Path);
  final refs = load(refsPath);
  final release = load(releasePath);

  final generated = <String>{};
  if (genPath != null) {
    for (final l in File(genPath).readAsLinesSync()) {
      final t = l.trim();
      if (t.isNotEmpty && !t.startsWith('#')) generated.add(t);
    }
  }

  String key(Object? library, Object? owner, Object? kind, Object? name) =>
      '$library#${owner ?? ''}#$kind#$name';
  String rowKey(Map<String, Object?> r) =>
      key(r['library'], r['owner'], r['kind'], r['name']);

  final privacyBy = <String, Map<String, Object?>>{};
  for (final r in (g3['rows'] as List).cast<Map<String, Object?>>()) {
    privacyBy[rowKey(r)] = r;
  }
  final retentionBy = <String, Map<String, Object?>>{};
  for (final r in (g4['rows'] as List).cast<Map<String, Object?>>()) {
    retentionBy[rowKey(r)] = r;
  }
  final refsBy = <String, Map<String, Object?>>{};
  for (final r in (refs['rows'] as List).cast<Map<String, Object?>>()) {
    refsBy[rowKey(r)] = r;
  }

  // THE EXACT-RELEASE RETENTION PROOF, at FULL identity.
  //
  // Round 2 keyed this `library#owner#name` and unioned the pragmas, so an
  // entry on `get:x` could stand as proof for `set:x`. Identity now includes
  // KIND, and a key answered by more than one release declaration is refused
  // rather than merged -- merging is how a proof becomes a guess.
  final releaseRows = <String, Map<String, Object?>>{};
  final releaseAmbiguous = <String>{};
  for (final r in (release['rows'] as List).cast<Map<String, Object?>>()) {
    final k = r['key'] as String;
    if (r['ambiguous'] == true) releaseAmbiguous.add(k);
    releaseRows[k] = r;
  }
  ({bool present, bool ambiguous, bool known}) releaseHas(
      String library, String? owner, String kind, String name, String cls) {
    final want = pragmaForClass[cls];
    if (want == null) return (present: false, ambiguous: false, known: false);
    final k = '$library#${owner ?? ''}#$kind#$name';
    final row = releaseRows[k];
    if (row == null) return (present: false, ambiguous: false, known: false);
    if (releaseAmbiguous.contains(k)) {
      return (present: false, ambiguous: true, known: true);
    }
    return (
      present: (row['contract_entries'] as List).contains(want),
      ambiguous: false,
      known: true,
    );
  }

  // Owner ABI, so a member of a class the map refuses cannot be predicted
  // patchable on the strength of its own signature alone.
  final classAbiShape = <String, String>{};
  for (final r in (g2['rows'] as List).cast<Map<String, Object?>>()) {
    if (r['kind'] == 'class') {
      classAbiShape['${r['library']}#${r['name']}'] =
          r['abi_shape'] as String? ?? 'unknown';
    }
  }

  // RELEASE-LEVEL PREREQUISITE, evaluated once. SM1-G5's positive control
  // measured that a release built without --patchable_static_calls attaches the
  // replacement, reports "APPLY ok", and keeps running the old body -- so no
  // declaration in such a release may be predicted patchable.
  final capability = release['release_patch_capability'] as String? ?? 'UNPROVEN';
  final releaseReason = switch (capability) {
    'PROVEN' => null,
    'NOT_PATCHABLE' => 'RELEASE_NOT_PATCHABLE_BUILD',
    _ => 'RELEASE_PATCHABILITY_UNPROVEN',
  };

  final out = <Map<String, Object?>>[];

  for (final r in (g2['rows'] as List).cast<Map<String, Object?>>()) {
    final k = rowKey(r);
    final reasons = <String>[];
    final kind = r['kind'] as String;
    final owner = r['owner'] as String?;
    final name = r['name'] as String;
    final library = r['library'] as String;
    final isStatic = r['static'] == true;

    final replaceable =
        const {'method', 'getter', 'setter', 'operator'}.contains(kind);
    if (!replaceable) reasons.add('ABI_SHAPE_UNSUPPORTED');

    // ---- FRONT-END MATERIALIZATION ---------------------------------------
    //
    // PHASE B closed the static-call question and opened this one.
    //
    // WHAT IS PROVEN SAFE: under --patchable_static_calls,
    // FlowGraphCompiler::GenerateStaticDartCall returns early and dispatches
    // through the callee's FUNCTION, which Function::AttachBytecode redirects
    // via SetInstructions(StubCode::InterpretCall()). The two forms that do not
    // consult the Function -- a PC-relative branch and a Code-holding pool slot
    // bound by ProgramVisitor::BindStaticCalls -- live only in the non-flag
    // branch of that one emitter, which has three call sites in the tree. So
    // for a static target in a flag-built release, the static-call inbound path
    // is redirectable by construction.
    //
    // WHAT IS NOT: a front-end transform can materialize a declaration's VALUE
    // into its callers before the VM compiler runs. This lane recorded the
    // behaviour directly -- route_b/packaging/container_target.dart and four
    // probe scripts note that a literal return is constant-folded by the
    // type-flow analysis EVEN UNDER vm:never-inline, and that a working patch
    // mechanism then reported OLD. Route 2's note records the VM inliner's own
    // decisions; whether it witnesses a kernel-level fold is UNTESTED, and it
    // cannot be tested on the canonical release without extending the corpus,
    // which needs a G1 projection producer that is not checked in.
    //
    // An untested mechanism that can produce stale behaviour is a refusal, not
    // a permission. This applies to every replaceable declaration, static or
    // not -- it is not an instance-dispatch fact.
    if (replaceable) reasons.add('FRONTEND_MATERIALIZATION_UNPROVEN');

    // ---- INSTANCE DISPATCH -----------------------------------------------
    //
    // SM1-G5's dispatch experiment settled this on one release AOT: Base.work
    // is reported NOT_INLINED by the route-2 reader, its replacement attaches
    // and returns the patched value when invoked directly, and an ordinary
    // call site STILL read the old value. The mechanism is in the shipped
    // machine code -- a dispatch-table call reads its entry point out of the
    // table indexed by the RECEIVER'S CLASS ID and never consults the callee's
    // pool entry, so attaching a body cannot redirect it.
    //
    // That mechanism is available to every declaration reached by instance
    // dispatch, and this gate cannot yet attribute a dispatch-table site to
    // the declarations it can reach -- that needs the precompiler's selector
    // map, which is not in the release. So a replaceable declaration that is
    // not PROVEN static refuses.
    //
    // THE CONVERSE IS NOT ASSERTED. `static == true` is not treated as safe:
    // it only avoids THIS refusal. The inbound call mechanism for static
    // declarations has not been closed, and CALL_SITE_SHAPE_UNPROVEN below
    // still applies to them.
    if (replaceable) {
      final staticFlag = r['static'];
      if (staticFlag is! bool) {
        // Absent, null, or not a boolean. An unusable fact is not a permission.
        reasons.add('STATIC_METADATA_UNUSABLE');
      } else if (!staticFlag) {
        reasons.add('NON_STATIC_DISPATCH_UNPROVEN');
      }
    }

    // ---- ABI, the declaration's own and its OWNER's ----------------------
    if ((r['abi_shape'] as String? ?? 'unknown') != 'supported') {
      reasons.add('ABI_SHAPE_UNSUPPORTED');
    }
    if (owner != null) {
      final ownerShape = classAbiShape['$library#$owner'];
      // `Box.unwrap` reads T -> T and looks supported while `Box` itself is
      // refused:type_parameters. Predicting the member patchable on its own
      // signature is too optimistic without a demonstrated carve-out.
      if (ownerShape != null && ownerShape != 'supported') {
        reasons.add('OWNER_ABI_SHAPE_UNSUPPORTED');
      }
    }

    if ((r['body_status'] as String? ?? 'unknown') != 'supported') {
      reasons.add('BODY_ENCODING_REFUSED');
    }

    // ---- what the BODY does, not what the target is ----------------------
    final br = refsBy[k];
    if (br == null) {
      if (replaceable) reasons.add('BODY_REFERENCES_UNPROVEN');
    } else {
      if (br['traversal_status'] != 'supported') {
        reasons.add('BODY_REFERENCES_UNPROVEN');
      }
      if (br['references_private_type'] == true) {
        reasons.add('PRIVATE_TYPE_REFERENCE');
      }
      // EVERY private reference the body makes is asked of G3, by mode. Round 2
      // consumed only writes and ignored reads entirely, leaving the historical
      // blocker family -- private member references, not just private types --
      // unchecked. A reference that cannot be resolved to a G3 declaration
      // fails closed: "we could not tell what this was" is not "there was
      // nothing to check".
      for (final ref in (br['private_refs'] as List)
          .cast<Map<String, Object?>>()) {
        final mode = ref['mode'] as String;
        if (ref['resolved'] != true) {
          reasons.add('PRIVATE_REFERENCE_UNRESOLVED');
          continue;
        }
        // EXACT LOOKUP, no fallback across kinds. Searching kinds and taking
        // the first match let a private getter's G3 row answer for a same-named
        // setter, which is evidence for one declaration authorising another.
        //
        // A refs document written before target_key existed refuses here rather
        // than crashing on a null cast: a stale input is exactly the case that
        // must not silently resolve to some other declaration.
        final tk = ref['target_key'];
        if (tk is! String) {
          reasons.add('PRIVATE_REFERENCE_UNRESOLVED');
          continue;
        }
        final target = privacyBy[tk];
        if (target == null) {
          reasons.add('PRIVATE_REFERENCE_UNRESOLVED');
          continue;
        }
        if (target['retained_in_release'] == false) {
          reasons.add('NOT_RETAINED');
        }
        switch (mode) {
          case 'write':
            // NOT a blanket refusal. SM1-G3 measured that a SETTER's key names
            // its mode (`set:x`), so a write through one can be proven granted;
            // it is a mutable FIELD whose single bare key serves both modes and
            // therefore can never prove a write. Refusing both would ignore the
            // very row-level distinction the exact identity exists to make.
            if (target['capability_key_write'] == null) {
              reasons.add('PRIVATE_REFERENCE_UNGRANTED');
            } else if (target['capability_key_identifies_mode'] != true) {
              reasons.add('PRIVATE_WRITE');
            }
          case 'construct':
            if (target['capability_key_construct'] == null) {
              reasons.add('PRIVATE_REFERENCE_UNGRANTED');
            }
          default:
            if (target['capability_key_read'] == null) {
              reasons.add('PRIVATE_REFERENCE_UNGRANTED');
            }
        }
      }
    }

    // ---- retention, PROVEN AGAINST THE EXACT RELEASE ---------------------
    final ret = retentionBy[k];
    if (ret == null) {
      if (replaceable) reasons.add('RETENTION_UNPROVEN');
    } else {
      if (ret['retained_in_release'] == false) reasons.add('NOT_RETAINED');
      for (final c in (ret['required_classes'] as List).cast<String>()) {
        final onClass = c == 'extendable' || c == 'can-be-used-as-type';
        final q = onClass && owner != null
            ? releaseHas(library, null, 'class', owner, c)
            : releaseHas(library, owner, kind, name, c);
        if (q.ambiguous) {
          reasons.add('RELEASE_IDENTITY_AMBIGUOUS');
        }
        if (!q.present) {
          // MISSING can-be-overridden is its own reason because SM1-G4
          // measured that omitting it FAILS OPEN -- the module loads and the
          // release's own body answers. It cannot be a runtime safety net, so
          // publication is the last place it can be caught.
          reasons.add(c == 'can-be-overridden'
              ? 'MISSING_CAN_BE_OVERRIDDEN'
              : 'RETENTION_UNPROVEN');
        }
      }
    }

    if (generated.contains(k) || generated.any(library.endsWith)) {
      reasons.add('GENERATED_CODE');
    }

    // ---- CALL-SITE SHAPE: unproven, and therefore refused ----------------
    //
    // #54 names devirtualized call sites and inlined bodies as adversarial
    // arms. Nothing here can yet establish either fact -- deciding them needs
    // the release's machine code, the way SL1-G4 read dispatch-table calls out
    // of the AOT with llvm-objdump. Until that exists the fact is UNKNOWN, and
    // an unknown that would make a patch silently ineffective must refuse.
    //
    // This is deliberately conservative to the point of refusing everything on
    // this corpus. Under-claim is safe degradation; the alternative is to
    // default two of #54's named arms to "patchable", which is the over-claim
    // the gate exists to prevent.
    if (replaceable) reasons.add('CALL_SITE_SHAPE_UNPROVEN');

    // Applies to every declaration, because it is a fact about the release
    // rather than about any one of them.
    if (releaseReason != null && replaceable) reasons.add(releaseReason);

    final uniq = reasons.toSet().toList()..sort();
    out.add({
      'key': k,
      'library': library,
      'owner': owner,
      'kind': kind,
      'name': name,
      'declaration_id': r['declaration_id'],
      'static': isStatic,
      'predicted_patchable': uniq.isEmpty,
      'refusal_reasons': uniq,
    });
  }

  final patchable = out.where((r) => r['predicted_patchable'] == true).length;
  final byReason = <String, int>{};
  for (final r in out) {
    for (final x in (r['refusal_reasons'] as List).cast<String>()) {
      byReason[x] = (byReason[x] ?? 0) + 1;
    }
  }

  File(outPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'schema': 'semantic-map-1/g5-predictions/2',
      'gate': 'SM1-G5',
      'issue': 54,
      'count': out.length,
      'predicted_patchable': patchable,
      // DIAGNOSTIC ONLY. #54: a percentage must never make an unsafe map
      // publishable, so the scorer is forbidden from letting this affect a
      // verdict.
      'coverage_diagnostic_only': out.isEmpty
          ? null
          : '${(patchable * 100 / out.length).toStringAsFixed(1)}%',
      'refusal_reason_vocabulary': refusalReasons,
      'release_patch_capability': capability,
      'release_patch_capability_evidence':
          release['release_patch_capability_evidence'],
      'refusal_histogram': byReason,
      'unproven_facts': [
        if (byReason.containsKey('CALL_SITE_SHAPE_UNPROVEN'))
          'call-site shape (devirtualized / inlined) is not yet decidable here, '
              'so every replaceable declaration is refused',
      ],
      'rows': out,
    })}\n',
  );
  print('  predictions=${out.length} patchable=$patchable '
      'refused=${out.length - patchable} -> $outPath');
}
