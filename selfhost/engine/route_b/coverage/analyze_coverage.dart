// Copyright (c) 2026, the Shorebird self-host fork.
//
// analyze_coverage.dart -- Route B step 3, producer half: the target manifest
// and the change classification, as ONE artifact the CLI can run.
//
// WHY THIS EXISTS AS A CELL ARTIFACT AND NOT AS CLI CODE
//
// `shorebird patch` cannot read a dill. `package:kernel` is not obtainable:
// the copy on pub.dev is the abandoned pre-null-safety publication
// (sdk: '>=1.8.0 <3.0.0'), the vended Flutter SDK ships no `pkg/` at all, and
// the live package exists only inside an engine checkout. Reimplementing the
// kernel binary reader in the CLI would mean reimplementing `Printer` too,
// since the member diff is defined as printed-AST equality.
//
// That constraint points the same way the provenance work already did. The
// kernel binary format is versioned and must match the frontend that emitted
// the dill, so the analyzer belongs to the RELEASE's toolchain, not to the
// machine running the patch. It ships in the compiler cell, beside
// dart2bytecode.aot, resolved by the release's engine hash.
//
// WHAT THIS IS A TRANSCRIPTION OF
//
// identity/gen_target_manifest.dart  -- target identity + reachability
// packaging/build_patch.dart         -- kernel diff + classification + verdict
//
// Those two are left untouched, deliberately. They are the reference
// implementation, and `coverage/parity.sh` runs both them and this against the
// same kernel pair and fails on any field that differs. If they shared code the
// harness would prove nothing; the transcription risk IS what it checks.
//
// Reason strings are copied verbatim. A reason is not decoration: "unsupported
// dispatch-table call" and "target unreachable" send you to opposite places --
// one to compiler coverage, the other to retention.
//
// cspell:words devirtualize devirtualizes dartaotruntime
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/text/ast_to_text.dart';

/// Bump when a consumer would have to change. The CLI refuses a version it does
/// not know rather than reading fields that may have moved -- the `*.vmcode`
/// filename convention is the cautionary tale for unversioned contracts.
///
/// 7: a private receiver access is REPORTED as an access carrying its manifest
///    key, where 6 refused it outright. A version-6 consumer reading a
///    version-7 document would see the access with no `unsupported` reason
///    beside it and lower it unconditionally -- accepting a private reference
///    the release may never have retained. That is exactly the silent-accept
///    this contract is versioned to prevent, so the bump is mandatory.
///
/// 8 (G3.7): a method with its own REQUIRED POSITIONAL parameters is no longer
///    `unsupported`. The entry-point contract now permits any number of them
///    (`bytecode_generator.dart`, patch `0006`), so the receiver no longer has to
///    be the only parameter. The bump is mandatory in the same way 7's was, and
///    in the opposite direction: a version-7 CONSUMER would still be refusing
///    these targets while a version-8 document reports them as lowerable, so the
///    two would disagree about what a release can accept. Named parameters,
///    optional positionals and generics stay `unsupported` here, matching the
///    compiler contract exactly -- the analyzer must never report a shape the
///    compiler will reject, because the refusal would then arrive at compile time
///    with a message about bytecode rather than about the patch.
///
/// 10: a genuine `SuperMethodInvocation` is REPORTED as a `superInvocations`
///     entry carrying its source-site identity, where 9 collapsed it into the
///     `unsupported` reason `calls \`super.x()\``. A version-9 consumer reading
///     a version-10 document would see a lowering with no `unsupported` reason
///     and conclude the body is fully lowerable, which is why this is a version
///     bump and not an additive field.
///
///     `super` GETTERS and SETTERS stay `unsupported`, unchanged.
///
///     WHAT IS DELIBERATELY NOT REPORTED: the resolved super target, its
///     declaring class, its signature, and the call site's argument count.
///     Each has been disqualified as a cross-boundary authority by measurement
///     -- the target's canonical owner is renamed by AOT mixin deduplication
///     (`super0/s2a/`), and TFA can rewrite `super.tag('a', 7)` to zero
///     arguments in this very kernel (`super0/s2b0/`). The source is the
///     authority for shape; the replacement compiler's own kernel is the
///     authority for the target.
///
/// 11: a super site now carries its resolved `target` as a SOURCE PROVENANCE
///     tuple, and each changed instance method carries `releaseSuperTargets` --
///     the same tuple for every super target the RELEASE version of that method
///     already direct-called.
///
///     Version 10 deliberately reported NO resolved target, because a target's
///     canonical owner is renamed by AOT mixin deduplication and is not portable
///     (`super0/s2a/`). What 2A.2 measured as portable is the narrower tuple
///     `fileUri | fileOffset | name | kind`, and 2B.1f showed the product needs
///     it: the release-evidence gate compares TARGETS, because a call SITE moves
///     when the patch edits around it.
///
///     So the exact-key assertion changes deliberately rather than the
///     prohibition being weakened silently. Still never reported: the canonical
///     owner, the synthetic mixin-application name, and any argument count.
const analysisVersion = 11;

/// How the VM names a member of a given kind. ONE place, so no caller has to
/// know it. Verbatim from gen_target_manifest.dart.
String vmMemberName(String name, String kind) => switch (kind) {
  'getter' => 'get:$name',
  'setter' => 'set:$name',
  _ => name,
};

