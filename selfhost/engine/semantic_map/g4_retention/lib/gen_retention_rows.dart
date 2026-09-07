// Copyright (c) 2026, the Shorebird self-host fork.
//
// gen_retention_rows.dart -- SEMANTIC-MAP-1 G4: what a release must RETAIN for
// each patchable declaration, stated per declaration.
//
// THE STOP CONDITION THIS ANSWERS. #53 says: if retention can only be stated
// per library or per release, stop and classify, because a coarser contract
// cannot support per-declaration reuse. It can be stated per declaration --
// every row below names its own dynamic-interface entries -- so the gate
// proceeds. The rows are what makes that claim checkable rather than asserted.
//
// WHAT A CONTRACT ENTRY IS. `--dynamic-interface` takes a yaml naming
// declarations under four keys. `dynamic_interface_annotator.dart` lowers each
// into a real pragma on the named node, so the contract is a set of annotations
// the release's kernel either carries or does not.
//
//   extendable            a module may subclass this class
//   can-be-used-as-type   a module may name this class in a type position
//   can-be-overridden     a member's dispatch point stays open for a subtype
//                         that does not exist yet -- SL1-G4's finding
//   callable              a module may call this member; `member: ''` is the
//                         unnamed constructor
//
// ENFORCEMENT IS MEASURED, NOT ASSUMED. Declaring an entry required is a
// statement about what a release must publish. Whether withholding it actually
// stops a patch is a separate, empirical question, and G4's arms measure it per
// class. Each row therefore carries `enforced_at_load` sourced from those
// measurements rather than from the contract's intent -- two of the four
// classes do not fail closed, and a contract that quietly implied they did
// would be overstating itself.
//
// ignore_for_file: avoid_print, implementation_imports
import 'dart:convert';
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

Never _die(String m) {
  stderr.writeln('gen_retention_rows: $m');
  exit(2);
}

String _procKind(Procedure p) => switch (p.kind) {
  ProcedureKind.Getter => 'getter',
  ProcedureKind.Setter => 'setter',
  ProcedureKind.Operator => 'operator',
  ProcedureKind.Factory => 'factory',
  _ => 'method',
};

/// One dynamic-interface entry, in the shape the yaml uses.
Map<String, Object?> entry(String key, String library,
        {String? cls, String? member}) =>
    {
      'key': key,
      'library': library,
      if (cls != null) 'class': cls,
      if (member != null) 'member': member,
    };

