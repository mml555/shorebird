// Copyright (c) 2026, the Shorebird self-host fork.
//
// gen_declaration_ids.dart -- SEMANTIC-MAP-1 G1: name every declaration in a
// release kernel, stably.
//
// TWO IMPLEMENTATIONS, ON PURPOSE.
//
//   declaration_id  the identity under test: a hash over the library identity,
//                   the owner path, the declaration kind and the declared name,
//                   with every human-readable component RETAINED beside it
//   index_id        a deliberately ORDER-DERIVED identity, emitted as the
//                   positive control on the harness. It is not a candidate. If
//                   the harness cannot show this one failing under `reorder`,
//                   it has shown nothing about the canonical one either.
//
// DECLARATION ORDER IS NEVER AN INPUT to declaration_id. Not the kernel's member
// order, not the dill's byte layout, not a canonical-name index. SM1-G0 measured
// why: the `reorder` mutant moves the release-dill digest, because a dill
// preserves declaration order.
//
// WHAT THE REFERENCE TOOL COVERS, AND WHAT THIS MUST NOT INHERIT.
// gen_target_manifest.dart walks `lib.procedures` and `cls.procedures` only.
// Generative constructors are Constructor nodes and fields are Field nodes, so a
// manifest built from procedures alone cannot name `Shape.square()` or
// `Shape.sides` at all. This walks all four member kinds.
//
// Run with the frozen Dart tree's package config so package:kernel resolves.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

/// How the VM names a member of a given kind -- the same rule
/// gen_target_manifest.dart uses, kept here so no caller has to know it.
String vmMemberName(String name, String kind) => switch (kind) {
  'getter' => 'get:$name',
  'setter' => 'set:$name',
  _ => name,
};

/// U+0000 as the field separator, because it cannot occur in a library URI, a
/// class name or a Dart identifier. A printable separator would let `a|b` and
/// `ab|` collide by concatenation -- a collision the map would be inventing
/// rather than one the program has.
const String _sep = '\u0000';

String _hash(List<String> parts) {
  for (final p in parts) {
    if (p.contains(_sep)) {
      throw StateError('identity component contains the separator: $p');
    }
  }
  return sha256.convert(utf8.encode(parts.join(_sep))).toString();
}

/// The canonical identity. Structured components, fixed order, no position.
String canonicalId({
  required String library,
  required String ownerPath,
  required String kind,
  required String name,
}) => _hash([library, ownerPath, kind, name]);