void main(List<String> args) {
  String? basePath;
  String? patchedPath;
  String? outPath;
  // D0.2. Census mode reads ONE dill and asks the lowering contract about every
  // instance procedure in it, rather than about the members a patch changed.
  var census = false;
  String? censusPath;
  final includePrefixes = <String>[];

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String next() {
      if (i + 1 >= args.length) _die('$a needs a value');
      return args[++i];
    }

    switch (a) {
      case '--base-dill':
        basePath = next();
      case '--patched-dill':
        patchedPath = next();
      case '--out':
        outPath = next();
      case '--include':
        includePrefixes.add(next());
      case '--census':
        census = true;
      case '--dill':
        censusPath = next();
      case '-h':
      case '--help':
        print('''
Route B coverage analyzer -- classifies a kernel change against a release.

analyze_coverage --base-dill <release.dill> --patched-dill <patched.dill>
                 [--include <library-uri-prefix>]... [--out coverage.json]

Writes one JSON document (stdout if --out is omitted) and always exits 0: the
verdict is data, not an exit code, so a caller cannot act on it by accident.

analyze_coverage --census --dill <app.dill>
                 [--include <library-uri-prefix>]... [--out rows.jsonl]

CENSUS MODE (D0.2). Asks the SAME lowering contract about every instance
procedure in one kernel, and writes one JSON object per line. It is a
STRUCTURAL reachability measurement over methods that EXIST -- not an estimate
of how many real patches would succeed. See the header of the reporter,
coverage/census_report.py, for what the numbers may and may not be read as.
''');
        return;
      default:
        _die('unknown argument: $a');
    }
  }
  if (census) {
    if (censusPath == null) _die('--census needs --dill');
    _runCensus(censusPath, includePrefixes, outPath);
    return;
  }
  if (basePath == null) _die('--base-dill is required');
  if (patchedPath == null) _die('--patched-dill is required');

  final base = _load(basePath);
  final patched = _load(patchedPath);
  // One hierarchy per component. The RELEASE's is what makes the release
  // evidence meaningful: it must be resolved in the kernel that was actually
  // compiled, not in the patch's.
  // LAZY, and that is load-bearing rather than a micro-optimisation.
  //
  // v11 added these two lines eagerly, which silently made a fully-LINKED base
  // kernel a precondition of EVERY analysis. The release flow's early and late
  // agreement checks pass the `--no-aot --no-link-platform` import kernel as
  // the base: its `dart:core` classes are external references with no AST, so
  // `ClassHierarchy` throws "Reference to dart:core::Object is not bound to an
  // AST node" and the analyzer exits 255. `agreesWith()` catches that, warns,
  // and returns false -- which makes the release DELETE `release_import.dill`
  // and ship unpatchable. Measured on release 140; the pre-v11 analyzer handles
  // the identical kernel at exit 0.
  //
  // Only the super-target paths need a hierarchy, and only for members that
  // actually carry a super invocation. Deferring construction means an unlinked
  // base kernel costs nothing unless something genuinely needs to resolve
  // against it -- and then it still fails loudly, at the member that needed it.
  // Whether the BASE component carries its platform. A `--no-link-platform`
  // kernel names dart:core but binds no AST for it, so any hierarchy over it
  // throws. Measured, not assumed: the class list is what ClassHierarchy walks.
  final baseIsLinked = base.libraries.any(
    (l) => l.importUri.toString() == 'dart:core' && l.classes.isNotEmpty,
  );
  late final baseHierarchy = ClassHierarchy(base, CoreTypes(base));
  late final patchedHierarchy = ClassHierarchy(patched, CoreTypes(patched));

  bool isApp(Library lib) {
    final uri = lib.importUri.toString();
    if (uri.startsWith('dart:')) return false;
    if (includePrefixes.isEmpty) return true;
    return includePrefixes.any(uri.startsWith);
  }

  // ---- target manifest, from the RELEASE kernel -------------------------
  //
  // The base dill, never the patched one. The manifest describes what the
  // shipped release can accept; asking the rebuilt kernel would let a change
  // vouch for itself.
  final targets = _manifest(base, isApp);

  // ---- what changed -----------------------------------------------------
  final baseText = _memberText(base, isApp);
  final patchedText = _memberText(patched, isApp);
  // P4.4. The SIGNATURE, separately from the whole printed procedure.
  //
  // `_memberText` already differs when a signature changes, so a signature
  // change is reported as `changed` -- but that is indistinguishable from a body
  // edit, and the two have opposite consequences. A body edit is the point of a
  // patch; a signature change replaces a function the release's call sites
  // invoke with a DIFFERENT arity or shape, and those call sites carry the
  // release's own ArgumentsDescriptor. Nothing downstream could tell them apart
  // from here, so both sides are reported and the product decides.
  final baseSig = _memberSignature(base, isApp);
  final patchedSig = _memberSignature(patched, isApp);

  final changed = <String>[];
  final added = <String>[];
  for (final entry in patchedText.entries) {
    final before = baseText[entry.key];
    if (before == null) {
      added.add(entry.key);
    } else if (before != entry.value) {
      changed.add(entry.key);
    }
  }
  final removed = baseText.keys
      .where((k) => !patchedText.containsKey(k))
      .toList();
  changed.sort();
  added.sort();
  removed.sort();

  // ---- where each changed member's new body lives ------------------------
  //
  // From the PATCHED component, because that is the body a replacement carries.
  // Emitted as a source span rather than as text: the producer has the file, and
  // a span keeps this tool free of any opinion about how the replacement library
  // is assembled.
  //
  // `Dart_RouteBActivatePatch` attaches ONE function per payload, so a producer
  // needs exactly one declaration per target -- which is what a span gives it.
  final sources = <String, Map<String, Object?>>{};
  for (final lib in patched.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    void record(String? className, Procedure p) {
      final key = '$uri#${_selector(className, p)}';
      if (!changed.contains(key)) return;
      // fileStartOffset spans the declaration INCLUDING annotations;
      // fileEndOffset is the closing token. Together they are the exact
      // source a single-function replacement library needs.
      final start = p.fileStartOffset;
      final end = p.fileEndOffset;
      if (start < 0 || end < 0 || end <= start) return;
      sources[key] = {
        'fileUri': p.fileUri.toString(),
        'start': start,
        // Inclusive of the closing token, which is what makes the slice a
        // complete declaration.
        'end': end + 1,
      };
    }

    for (final p in lib.procedures) {
      record(null, p);
    }
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        record(cls.name, p);
      }
    }
  }

  // ---- implicit-`this` lowering, for INSTANCE targets --------------------
  //
  // Kernel decides MEANING; the producer's source edit supplies syntax. What is
  // emitted here is only what text cannot answer: which accesses are
  // receiver-based, what they resolve to, and where their identifier starts.
  //
  // Deliberately narrow. Anything outside the supported surface is reported as
  // an `unsupported` reason rather than lowered on a guess -- a wrong lowering
  // compiles and then misbehaves on a device, which is the failure mode this
  // whole project is organised against.
  final lowering = <String, Map<String, Object?>>{};
  for (final lib in patched.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        final key = '$uri#${_selector(cls.name, p)}';
        if (!changed.contains(key) || p.isStatic) continue;
        lowering[key] = _lowering(cls, p, patchedHierarchy);
        // RELEASE EVIDENCE for the SAME method (analysis version 11).
        //
        // Same-method, never program-wide: the causal argument for the target
        // having AOT code is that the RELEASE version of THIS compiled method
        // direct-called it. Evidence from an unrelated method would not support
        // that chain (`super0/s2b1f/`).
        //
        // An empty list is meaningful and is emitted: it says the release
        // version of this method direct-called nothing, so any super site the
        // patch introduces has no evidence behind it.
        //
        // Resolving a super target needs a ClassHierarchy over the BASE
        // component, which needs its platform LINKED. The release flow also
        // calls this analyzer with the `--no-link-platform` import kernel as
        // base, to ask a different question -- does the import kernel contain
        // everything the AOT kernel compiled. For that base there is no
        // hierarchy to build, and v11 crashed the whole analysis trying.
        //
        // The key is OMITTED rather than emitted empty. Empty is a claim --
        // "the release version of this method direct-called nothing" -- and
        // making that claim from a kernel we could not examine would be a
        // measurement we did not take. Absent says we did not look.
        if (baseIsLinked) {
          final releaseClass = _findClass(base, uri, cls.name);
          final releaseMember = releaseClass == null
              ? null
              : _findProcedure(releaseClass, p.name.text, p.kind);
          lowering[key]!['releaseSuperTargets'] = releaseMember == null
              ? const <Map<String, Object?>>[]
              : _superTargets(baseHierarchy, releaseClass!, releaseMember);
        }
      }
    }
  }

  // ---- classify ---------------------------------------------------------
  final reach = <String, String>{};
  final reasonFor = <String, String>{};
  for (final t in targets) {
    final key = '${t['library']}#${t['selector']}';
    reach[key] = t['reachable']! as String;
    reasonFor[key] = t['reason']! as String;
  }

  final patchable = <String>[];
  final conditional = <String>[];
  final unreachable = <String>[];
  final unknown = <String>[];
  for (final key in changed) {
    switch (reach[key]) {
      case 'yes':
        patchable.add(key);
      case 'conditional':
        conditional.add(key);
      case 'no':
        unreachable.add(key);
      default:
        unknown.add(key);
    }
  }

  // ---- the verdict ------------------------------------------------------
  //
  // Whole-patch, never per-target: 4 changed / 3 representable / 1 rejected
  // rejects all four. Shipping the 3 would install cleanly and leave the app
  // in a state no one designed -- three functions from the patch, one from the
  // release.
  //
  // Rejection reasons are attributed PER TARGET here, where the reference tool
  // reports counts. Same rule, same strings; a count cannot tell you which
  // function to go look at.
  final rejections = <Map<String, Object?>>[
    for (final key in unreachable)
      {'target': key, 'category': 'unreachable', 'reason': reasonFor[key]},
    for (final key in unknown)
      {
        'target': key,
        'category': 'unknown',
        'reason': 'not in the release manifest; unknown reachability is not '
            'the same as reachable',
      },
    for (final key in added)
      {
        'target': key,
        'category': 'added',
        'reason': 'a patch replaces bodies and cannot introduce members, so '
            'bytecode referencing them would fail to bind',
      },
  ];

  // Verbatim from build_patch.dart, including the order, so the harness can
  // compare the joined string against that tool's stderr.
  final reasons = <String>[];
  if (unreachable.isNotEmpty) {
    reasons.add('${unreachable.length} changed member(s) are not reachable');
  }
  if (unknown.isNotEmpty) {
    reasons.add('${unknown.length} changed member(s) are not in the manifest');
  }
  if (added.isNotEmpty) {
    reasons.add(
      '${added.length} member(s) are new; a patch replaces bodies and cannot '
      'introduce members, so bytecode referencing them would fail to bind',
    );
  }

  // Three outcomes, matching the reference tool's exit codes 0 / 3 / 4. `inert`
  // is not a failure and not a success: a patch carrying nothing installs and
  // changes nothing, which is worse than refusing because it looks like it
  // worked.
  final String verdict;
  if (changed.isEmpty && added.isEmpty && removed.isEmpty) {
    verdict = 'inert';
  } else if (changed.isEmpty) {
    verdict = reasons.isEmpty ? 'inert' : 'reject';
  } else {
    verdict = reasons.isEmpty ? 'accept' : 'reject';
  }

  // Only for members that exist on BOTH sides: an added member has no release
  // signature to compare against, and a removed one has no replacement.
  final signatures = <String, Map<String, Object?>>{
    for (final key in changed)
      if (baseSig[key] != null && patchedSig[key] != null)
        key: {
          'release': baseSig[key],
          'patch': patchedSig[key],
          'changed': baseSig[key] != patchedSig[key],
        },
  };

  final document = {
    'analysisVersion': analysisVersion,
    'baseDill': basePath,
    'patchedDill': patchedPath,
    'targets': targets,
    'changed': changed,
    'added': added,
    'removed': removed,
    'patchable': patchable,
    'conditional': conditional,
    'unreachable': unreachable,
    'unknown': unknown,
    'sources': sources,
    'lowering': lowering,
    'signatures': signatures,
    'rejections': rejections,
    'refusalSummary': reasons.isEmpty ? null : reasons.join('; '),
    'verdict': verdict,
  };

  final json = '${const JsonEncoder.withIndent('  ').convert(document)}\n';
  if (outPath == null) {
    stdout.write(json);
  } else {
    File(outPath).writeAsStringSync(json);
  }
}

