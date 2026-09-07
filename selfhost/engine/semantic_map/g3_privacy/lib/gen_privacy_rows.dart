// Copyright (c) 2026, the Shorebird self-host fork.
//
// gen_privacy_rows.dart -- SEMANTIC-MAP-1 G3: per declaration, which private
// namespace it belongs to and what a patch may legally resolve.
//
// THE DOMAIN IS DERIVED, NOT ASSUMED. Dart privacy is library-scoped, and the
// scope is carried in Kernel by `Name` itself:
//
//   abstract class Name {
//     Reference? get libraryReference;   // non-null ONLY for a private name
//     bool get isPrivate;
//   }
//   bool operator ==(other) => text == other.text && library == other.library;
//
// So the domain is `name.libraryReference`, read off the node -- not inferred
// from a leading underscore, and not taken to be the enclosing library (they
// coincide for ordinary declarations and must not be assumed to). Two libraries
// each declaring `_privateHelper` hold two DIFFERENT names, and Kernel's own
// equality says so.
//
// WHAT A PATCH MAY RESOLVE. `--resolve-private-names-in-library` makes EVERY
// private name in the named library resolvable, not only the ones the analyzer
// classified -- ROADMAP P1.3 states this explicitly. So the grant is a SCOPE,
// and the map records which scope a patch replacing this declaration is
// entitled to name: its own library and no other.
//
// READ IS NOT WRITE, AND THE SHIPPED KEY CANNOT ALWAYS TELL THEM APART.
// `RouteBPrivateTarget.name` is VM-shaped: `get:`/`set:`-prefixed for an
// accessor, BARE FOR A FIELD. Measured in the real manifests in this repo:
//
//   package:airgap_probe/main.dart#_ProbeBodyState#get:_assetsPatch   accessor
//   package:airgap_probe/main.dart#RouteBThing#_secret                FIELD, bare
//
// and across every capability manifest this fork has ever produced the count of
// `set:` keys is ZERO. So for an accessor the two modes are distinguishable, and
// for a FIELD one key authorises both -- while the single access mode that is
// device-proven (ROADMAP P1.4: a private FIELD READ, release 32 patch 2,
// `value() => _secret`) is exactly the collapsed case. A write is not granted,
// and the manifest key alone cannot enforce that. The map therefore carries the
// mode, so the refusal can happen before publication rather than at load.
//
// ignore_for_file: avoid_print, implementation_imports
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

/// The same separator SM1-G1 and SM1-G2 use. It must stay byte-identical or the
/// recomputed identity would not match theirs and the parity check would fail
/// for a reason that has nothing to do with privacy.
const String _sep = '\u0000';

String _hash(List<String> parts) =>
    sha256.convert(utf8.encode(parts.join(_sep))).toString();

Never _die(String m) {
  stderr.writeln('gen_privacy_rows: $m');
  exit(2);
}

/// SM1-G1's identity, recomputed rather than imported, so the driver's parity
/// check against G1's own tool is a real comparison.
String declarationId(String library, String? owner, String kind, String name) =>
    _hash([library, owner ?? '', kind, name]);

String _procKind(Procedure p) => switch (p.kind) {
  ProcedureKind.Getter => 'getter',
  ProcedureKind.Setter => 'setter',
  ProcedureKind.Operator => 'operator',
  ProcedureKind.Factory => 'factory',
  _ => 'method',
};

/// The manifest key shape, mirroring `RouteBCapabilities.refuseInstanceMember`
/// (`library#Class#member`) and `refuseTopLevel` (`library#member`).
String? capabilityKey(String library, String? owner, String? vmName) =>
    vmName == null
        ? null
        : (owner == null ? '$library#$vmName' : '$library#$owner#$vmName');

/// What it takes to READ and to WRITE this declaration, as manifest keys.
///
/// `null` means the mode does not exist for this declaration -- a getter cannot
/// be written, a `final` field cannot be written -- which is a different fact
/// from "the mode exists and is ungranted".
({String? read, String? write}) accessKeys({
  required String library,
  required String? owner,
  required String kind,
  required String name,
  required bool isMutableField,
}) {
  switch (kind) {
    case 'field':
      final bare = capabilityKey(library, owner, name);
      // ONE KEY FOR BOTH MODES. This is the collapse: a release that only ever
      // evidenced a read grants the same string a write would present.
      return (read: bare, write: isMutableField ? bare : null);
    case 'getter':
      return (read: capabilityKey(library, owner, 'get:$name'), write: null);
    case 'setter':
      return (read: null, write: capabilityKey(library, owner, 'set:$name'));
    case 'method':
    case 'operator':
      // An invoke reads the member in order to call it; there is no write mode.
      return (read: capabilityKey(library, owner, name), write: null);
    default:
      // constructor / factory / class: not a member read or write.
      return (read: null, write: null);
  }
}