void main(List<String> args) {
  String? dillPath;
  var outPath = 'declaration_ids.json';
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
      case '-h':
      case '--help':
        print(
          'gen_declaration_ids.dart --dill <app.dill> [--out out.json] '
          '[--include <library-uri-prefix>]...',
        );
        return;
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
  var libIndex = 0;

  // EXTENSION MEMBERS ARE LOWERED TO MANGLED TOP-LEVEL PROCEDURES.
  // `extension ShapeX on Shape { int doubled() => ...; }` reaches the kernel as
  // a top-level procedure literally named `ShapeX|doubled` with no owner. Taking
  // that at face value would put a VM-internal mangling into what becomes a wire
  // contract -- the same complaint gen_target_manifest.dart records about
  // `get:`/`set:` -- and would leave the extension name buried in a string
  // instead of being a structured component.
  //
  // So the Extension nodes are read first and the real owner and declared name
  // are recovered. Two extensions on different types that both declare `doubled`
  // then differ by OWNER rather than by accident of the mangling.
  final extensionOwner = <Reference, List<String>>{};
  for (final lib in component.libraries.where(isApp)) {
    for (final ext in lib.extensions) {
      for (final d in ext.memberDescriptors) {
        final ref = d.memberReference;
        if (ref != null) extensionOwner[ref] = [ext.name, d.name.text];
      }
      final tearOffs = ext.memberDescriptors
          .map((d) => d.tearOffReference)
          .whereType<Reference>();
      for (final ref in tearOffs) {
        extensionOwner[ref] = [ext.name, 'tearOff'];
      }
    }
  }

  void add({
    required String library,
    required String? owner,
    required String name,
    required String kind,
    required bool isStatic,
    required bool isSynthetic,
    required int memberIndex,
    String? loweredName,
    String? ownerKind,
  }) {
    rows.add({
      // Human-readable components retained BESIDE the hash rather than replaced
      // by it: an id nobody can read is an id nobody can debug.
      'library': library,
      'owner': owner,
      'name': name,
      'kind': kind,
      'static': isStatic,
      'synthetic': isSynthetic,
      'ownerKind': ownerKind,
      // What the kernel actually called it, kept only where it differs from the
      // declared name -- so a reader can see the lowering without the identity
      // depending on it.
      'loweredName': loweredName,
      'vmName': vmMemberName(loweredName ?? name, kind),
      'selector': owner == null
          ? vmMemberName(name, kind)
          : '$owner.${vmMemberName(name, kind)}',
      'declaration_id': canonicalId(
        library: library,
        ownerPath: owner ?? '',
        kind: kind,
        name: name,
      ),
      // THE CONTROL. Order-derived on purpose; never a candidate identity.
      'index_id': _hash([library, '$libIndex', '$memberIndex']),
    });
  }

  for (final lib in component.libraries.where(isApp)) {
    final library = lib.importUri.toString();
    var m = 0;
    for (final p in lib.procedures) {
      final ext = extensionOwner[p.reference];
      add(
        library: library,
        // An extension member's owner is its EXTENSION, recovered above, not
        // `null` with the extension name mangled into the member name.
        owner: ext?[0],
        name: ext?[1] ?? p.name.text,
        kind: _procKind(p),
        isStatic: true,
        isSynthetic: p.isSynthetic,
        memberIndex: m++,
        loweredName: ext == null ? null : p.name.text,
        ownerKind: ext == null ? null : 'extension',
      );
    }
    for (final f in lib.fields) {
      add(
        library: library,
        owner: null,
        name: f.name.text,
        kind: 'field',
        isStatic: true,
        isSynthetic: false,
        memberIndex: m++,
      );
    }
    for (final cls in lib.classes) {
      // The CLASS itself is a declaration. A generic bound, a supertype and a
      // type-parameter list all live here, not on any member, so a map that
      // names only members cannot express a change to them. The reference tool
      // walks procedures only and therefore cannot name a class at all.
      add(
        library: library,
        owner: null,
        name: cls.name,
        kind: 'class',
        isStatic: false,
        isSynthetic: false,
        memberIndex: m++,
      );
      for (final p in cls.procedures) {
        add(
          library: library,
          owner: cls.name,
          name: p.name.text,
          kind: _procKind(p),
          isStatic: p.isStatic,
          isSynthetic: p.isSynthetic,
          memberIndex: m++,
        );
      }
      for (final c in cls.constructors) {
        add(
          library: library,
          owner: cls.name,
          name: c.name.text,
          kind: 'constructor',
          isStatic: false,
          isSynthetic: c.isSynthetic,
          memberIndex: m++,
        );
      }
      for (final f in cls.fields) {
        add(
          library: library,
          owner: cls.name,
          name: f.name.text,
          kind: 'field',
          isStatic: f.isStatic,
          // Field carries no isSynthetic in this kernel AST (Procedure and
          // Constructor do). Recorded as false because it is unknown, not
          // because it was determined -- see the note in the emitted schema.
          isSynthetic: false,
          memberIndex: m++,
        );
      }
    }
    libIndex++;
  }

  // Deterministic order for the OUTPUT only. The identity does not depend on
  // this sort, and the sort does not depend on the identity.
  rows.sort((a, b) {
    for (final k in ['library', 'owner', 'kind', 'name']) {
      final c = (a[k] ?? '').toString().compareTo((b[k] ?? '').toString());
      if (c != 0) return c;
    }
    return 0;
  });

  // Collisions are a FAIL_OPEN, searched for rather than assumed away: two
  // distinct declarations sharing one id is what silently misroutes a patch.
  final byId = <String, List<String>>{};
  for (final r in rows) {
    byId
        .putIfAbsent(r['declaration_id']! as String, () => <String>[])
        .add('${r['library']}::${r['selector']}');
  }
  final collisions = <String, List<String>>{
    for (final e in byId.entries)
      if (e.value.length > 1) e.key: e.value,
  };

  File(outPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'schema': 'semantic-map-1/declaration-ids/1',
    'notes': {
      'synthetic_for_fields':
          'Field carries no isSynthetic in this kernel AST, so `synthetic` is '
          'false for every field because it is UNKNOWN, not because it was '
          'determined. It is metadata and is not an input to declaration_id.',
      'index_id':
          'A deliberately ORDER-DERIVED control identity. Never a candidate; '
          'it exists so the harness can be shown capable of detecting an '
          'order-dependent identity.',
    },
      'sourceDill': dillPath,
      'count': rows.length,
      'collisions': collisions,
      'declarations': rows,
    })}\n',
  );
  stderr.writeln(
    'wrote $outPath  declarations=${rows.length} '
    'collisions=${collisions.length}',
  );
}

String _procKind(Procedure p) => switch (p.kind) {
  ProcedureKind.Getter => 'getter',
  ProcedureKind.Setter => 'setter',
  ProcedureKind.Operator => 'operator',
  ProcedureKind.Factory => 'factory',
  ProcedureKind.Method => 'method',
};

Never _die(String message) {
  stderr.writeln('error: $message');
  exit(2);
}