/// Verbatim from gen_target_manifest.dart, minus the file/argument handling.
List<Map<String, Object?>> _manifest(
  Component component,
  bool Function(Library) isApp,
) {
  final targets = <Map<String, Object?>>[];

  void addProcedure(Procedure p, String libraryUri, String? className) {
    final kind = switch (p.kind) {
      ProcedureKind.Getter => 'getter',
      ProcedureKind.Setter => 'setter',
      ProcedureKind.Operator => 'operator',
      ProcedureKind.Factory => 'factory',
      ProcedureKind.Method => 'method',
    };

    // Reachability, per step 1's measured inventory. A static-shaped call is
    // emitted as Route B's patchable form. An instance member is only reachable
    // where the compiler devirtualizes its call sites; where it stays
    // polymorphic the call is specialized into a dispatch-table call and no
    // patch can reach it. Which of those a given SITE is, is decided by the
    // precompiler and is not visible in this kernel -- so it is reported as
    // conditional rather than guessed at. Reporting a guess as a fact is how a
    // link percentage becomes a lie.
    final isStaticShaped = p.isStatic || className == null;
    final String reachable;
    final String reason;
    if (isStaticShaped) {
      reachable = 'yes';
      reason = 'static-shaped call; emitted as the patchable form';
    } else if (p.isAbstract) {
      reachable = 'no';
      reason = 'abstract; call sites dispatch to implementations';
    } else {
      reachable = 'conditional';
      reason =
          'instance member; reachable only where the call site devirtualizes '
          'or goes through the cid chain, not where it becomes a '
          'dispatch-table call';
    }

    targets.add({
      'library': libraryUri,
      'class': className,
      'name': p.name.text,
      'kind': kind,
      'vmName': vmMemberName(p.name.text, kind),
      'selector': className == null
          ? vmMemberName(p.name.text, kind)
          : '$className.${vmMemberName(p.name.text, kind)}',
      'reachable': reachable,
      'reason': reason,
    });
  }

  for (final lib in component.libraries.where(isApp)) {
    final libraryUri = lib.importUri.toString();
    for (final p in lib.procedures) {
      addProcedure(p, libraryUri, null);
    }
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        addProcedure(p, libraryUri, cls.name);
      }
    }
  }

  targets.sort((a, b) {
    final byLib = (a['library']! as String).compareTo(b['library']! as String);
    if (byLib != 0) return byLib;
    final byCls = ((a['class'] ?? '') as String).compareTo(
      (b['class'] ?? '') as String,
    );
    if (byCls != 0) return byCls;
    return (a['name']! as String).compareTo(b['name']! as String);
  });

  return targets;
}

