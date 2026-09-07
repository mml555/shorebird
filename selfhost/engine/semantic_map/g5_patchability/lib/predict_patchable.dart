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
      case '--release-pragmas':
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
    _die('--release-pragmas is required: retention must be proven present in '
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

  // THE EXACT-RELEASE RETENTION PROOF. dump_pragmas reports, per declaration in
  // the built release kernel, which dyn-module annotations it actually carries.
  // Keyed loosely by (library, owner, name) because that document uses
  // 'procedure' for every procedure kind.
  final releasePragmas = <String, Set<String>>{};
  for (final r in (release['rows'] as List).cast<Map<String, Object?>>()) {
    final k = '${r['library']}#${r['owner'] ?? ''}#${r['name']}';
    releasePragmas
        .putIfAbsent(k, () => <String>{})
        .addAll((r['pragmas'] as List).cast<String>());
  }
  bool releaseHas(String library, String? owner, String name, String cls) {
    final want = pragmaForClass[cls];
    if (want == null) return false;
    return releasePragmas['$library#${owner ?? ''}#$name']?.contains(want) ??
        false;
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
      if ((br['private_writes'] as List).isNotEmpty) {
        reasons.add('PRIVATE_WRITE');
      }
      if (br['references_private_type'] == true) {
        reasons.add('PRIVATE_TYPE_REFERENCE');
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
        final present = onClass && owner != null
            ? releaseHas(library, null, owner, c)
            : releaseHas(library, owner, name, c);
        if (!present) {
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
