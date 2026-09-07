// Copyright (c) 2026, the Shorebird self-host fork.
//
// predict_patchable.dart -- SEMANTIC-MAP-1 G5: per declaration, is it patchable?
//
// THE RULE THIS EXISTS TO SATISFY:
//
//     predicted patchable  SUBSET-OF  mechanically demonstrated patchable
//
// An OVER-CLAIM -- one declaration predicted patchable that cannot be
// demonstrated -- is a FAIL_OPEN and fails the gate. An UNDER-CLAIM is safe
// degradation and is merely reported as coverage. The asymmetry is the whole
// design: this predictor is built to REFUSE when unsure, never to maximise a
// percentage.
//
// THIS FILE READS ONLY MAP ROWS. It never reads the demonstrator's output, and
// the demonstrator never reads this. If the two shared a model the subset check
// would compare the model with itself, which is #54's stated confound.
//
// THE HISTORICAL OVER-CLAIM THIS LANE ALREADY MEASURED. D-DEMAND-1 recorded
// that the shipping ANALYZER admits changes the shipping PRODUCER refuses --
// Wonderous 70.00% analyzer against 45.00% producer, later 50.00%. The cause
// was identified and then replicated across both corpora by
// D-PRODUCER-DEMAND-2: `private non-construction references`, i.e. a body that
// NAMES A PRIVATE TYPE. The analyzer modelled private MEMBER accesses and
// reported the capability key a release would have had to grant; it did not
// model a private TYPE named in a body, and the producer scans the source and
// refuses.
//
// So `PRIVATE_TYPE_REFERENCE` is a refusal reason here even though #54's list
// does not name it. Omitting it would reproduce a known, measured over-claim,
// which is precisely what this gate forbids.
//
// ignore_for_file: avoid_print, implementation_imports
import 'dart:convert';
import 'dart:io';

Never _die(String m) {
  stderr.writeln('predict_patchable: $m');
  exit(2);
}

/// Every reason a declaration may be refused. One reason per cause, because the
/// remedies differ and a merged reason cannot be acted on.
const refusalReasons = <String>[
  // #54's named arms
  'DEVIRTUALIZED_CALL_SITE',
  'INLINED_BODY',
  'ABI_SHAPE_UNSUPPORTED',
  'MISSING_CAN_BE_OVERRIDDEN',
  'PRIVATE_WRITE',
  'GENERATED_CODE',
  // derived from measured history, see the header
  'PRIVATE_TYPE_REFERENCE',
  // carried forward from SM1-G4's disposition
  'RETENTION_UNPROVEN',
  // fail-closed catch-alls
  'BODY_ENCODING_REFUSED',
  'NOT_RETAINED',
];