Component _load(String path) {
  final c = Component();
  BinaryBuilder(File(path).readAsBytesSync()).readComponent(c);
  return c;
}

/// `library#selector` -> a stable textual form of the member.
///
/// Printed from the kernel AST rather than hashed from the binary: the binary
/// carries offsets and canonical-name indices that shift when unrelated code
/// moves, which would report the whole program as changed after a one-line
/// edit. Verbatim from build_patch.dart.
Map<String, String> _memberText(Component c, bool Function(Library) isApp) {
  final out = <String, String>{};
  for (final lib in c.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    for (final p in lib.procedures) {
      out['$uri#${_selector(null, p)}'] = _text(p);
    }
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        out['$uri#${_selector(cls.name, p)}'] = _text(p);
      }
    }
  }
  return out;
}

String _selector(String? className, Procedure p) {
  final name = switch (p.kind) {
    ProcedureKind.Getter => 'get:${p.name.text}',
    ProcedureKind.Setter => 'set:${p.name.text}',
    _ => p.name.text,
  };
  return className == null ? name : '$className.$name';
}

/// `library#selector` -> a stable identity for the member's SIGNATURE only.
///
/// Deliberately not the printed procedure: that includes the body, so it changes
/// on every patch and could never answer "did the shape change?". Built from the
/// pieces a call site actually depends on -- arity, which positionals are
/// required, the named parameters BY NAME, type-parameter count, and the return
/// and parameter types -- so a reordering of named parameters (which callers do
/// not see) does not read as a change, while adding one does.
Map<String, String> _memberSignature(Component c, bool Function(Library) isApp) {
  final out = <String, String>{};
  for (final lib in c.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    for (final p in lib.procedures) {
      out['$uri#${_selector(null, p)}'] = _signature(p);
    }
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        out['$uri#${_selector(cls.name, p)}'] = _signature(p);
      }
    }
  }
  return out;
}

String _signature(Procedure p) {
  final f = p.function;
  String type(DartType t) {
    final buffer = StringBuffer();
    Printer(buffer).writeType(t);
    return buffer.toString();
  }

  final positional = [
    for (var i = 0; i < f.positionalParameters.length; i++)
      '${i < f.requiredParameterCount ? '' : '?'}'
          '${type(f.positionalParameters[i].type)}',
  ];
  // Sorted by name: callers pass named arguments by name, so their ORDER in the
  // declaration is not part of the contract and must not read as a change.
  final named = [
    for (final n in [...f.namedParameters]..sort((a, b) => a.name!.compareTo(b.name!)))
      '${n.isRequired ? 'required ' : ''}${n.name}:${type(n.type)}',
  ];
  return '<${f.typeParameters.length}>(${positional.join(',')}'
      '${named.isEmpty ? '' : '{${named.join(',')}}'})'
      '->${type(f.returnType)}';
}

String _text(Procedure p) {
  final buffer = StringBuffer();
  Printer(buffer).writeNode(p);
  return buffer.toString();
}

