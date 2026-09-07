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

/// What it takes to READ, to WRITE and to CONSTRUCT this declaration, as
/// manifest keys.
///
/// `null` means the mode does not exist for this declaration -- a getter cannot
/// be written, a `final` field cannot be written, only a constructor can be
/// constructed -- which is a different fact from "the mode exists and is
/// ungranted".
///
/// CONSTRUCTION IS ITS OWN MODE, not a read. The shipped manifest keeps it in a
/// separate list (`privateClassesConstructible` / `implicitlyConstructible`)
/// with its own key shape, e.g.
///
///   package:super_fixture/main.dart#_Boxed.new
///
/// so the unnamed constructor is `.new` rather than an empty member name. An
/// earlier version returned no key at all for a constructor, which made a
/// legitimate construction of a private class report NO_SUCH_MODE.
({String? read, String? write, String? construct}) accessKeys({
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
      return (read: bare, write: isMutableField ? bare : null, construct: null);
    case 'getter':
      return (
        read: capabilityKey(library, owner, 'get:$name'),
        write: null,
        construct: null,
      );
    case 'setter':
      return (
        read: null,
        write: capabilityKey(library, owner, 'set:$name'),
        construct: null,
      );
    case 'method':
    case 'operator':
      // An invoke reads the member in order to call it; there is no write mode.
      return (
        read: capabilityKey(library, owner, name),
        write: null,
        construct: null,
      );
    case 'constructor':
    case 'factory':
      // `library#Class.new` for the unnamed constructor, matching the shipped
      // manifest's own spelling.
      return (
        read: null,
        write: null,
        construct: owner == null
            ? null
            : '$library#$owner.${name.isEmpty ? 'new' : name}',
      );
    default:
      // A class itself is not read, written or constructed; its constructors
      // are.
      return (read: null, write: null, construct: null);
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

  /// A MEMBER's own privacy, read off its `Name` node.
  ({bool isPrivate, String domain, String derivation}) memberPrivacy(
    Name name,
    Library enclosing,
  ) {
    if (!name.isPrivate) {
      return (
        isPrivate: false,
        domain: 'public',
        derivation: 'kernel:Name.isPrivate=false',
      );
    }
    final ref = name.libraryReference;
    if (ref == null) {
      // Kernel asserts a private name carries a library, so this should be
      // unreachable. It is NOT defaulted to the enclosing library: a domain
      // that cannot be derived is classified, per this gate's stop condition.
      return (
        isPrivate: true,
        domain: 'UNDERIVABLE_NO_LIBRARY_REFERENCE',
        derivation: 'kernel:Name.libraryReference=null',
      );
    }
    final uri = ref.asLibrary.importUri.toString();
    return (
      isPrivate: true,
      domain: uri,
      derivation: uri == enclosing.importUri.toString()
          ? 'kernel:Name.libraryReference'
          // A private name whose domain is NOT the library it appears in is the
          // `_enumToString` shape, which `routeBUnconditionalRefusals` refuses
          // under every policy.
          : 'kernel:Name.libraryReference(foreign-domain)',
    );
  }

  /// A CLASS HAS NO `Name` NODE, and this is stated rather than papered over.
  ///
  /// Kernel models `Class.name` as a plain `String`, so there is no
  /// `libraryReference` to read and no honest way to claim one. An earlier
  /// version synthesised a `Name` from `cls.name` and let the row carry the
  /// member rule's derivation label -- which asserted a Kernel fact that does
  /// not exist for classes. Class privacy is instead derived from the two facts
  /// Kernel does carry, the declared name and the enclosing library, and the
  /// derivation string says exactly that.
  ({bool isPrivate, String domain, String derivation}) classPrivacy(
    Class cls,
    Library enclosing,
  ) {
    if (!cls.name.startsWith('_')) {
      return (
        isPrivate: false,
        domain: 'public',
        derivation: 'derived:Class.name(no-leading-underscore)',
      );
    }
    return (
      isPrivate: true,
      domain: enclosing.importUri.toString(),
      derivation: 'derived:Class.name(leading-underscore)+Class.enclosingLibrary'
          '(kernel-has-no-Name-node-for-a-class)',
    );
  }

  /// WHICH DOMAIN ACTUALLY GATES ACCESS.
  ///
  /// A public member of a private class is not reachable from outside that
  /// class's library, so its EFFECTIVE domain is the owner's even though its own
  /// name is public. Comparing the member's own domain against a grant scope
  /// turned every such declaration into a cross-domain refusal, including a
  /// legitimate same-library access -- the member's domain was the string
  /// `public`, which matches no library.
  ({String domain, String derivation}) effectivePrivacy({
    required ({bool isPrivate, String domain, String derivation}) member,
    required ({bool isPrivate, String domain, String derivation})? owner,
  }) {
    if (member.isPrivate) {
      return (domain: member.domain, derivation: 'member');
    }
    if (owner != null && owner.isPrivate) {
      return (domain: owner.domain, derivation: 'owner(public-member-of-private-class)');
    }
    return (domain: 'public', derivation: 'neither');
  }

  void addRow({
    required Library lib,
    required String? owner,
    required ({bool isPrivate, String domain, String derivation})? ownerPriv,
    required String kind,
    required String name,
    required ({bool isPrivate, String domain, String derivation}) memberPriv,
    required bool isMutableField,
  }) {
    final library = lib.importUri.toString();
    final eff = effectivePrivacy(member: memberPriv, owner: ownerPriv);
    final ownerIsPrivate = ownerPriv?.isPrivate ?? false;
    final id = declarationId(library, owner, kind, name);
    final keys = accessKeys(
      library: library,
      owner: owner,
      kind: kind,
      name: name,
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
      'name': name,
      // THE MEMBER'S OWN privacy, and the OWNER'S, recorded separately -- then
      // the effective domain derived from them. Collapsing the three is what
      // made a public method of a private class compare `public` against a
      // library URI and refuse as cross-domain.
      'is_private': memberPriv.isPrivate,
      'privacy_domain': memberPriv.domain,
      'domain_derivation': memberPriv.derivation,
      'owner_is_private': ownerIsPrivate,
      'owner_privacy_domain': ownerPriv?.domain,
      'owner_domain_derivation': ownerPriv?.derivation,
      'effective_privacy_domain': eff.domain,
      'effective_domain_source': eff.derivation,
      'domain_is_enclosing_library': eff.domain == library,
      // The scope `--resolve-private-names-in-library` may name for a patch
      // replacing THIS declaration. Derived from the target's own identity,
      // which is what route_b_producer.dart does per compile.
      'grant_scope': eff.domain == 'public' ? null : library,
      'capability_key_read': keys.read,
      'capability_key_write': keys.write,
      'capability_key_construct': keys.construct,
      'write_mode_exists': keys.write != null,
      'construct_mode_exists': keys.construct != null,
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
        ownerPriv: null,
        kind: _procKind(p),
        name: p.name.text,
        memberPriv: memberPrivacy(p.name, lib),
        isMutableField: false,
      );
    }
    for (final f in lib.fields) {
      addRow(
        lib: lib,
        owner: null,
        ownerPriv: null,
        kind: 'field',
        name: f.name.text,
        memberPriv: memberPrivacy(f.name, lib),
        isMutableField: !f.isFinal && !f.isConst,
      );
    }
    for (final cls in lib.classes) {
      final clsPriv = classPrivacy(cls, lib);
      addRow(
        lib: lib,
        owner: null,
        ownerPriv: null,
        kind: 'class',
        name: cls.name,
        memberPriv: clsPriv,
        isMutableField: false,
      );
      for (final p in cls.procedures) {
        addRow(
          lib: lib,
          owner: cls.name,
          ownerPriv: clsPriv,
          kind: _procKind(p),
          name: p.name.text,
          memberPriv: memberPrivacy(p.name, lib),
          isMutableField: false,
        );
      }
      for (final c in cls.constructors) {
        // The unnamed constructor's `Name` text is the empty string, so its own
        // privacy is PUBLIC. Under a private class its effective domain must
        // still come from the owner, which is the case the owner rule exists
        // for -- and the one a member-only model gets wrong most quietly.
        addRow(
          lib: lib,
          owner: cls.name,
          ownerPriv: clsPriv,
          kind: 'constructor',
          name: c.name.text,
          memberPriv: memberPrivacy(c.name, lib),
          isMutableField: false,
        );
      }
      for (final f in cls.fields) {
        addRow(
          lib: lib,
          owner: cls.name,
          ownerPriv: clsPriv,
          kind: 'field',
          name: f.name.text,
          memberPriv: memberPrivacy(f.name, lib),
          isMutableField: !f.isFinal && !f.isConst,
        );
      }
    }
  }

  // "Private" for census and grant purposes means EFFECTIVELY private: a
  // public member of a private class is not reachable from outside its
  // library, so it belongs here.
  final privateRows = rows
      .where((r) => r['effective_privacy_domain'] != 'public')
      .toList();
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
      // EFFECTIVE domains. A census keyed on the member's own domain files a
      // public method of a private class under `public`, which is the very
      // conflation that hid the owner defect: private_count said 11 while the
      // census summed to 4 non-public.
      'domains': {
        for (final d in {
          for (final r in rows) r['effective_privacy_domain'] as String,
        })
          d: rows.where((r) => r['effective_privacy_domain'] == d).length,
      },
      // Kept alongside it so the two are visibly different numbers rather than
      // one number that could silently be either.
      'member_own_domains': {
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
