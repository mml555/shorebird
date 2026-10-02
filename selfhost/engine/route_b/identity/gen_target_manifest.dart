// Copyright (c) 2026, the Shorebird self-host fork.
//
// gen_target_manifest.dart -- Route B step 3: name the things a patch can
// target, and say which ones it can actually reach.
//
// WHAT STEP 3 TURNED OUT TO BE. The plan framed this as "the runtime cannot
// lean on addresses or incidental object-pool positions", which sounds like a
// release must carry a bespoke target table. It does not:
// identity/probe_retention_lookup.sh showed that step 2's whole-library
// retention lowers to @pragma('dyn-module:callable'), which the VM treats as
// vm:entry-point, so every app function is ALREADY resolvable by name at run
// time with no annotations at all. What was left is naming and bookkeeping.
//
// THE IDENTITY. Structured fields, never a joined string:
//
//   { library, class, name, kind }
//
// The harness used "Class.name" and split on the first dot, which is wrong the
// moment a name contains one, and it forced callers to know that the VM stores
// a getter as "get:name" -- a VM internal leaking into what will become a wire
// contract. Kind is explicit here and the mangling happens at the boundary.
//
// REACHABILITY IS PART OF THE IDENTITY'S JOB. Step 1's inventory established
// that patch coverage is not "any Dart function": a statically-typed
// polymorphic call is specialized into a dispatch-table call, which loads a raw
// entry point and never consults the Function. A manifest that lists every
// function as patchable would be lying in exactly the way Shorebird's link
// percentage exists to prevent, so each entry carries a `reachable` verdict and
// a reason.
//
// Run with the Dart tree's package config so package:kernel resolves:
//
//   $OUT/dart-sdk/bin/dart --packages=<dart-tree>/.dart_tool/package_config.json \
//     gen_target_manifest.dart --dill app.dill --out targets.json
//
// cspell:words devirtualize devirtualizes
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

/// How the VM names a member of a given kind, which is what the runtime lookup
/// ultimately needs. Kept in ONE place so no caller has to know it.
String vmMemberName(String name, String kind) => switch (kind) {
  'getter' => 'get:$name',
  'setter' => 'set:$name',
  _ => name,
};

void main(List<String> args) {
  String? dillPath;
  var outPath = 'targets.json';
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
        print('''
gen_target_manifest.dart --dill <app.dill> [--out targets.json]
                         [--include <library-uri-prefix>]...
''');
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

  final targets = <Map<String, Object?>>[];

  void addProcedure(Procedure p, String libraryUri, String? className) {
    final kind = switch (p.kind) {
      ProcedureKind.Getter => 'getter',
      ProcedureKind.Setter => 'setter',
      ProcedureKind.Operator => 'operator',
      ProcedureKind.Factory => 'factory',
      ProcedureKind.Method => 'method',
    };

    // Reachability, per step 1's measured inventory.
    //
    // A static-shaped call (top-level function, static method, constructor) is
    // emitted as Route B's patchable form. An instance member is only reachable
    // when the compiler devirtualizes its call sites; when it stays polymorphic
    // the call is specialized into a dispatch-table call and no patch can reach
    // it. Whether a given site devirtualizes is a per-call-site property the
    // precompiler decides, and it is NOT visible in the kernel -- so an instance
    // member is reported as conditional rather than guessed at.
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
      // What you hand the runtime. Composed here so no caller has to know
      // either the get:/set: mangling or the class-qualification rule -- the
      // harness made callers build this by hand and a getter promptly read as
      // an unpatchable form when it was really a naming mismatch.
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

  final counts = <String, int>{};
  for (final t in targets) {
    final r = t['reachable']! as String;
    counts[r] = (counts[r] ?? 0) + 1;
  }

  final manifest = {
    // Version the manifest from its first byte. The *.vmcode filename
    // convention is the cautionary tale here: bring-up scaffolding that would
    // have become the contract by default.
    'manifestVersion': 1,
    'sourceDill': dillPath,
    'targets': targets,
  };

  File(outPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );

  stderr
    ..writeln('wrote $outPath')
    ..writeln('  targets      : ${targets.length}')
    ..writeln('  reachable    : ${counts['yes'] ?? 0}')
    ..writeln('  conditional  : ${counts['conditional'] ?? 0}')
    ..writeln('  not reachable: ${counts['no'] ?? 0}');
}

Never _die(String message) {
  stderr.writeln('error: $message');
  exit(2);
}
