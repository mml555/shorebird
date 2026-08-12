// Copyright (c) 2026, the Shorebird self-host fork.
// cspell:words prepass behaviour synthesises
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
import 'dart:convert';
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
// The same index the dynamic-interface annotator resolves entries through
// (dynamic_module_validator.dart:306), so this generator can refuse to emit what
// that annotator would reject.
import 'package:kernel/library_index.dart';

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

/// A named private-retention policy.
///
/// POLICIES LIVE IN CODE, NOT IN PROSE. An arm described only in a document cannot be
/// run twice and cannot be diffed; naming them here means `--policy p2` is the whole
/// definition and every run of it is the same run.
///
/// The three are chosen to bracket the decision rather than to sample it: P1 is the
/// only shape already proven, P2 is everything the mechanism can reach, and P3 exists
/// to test ONE specific hypothesis -- that withholding class retention withholds
/// constructibility while keeping member reach.
enum _Policy {
  /// Private TOP-LEVEL and STATIC members only. No private classes, and no private
  /// INSTANCE members.
  ///
  /// The shape `probe D` proved: a private top-level function named in the interface
  /// becomes a raw direct call, TFA analyses its body, and it works. Statics are
  /// included because they dispatch the same way -- what distinguishes this policy is
  /// the absence of a RECEIVER, not the absence of a class.
  p1('top-level and static privates only'),

  /// Every private member and class of the app's own libraries.
  ///
  /// What non-AOT enumeration produces when nothing is withheld: instance members,
  /// fields, accessors, private classes -- and, as a consequence rather than an entry,
  /// construction of those classes.
  p2('all app-private members and classes'),

  /// Private members INCLUDING instance members, but NO private `class:` items.
  ///
  /// The hypothesis under test: a `class:` item is what grants an implicit public
  /// constructor, so withholding it should withhold CONSTRUCTIBILITY while leaving
  /// member reach intact. If that holds, P3 is a real middle ground. If the members
  /// turn out to be unreachable without their class retained, P3 collapses into P1 and
  /// the middle ground does not exist -- which is itself the answer.
  p3('private members without private class retention');

  const _Policy(this.describe);

  /// Human-readable, carried into the manifest so a recorded arm explains itself.
  final String describe;

  bool get retainsPrivateClasses => this == _Policy.p2;
  bool get retainsPrivateInstanceMembers => this != _Policy.p1;
  bool get retainsPrivateTopLevel => true;
  bool get retainsPrivateStatics => true;
}

