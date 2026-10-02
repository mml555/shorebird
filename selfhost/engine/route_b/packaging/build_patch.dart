// Copyright (c) 2026, the Shorebird self-host fork.
//
// build_patch.dart -- Route B step 5, host side: turn "the Dart changed" into
// a patch container, and say honestly how much of the change actually landed.
//
// This is the shape `shorebird patch` will wear. It is a separate tool rather
// than a CLI change because the iOS engine port has not happened yet: wiring a
// half-path into the shipping CLI would let someone run it and believe the
// result. See README.md.
//
// WHAT IT DOES
//   1. diff the release kernel against the rebuilt kernel, per member
//   2. classify each changed member against the release's target manifest
//   3. report coverage -- the link-percentage analogue
//   4. emit the target list for the packer
//
// WHY DIFF THE KERNEL AND NOT THE SOURCE. A source diff answers "which lines
// did the author touch", which is not the question. The question is which
// COMPILED members differ, because that is what a patch replaces: a whitespace
// edit changes source and not kernel, and a change to a const or an inlined
// helper changes kernel far beyond the line that was edited.
//
// COVERAGE IS THE POINT, not a footnote. Step 1's inventory established that a
// statically-typed polymorphic call is specialized into a dispatch-table call
// that no patch can reach. A tool that emitted a container without saying so
// would produce a patch that installs cleanly and silently does nothing for
// some of what changed -- which is precisely the failure Shorebird's link
// percentage exists to surface.
//
// cspell:words SBRBPTCH sbrb
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:kernel/text/ast_to_text.dart';

void main(List<String> args) {
  String? basePath;
  String? patchedPath;
  String? manifestPath;
  var outPath = 'changed_targets.json';
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
      case '--manifest':
        manifestPath = next();
      case '--out':
        outPath = next();
      case '--include':
        includePrefixes.add(next());
      case '-h':
      case '--help':
        print('''
build_patch.dart --base-dill <release.dill> --patched-dill <rebuilt.dill>
                 [--manifest targets.json] [--out changed_targets.json]
                 [--include <library-uri-prefix>]...
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

  // Reachability, from the release's own manifest. Without it this tool can
  // report what changed but not what a patch can do about it.
  final reach = <String, String>{};
  if (manifestPath != null) {
    final m =
        jsonDecode(File(manifestPath).readAsStringSync())
            as Map<String, Object?>;
    for (final t in m['targets']! as List<Object?>) {
      final e = t! as Map<String, Object?>;
      reach['${e['library']}#${e['selector']}'] = e['reachable']! as String;
    }
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

  File(outPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'changed': changed,
      'added': added,
      'removed': removed,
      'patchable': patchable,
      'conditional': conditional,
      'unreachable': unreachable,
      'unknown': unknown,
    })}\n',
  );

  final b = StringBuffer()
    ..writeln('changed members : ${changed.length}')
    ..writeln('  patchable     : ${patchable.length}')
    ..writeln('  conditional   : ${conditional.length}')
    ..writeln('  NOT reachable : ${unreachable.length}')
    ..writeln('  not in manifest: ${unknown.length}');
  // Added and removed members are NOT patchable at all: a patch replaces the
  // body of a function the release already contains. Reported rather than
  // silently dropped, because "I added a function and the patch did nothing"
  // is otherwise a mystery.
  if (added.isNotEmpty) {
    b.writeln('added members   : ${added.length}  (cannot be patched in)');
  }
  if (removed.isNotEmpty) {
    b.writeln('removed members : ${removed.length}  (cannot be patched out)');
  }
  stderr.write(b);

  if (changed.isEmpty) {
    stderr.writeln('nothing changed; a patch would be inert');
    exit(3);
  }
  // A non-zero exit when any part of the change cannot land, so a pipeline
  // cannot ship a partially-effective patch by ignoring stdout.
  final reasons = <String>[];
  if (unreachable.isNotEmpty) {
    reasons.add('${unreachable.length} changed member(s) are not reachable');
  }
  if (unknown.isNotEmpty) {
    reasons.add('${unknown.length} changed member(s) are not in the manifest');
  }
  if (added.isNotEmpty) {
    // An addition that survived AOT tree-shaking is one that retained code
    // references -- so some changed member's new body calls it. That bytecode
    // cannot bind against a release which does not contain it, and the failure
    // would land at patch-load time on a user's device rather than here.
    reasons.add(
      '${added.length} member(s) are new; a patch replaces bodies and cannot '
      'introduce members, so bytecode referencing them would fail to bind',
    );
  }
  if (reasons.isNotEmpty) {
    stderr.writeln('REFUSING: ${reasons.join('; ')}');
    exit(4);
  }
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
/// edit.
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
