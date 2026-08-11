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
import 'package:kernel/text/ast_to_text.dart';

/// Bump when a consumer would have to change. The CLI refuses a version it does
/// not know rather than reading fields that may have moved -- the `*.vmcode`
/// filename convention is the cautionary tale for unversioned contracts.
const analysisVersion = 5;

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
      case '-h':
      case '--help':
        print('''
Route B coverage analyzer -- classifies a kernel change against a release.

analyze_coverage --base-dill <release.dill> --patched-dill <patched.dill>
                 [--include <library-uri-prefix>]... [--out coverage.json]

Writes one JSON document (stdout if --out is omitted) and always exits 0: the
verdict is data, not an exit code, so a caller cannot act on it by accident.
''');
        return;
      default:
        _die('unknown argument: $a');
    }
  }
  if (basePath == null) _die('--base-dill is required');
  if (patchedPath == null) _die('--patched-dill is required');

  final base = _load(basePath);
  final patched = _load(patchedPath);

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
        lowering[key] = _lowering(cls, p);
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

String _text(Procedure p) {
  final buffer = StringBuffer();
  Printer(buffer).writeNode(p);
  return buffer.toString();
}

Never _die(String message) {
  stderr.writeln('error: $message');
  exit(2);
}

/// What a producer needs to turn an instance method into a static replacement
/// taking its receiver as argument 0.
///
/// The supported surface is ONE form: a public instance getter read off `this`,
/// spelled either `label` or `this.label` -- which are the same Kernel node, so
/// only the source text distinguishes them and only the producer needs to care.
Map<String, Object?> _lowering(Class cls, Procedure p) {
  final unsupported = <String>[];

  final function = p.function;
  if (function.positionalParameters.isNotEmpty ||
      function.namedParameters.isNotEmpty) {
    // The entry-point contract allows exactly one positional parameter, and the
    // receiver already claims it. Methods with their own parameters are a
    // separate ABI question and must get their own probe rather than
    // piggybacking on this one.
    unsupported.add(
      'the method takes parameters; the single allowed entry-point parameter '
      'is the receiver',
    );
  }
  if (function.typeParameters.isNotEmpty) {
    unsupported.add('the method is generic');
  }

  final visitor = _ReceiverUses();
  function.accept(visitor);
  unsupported.addAll(visitor.unsupported);

  return {
    'receiverType': cls.name,
    // Where the producer starts looking for the parameter list. Kernel puts
    // `fileOffset` on the NAME, and an annotation like @pragma('...') contains
    // parentheses of its own, so scanning from the declaration start would find
    // the wrong ones.
    'nameOffset': p.fileOffset,
    'accesses': [
      for (final a in visitor.accesses)
        {'offset': a.offset, 'member': a.member, 'kind': a.kind},
    ],
    'unsupported': unsupported,
  };
}

class _Access {
  _Access(this.offset, this.member, this.kind);
  final int offset;
  final String member;
  final String kind;
}

/// Every use of the receiver, and a reason for each one that is not supported.
class _ReceiverUses extends RecursiveVisitor {
  final accesses = <_Access>[];
  final unsupported = <String>[];

  /// `ThisExpression` nodes already accounted for as the receiver of a
  /// supported access. Without this every `label` reports twice: once as the
  /// InstanceGet and once as its own synthesized receiver.
  final _consumed = <ThisExpression>{};

  @override
  void visitInstanceGet(InstanceGet node) {
    final receiver = node.receiver;
    if (receiver is ThisExpression) {
      _consumed.add(receiver);
      final name = node.name.text;
      if (name.startsWith('_')) {
        // Rung D: private identity is library-scoped, so a synthetic
        // replacement library cannot name it however it is spelled.
        unsupported.add('reads the private member `$name`');
      } else {
        accesses.add(_Access(node.fileOffset, name, 'get'));
      }
    }
    node.visitChildren(this);
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    if (node.receiver is ThisExpression) {
      _consumed.add(node.receiver as ThisExpression);
      unsupported.add('assigns to `${node.name.text}` on the receiver');
    }
    node.visitChildren(this);
  }

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    final receiver = node.receiver;
    if (receiver is ThisExpression) {
      _consumed.add(receiver);
      final name = node.name.text;
      if (name.startsWith('_')) {
        unsupported.add('calls the private member `$name()`');
      } else {
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
        accesses.add(_Access(node.fileOffset, name, 'invoke'));
      }
    }
    node.visitChildren(this);
  }

  @override
  void visitInstanceGetterInvocation(InstanceGetterInvocation node) {
    if (node.receiver is ThisExpression) {
      _consumed.add(node.receiver as ThisExpression);
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
    unsupported.add('calls `super.${node.name.text}()`');
    node.visitChildren(this);
  }

  @override
  void visitThisExpression(ThisExpression node) {
    // A `this` that is not the receiver of a supported access -- passed as an
    // argument, captured by a closure, stored. Each is its own question.
    if (!_consumed.contains(node)) {
      unsupported.add('uses `this` other than to read a member');
    }
  }
}