Never _die(String message) {
  stderr.writeln('error: $message');
  exit(2);
}

/// D0.2 -- the structural body census.
///
/// WHY THIS LIVES HERE AND NOT IN A SECOND TOOL. `_lowering` IS the product's
/// refusal contract: the ABI clauses, the receiver traversal, the same-offset
/// read/write collision, the private-capability reporting. A census that
/// reimplemented any of it would drift from the thing it claims to measure, and
/// would drift silently. So census mode calls the same function the patch path
/// calls, over a different set of members.
///
/// WHAT THE DENOMINATOR IS, stated so a reader cannot mistake it:
///
///   every INSTANCE `Procedure` on a class in an included library, that has a
///   body to replace
///
/// Excluded, with the count reported so the exclusion is visible rather than
/// silent: static procedures (the lowering does not apply -- there is no
/// receiver to lower), abstract and external procedures (no body), and
/// procedures with no usable source span.
///
/// WHAT IT DOES NOT RUN. `_lowering` is one stage of several. Reachability and
/// retention are per-release facts held in a manifest this tool does not have;
/// the producer's own source-text refusals (`this . label` spacing, an escaped
/// `\$\$`) need the file and the edit; the bytecode compiler gets the last word.
/// A row saying `lowerable` means THIS stage raised no objection, and nothing
/// more.
void _runCensus(String path, List<String> includePrefixes, String? outPath) {
  final component = _load(path);
  final censusHierarchy = ClassHierarchy(component, CoreTypes(component));
  bool isApp(Library lib) {
    final uri = lib.importUri.toString();
    if (uri.startsWith('dart:')) return false;
    if (includePrefixes.isEmpty) return true;
    return includePrefixes.any(uri.startsWith);
  }

  // Source files are read once and cached: a census over a real app asks about
  // thousands of procedures spread over hundreds of files.
  final sourceCache = <String, String?>{};
  String? sourceOf(Uri uri) => sourceCache.putIfAbsent(uri.toString(), () {
    try {
      final file = File.fromUri(uri);
      if (!file.existsSync()) return null;
      return utf8.decode(file.readAsBytesSync());
    } on Object {
      return null;
    }
  });

  // IS THIS FILE GENERATED. Reported per row so a corpus dominated by codegen
  // cannot be mistaken for a corpus dominated by hand-written code.
  //
  // BY THE MARKER, NOT BY THE FILENAME. A `.g.dart` filter looked sufficient
  // until localsend: its flutter_rust_bridge bindings are named
  // `frb_generated.dart` and `rust/api/*.dart`, carry the standard marker, and
  // are committed to the repository -- and they turned out to hold 101 of the
  // 108 `this` escapes that the first reading of that corpus ranked first. A
  // hand-maintained list of filename patterns is a filter that has to be
  // rediscovered per corpus, which is another way of saying it is tuned.
  //
  // THE CONVENTION, NOT A LIST OF TOOLS. There is no single marker: build_runner
  // writes `GENERATED CODE - DO NOT MODIFY BY HAND`, flutter_rust_bridge writes
  // `@generated`, slang writes `Generated file. Do not edit.`. Enumerating them
  // is a list that has to grow every time a new corpus arrives -- which is how
  // localsend's 18,193 slang getters survived the first filter.
  //
  // So the test is the SHAPE of the convention: the file's head says it was
  // generated AND says not to edit it. That is what every one of those tools
  // actually agrees on.
  //
  // A convention is not a guarantee. A generated file that declares nothing is
  // counted as hand-written, which is the safe direction: it under-excludes
  // rather than quietly removing real code. Both views are reported either way.
  final generatedCache = <String, bool>{};
  bool isGenerated(Uri uri) => generatedCache.putIfAbsent(uri.toString(), () {
    final text = sourceOf(uri);
    if (text == null) return false;
    final head =
        (text.length > 2048 ? text.substring(0, 2048) : text).toLowerCase();
    if (head.contains('@generated')) return true;
    return head.contains('generated') &&
        (head.contains('do not edit') || head.contains('do not modify'));
  });

  final rows = <Map<String, Object?>>[];
  var skippedStatic = 0;
  var skippedNoBody = 0;
  var skippedNoSpan = 0;

  for (final lib in component.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        if (p.isStatic) {
          skippedStatic++;
          continue;
        }
        if (p.isAbstract || p.isExternal || p.function.body == null) {
          skippedNoBody++;
          continue;
        }
        final start = p.fileStartOffset;
        final end = p.fileEndOffset;
        if (start < 0 || end < 0 || end <= start) {
          skippedNoSpan++;
          continue;
        }

        final lowering = _lowering(cls, p, censusHierarchy);
        final unsupported =
            (lowering['unsupported']! as List).cast<String>();
        final accesses = (lowering['accesses']! as List).length;

        // WHY THE `this` REFUSAL FIRED, which its own reason string cannot say.
        //
        // "uses `this` other than to read a member" is ONE reason covering
        // shapes with nothing in common. In real Flutter code it turns out to be
        // dominated by implicit METHOD TEAR-OFFS -- `onPressed: _handleTap`,
        // `bgBuilder: _buildBg` -- where `this` is the receiver of an
        // InstanceTearOff and the lowered spelling is the same textual edit as a
        // read. That is a different mechanism, and a different cost, from
        // `vsync: this`, where the receiver itself escapes into someone else's
        // hands. Ranking them as one category picks the wrong feature.
        //
        // So the census classifies each unconsumed `this` by its PARENT node and
        // reports the raw Kernel node name -- a shape nobody has looked at yet
        // appears under its own name instead of hiding in an `other` row.
        //
        // MEASUREMENT ONLY. It takes no part in the refusal, which is
        // `_lowering`'s and is unchanged. The consumption rule is not restated
        // either: a second `_ReceiverUses` is run and its own `consumed` set is
        // read, so there is one definition of "consumed".
        final probe = _ReceiverUses();
        p.function.accept(probe);
        final everyThis = _ThisExpressions();
        p.function.accept(everyThis);
        final parents = <String, int>{};
        for (final t in everyThis.found) {
          if (probe.consumed.contains(t)) continue;
          final name = t.parent?.runtimeType.toString() ?? 'none';
          parents[name] = (parents[name] ?? 0) + 1;
        }

        // D-HYGIENE, reported as METADATA and never as a refusal. Capture-
        // avoiding receiver naming closed that defect, so a declaration
        // spelling `self` is lowered correctly -- it just costs an alpha-
        // rename. Counting it as unsupported would put a solved problem back
        // into the blocker ranking; not counting it at all would leave no way
        // to tell how often the mechanism is exercised.
        //
        // The test mirrors the producer's allocator exactly: a plain substring
        // scan of the whole declaration, comments and strings included. It
        // over-triggers in the same direction, for the same reason.
        final text = sourceOf(p.fileUri);
        final span = (text != null && end + 1 <= text.length)
            ? text.substring(start, end + 1)
            : null;

        rows.add({
          'target': '$uri#${_selector(cls.name, p)}',
          'kind': p.kind.name,
          'private': p.name.text.startsWith('_'),
          'accesses': accesses,
          // The analyzer now DESCRIBES super instead of refusing it (v10), but
          // the shipping product still cannot lower it. The census measures the
          // product's surface, so a reported super site keeps counting as a
          // blocker here -- otherwise D0.2/D0.4's banked numbers would move with
          // no change in what a user can actually patch.
          'superInvocations':
              (lowering['superInvocations']! as List).length,
          'lowerable': unsupported.isEmpty &&
              (lowering['superInvocations']! as List).isEmpty,
          'unsupported': unsupported,
          // null when the source file could not be read, so "no rename needed"
          // and "not known" are never conflated.
          'needsAlphaRename': span == null ? null : span.contains('self'),
          'generated': isGenerated(p.fileUri),
          'unconsumedThisParents': parents,
        });
      }
    }
  }

  rows.sort(
    (a, b) => (a['target']! as String).compareTo(b['target']! as String),
  );

  final buffer = StringBuffer()
    ..writeln(
      jsonEncode({
        'censusVersion': 1,
        'dill': path,
        'include': includePrefixes,
        'considered': rows.length,
        'skippedStatic': skippedStatic,
        'skippedNoBody': skippedNoBody,
        'skippedNoSpan': skippedNoSpan,
        'analysisVersion': analysisVersion,
      }),
    );
  for (final row in rows) {
    buffer.writeln(jsonEncode(row));
  }
  if (outPath == null) {
    stdout.write(buffer.toString());
  } else {
    File(outPath).writeAsStringSync(buffer.toString());
  }
}

