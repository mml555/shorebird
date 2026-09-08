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

import 'package:crypto/crypto.dart' show sha256;
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

/// Reads the compiler-emitted capability note out of an AOT ELF.
///
/// PARSED, NOT GREPPED. Scanning the file for the payload text would match a
/// string anywhere in the artifact -- including one a patch author could put in
/// a Dart string literal. The section table is walked so the bytes are read
/// from the note section the compiler actually wrote.
///
/// FOUR OUTCOMES, and only one of them is a positive claim:
///
///   present, true          -> PROVEN
///   present, false         -> NOT_PATCHABLE
///   absent                 -> UNPROVEN_MARKER_ABSENT
///   malformed / unknown    -> UNPROVEN_MARKER_MALFORMED / _UNKNOWN_SCHEMA
///
/// Absence is never NOT_PATCHABLE: an older or unknown toolchain simply does not
/// say, and turning silence into a claim about the artifact is the failure this
/// gate exists to prevent.
/// Whether the bytes at [off] begin the versioned payload this reader expects.
/// Used only to choose between the padded and unpadded note layouts.
bool _looksLikePayload(List<int> b, int off, int len) {
  const want = 'schema_version=';
  if (off < 0 || off + want.length > b.length) return false;
  for (var i = 0; i < want.length; i++) {
    if (b[off + i] != want.codeUnitAt(i)) return false;
  }
  return true;
}

({String state, String evidence}) _readCapabilityNote(List<int> b) {
  const noteName = '.note.shorebird.capabilities';
  int u16(int o) => b[o] | (b[o + 1] << 8);
  int u32(int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
  int u64(int o) => u32(o) | (u32(o + 4) << 32);

  if (b.length < 64 || b[0] != 0x7f || b[1] != 0x45 || b[2] != 0x4c ||
      b[3] != 0x46) {
    return (state: 'UNPROVEN_MARKER_MALFORMED', evidence: 'not an ELF file');
  }
  if (b[4] != 2) {
    return (
      state: 'UNPROVEN_MARKER_MALFORMED',
      evidence: 'not ELF64; this reader does not model ELF32',
    );
  }
  final shoff = u64(0x28);
  final shentsize = u16(0x3a);
  final shnum = u16(0x3c);
  final shstrndx = u16(0x3e);
  if (shoff == 0 || shnum == 0) {
    return (
      state: 'UNPROVEN_MARKER_ABSENT',
      evidence: 'no section table',
    );
  }
  final strHdr = shoff + shstrndx * shentsize;
  final strOff = u64(strHdr + 0x18);
  String nameAt(int nameIdx) {
    final start = strOff + nameIdx;
    var end = start;
    while (end < b.length && b[end] != 0) {
      end++;
    }
    return String.fromCharCodes(b.sublist(start, end));
  }

  for (var i = 0; i < shnum; i++) {
    final hdr = shoff + i * shentsize;
    if (nameAt(u32(hdr)) != noteName) continue;
    final off = u64(hdr + 0x18);
    final size = u64(hdr + 0x20);
    if (size < 12) {
      return (
        state: 'UNPROVEN_MARKER_MALFORMED',
        evidence: 'capability note is $size bytes, too short for a header',
      );
    }
    final nameSize = u32(off);
    final descSize = u32(off + 4);
    // TWO POSSIBLE LAYOUTS, and this reader must not assume one.
    //
    // ELF pads a note's name to 4 bytes, but the Dart ELF writer lays the name
    // and description CONTIGUOUSLY -- GenerateBuildId does the same. Assuming
    // the padded offset silently sliced two characters off the payload and the
    // schema check then reported UNKNOWN_SCHEMA for a note that was perfectly
    // well formed. Both offsets are tried and the one that parses is used; if
    // neither does, the note is malformed rather than absent.
    final unpadded = off + 12 + nameSize;
    final padded = off + 12 + ((nameSize + 3) & ~3);
    final descOff = _looksLikePayload(b, unpadded, descSize) ? unpadded : padded;
    if (descOff + descSize > b.length || descSize == 0) {
      return (
        state: 'UNPROVEN_MARKER_MALFORMED',
        evidence: 'capability note description runs past the artifact',
      );
    }
    var end = descOff + descSize;
    while (end > descOff && b[end - 1] == 0) {
      end--;
    }
    final payload = String.fromCharCodes(b.sublist(descOff, end));
    final fields = <String, String>{};
    for (final part in payload.split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0) fields[part.substring(0, eq)] = part.substring(eq + 1);
    }
    final version = fields['schema_version'];
    if (version != '1') {
      return (
        state: 'UNPROVEN_MARKER_UNKNOWN_SCHEMA',
        evidence: 'capability note schema_version=${version ?? "<missing>"}, '
            'this reader understands 1',
      );
    }
    final psc = fields['patchable_static_calls'];
    return switch (psc) {
      'true' => (state: 'PROVEN', evidence: 'note: $payload'),
      'false' => (state: 'NOT_PATCHABLE', evidence: 'note: $payload'),
      _ => (
        state: 'UNPROVEN_MARKER_MALFORMED',
        evidence: 'patchable_static_calls=${psc ?? "<missing>"}',
      ),
    };
  }
  return (
    state: 'UNPROVEN_MARKER_ABSENT',
    evidence: 'no $noteName section; an older or unknown toolchain does not '
        'say, which is not the same as saying false',
  );
}

void main(List<String> args) {
  String? dillPath;
  String? aotPath;
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
      case '--aot':
        aotPath = next();
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

  // RELEASE-LEVEL PATCH CAPABILITY.
  //
  // SM1-G5's positive control measured that a release built WITHOUT
  // --patchable_static_calls attaches the replacement, reports "APPLY ok", and
  // then keeps running the old body. So patchability depends on how the RELEASE
  // BINARY was produced, not only on the declaration -- and its absence is a
  // silent bypass.
  //
  // THREE STATES, NEVER TWO. "We could not establish this" is not "this release
  // is incapable"; collapsing them would turn a missing input into a positive
  // claim about the artifact.
  var capability = 'UNPROVEN';
  String? capabilityEvidence;
  String? aotSha;
  if (aotPath == null) {
    capabilityEvidence = 'no --aot supplied';
  } else {
    final f = File(aotPath);
    if (!f.existsSync()) {
      capabilityEvidence = 'no artifact at $aotPath';
    } else {
      final bytes = f.readAsBytesSync();
      aotSha = sha256.convert(bytes).toString();
      final note = _readCapabilityNote(bytes);
      capabilityEvidence = note.evidence;
      capability = note.state;
    }
  }

  File(outPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'schema': 'semantic-map-1/g5-release-contract/2',
      'release_patch_capability': capability,
      'release_patch_capability_evidence': capabilityEvidence,
      // Recorded beside the result whatever the result is, so an UNPROVEN can
      // be tied to the exact artifact that produced it.
      'release_aot_sha256': aotSha,
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