void main(List<String> args) {
  String? g2Path, g3Path, g4Path, genPath;
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
      case '--generated':
        genPath = next();
      case '--out':
        outPath = next();
      default:
        _die('unknown argument: $a');
    }
  }
  if (g2Path == null || g3Path == null || g4Path == null) {
    _die('--g2, --g3 and --g4 row files are all required: a prediction that '
        'ignores any of identity/ABI, privacy or retention would be guessing '
        'about the dimension it dropped');
  }

  Map<String, Object?> load(String p) =>
      jsonDecode(File(p).readAsStringSync()) as Map<String, Object?>;

  final g2 = load(g2Path);
  final g3 = load(g3Path);
  final g4 = load(g4Path);

  // Generated-code markers, supplied rather than guessed. D-DEMAND-1's own
  // correction was that a generated-file filter was applied to one table and
  // not another, counting 21 slang-generated methods in a corpus that is 97%
  // codegen. The list is an input so it can be audited.
  final generated = <String>{};
  if (genPath != null) {
    for (final l in File(genPath).readAsLinesSync()) {
      final t = l.trim();
      if (t.isNotEmpty && !t.startsWith('#')) generated.add(t);
    }
  }

  String key(Map<String, Object?> r) =>
      '${r['library']}#${r['owner'] ?? ''}#${r['kind']}#${r['name']}';

  final privacyBy = <String, Map<String, Object?>>{};
  for (final r in (g3['rows'] as List).cast<Map<String, Object?>>()) {
    privacyBy[key(r)] = r;
  }
  final retentionBy = <String, Map<String, Object?>>{};
  for (final r in (g4['rows'] as List).cast<Map<String, Object?>>()) {
    retentionBy[key(r)] = r;
  }
  final enforced = (g4['enforced_at_load'] as Map<String, Object?>);

  final out = <Map<String, Object?>>[];

  for (final r in (g2['rows'] as List).cast<Map<String, Object?>>()) {
    final k = key(r);
    final reasons = <String>[];
    final kind = r['kind'] as String;
    final owner = r['owner'] as String?;
    final isStatic = r['static'] == true;

    // A class, constructor or factory is not a replaceable BODY in this model.
    // Reported as refused rather than silently dropped, so the census adds up.
    final replaceable = const {'method', 'getter', 'setter', 'operator'}
        .contains(kind);

    // 1. ABI shape. G2 already refuses named parameters and type parameters in
    //    the row itself; the map states the boundary rather than a caller
    //    inferring it.
    final abiShape = r['abi_shape'] as String? ?? 'unknown';
    if (abiShape != 'supported') reasons.add('ABI_SHAPE_UNSUPPORTED');

    // 2. Body encoding. An unsupported body means the encoder hit a node
    //    outside its allowlist, so "unchanged" would mean "unchanged in the
    //    parts I looked at". It can never be predicted patchable.
    final bodyStatus = r['body_status'] as String? ?? 'unknown';
    if (bodyStatus != 'supported') reasons.add('BODY_ENCODING_REFUSED');

    // 3. Privacy. A write to a private declaration is refused: SM1-G3 measured
    //    that for a mutable field the manifest key cannot even express which
    //    mode it authorised, and ROADMAP P1.4 never claimed a private write.
    final priv = privacyBy[k];
    if (priv != null) {
      final effective = priv['effective_privacy_domain'] as String?;
      final isPrivate = effective != null && effective != 'public';
      if (isPrivate && priv['write_mode_exists'] == true &&
          priv['capability_key_identifies_mode'] == false) {
        reasons.add('PRIVATE_WRITE');
      }
      // The measured over-claim class. A private declaration whose own name is
      // public but whose OWNER is private is exactly the shape the producer
      // refuses when a body names the private type.
      if (isPrivate && priv['owner_is_private'] == true &&
          priv['is_private'] == false) {
        reasons.add('PRIVATE_TYPE_REFERENCE');
      }
    }

    // 4. Retention, per SM1-G4's carried-forward rule: every required entry
    //    must be PROVEN present in the exact release. Unproven is refused.
    final ret = retentionBy[k];
    if (ret == null) {
      if (replaceable) reasons.add('RETENTION_UNPROVEN');
    } else {
      if (ret['retained_in_release'] == false) reasons.add('NOT_RETAINED');
      final required = (ret['required_classes'] as List).cast<String>();
      // MISSING can-be-overridden is its own reason: SL1-G4 established that
      // without it the optimizer devirtualizes the call site, and SM1-G4
      // observed that omitting it FAILS OPEN -- the module loads and the old
      // body answers. It cannot be a runtime safety net, so it is refused here.
      if (replaceable && !isStatic && owner != null &&
          !required.contains('can-be-overridden')) {
        reasons.add('MISSING_CAN_BE_OVERRIDDEN');
      }
      for (final c in required) {
        if (!enforced.containsKey(c)) {
          reasons.add('RETENTION_UNPROVEN');
          break;
        }
      }
    }

    // 5. Generated code, from the supplied marker list.
    if (generated.contains(k) ||
        generated.any((g) => (r['library'] as String).endsWith(g))) {
      reasons.add('GENERATED_CODE');
    }

    if (!replaceable) {
      reasons.add('ABI_SHAPE_UNSUPPORTED');
    }

    final uniq = reasons.toSet().toList()..sort();
    out.add({
      'key': k,
      'library': r['library'],
      'owner': owner,
      'kind': kind,
      'name': r['name'],
      'declaration_id': r['declaration_id'],
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
      'schema': 'semantic-map-1/g5-predictions/1',
      'gate': 'SM1-G5',
      'issue': 54,
      'count': out.length,
      'predicted_patchable': patchable,
      // DIAGNOSTIC ONLY. #54 is explicit that a percentage must never make an
      // unsafe map publishable, so this number is emitted for reporting and the
      // scorer is forbidden from letting it affect the verdict.
      'coverage_diagnostic_only': out.isEmpty
          ? null
          : '${(patchable * 100 / out.length).toStringAsFixed(1)}%',
      'refusal_reason_vocabulary': refusalReasons,
      'refusal_histogram': byReason,
      'rows': out,
    })}\n',
  );
  print('  predictions=${out.length} patchable=$patchable '
      'refused=${out.length - patchable} -> $outPath');
}