/// What a producer needs to turn an instance method into a static replacement
/// taking its receiver as argument 0.
///
/// The supported surface is ONE form: a public instance getter read off `this`,
/// spelled either `label` or `this.label` -- which are the same Kernel node, so
/// only the source text distinguishes them and only the producer needs to care.
Map<String, Object?> _lowering(
  Class cls,
  Procedure p,
  ClassHierarchy hierarchy,
) {
  final unsupported = <String>[];

  final function = p.function;
  // G3.7: the method's OWN required positional parameters are now supported. The
  // entry-point contract permits any number of them, so the receiver no longer has
  // to be the only parameter, and the producer copies the source's parameter list
  // verbatim while inserting the receiver in front of it.
  //
  // These three stay refused, and each mirrors a clause of the compiler contract
  // rather than a separate opinion. Keeping them aligned is the point: an analyzer
  // that reported a shape the compiler rejects would move the refusal from patch
  // time to compile time, where the message talks about bytecode instead of about
  // the patch.
  if (function.namedParameters.isNotEmpty) {
    unsupported.add('the method takes named parameters');
  }
  if (function.requiredParameterCount != function.positionalParameters.length) {
    // Their default values live in the AOT function the replacement stands in
    // for, and nothing carries them across.
    unsupported.add('the method takes optional positional parameters');
  }
  if (function.typeParameters.isNotEmpty) {
    unsupported.add('the method is generic');
  }

  final visitor = _ReceiverUses();
  function.accept(visitor);
  unsupported.addAll(visitor.unsupported);

  // ONE SOURCE TOKEN CANNOT BE TWO EDITS. `label += 'X'`, `count++` and
  // `maybe ??= 'Z'` each report a read AND a write at the SAME offset, because
  // one identifier is doing both jobs. The producer inserts a receiver prefix
  // at an offset, so two edits there would yield `self.self.label`.
  //
  // Detected by the collision rather than by listing operators: it catches
  // compound assignment, increment and if-null uniformly, including forms
  // nobody has thought of yet. `label = label + 'Y'` is untouched by it --
  // measured at two distinct offsets, because it really is two tokens.
  final byOffset = <int, List<_Access>>{};
  for (final a in visitor.accesses) {
    byOffset.putIfAbsent(a.offset, () => []).add(a);
  }
  for (final entry in byOffset.entries) {
    if (entry.value.length > 1) {
      final kinds = entry.value.map((a) => a.kind).join('+');
      unsupported.add(
        'reads and writes `${entry.value.first.member}` in one expression '
        '($kinds), which this lowering cannot rewrite as a single edit',
      );
    }
  }

  return {
    'receiverType': cls.name,
    // ORIGIN IDENTITY (analysis version 10). What the replacement compiler needs
    // to find this method again in ITS OWN kernel and re-derive the super target
    // there. Stable source-level facts only.
    //
    // `memberKind` is carried alongside the name rather than assumed: a class
    // may hold a method, a getter and a setter of the same name, so name + class
    // is not an identity. Cheap now; an implicit assumption later.
    'origin': {
      'library': cls.enclosingLibrary.importUri.toString(),
      'class': cls.name,
      'member': p.name.text,
      'memberKind': p.kind.name,
    },
    // Where the producer starts looking for the parameter list. Kernel puts
    // `fileOffset` on the NAME, and an annotation like @pragma('...') contains
    // parentheses of its own, so scanning from the declaration start would find
    // the wrong ones.
    'nameOffset': p.fileOffset,
    'accesses': [
      for (final a in visitor.accesses)
        {
          'offset': a.offset,
          'member': a.member,
          'kind': a.kind,
          if (a.private != null) 'private': a.private,
        },
    ],
    // Genuine `super.member()` sites. An EMPTY list is the common case and the
    // only one a producer without direct-super support may proceed on.
    'superInvocations': [
      for (final site in visitor.superInvocations)
        {
          'offset': site.offset,
          'member': site.member,
          'kind': site.kind,
          // The RESOLVED target, as provenance only (analysis version 11).
          // Null when nothing resolves: reported rather than omitted, because a
          // site with no target is a finding and not an absence.
          'target': _provenance(
            cls.superclass == null
                ? null
                : hierarchy.getDispatchTarget(
                    cls.superclass!,
                    site.member.startsWith('_')
                        ? Name(site.member, cls.enclosingLibrary)
                        : Name(site.member),
                  ),
          ),
        },
    ],
    'unsupported': unsupported,
  };
}

