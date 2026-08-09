// Copyright (c) 2026, the Shorebird self-host fork.
//
// gen_dynamic_interface.dart -- emit a Route B dynamic interface from an app's
// own kernel.
//
// WHY THIS EXISTS (Route B step 2). Patch bytecode does not resolve against the
// base snapshot for free: the AOT precompiler drops library dictionaries, and
// Spike B's first replacement died in bytecode_reader.cc:1172 with "Unable to
// find function print in Library:'dart:core'". Retention has to be DECLARED at
// release time, via gen_kernel --dynamic-interface, whose annotator turns each
// entry into @pragma('dyn-module:callable') -- which the VM treats exactly like
// vm:entry-point (object.cc FindEntryPointPragma).
//
// Spike B declared three members by hand. A release cannot: nobody knows which
// members a future patch will touch. The lever that makes this tractable is in
// pkg/vm/dynamic_interface.md -- a `library:` item with no `class:` retains
// every public class and member of that library. So a release does not
// enumerate symbols, it chooses LIBRARY BREADTH, and the only real question is
// what that breadth costs. This tool makes the choice explicit and measurable
// instead of hand-maintained.
//
// Run it with the Dart tree's own package config so package:kernel resolves:
//
//   $OUT/dart-sdk/bin/dart \
//     --packages=<dart-tree>/.dart_tool/package_config.json \
//     gen_dynamic_interface.dart --dill app.dill --out di.yaml
//
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

/// SDK symbols a patch may call into, as `library#member` pairs.
///
/// MEMBER-scoped, not library-scoped, and that distinction is the whole result
/// of Route B step 2's measurement. Retaining the app's own libraries whole
/// costs +0.89% -- effectively free. Retaining `dart:core` whole costs +310%, a
/// four-fold snapshot, because a library item keeps every public member of
/// every public class in it and AOT can no longer tree-shake any of them.
///
/// So the policy is asymmetric on purpose: whole-library for the app, an
/// explicit member list for the SDK. See measure_retention.sh for the sweep.
///
/// This default is deliberately tiny -- `print` is Spike B's canonical failure
/// (bytecode_reader.cc:1172) and little else has earned its place yet. Widen it
/// from evidence about what patches actually call, and re-run the sweep when
/// you do.
const _defaultSdkMembers = <String>[
  'dart:core#print',
];