void main(List<String> args) {
  String? dillPath;
  String? privateDillPath;
  String outPath = 'dynamic_interface.yaml';
  var sdkMembers = _defaultSdkMembers;
  var sdkLibraries = const <String>[];
  var includeSdk = true;
  var retainPrivate = true;
  var retainPrivateClasses = true;
  var policy = _Policy.p2;
  String? manifestPath;
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
      case '--private-dill':
        // Enumerate PRIVATE members from this kernel instead of from --dill.
        //
        // WHY A SECOND KERNEL. --dill is the `--aot` prepass, and that is correct
        // for everything else: it is the kernel that fed the release. But TFA has
        // already tree-shaken it, so a private member NOTHING IN THE RELEASE CALLS
        // is gone before this generator can name it -- and a patch's whole purpose
        // can be to start calling a private helper the old code did not. Naming it
        // here is what would keep it, because the interface is an INPUT to the
        // release build; but it cannot be named if it is not in the kernel read.
        //
        // Pass the NON-AOT kernel (the release_import.dill a release already
        // produces) to enumerate the full private surface. Public retention is
        // unaffected: a `library:` item covers it either way.
        //
        // Off by default because it is a size trade, not a free win --
        // measure_real_app.sh prices it, and the policy should be chosen from that
        // number rather than assumed.
        privateDillPath = next();
      case '--out':
        outPath = next();
      case '--include':
        // Repeatable. A library URI prefix to treat as "the app", e.g.
        // package:your_app/ -- so a monorepo can retain several packages.
        includePrefixes.add(next());
      case '--sdk-members':
        // Comma separated. `library#member` for a top-level member,
        // `library#Class.member` for a class member. The member half may carry
        // the VM's get:/set: disambiguation, e.g.
        // `dart:core#DateTime.get:millisecondsSinceEpoch`.
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
      case '--policy':
        // The arm's whole definition. See _Policy for what each grants and, for
        // p3, the specific hypothesis it exists to test.
        final name = next();
        policy = _Policy.values.firstWhere(
          (p) => p.name == name,
          orElse: () => _die(
            "unknown --policy '$name'; expected one of "
            '${_Policy.values.map((p) => p.name).join(", ")}',
          ),
        );
        retainPrivateClasses = policy.retainsPrivateClasses;
      case '--manifest':
        // The CAPABILITY MANIFEST, emitted by the tool that did the granting.
        // Deliberately not derivable by reading the interface: a `class:` item
        // grants an implicit public constructor that appears in no line of it.
        manifestPath = next();
      case '--no-private-classes':
        // Isolates the cost of the CLASS-level shapes (private classes and
        // private members of classes) from the top-level shape that was already
        // measured at +0.01%. The class shapes are far more numerous -- 1,462
        // classes and 6,626 members across a Flutter app's whole dependency
        // closure -- so they need their own line in measure_retention.sh rather
        // than inheriting a number measured on the cheap half.
        retainPrivateClasses = false;
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

  // The kernel the PRIVATE enumeration walks. Defaults to --dill, so behaviour is
  // unchanged unless --private-dill is passed.
  //
  // Its LibraryIndex is built separately and used for the private candidates,
  // because resolvability has to be checked against the kernel the name came
  // from -- checking a non-AOT name against the AOT index would reintroduce
  // exactly the cross-kernel mismatch that cost two failed builds.
  var privateComponent = component;
  if (privateDillPath != null) {
    privateComponent = Component();
    BinaryBuilder(
      File(privateDillPath).readAsBytesSync(),
    ).readComponent(privateComponent);
  }

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
  // THREE SHAPES, NOT ONE, and each is retained by a different item. Measured
  // against pkg/vm's own annotator rather than assumed:
  //
  //   dynamic_interface_annotator.dart:221-235  a `class:` item annotates the
  //     class and then only `_visitPublicMembers` of it -- constructors,
  //     procedures and fields whose name is NOT private. So a class item is the
  //     exact analogue of a library item, one level down.
  //   library_index.dart:189-190  containers are keyed by plain `class_.name`
  //     with no privacy filter, so `class: '_FooState'` resolves.
  //   library_index.dart:329-332  a private member IS indexable as long as its
  //     name belongs to the library being indexed -- which is always true for an
  //     app's own privates.
  //
  // Hence: private CLASSES need a class item (that is what makes a private
  // class's PUBLIC members reachable, which is the whole runtime half of the
  // `dynamic self` lowering); private members of any class need naming one by
  // one; and top-level privates need naming, which is the only shape this
  // generator handled before.
  final privateMembers = <String>[];
  final privateClasses = <String>[];
  final privateClassMembers = <String>[];

  // THE CAPABILITY MANIFEST'S OWN SETS, kept beside the emission rather than
  // reconstructed from it.
  //
  // `privateStatics` is a subset of privateClassMembers, tracked separately because
  // P1 grants statics while withholding instance members, and a manifest that could
  // not tell them apart could not describe P1 at all.
  //
  // `implicitlyConstructible` is the row that does not exist in the interface text.
  // `refused` is the row that exists nowhere at all today: it records what a policy
  // or the index declined, so `G3.6b` can refuse against a concrete absence rather
  // than inferring one.
  final privateStatics = <String>[];
  final implicitlyConstructible = <String>[];
  final refused = <String>[];

  // EMIT ONLY WHAT THE ANNOTATOR CAN RESOLVE, and prove it here rather than
  // discovering it during the release build.
  //
  // A single unresolvable entry fails the WHOLE interface, so a generator that
  // reasons about which names are nameable is a generator that eventually emits
  // a wrong one. Two real cases proved that in one afternoon, both invisible to
  // a toy program and both found only on a real Flutter component:
  //
  //   ThemeMode._enumToString          the front end synthesises enum machinery
  //     whose Name is private to `dart:core`, not to the library declaring the
  //     enum, and library_index.dart:329-332 refuses to index a member whose
  //     name belongs to another library.
  //   ScaffoldMessengerState.set:_accessibleNavigation
  //     the field is indexed under its BARE name and no `set:` entry exists
  //     beside it, so the accessor spelling that is right for a private Setter
  //     procedure is wrong here.
  //
  // Rather than encode those two rules and wait for the third, ask the same
  // index the annotator will use — `LibraryIndex`, via the same `getMember`
  // called at dynamic_module_validator.dart:306. What it cannot find, a release
  // must not name. Skips are COUNTED and reported, never silent: a rising skip
  // count is a retention gap worth looking at, not a success.
  //
  // WHAT THIS CHECK CANNOT DO, stated because it took three attempts to accept:
  // it indexes the kernel it is GIVEN, and that is the `--aot` prepass, while the
  // annotator indexes a fresh pre-transform component. Where AOT has reshaped a
  // class the two disagree, and a name valid in one is invalid in the other --
  // measured: `ScaffoldMessengerState._accessibleNavigation` is a Setter
  // *Procedure* in the prepass, resolvable as `set:_accessibleNavigation`, while
  // the annotator's component has no such key. There is no filter available here
  // that predicts the other component's shape.
  //
  // It does not matter for the SHIPPING policy, and that is the whole reason this
  // is a note rather than a project: with `--include package:your_app/` the app's
  // own libraries resolve cleanly (0 skipped, measured on the fixture). It bites
  // only the naive all-libraries breadth, which retains the framework's privates
  // and which no release should use -- see `measure_real_app.sh`, where that arm
  // now reports "does not build" rather than a size.
  final index = LibraryIndex.all(privateComponent);
  var unresolvable = 0;
  // Skips are now LISTED, not only counted. A count says how much was withheld; the
  // list says WHICH capability the release does not grant, which is what `G3.6b` has
  // to refuse against. Previously this incremented a counter and discarded the name.
  bool resolvableClass(String uri, String name) {
    try {
      index.getClass(uri, name);
      return true;
    } catch (_) {
      unresolvable++;
      refused.add('$uri#$name (class, not indexable)');
      return false;
    }
  }

  bool resolvableMember(String uri, String container, String name) {
    try {
      index.getMember(uri, container, name);
      return true;
    } catch (_) {
      unresolvable++;
      refused.add(
        container == '::'
            ? '$uri#$name (top-level, not indexable)'
            : '$uri#$container#$name (member, not indexable)',
      );
      return false;
    }
  }

  if (retainPrivate) {
    for (final lib in privateComponent.libraries.where(isApp)) {
      final uri = lib.importUri.toString();

      for (final cls in lib.classes) {
        // NO EARLY BREAK. P1 withholds private classes AND private instance members
        // but still grants private STATICS, which only exist inside classes -- an
        // early break skipped them and made P1 report zero statics while its own
        // definition is "top-level and static". The per-shape gates below are what
        // enforce the policy; the walk itself must always happen.
        // Synthetic mixin applications (`_Foo&Bar&Baz`) are composed by the
        // front end, are named in no source, and are patched by nobody. In
        // flutter/src/material they outnumber real classes' in-contract methods
        // (739 vs 320), so retaining them would be pure cost.
        if (cls.name.contains('&')) continue;

        if (retainPrivateClasses &&
            cls.name.startsWith('_') &&
            resolvableClass(uri, cls.name)) {
          privateClasses.add('$uri#${cls.name}');
          // EFFECTIVE CAPABILITY, not an interface line. A `class:` item annotates
          // the class AND its public members, and a class's implicit default
          // constructor is public -- which is how a patch constructed `_Dead()`
          // with no constructor named anywhere in the YAML. Recording it here is
          // the only way the manifest can describe what was actually granted.
          for (final c in cls.constructors) {
            if (c.name.text.startsWith('_')) continue;
            implicitlyConstructible.add(
              '$uri#${cls.name}.${c.name.text.isEmpty ? "new" : c.name.text}',
            );
          }
          // A factory is a Procedure, not a Constructor, and is granted by the
          // same class item.
          for (final p in cls.procedures) {
            if (!p.isFactory || p.name.text.startsWith('_')) continue;
            implicitlyConstructible.add(
              '$uri#${cls.name}.${p.name.text.isEmpty ? "new" : p.name.text} '
              '(factory)',
            );
          }
        }
        for (final p in cls.procedures) {
          if (!p.name.text.startsWith('_')) continue;
          if (!policy.retainsPrivateInstanceMembers && !p.isStatic) {
            refused.add('$uri#${cls.name}#${_vmName(p)} (instance, policy)');
            continue;
          }
          if (!resolvableMember(uri, cls.name, _vmName(p))) continue;
          if (p.isStatic) {
            privateStatics.add('$uri#${cls.name}#${_vmName(p)}');
          }
          privateClassMembers.add('$uri#${cls.name}#${_vmName(p)}');
        }
        for (final f in cls.fields) {
          if (!f.name.text.startsWith('_')) continue;
          if (!policy.retainsPrivateInstanceMembers && !f.isStatic) {
            refused.add('$uri#${cls.name}#${f.name.text} (instance, policy)');
            continue;
          }
          if (!resolvableMember(uri, cls.name, f.name.text)) continue;
          if (f.isStatic) {
            privateStatics.add('$uri#${cls.name}#${f.name.text}');
          }
          // A FIELD IS NAMED BARE, not `get:`/`set:`.
          // library_index.dart:320-326 applies the accessor prefixes only to a
          // Procedure; a Field is indexed under `member.name.text`. Naming the
          // field is also enough for both directions — precompiler.cc:1642-1651
          // adds the field and synthesises its implicit getter and setter.
          privateClassMembers.add('$uri#${cls.name}#${f.name.text}');
        }
      }

      // Top-level private FIELDS were missed entirely before: this loop read
      // only `lib.procedures`, so a private top-level variable was named by
      // nothing even though the same `library:` item skipped it.
      for (final f in lib.fields) {
        if (!f.name.text.startsWith('_')) continue;
        if (!resolvableMember(uri, '::', f.name.text)) continue;
        privateMembers.add('$uri#${f.name.text}');
      }

      for (final p in lib.procedures) {
        if (!p.name.text.startsWith('_')) continue;
        if (!resolvableMember(uri, '::', _vmName(p))) continue;
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
      final library = entry.substring(0, i);
      final name = entry.substring(i + 1);

      // `Class.member` retains a CLASS member; a bare name retains a top-level
      // one. Without this a class member is emitted as a top-level `member:`
      // and the annotator rejects the whole interface:
      //
      //   A member with disambiguated name 'DateTime.now' was not found in
      //   top-level of library 'dart:core'
      //
      // Split on the FIRST dot: a top-level Dart member cannot contain one,
      // and the remainder may legitimately carry the VM's `get:`/`set:`
      // disambiguation, as in `DateTime.get:millisecondsSinceEpoch`.
      final dot = name.indexOf('.');
      buf.writeln("  - library: '$library'");
      if (dot > 0) {
        buf
          ..writeln("    class: '${name.substring(0, dot)}'")
          ..writeln("    member: '${name.substring(dot + 1)}'");
      } else {
        buf.writeln("    member: '$name'");
      }
    }
  }
  if (privateMembers.isNotEmpty) {
    buf.writeln(
      '  # Private top-level app members -- a `library:` item does not cover '
      'these.',
    );
    for (final entry in privateMembers) {
      final i = entry.indexOf('#');
      buf
        ..writeln("  - library: '${entry.substring(0, i)}'")
        ..writeln("    member: '${entry.substring(i + 1)}'");
    }
  }
  if (privateClasses.isNotEmpty) {
    buf.writeln(
      '  # PRIVATE CLASSES. A `library:` item retains public classes only, so '
      'without',
    );
    buf.writeln(
      '  # these a replacement lowered to `dynamic self` compiles and then '
      'finds',
    );
    buf.writeln(
      '  # nothing at run time. Each item also retains the class\'s PUBLIC '
      'members.',
    );
    for (final entry in privateClasses) {
      final i = entry.indexOf('#');
      buf
        ..writeln("  - library: '${entry.substring(0, i)}'")
        ..writeln("    class: '${entry.substring(i + 1)}'");
    }
  }
  if (privateClassMembers.isNotEmpty) {
    buf.writeln(
      '  # Private members of app classes -- covered by neither a `library:` '
      'nor a',
    );
    buf.writeln(
      '  # `class:` item, because both stop at public members.',
    );
    for (final entry in privateClassMembers) {
      final parts = entry.split('#');
      buf
        ..writeln("  - library: '${parts[0]}'")
        ..writeln("    class: '${parts[1]}'")
        ..writeln("    member: '${parts[2]}'");
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

  // THE CAPABILITY MANIFEST. Five categories, and the last two are the ones that
  // exist nowhere else:
  //
  //   privateTopLevelCallable    top-level privates a patch may now call
  //   privateStaticsCallable     private statics -- separated from instance members
  //                              because P1 grants these and withholds those
  //   privateInstanceCallable    private instance members a patch may now call
  //   privateClassesConstructible    classes a patch may now INSTANTIATE
  //   implicitlyConstructible    the constructors and factories that came with them,
  //                              named in NO line of the interface
  //   refused                    what was NOT granted, and why
  //
  // Emitted by the generator rather than derived by a reader, because a reader can
  // only see what was written down and the fourth category never is.
  if (manifestPath != null) {
    final instanceCallable = privateClassMembers
        .where((m) => !privateStatics.contains(m))
        .toList();
    File(manifestPath).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'policy': policy.name,
        'policyDescription': policy.describe,
        'privateEnumerationSource': privateDillPath == null
            ? 'dill (the --aot prepass)'
            : 'private-dill (non-AOT)',
        'appLibraries': appLibraries.length,
        'counts': {
          'privateTopLevelCallable': privateMembers.length,
          'privateStaticsCallable': privateStatics.length,
          'privateInstanceCallable': instanceCallable.length,
          'privateClassesConstructible': privateClasses.length,
          'implicitlyConstructible': implicitlyConstructible.length,
          'refused': refused.length,
        },
        'privateTopLevelCallable': privateMembers,
        'privateStaticsCallable': privateStatics,
        'privateInstanceCallable': instanceCallable,
        'privateClassesConstructible': privateClasses,
        'implicitlyConstructible': implicitlyConstructible,
        'refused': refused,
      })}\n',
    );
  }

  // Report to stderr so stdout stays clean if anyone pipes this.
  // Counts are broken out per shape because each one buys a different thing and
  // costs differently. `measure_retention.sh` prices them; a jump in the class
  // or class-member line is where a size regression would come from.
  stderr
    ..writeln('wrote $outPath')
    ..writeln('  app libraries        : ${appLibraries.length}')
    ..writeln('  private top-level    : ${privateMembers.length}')
    ..writeln('  private classes      : ${privateClasses.length}')
    ..writeln('  private class members: ${privateClassMembers.length}')
    ..writeln(
      '  unresolvable (skipped): $unresolvable'
      '${unresolvable > 0 ? "  <- named in kernel, not indexable; see the "
          "LibraryIndex note in this file" : ""}',
    )
    ..writeln('  sdk members          : ${members.length}')
    ..writeln('  sdk libraries        : ${wholeSdk.length}');
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