void main(List<String> args) {
  String? dillPath;
  String? enforcementPath;
  var outPath = 'retention_rows.json';
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
      case '--enforcement':
        enforcementPath = next();
      case '--out':
        outPath = next();
      case '--include':
        includePrefixes.add(next());
      default:
        _die('unknown argument: $a');
    }
  }
  if (dillPath == null) _die('--dill is required');
  if (enforcementPath == null) {
    // Refused rather than defaulted. A contract that claimed enforcement it had
    // not measured would be exactly the over-claim this lane exists to prevent.
    _die('--enforcement is required: whether withholding a class actually stops '
        'a patch is measured by this gate\'s arms, never assumed');
  }

  final enforcement = (jsonDecode(File(enforcementPath).readAsStringSync())
      as Map<String, Object?>);
  final enforced = (enforcement['enforced_at_load'] as Map<String, Object?>);

  final component = Component();
  BinaryBuilder(File(dillPath).readAsBytesSync()).readComponent(component);

  bool isApp(Library lib) {
    final uri = lib.importUri.toString();
    if (uri.startsWith('dart:')) return false;
    if (includePrefixes.isEmpty) return true;
    return includePrefixes.any(uri.startsWith);
  }

  final rows = <Map<String, Object?>>[];

  void add({
    required String library,
    required String? owner,
    required String kind,
    required String name,
    required List<Map<String, Object?>> required_,
    required String rationale,
  }) {
    final keys = required_.map((e) => e['key'] as String).toSet().toList()
      ..sort();
    rows.add({
      'library': library,
      'owner': owner,
      'kind': kind,
      'name': name,
      'required_entries': required_,
      'required_classes': keys,
      // Measured per class by this gate's arms, carried here so a consumer of
      // the map cannot mistake "the contract requires it" for "the runtime
      // enforces it".
      'enforced_at_load': {
        for (final k in keys) k: enforced[k] ?? 'UNMEASURED',
      },
      'rationale': rationale,
    });
  }

  for (final lib in component.libraries.where(isApp)) {
    final library = lib.importUri.toString();

    for (final p in lib.procedures) {
      // A top-level function has no owner, so no class entries apply.
      add(
        library: library,
        owner: null,
        kind: _procKind(p),
        name: p.name.text,
        required_: [entry('callable', library, member: p.name.text)],
        rationale: 'a top-level member is called directly; there is no '
            'dispatch point to keep open and no class to extend',
      );
    }
    for (final f in lib.fields) {
      add(
        library: library,
        owner: null,
        kind: 'field',
        name: f.name.text,
        required_: [entry('callable', library, member: f.name.text)],
        rationale: 'a top-level field is reached through its implicit '
            'accessors, which the callable entry covers',
      );
    }

    for (final cls in lib.classes) {
      final clsEntries = [
        entry('extendable', library, cls: cls.name),
        entry('can-be-used-as-type', library, cls: cls.name),
      ];
      add(
        library: library,
        owner: null,
        kind: 'class',
        name: cls.name,
        required_: clsEntries,
        rationale: 'a module that subclasses this class must be able to name '
            'it and to extend it',
      );

      for (final c in cls.constructors) {
        add(
          library: library,
          owner: cls.name,
          kind: 'constructor',
          name: c.name.text,
          required_: [
            ...clsEntries,
            // The unnamed constructor is `member: ''`, and it is the
            // declaration the VM resolves first when a module instantiates a
            // subtype -- withholding it aborts before any member is reached.
            entry('callable', library, cls: cls.name, member: c.name.text),
          ],
          rationale: 'a module instantiating a subtype resolves the '
              "superclass constructor first; ''" ' is the unnamed one',
        );
      }

      for (final p in cls.procedures) {
        final kind = _procKind(p);
        final isOverridable = !p.isStatic && kind != 'factory';
        add(
          library: library,
          owner: cls.name,
          kind: kind,
          name: p.name.text,
          required_: [
            ...clsEntries,
            entry('callable', library, cls: cls.name, member: p.name.text),
            if (isOverridable)
              entry('can-be-overridden', library,
                  cls: cls.name, member: p.name.text),
          ],
          rationale: isOverridable
              // SL1-G4's finding, carried forward: without this entry the
              // optimizer is free to devirtualize the call site, and a patch
              // subtype never reaches it.
              ? 'an overridable instance member needs its dispatch point kept '
                  'open for a subtype that does not exist at build time'
              : 'a static or factory member is called directly, so no dispatch '
                  'point has to stay open',
        );
      }

      for (final f in cls.fields) {
        add(
          library: library,
          owner: cls.name,
          kind: 'field',
          name: f.name.text,
          required_: [
            ...clsEntries,
            entry('callable', library, cls: cls.name, member: f.name.text),
          ],
          rationale: 'an instance field is reached through its implicit '
              'accessors, which the callable entry covers',
        );
      }
    }
  }

  final byClass = <String, int>{};
  for (final r in rows) {
    for (final k in r['required_classes'] as List) {
      byClass[k as String] = (byClass[k] ?? 0) + 1;
    }
  }

  File(outPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'schema': 'semantic-map-1/g4-retention/1',
      'gate': 'SM1-G4',
      'issue': 53,
      'count': rows.length,
      'required_class_histogram': byClass,
      'enforcement_source': enforcementPath,
      'enforced_at_load': enforced,
      'rows': rows,
    })}\n',
  );
  print('  retention rows=${rows.length} -> $outPath');
}