void main(List<String> args) {
  String? dillPath;
  String? preDillPath;
  var outPath = 'privacy_rows.json';
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
      case '--pre-dill':
        preDillPath = next();
      case '--out':
        outPath = next();
      case '--include':
        includePrefixes.add(next());
      case '-h':
      case '--help':
        print(
          'gen_privacy_rows.dart --dill <aot.dill> --pre-dill <preaot.dill> '
          '[--out out.json] [--include <library-uri-prefix>]...',
        );
        return;
      default:
        _die('unknown argument: $a');
    }
  }
  if (dillPath == null) _die('--dill is required');
  // The PRE-AOT kernel is the declaration domain; the AOT kernel says what
  // survived. G1 measured that `--aot` TREE-SHAKES declarations, so a private
  // member absent from the AOT kernel is not "not private" -- it is not
  // retained, a different refusal with a different remedy.
  if (preDillPath == null) {
    _die(
      '--pre-dill is required: the AOT kernel tree-shakes declarations, so it '
      'cannot enumerate the privacy domain',
    );
  }

  final aot = Component();
  BinaryBuilder(File(dillPath).readAsBytesSync()).readComponent(aot);
  final pre = Component();
  BinaryBuilder(File(preDillPath).readAsBytesSync()).readComponent(pre);

  bool isApp(Library lib) {
    final uri = lib.importUri.toString();
    if (uri.startsWith('dart:')) return false;
    if (includePrefixes.isEmpty) return true;
    return includePrefixes.any(uri.startsWith);
  }

  // What the AOT kernel retained, keyed by identity, for the tree-shaken arm.
  final retained = <String>{};
  for (final lib in aot.libraries.where(isApp)) {
    final library = lib.importUri.toString();
    for (final p in lib.procedures) {
      retained.add(declarationId(library, null, _procKind(p), p.name.text));
    }
    for (final f in lib.fields) {
      retained.add(declarationId(library, null, 'field', f.name.text));
    }
    for (final cls in lib.classes) {
      retained.add(declarationId(library, null, 'class', cls.name));
      for (final p in cls.procedures) {
        retained.add(
          declarationId(library, cls.name, _procKind(p), p.name.text),
        );
      }
      for (final c in cls.constructors) {
        retained.add(
          declarationId(library, cls.name, 'constructor', c.name.text),
        );
      }
      for (final f in cls.fields) {
        retained.add(declarationId(library, cls.name, 'field', f.name.text));
      }
    }
  }

  final rows = <Map<String, Object?>>[];

  /// The privacy domain, read off the Name node.
  ({String domain, String derivation}) domainOf(Name name, Library enclosing) {
    if (!name.isPrivate) {
      return (domain: 'public', derivation: 'kernel:Name.isPrivate=false');
    }
    final ref = name.libraryReference;
    if (ref == null) {
      // Kernel asserts a private name carries a library, so this should be
      // unreachable. It is NOT defaulted to the enclosing library: a domain
      // that cannot be derived is classified, per this gate's stop condition.
      return (
        domain: 'UNDERIVABLE_NO_LIBRARY_REFERENCE',
        derivation: 'kernel:Name.libraryReference=null',
      );
    }
    final uri = ref.asLibrary.importUri.toString();
    return (
      domain: uri,
      derivation: uri == enclosing.importUri.toString()
          ? 'kernel:Name.libraryReference'
          // Worth distinguishing: a private name whose domain is NOT the
          // library it appears in is the `_enumToString` shape, which
          // `routeBUnconditionalRefusals` refuses under every policy.
          : 'kernel:Name.libraryReference(foreign-domain)',
    );
  }

  void addRow({
    required Library lib,
    required String? owner,
    required bool ownerIsPrivate,
    required String kind,
    required Name name,
    required bool isMutableField,
  }) {
    final library = lib.importUri.toString();
    final d = domainOf(name, lib);
    final id = declarationId(library, owner, kind, name.text);
    final keys = accessKeys(
      library: library,
      owner: owner,
      kind: kind,
      name: name.text,
      isMutableField: isMutableField,
    );
    // DOES THIS DECLARATION'S CAPABILITY KEY NAME THE ACCESS MODE?
    //
    // The first version asked whether ONE declaration had both a read key and a
    // write key that differed. That is never true -- a getter has no write and a
    // setter has no read -- so it reported `false` for accessors, understating
    // the model: `get:x` and `set:x` DO name their mode, they just live on two
    // declarations. What actually matters is whether the key a patch presents
    // reveals which mode it intends.
    //
    //   mutable field   bare key serves BOTH read and write  -> false
    //   final field     no write mode exists                 -> true
    //   getter/setter   the get:/set: prefix names the mode   -> true
    //   method/operator no write mode exists                 -> true
    final identifiesMode = !(kind == 'field' && isMutableField);
    rows.add({
      'declaration_id': id,
      'library': library,
      'owner': owner,
      'kind': kind,
      'name': name.text,
      'is_private': name.isPrivate,
      'privacy_domain': d.domain,
      'domain_derivation': d.derivation,
      'domain_is_enclosing_library': d.domain == library,
      'owner_is_private': ownerIsPrivate,
      // The scope `--resolve-private-names-in-library` may name for a patch
      // replacing THIS declaration. Derived from the target's own identity,
      // which is what route_b_producer.dart does per compile.
      'grant_scope': name.isPrivate || ownerIsPrivate ? library : null,
      'capability_key_read': keys.read,
      'capability_key_write': keys.write,
      'write_mode_exists': keys.write != null,
      // False when ONE manifest key authorises both modes -- a mutable field.
      // That is exactly the shape whose read is the only mode ever
      // device-proven, so it is the shape a write can hide behind.
      'capability_key_identifies_mode': identifiesMode,
      'retained_in_release': retained.contains(id),
    });
  }

  for (final lib in pre.libraries.where(isApp)) {
    for (final p in lib.procedures) {
      addRow(
        lib: lib,
        owner: null,
        ownerIsPrivate: false,
        kind: _procKind(p),
        name: p.name,
        isMutableField: false,
      );
    }
    for (final f in lib.fields) {
      addRow(
        lib: lib,
        owner: null,
        ownerIsPrivate: false,
        kind: 'field',
        name: f.name,
        isMutableField: !f.isFinal && !f.isConst,
      );
    }
    for (final cls in lib.classes) {
      final ownerIsPrivate = cls.name.startsWith('_');
      // A CLASS has no `Name` node of its own in Kernel -- `Class.name` is a
      // bare String. One is constructed here so the domain is derived by the
      // same rule as every other row rather than by a second, parallel code
      // path; `Name.byReference` requires the library for a private name and
      // rejects one for a public name, which is itself the check.
      addRow(
        lib: lib,
        owner: null,
        ownerIsPrivate: false,
        kind: 'class',
        name: Name(cls.name, ownerIsPrivate ? lib : null),
        isMutableField: false,
      );
      for (final p in cls.procedures) {
        addRow(
          lib: lib,
          owner: cls.name,
          ownerIsPrivate: ownerIsPrivate,
          kind: _procKind(p),
          name: p.name,
          isMutableField: false,
        );
      }
      for (final c in cls.constructors) {
        addRow(
          lib: lib,
          owner: cls.name,
          ownerIsPrivate: ownerIsPrivate,
          kind: 'constructor',
          name: c.name,
          isMutableField: false,
        );
      }
      for (final f in cls.fields) {
        addRow(
          lib: lib,
          owner: cls.name,
          ownerIsPrivate: ownerIsPrivate,
          kind: 'field',
          name: f.name,
          isMutableField: !f.isFinal && !f.isConst,
        );
      }
    }
  }

  final privateRows = rows.where((r) => r['is_private'] == true).toList();
  final collapsed = privateRows
      .where(
        (r) =>
            r['write_mode_exists'] == true &&
            r['capability_key_identifies_mode'] == false,
      )
      .toList();

  File(outPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'schema': 'semantic-map-1/g3-privacy/1',
      'gate': 'SM1-G3',
      'issue': 52,
      'count': rows.length,
      'private_count': privateRows.length,
      'domains': {
        for (final d in {for (final r in rows) r['privacy_domain'] as String})
          d: rows.where((r) => r['privacy_domain'] == d).length,
      },
      'write_capability_collapsed_count': collapsed.length,
      'rows': rows,
    })}\n',
  );
  print(
    '  rows=${rows.length} private=${privateRows.length} '
    'write-collapsed=${collapsed.length} -> $outPath',
  );
}