/// The class of that name in [component], or null.
Class? _findClass(Component component, String libraryUri, String name) {
  for (final lib in component.libraries) {
    if (lib.importUri.toString() != libraryUri) continue;
    for (final cls in lib.classes) {
      if (cls.name == name) return cls;
    }
  }
  return null;
}

/// The procedure of that name AND KIND, or null.
///
/// Kind is required, not incidental: a class may hold a method, a getter and a
/// setter of one name, so a name alone is not an identity.
Procedure? _findProcedure(Class cls, String name, ProcedureKind kind) {
  for (final p in cls.procedures) {
    if (p.name.text == name && p.kind == kind) return p;
  }
  return null;
}

/// SOURCE PROVENANCE of a member, as the only portable cross-kernel identity.
///
/// No enclosing class: including it would reimport the transformed identity that
/// AOT mixin deduplication renames. Dart has no overloading, so a file offset
/// plus a name and kind identifies exactly one declaration.
Map<String, Object?>? _provenance(Member? m) => m == null
    ? null
    : {
        'fileUri': m.fileUri.toString(),
        'fileOffset': m.fileOffset,
        'name': m.name.text,
        'kind': m is Procedure ? m.kind.name : m.runtimeType.toString(),
      };

/// Every super target [p] direct-calls, resolved with [hierarchy].
///
/// Used on the RELEASE side to record what that version of the method already
/// required AOT to compile — which is the whole basis of the narrow-v1
/// admission rule (`super0/s2b1f/`).
List<Map<String, Object?>> _superTargets(
  ClassHierarchy hierarchy,
  Class cls,
  Procedure p,
) {
  final visitor = _ReceiverUses();
  p.function.accept(visitor);
  final superclass = cls.superclass;
  if (superclass == null) return const [];
  final out = <Map<String, Object?>>[];
  for (final site in visitor.superInvocations) {
    final name = site.member.startsWith('_')
        ? Name(site.member, cls.enclosingLibrary)
        : Name(site.member);
    final resolved = hierarchy.getDispatchTarget(superclass, name);
    final provenance = _provenance(resolved);
    if (provenance != null) out.add(provenance);
  }
  return out;
}

/// A genuine `super.member()` site: where it is, and what it names.
///
/// Deliberately NOT the resolved target, its owner, or its arity. See the
/// `analysisVersion` 10 note.
class _SuperSite {
  _SuperSite(this.offset, this.member, this.kind);
  final int offset;
  final String member;
  final String kind;
}

class _Access {
  _Access(this.offset, this.member, this.kind, {this.private});
  final int offset;
  final String member;
  final String kind;

  /// Set when [member] is private, naming what the release would have had to
  /// retain for this access to bind. Null for a public access.
  ///
  /// The analyzer does NOT decide whether the release retained it. It cannot:
  /// the capability manifest is a per-release artifact and this tool ships in
  /// the compiler cell, resolved by engine hash. So it reports the key and the
  /// CLI matches it against the manifest the release actually published.
  final Map<String, Object?>? private;
}

/// The manifest key for a private member reached off the receiver.
///
/// Resolved from the interface target rather than from the enclosing class of
/// the method being patched, because `this._controller` may be DECLARED on a
/// superclass in the same library -- and the manifest keys a member under the
/// class that declares it. Guessing the patched class would refuse a member
/// that was in fact granted.
///
/// The name follows `LibraryIndex`: a Field is keyed BARE, a Procedure carries
/// the VM's `get:`/`set:` disambiguation. That is the same rule
/// gen_dynamic_interface.dart applied when it emitted the manifest, and the two
/// have to agree exactly or every lookup misses.
Map<String, Object?>? _privateKey(Member? target) {
  if (target == null) return null;
  final cls = target.enclosingClass;
  if (cls == null) return null;
  final name = target is Procedure
      ? switch (target.kind) {
          ProcedureKind.Getter => 'get:${target.name.text}',
          ProcedureKind.Setter => 'set:${target.name.text}',
          _ => target.name.text,
        }
      : target.name.text;
  return {
    'library': target.enclosingLibrary.importUri.toString(),
    'class': cls.name,
    'name': name,
  };
}

/// Every `ThisExpression` in a body, for the census to classify.
///
/// Census-only. It makes no decision; `_lowering` has already made it.
class _ThisExpressions extends RecursiveVisitor {
  final found = <ThisExpression>[];

  @override
  void visitThisExpression(ThisExpression node) => found.add(node);
}

/// Every use of the receiver, and a reason for each one that is not supported.
class _ReceiverUses extends RecursiveVisitor {
  final accesses = <_Access>[];
  final unsupported = <String>[];

