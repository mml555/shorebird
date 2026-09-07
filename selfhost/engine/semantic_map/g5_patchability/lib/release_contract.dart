// Copyright (c) 2026, the Shorebird self-host fork.
//
// release_contract.dart -- SEMANTIC-MAP-1 G5: the EXACT-RELEASE retention proof.
//
// WHY NOT REUSE G4's dump_pragmas.dart. That tool reports every procedure as
// kind `procedure`, so a getter and a setter of the same name collapse to one
// key. G5's predictor then rekeyed it `library#owner#name` and UNIONED the
// pragmas, which means an entry present on `get:x` could serve as proof for
// `set:x`. For an exact-release retention proof that is not acceptable: the
// whole point is that this specific declaration's entry is present.
//
// G4 is closed and its evidence is banked, so its tool is left alone and this
// one carries precise identity instead:
//
//     library + owner + kind + name + vmName
//
// AMBIGUITY IS REFUSED, NOT MERGED. If two release declarations map to one
// semantic key, the row is marked `ambiguous` and the predictor must refuse it.
// Merging them is how a proof becomes a guess.
//
// ignore_for_file: avoid_print, implementation_imports
import 'dart:convert';
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

Never _die(String m) {
  stderr.writeln('release_contract: $m');
  exit(2);
}

String _procKind(Procedure p) => switch (p.kind) {
  ProcedureKind.Getter => 'getter',
  ProcedureKind.Setter => 'setter',
  ProcedureKind.Operator => 'operator',
  ProcedureKind.Factory => 'factory',
  _ => 'method',
};

/// The VM-shaped name, matching what the dynamic interface and the capability
/// manifest key: `get:`/`set:`-prefixed for an accessor, bare otherwise.
String _vmName(String name, String kind) => switch (kind) {
  'getter' => 'get:$name',
  'setter' => 'set:$name',
  _ => name,
};

const contractPragmas = <String>{
  'dyn-module:callable',
  'dyn-module:implicitly-callable',
  'dyn-module:extendable',
  'dyn-module:can-be-used-as-type',
  'dyn-module:can-be-overridden',
  'dyn-module:can-be-overridden-implicitly',
};

const sourcePragmas = <String>{'vm:entry-point', 'dyn-module:entry-point'};

List<String> _pragmaNames(List<Expression> annotations) {
  final out = <String>[];
  for (final a in annotations) {
    if (a is! ConstantExpression) continue;
    final c = a.constant;
    if (c is! InstanceConstant) continue;
    if (c.classNode.name != 'pragma') continue;
    for (final e in c.fieldValues.entries) {
      if (e.key.canonicalName?.name != 'name') continue;
      final v = e.value;
      if (v is StringConstant) out.add(v.value);
    }
  }
  out.sort();
  return out;
}

void main(List<String> args) {
  String? dillPath;
  var outPath = 'release_contract.json';
  final includePrefixes = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String next() {
      if (i + 1 >= args.length) _die('$a needs a value');
      return args[++i];
    }

    switch (a) {
      case '--dill':
        dillPath = next();
      case '--out':
        outPath = next();
      case '--include':
        includePrefixes.add(next());
      default:
        _die('unknown argument: $a');
    }
  }
  if (dillPath == null) _die('--dill is required');

  final component = Component();
  BinaryBuilder(File(dillPath).readAsBytesSync()).readComponent(component);

  bool isApp(Library lib) {
    final uri = lib.importUri.toString();
    if (uri.startsWith('dart:')) return false;
    if (includePrefixes.isEmpty) return true;
    return includePrefixes.any(uri.startsWith);
  }

  final rows = <Map<String, Object?>>[];
  final seen = <String, int>{};

  void add(String library, String? owner, String kind, String name,
      List<Expression> annotations) {
    final names = _pragmaNames(annotations);
    final k = '$library#${owner ?? ''}#$kind#$name';
    seen[k] = (seen[k] ?? 0) + 1;
    rows.add({
      'library': library,
      'owner': owner,
      'kind': kind,
      'name': name,
      'vm_name': _vmName(name, kind),
      'key': k,
      'pragmas': names,
      'contract_entries': names.where(contractPragmas.contains).toList(),
      'source_pragmas': names.where(sourcePragmas.contains).toList(),
    });
  }

  for (final lib in component.libraries.where(isApp)) {
    final library = lib.importUri.toString();
    for (final p in lib.procedures) {
      add(library, null, _procKind(p), p.name.text, p.annotations);
    }
    for (final f in lib.fields) {
      add(library, null, 'field', f.name.text, f.annotations);
    }
    for (final cls in lib.classes) {
      add(library, null, 'class', cls.name, cls.annotations);
      for (final p in cls.procedures) {
        add(library, cls.name, _procKind(p), p.name.text, p.annotations);
      }
      for (final c in cls.constructors) {
        add(library, cls.name, 'constructor', c.name.text, c.annotations);
      }
      for (final f in cls.fields) {
        add(library, cls.name, 'field', f.name.text, f.annotations);
      }
    }
  }

  // Mark, rather than merge, any key more than one declaration answers to.
  var ambiguous = 0;
  for (final r in rows) {
    final dup = (seen[r['key'] as String] ?? 0) > 1;
    r['ambiguous'] = dup;
    if (dup) ambiguous++;
  }

  File(outPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'schema': 'semantic-map-1/g5-release-contract/1',
      'gate': 'SM1-G5',
      'issue': 54,
      'dill': dillPath,
      'count': rows.length,
      'ambiguous_count': ambiguous,
      'rows': rows,
    })}\n',
  );
  print('  release declarations=${rows.length} ambiguous=$ambiguous -> $outPath');
}