void main(List<String> args) {
  String? dillPath;
  String outPath = 'dynamic_interface.yaml';
  var sdkMembers = _defaultSdkMembers;
  var sdkLibraries = const <String>[];
  var includeSdk = true;
  var retainPrivate = true;
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
        // Repeatable. A library URI prefix to treat as "the app", e.g.
        // package:your_app/ -- so a monorepo can retain several packages.
        includePrefixes.add(next());
      case '--sdk-members':
        // library#member, comma separated.
        sdkMembers = next().split(',').where((s) => s.isNotEmpty).toList();
      case '--sdk-libraries':
        // Whole-library SDK retention. Measured at +310% for dart:core alone --
        // present so the expensive option stays reachable and measurable, not
        // because anything should ship it.
        sdkLibraries = next().split(',').where((s) => s.isNotEmpty).toList();
      case '--no-sdk':
        includeSdk = false;
      case '--no-private':
        // Present so the cost of private-member retention stays measurable.
        retainPrivate = false;
      case '-h':
      case '--help':
        _usage();
        return;
      default:
        _die('unknown argument: $a');
    }
  }

  if (dillPath == null) _die('--dill is required');

  final component = Component();
  BinaryBuilder(
    File(dillPath).readAsBytesSync(),
  ).readComponent(component);

  // Which libraries are "the app"? Default: everything that is not a platform
  // library, since the platform half is handled by the SDK allowlist and
  // retaining it wholesale is exactly the size blowup this tool exists to keep
  // visible.
  bool isApp(Library lib) {
    final uri = lib.importUri.toString();
    if (uri.startsWith('dart:')) return false;
    if (includePrefixes.isEmpty) return true;
    return includePrefixes.any(uri.startsWith);
  }

  final appLibraries =
      component.libraries
          .where(isApp)
          .map((l) => l.importUri.toString())
          .toList()
        ..sort();

  // Private members are NOT covered by a `library:` item -- pkg/vm's spec says
  // it retains "all _public_ classes and members", and the consequence is
  // concrete: attaching to a private function failed with "function _report not
  // found" even though its library was retained whole. Real apps are mostly
  // private, so a release that skipped these would report broad coverage and
  // deliver very little.
  //
  // They have to be named one by one, which is exactly what a generator is for.
  // The VM's own mangling (_name@<library key>) is NOT our problem here:
  // Library::LookupLocalObjectAllowPrivate applies it, so the plain source name
  // is the right thing to emit.
  final privateMembers = <String>[];
  if (retainPrivate) {
    for (final lib in component.libraries.where(isApp)) {
      final uri = lib.importUri.toString();
      for (final p in lib.procedures) {
        if (!p.name.text.startsWith('_')) continue;
        // The VM disambiguates accessors as get:/set:, and the dynamic
        // interface is matched against THOSE names. Emitting the bare name got
        // a real Flutter app rejected outright:
        //
        //   A member with disambiguated name '_platform' was not found ...
        //   Did you mean 'get:_platform' or 'set:_platform'?
        //
        // The toy programs had no private accessors, so this only appeared once
        // the measurement moved to a real app -- which is the argument for
        // measuring on one.
        privateMembers.add('$uri#${_vmName(p)}');
      }
    }
  }

  final members = includeSdk ? sdkMembers : const <String>[];
  final wholeSdk = includeSdk ? sdkLibraries : const <String>[];

  final buf = StringBuffer()
    ..writeln(
      '# GENERATED by selfhost/engine/route_b/gen_dynamic_interface.dart',
    )
    ..writeln('# Source dill: $dillPath')
    ..writeln('#')
    ..writeln('# Route B retention, asymmetric on purpose:')
    ..writeln('#   app libraries -> whole-library  (measured +0.89%)')
    ..writeln('#   SDK           -> named members  (whole dart:core is +310%)')
    ..writeln('# Re-run measure_retention.sh if you widen either half.')
    ..writeln('callable:');

  for (final uri in appLibraries) {
    buf.writeln("  - library: '$uri'");
  }
  if (members.isNotEmpty) {
    buf.writeln('  # Named SDK members a patch is allowed to call.');
    for (final entry in members) {
      final i = entry.indexOf('#');
      if (i <= 0 || i == entry.length - 1) {
        _die("--sdk-members entry must be 'library#member', got: $entry");
      }
      buf
        ..writeln("  - library: '${entry.substring(0, i)}'")
        ..writeln("    member: '${entry.substring(i + 1)}'");
    }
  }
  if (privateMembers.isNotEmpty) {
    buf.writeln(
      '  # Private app members -- a `library:` item does not cover these.',
    );
    for (final entry in privateMembers) {
      final i = entry.indexOf('#');
      buf
        ..writeln("  - library: '${entry.substring(0, i)}'")
        ..writeln("    member: '${entry.substring(i + 1)}'");
    }
  }
  if (wholeSdk.isNotEmpty) {
    buf.writeln(
      '  # WHOLE SDK libraries -- expensive, see measure_retention.sh.',
    );
    for (final uri in wholeSdk) {
      buf.writeln("  - library: '$uri'");
    }
  }

  File(outPath).writeAsStringSync(buf.toString());

  // Report to stderr so stdout stays clean if anyone pipes this.
  stderr
    ..writeln('wrote $outPath')
    ..writeln('  app libraries : ${appLibraries.length}')
    ..writeln('  private app   : ${privateMembers.length}')
    ..writeln('  sdk members   : ${members.length}')
    ..writeln('  sdk libraries : ${wholeSdk.length}');
}

/// How the VM names a member of this kind, which is what the dynamic interface
/// is matched against.
String _vmName(Procedure p) => switch (p.kind) {
  ProcedureKind.Getter => 'get:${p.name.text}',
  ProcedureKind.Setter => 'set:${p.name.text}',
  _ => p.name.text,
};

Never _die(String message) {
  stderr.writeln('error: $message');
  exit(2);
}

void _usage() {
  print('''
gen_dynamic_interface.dart --dill <app.dill> [options]

  --dill <path>            the app kernel to read libraries from (required)
  --out <path>             output yaml (default dynamic_interface.yaml)
  --include <uri-prefix>   repeatable; treat only these as app libraries
  --sdk-members <l#m,...>  named SDK members to retain (default dart:core#print)
  --sdk-libraries <a,b,c>  WHOLE SDK libraries -- +310% for dart:core alone
  --no-sdk                 emit no SDK entries at all
  --no-private             skip private app members (they are NOT covered by
                           a library: item, so this narrows real coverage)
''');
}