  /// Genuine `super.member()` sites, as STRUCTURE rather than as a refusal
  /// string (analysis version 10).
  final superInvocations = <_SuperSite>[];

  /// `ThisExpression` nodes already accounted for as the receiver of a
  /// supported access. Without this every `label` reports twice: once as the
  /// InstanceGet and once as its own synthesized receiver.
  ///
  /// Readable rather than private because the D0.2 census classifies the
  /// UNCONSUMED remainder, and restating the consumption rule there would be
  /// two definitions of one thing.
  final consumed = <ThisExpression>{};

  /// Record one receiver access.
  ///
  /// PRIVATE IS REPORTED HERE, NOT REFUSED. Rung D proved a synthetic
  /// replacement library CAN name a private member of the release, given
  /// `--resolve-private-names-in-library` and a release that retained it. The
  /// second half is a per-release fact recorded in that release's capability
  /// manifest, and this tool ships in the compiler cell resolved by engine
  /// hash -- so it reports the key and the CLI matches it against the manifest
  /// the release actually published.
  ///
  /// A private member whose key cannot be resolved is REFUSED, not reported:
  /// an access with no key is indistinguishable from a public one downstream,
  /// and that is the one direction where the mistake is silent.
  void _record(int offset, String name, String kind, Member? target) {
    if (!name.startsWith('_')) {
      accesses.add(_Access(offset, name, kind));
      return;
    }
    final key = _privateKey(target);
    if (key == null) {
      unsupported.add(
        '${_phrase(kind)} the private member `$name`, which resolves to no '
        'declaration this analysis can name -- so no release manifest can '
        'show it was retained',
      );
      return;
    }
    accesses.add(_Access(offset, name, kind, private: key));
  }

  static String _phrase(String kind) => switch (kind) {
    'set' => 'assigns to',
    'invoke' => 'calls',
    _ => 'reads',
  };

  @override
  void visitInstanceGet(InstanceGet node) {
    final receiver = node.receiver;
    if (receiver is ThisExpression) {
      consumed.add(receiver);
      _record(node.fileOffset, node.name.text, 'get', node.interfaceTarget);
    }
    node.visitChildren(this);
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    final receiver = node.receiver;
    if (receiver is ThisExpression) {
      consumed.add(receiver);
      // A write is the same lexical shape as a read: the offset is on the
      // identifier and everything after it -- `= <whatever>` -- is the
      // source's own text. The right-hand side is carried across untouched,
      // and any receiver use INSIDE it is its own reported access, so
      // `label = label + 'Y'` becomes `self.label = self.label + 'Y'`.
      _record(node.fileOffset, node.name.text, 'set', node.interfaceTarget);
    }
    node.visitChildren(this);
  }

  @override
  void visitSuperPropertySet(SuperPropertySet node) {
    // Refused for the same reason `super.foo()` is: a synthetic top-level
    // function has no `super`, and `self.foo = ...` would not mean the same
    // thing. Without this the generated library simply fails to compile, which
    // is loud but says nothing useful.
    unsupported.add('assigns to `super.${node.name.text}`');
    node.visitChildren(this);
  }

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    final receiver = node.receiver;
    if (receiver is ThisExpression) {
      consumed.add(receiver);
      // ARGUMENTS NEED NO PERMISSION. The producer's edit inserts a receiver
      // prefix immediately before this identifier and copies everything after
      // it verbatim, so the argument list -- positional, named, generic,
      // nested, however spelled -- is carried across as source text and never
      // interpreted. There is nothing about it for the lowering to get wrong,
      // and so nothing to gate on.
      //
      // Receiver uses INSIDE the arguments are a different matter, and they
      // are handled by the ordinary recursion: `helper(label)` reports two
      // accesses and becomes `self.helper(self.label)`.
      _record(
        node.fileOffset,
        node.name.text,
        'invoke',
        node.interfaceTarget,
      );
    }
    node.visitChildren(this);
  }

  @override
  void visitInstanceGetterInvocation(InstanceGetterInvocation node) {
    if (node.receiver is ThisExpression) {
      consumed.add(node.receiver as ThisExpression);
      unsupported.add('invokes the getter `${node.name.text}` on the receiver');
    }
    node.visitChildren(this);
  }

  @override
  void visitSuperPropertyGet(SuperPropertyGet node) {
    unsupported.add('reads `super.${node.name.text}`');
    node.visitChildren(this);
  }

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    // REPORTED, not refused. The producer decides admission from the SOURCE and
    // the replacement compiler re-establishes the target and the shape in its
    // own kernel; this tool's job is to say that a genuine super operation is
    // here and where it is.
    //
    // The offset is the site's own, measured to be identical in the AOT and
    // import kernels (`super0/s2b0/`), which is what makes it usable as the key
    // the other two stages read from.
    superInvocations.add(
      _SuperSite(node.fileOffset, node.name.text, 'method'),
    );
    node.visitChildren(this);
  }

  @override
  void visitThisExpression(ThisExpression node) {
    // ONE CONSTRUCT, ONE REPORT. The CFE puts a synthesized `this` inside every
    // `super` node -- proven on a probe whose source contains no `this` at all
    // (`super0/`) -- so before version 10 a single `super.dispose()` produced
    // TWO refusals: the super one, and this one. That double-reporting is what
    // made `super` look like it had 0% marginal unlock in the first D0.2
    // reading while inflating the `this` category with 43 methods that were
    // really super calls.
    //
    // It is the super operation's own receiver, and the super handling above has
    // already accounted for it.
    final parent = node.parent;
    if (parent is SuperMethodInvocation ||
        parent is SuperPropertyGet ||
        parent is SuperPropertySet) {
      return;
    }
    // A `this` that is not the receiver of a supported access -- passed as an
    // argument, captured by a closure, stored. Each is its own question.
    if (!consumed.contains(node)) {
      unsupported.add('uses `this` other than to read a member');
    }
  }
}
