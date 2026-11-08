// Copyright (c) 2026, the Shorebird self-host fork.
//
// dump_pragmas.dart -- SM1-G4: what retaining annotations does a built kernel
// ACTUALLY carry, per declaration.
//
// WHY THE KERNEL AND NOT THE SOURCE. Two separate reasons, and both matter.
//
// 1. A source grep cannot tell a pragma from a comment about a pragma. This
//    gate's own subject file explains the confound in a header comment, so a
//    text search for `vm:entry-point` matches the explanation.
//
// 2. More importantly, di.yaml's entries are not visible in the source at all.
//    `pkg/vm/lib/transformations/dynamic_interface_annotator.dart` LOWERS the
//    yaml into real pragma annotations on the nodes it names -- `callable:`
//    becomes `@pragma('dyn-module:callable')`. The contract is therefore only
//    observable in the built kernel, which is also the artifact the compiler
//    actually consumed.
//
// THE CONFOUND THIS EXISTS FOR. `pkg/vm/lib/transformations/pragma.dart` routes
// `dyn-module:callable` (case at line 253) through the SAME
// `getEntryPointTypeFromOptions` handler as `vm:entry-point` (case at line 184);
// both yield a `ParsedEntryPointPragma`. So a subject carrying `vm:entry-point`
// in its source is retained WHATEVER the dynamic interface says, and every
// withheld-retention arm would pass while measuring the pragma rather than the
// contract. SL1-G6A was bitten by exactly this.
//
// Distinguishing the two mechanisms therefore requires seeing which annotation
// is present and where it came from, which is what this prints.
//
// ignore_for_file: avoid_print, implementation_imports
import 'dart:convert';
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

Never _die(String m) {
  stderr.writeln('dump_pragmas: $m');
  exit(2);
}

/// Annotations that cause a declaration to be RETAINED, by either mechanism.
///
/// Split deliberately: `sourcePragmas` can only have come from the subject's own
/// source text, `contractPragmas` can only have been injected by the dynamic
/// interface. An arm that cannot say which one retained a declaration is not
/// measuring the contract.
const sourcePragmas = <String>{
  'vm:entry-point',
  'dyn-module:entry-point',
};

const contractPragmas = <String>{
  'dyn-module:callable',
  'dyn-module:implicitly-callable',
  'dyn-module:extendable',
  'dyn-module:can-be-used-as-type',
  'dyn-module:can-be-overridden',
  'dyn-module:can-be-overridden-implicitly',
};

/// Pragma names on a node, read off its Kernel annotations.
List<String> pragmaNames(List<Expression> annotations) {
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
  var outPath = 'pragmas.json';
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

  void add(String library, String? owner, String kind, String name,
      List<Expression> annotations) {
    final names = pragmaNames(annotations);
    final source = names.where(sourcePragmas.contains).toList();
    final contract = names.where(contractPragmas.contains).toList();
    rows.add({
      'library': library,
      'owner': owner,
      'kind': kind,
      'name': name,
      'pragmas': names,
      // WHICH MECHANISM would retain this declaration.
      'retained_by_source_pragma': source,
      'retained_by_contract': contract,
      'retained': source.isNotEmpty || contract.isNotEmpty,
    });
  }

  for (final lib in component.libraries.where(isApp)) {
    final library = lib.importUri.toString();
    add(library, null, 'library', '', lib.annotations);
    for (final p in lib.procedures) {
      add(library, null, 'procedure', p.name.text, p.annotations);
    }
    for (final f in lib.fields) {
      add(library, null, 'field', f.name.text, f.annotations);
    }
    for (final cls in lib.classes) {
      add(library, null, 'class', cls.name, cls.annotations);
      for (final p in cls.procedures) {
        add(library, cls.name, 'procedure', p.name.text, p.annotations);
      }
      for (final c in cls.constructors) {
        add(library, cls.name, 'constructor', c.name.text, c.annotations);
      }
      for (final f in cls.fields) {
        add(library, cls.name, 'field', f.name.text, f.annotations);
      }
    }
  }

  final bySource = rows.where((r) =>
      (r['retained_by_source_pragma'] as List).isNotEmpty).toList();
  final byContract = rows.where((r) =>
      (r['retained_by_contract'] as List).isNotEmpty).toList();

  File(outPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'schema': 'semantic-map-1/g4-pragmas/1',
      'gate': 'SM1-G4',
      'issue': 53,
      'dill': dillPath,
      'count': rows.length,
      'retained_by_source_pragma_count': bySource.length,
      'retained_by_contract_count': byContract.length,
      'rows': rows,
    })}\n',
  );
  print('  declarations=${rows.length} '
      'source-pragma-retained=${bySource.length} '
      'contract-retained=${byContract.length} -> $outPath');
}
