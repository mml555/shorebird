// Copyright (c) 2026, the Shorebird self-host fork.
// cspell:words prepass behaviour synthesises constructibility CONSTRUCTIBILITY targetable
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

/// The library `MixinDeduplication` creates in an AOT kernel; see `found`.
const _mixinDeduplicationLibrary = 'dart:mixin_deduplication';

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
  String? platformPath;
  String outPath = 'dynamic_interface.yaml';
  var sdkMembers = _defaultSdkMembers;
  var sdkLibraries = const <String>[];
  var includeSdk = true;
  var retainPrivate = true;
  var retainPrivateClasses = true;
  // Exact constructor grants, from `--grant-constructor`. Empty by default.
  final constructorGrants = <String>{};
  var policy = _Policy.p2;
  var retainFrameworkUses = true;
  // Which framework MEMBERS to retain alongside the types. A measurement knob:
  // `calls` leaves out the fields named only by constants.
  var frameworkMembersScope = 'all';
  String? manifestPath;
  final includePrefixes = <String>[];
  final extendableSpecs = <String>[];

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
      case '--platform':
        // The platform --private-dill was compiled against (the release passes
        // the cell's flutter_platform_strong.dill). Read under it, the non-AOT
        // kernel's `dart:` references bind, so the framework-use walk reads
        // one complete kernel and checks every name against the same program
        // the annotator resolves against.
        platformPath = next();
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
      case '--grant-constructor':
        // CONSTRUCTION IS OPT-IN, ONE CONSTRUCTOR AT A TIME.
        //
        // `library#Class.name`, with `new` for the unnamed one:
        //   --grant-constructor 'package:app/main.dart#_Dead.new'
        //   --grant-constructor 'package:app/main.dart#_Dead._mk'
        //
        // Repeatable. Nothing is granted by default, and discovering that a
        // class HAS constructors does not grant them -- the +8.35% ceiling
        // measured at 200 classes is what "retain every constructor just in
        // case" costs, on top of being broader authority than anyone asked for.
        constructorGrants.add(next());
      case '--no-private-classes':
        // Isolates the cost of the CLASS-level shapes (private classes and
        // private members of classes) from the top-level shape that was already
        // measured at +0.01%. The class shapes are far more numerous -- 1,462
        // classes and 6,626 members across a Flutter app's whole dependency
        // closure -- so they need their own line in measure_retention.sh rather
        // than inheriting a number measured on the cheap half.
        retainPrivateClasses = false;
      case '--extendable':
        // OFF BY DEFAULT. Repeatable. `library#Class` declares the class
        // `extendable` (a patch module may extend, mix in or implement it) and
        // every public member of it `can-be-overridden`; `library#Class.member`
        // narrows can-be-overridden to that member. Without these two sections
        // a module class that extends an AOT class aborts (tabled calls) or
        // silently runs the wrong override (untabled calls); see
        // probes/added_class.sh. The cost is real -- AOT can no longer
        // devirtualize calls on these classes -- so nothing passes this by
        // default. See extendableSections.
        extendableSpecs.add(next());
      case '--no-framework-uses':
        // Present so the cost of framework-use retention stays measurable.
        // Without it a patch that names a framework type or member the app
        // already uses (BuildContext in a build() signature, a Text
        // constructor) fails at load.
        retainFrameworkUses = false;
      case '--framework-members':
        frameworkMembersScope = next();
        if (!const [
          'none',
          'calls',
          'all',
          'with-sdk-instance',
        ].contains(frameworkMembersScope)) {
          _die(
            '--framework-members must be none, calls, all or with-sdk-instance',
          );
        }
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
    if (platformPath != null) {
      BinaryBuilder(
        File(platformPath).readAsBytesSync(),
      ).readComponent(privateComponent);
    }
    BinaryBuilder(
      File(privateDillPath).readAsBytesSync(),
    ).readComponent(privateComponent);
  }
  final privateIsComplete = privateDillPath != null && platformPath != null;

  // --extendable is checked against the kernels in hand before anything is
  // written: a spec that names nothing would otherwise be a silent no-op.
  final extendableParsed = <ExtendableSpec>[];
  if (extendableSpecs.isNotEmpty) {
    try {
      extendableParsed.addAll(parseExtendableSpecs(extendableSpecs));
    } on FormatException catch (e) {
      _die(e.message);
    }
    final problems = checkExtendableSpecs(extendableParsed, [
      component,
      if (!identical(privateComponent, component)) privateComponent,
    ]);
    if (problems.isNotEmpty) _die(problems.join('\n       '));
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
  final privateClassMembers = <String>[];

  // PUBLIC members of PRIVATE classes. These used to arrive for free inside a
  // bare `class:` item, together with construction; now they are named, and
  // construction is not. A patch's target is usually one of these -- `build`,
  // `initState` on a `_FooState`.
  final privateClassPublicMembers = <String>[];

  // Constructors this release deliberately does NOT grant. Not an interface
  // line: the audit trail for an authority that was removed, so its absence is
  // checkable and a regression is a non-empty set rather than silence.
  final constructionWithheld = <String>[];

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

        // A PRIVATE CLASS IS REPRESENTED BY ITS MEMBERS, NOT BY A CLASS ITEM.
        //
        // A bare `class:` item under `callable:` is defined -- by upstream, in
        // `_Annotator.visitClass` -- as "this class AND ITS PUBLIC MEMBERS",
        // and `_visitPublicMembers(node.constructors)` includes the implicit
        // unnamed constructor, which is public. So a class item silently granted
        // CONSTRUCTION of every private class it named. That is how a patch
        // constructed `_Dead()` with no constructor named anywhere in the YAML.
        //
        // Measured, not assumed (`probes/p1_dead_allocatability.sh`):
        //   C1     bare class item        -> `_Dead()` CONSTRUCTS
        //   Cfix3  member grants, no      -> a patch still ATTACHES to a method
        //          class item                of the class and reads its privates
        //   Cfix4  same grant set         -> `_Dead()` is refused
        //   C6     `member: ''`           -> the unnamed constructor, exactly
        //   C3     `member: '_mk'`        -> a private named constructor, exactly
        //
        // And it is free: member-only retention measures -0.01% / +0.00% /
        // +0.00% against the current policy on three fixtures
        // (`probes/p1_retention_price.sh`). Granting every constructor instead
        // would cost +8.35% at 200 classes, which is the second reason
        // construction is opt-in one constructor at a time.
        //
        // WHY THE PUBLIC MEMBERS MUST BE NAMED. Attach needs the TARGET member
        // granted, and a patch's target is usually a PUBLIC method of a private
        // class -- `build`, `initState`. The class item used to cover those for
        // free; now they are named.
        if (retainPrivateClasses &&
            cls.name.startsWith('_') &&
            resolvableClass(uri, cls.name)) {
          for (final p in cls.procedures) {
            // A factory is a Procedure and IS a construction edge, so it is
            // withheld here with the constructors rather than leaking through
            // the member list.
            if (p.isFactory) continue;
            if (p.name.text.startsWith('_')) continue; // its own loop below
            if (!resolvableMember(uri, cls.name, _vmName(p))) continue;
            privateClassPublicMembers.add('$uri#${cls.name}#${_vmName(p)}');
          }
          for (final f in cls.fields) {
            if (f.name.text.startsWith('_')) continue; // its own loop below
            if (!resolvableMember(uri, cls.name, f.name.text)) continue;
            privateClassPublicMembers.add('$uri#${cls.name}#${f.name.text}');
          }
          // WHAT IS NO LONGER GRANTED, recorded so the absence is auditable and
          // so a regression shows up as a non-empty set rather than as silence.
          for (final c in cls.constructors) {
            final name = c.name.text.isEmpty ? 'new' : c.name.text;
            if (!constructorGrants.contains('$uri#${cls.name}.$name')) {
              constructionWithheld.add('$uri#${cls.name}.$name');
            }
          }
          for (final p in cls.procedures) {
            if (!p.isFactory) continue;
            final name = p.name.text.isEmpty ? 'new' : p.name.text;
            if (!constructorGrants.contains('$uri#${cls.name}.$name')) {
              constructionWithheld.add('$uri#${cls.name}.$name (factory)');
            }
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

  // FRAMEWORK USES. Patch bytecode names every class and member it touches,
  // and the loader finds each by name (bytecode_reader.cc, kClass/kMember), so
  // a framework type the release never kept findable kills the patch at load:
  //
  //   bytecode_reader.cc: 1173: error: Unable to find class BuildContext in
  //   Library:'package:flutter/src/widgets/framework.dart'
  //
  // That was the first `build()` patch on a device. Its body named nothing new;
  // its SIGNATURE named BuildContext. So the release keeps what its own app
  // code already uses outside the app: each class as `can-be-used-as-type`
  // (findable by name, members untouched) and each member as a `callable`
  // member item. A patch that reaches for a framework member the release never
  // used still fails, and the analyzer is what should refuse it.
  final frameworkTypes = <String, Set<String>>{};
  final frameworkMembers = <String>{};
  final frameworkSkipped = <String>{};
  // Declarations whose walk threw. Each costs only that declaration's uses,
  // never the interface, and is listed so it is not silent.
  final frameworkWalkFailures = <String>[];
  if (retainFrameworkUses) {
    // WHICH KERNEL. The non-AOT kernel is what the source says, and so what
    // a patch compiled from that source names: the prepass has had TFA drop
    // arguments and constant fields (its `Label.build` returns `new Text()`,
    // no style). Read under --platform it is complete and is the only walk.
    // Without --platform its `dart:` references are unbound, so the prepass
    // is walked too, for those; its other names must also resolve in the
    // non-AOT kernel, the program the annotator sees.
    final walks = <Component>{
      privateComponent,
      if (!privateIsComplete) component,
    };
    final privateIndex = index;
    for (final kernel in walks) {
      final isPrepass = !identical(kernel, privateComponent);
      final kernelIndex = isPrepass ? LibraryIndex.all(kernel) : privateIndex;
      bool resolves(LibraryIndex idx, String uri, String container, String? n) {
        try {
          if (n == null) {
            idx.getClass(uri, container);
          } else {
            idx.getMember(uri, container, n);
          }
          return true;
        } catch (_) {
          return false;
        }
      }

      bool found(String uri, String container, String? name) {
        // AOT's mixin deduplication moves shared mixin applications into this
        // synthetic library after the annotator has run, so an AOT kernel
        // (the prepass, or a --dill with no --private-dill) can name it and
        // the annotator can never find it: gen_kernel then dies with "The
        // library 'dart:mixin_deduplication' has not been indexed".
        var ok =
            uri != _mixinDeduplicationLibrary &&
            resolves(kernelIndex, uri, container, name);
        if (ok &&
            isPrepass &&
            privateDillPath != null &&
            !uri.startsWith('dart:')) {
          ok = resolves(privateIndex, uri, container, name);
        }
        if (!ok) {
          frameworkSkipped.add(
            name == null ? '$uri#$container' : '$uri#$container#$name',
          );
        }
        return ok;
      }

      final collector = _FrameworkUseCollector(isApp);
      for (final lib in kernel.libraries.where(isApp)) {
        collector.walk(lib);
      }
      frameworkWalkFailures.addAll(collector.failures);
      for (final cls in collector.classes) {
        final uri = cls.enclosingLibrary.importUri.toString();
        if (!found(uri, cls.name, null)) continue;
        (frameworkTypes[uri] ??= <String>{}).add(cls.name);
      }
      final retainedMembers = switch (frameworkMembersScope) {
        'none' => const <Member>{},
        'calls' =>
          collector.members
              .difference(collector.constantFields)
              .difference(collector.sdkInstanceCalls),
        'with-sdk-instance' => collector.members,
        _ => collector.members.difference(collector.sdkInstanceCalls),
      };
      for (final m in retainedMembers) {
        final uri = m.enclosingLibrary.importUri.toString();
        final cls = m.enclosingClass;
        final container = cls == null ? '::' : cls.name;
        final name = switch (m) {
          Procedure() => _vmName(m),
          _ => m.name.text,
        };
        if (!found(uri, container, name)) continue;
        // Already named by --sdk-members: one item per member.
        final sdkSpelling = container == '::'
            ? '$uri#$name'
            : '$uri#$container.$name';
        if (includeSdk && sdkMembers.contains(sdkSpelling)) continue;
        frameworkMembers.add('$uri#$container#$name');
        if (cls != null) (frameworkTypes[uri] ??= <String>{}).add(cls.name);
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
  if (privateClassPublicMembers.isNotEmpty) {
    buf.writeln(
      '  # PUBLIC members of PRIVATE classes, named ONE BY ONE and deliberately',
    );
    buf.writeln(
      '  # NOT as a bare `class:` item. A class item is defined as "the class '
      'AND',
    );
    buf.writeln(
      '  # its public members", and a class\'s implicit unnamed constructor is',
    );
    buf.writeln(
      '  # public -- so a class item granted CONSTRUCTION of every private '
      'class it',
    );
    buf.writeln(
      '  # named. Naming the members keeps attach and member reach and drops '
      'that.',
    );
    buf.writeln(
      '  # Measured: probes/p1_dead_allocatability.sh (C1/Cfix3/Cfix4) and',
    );
    buf.writeln(
      '  # probes/p1_retention_price.sh (the split costs -0.01%/+0.00%/+0.00%).',
    );
    for (final entry in privateClassPublicMembers) {
      final parts = entry.split('#');
      buf
        ..writeln("  - library: '${parts[0]}'")
        ..writeln("    class: '${parts[1]}'")
        ..writeln("    member: '${parts[2]}'");
    }
  }
  if (constructorGrants.isNotEmpty) {
    buf.writeln(
      '  # CONSTRUCTORS, granted explicitly and one at a time. `member: \'\'` '
      'is the',
    );
    buf.writeln(
      '  # unnamed constructor -- the spelling kernel\'s LibraryIndex uses.',
    );
    for (final entry in constructorGrants.toList()..sort()) {
      final i = entry.indexOf('#');
      final dot = entry.lastIndexOf('.');
      if (i <= 0 || dot <= i) {
        _die(
          "--grant-constructor must be 'library#Class.name' (name `new` for "
          'the unnamed constructor), got: $entry',
        );
      }
      final name = entry.substring(dot + 1);
      buf
        ..writeln("  - library: '${entry.substring(0, i)}'")
        ..writeln("    class: '${entry.substring(i + 1, dot)}'")
        ..writeln("    member: '${name == 'new' ? '' : name}'");
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
  if (frameworkMembers.isNotEmpty) {
    buf.writeln(
      '  # Framework and SDK members the app\'s own code already uses, so a',
    );
    buf.writeln('  # patch that edits that code can still name them.');
    for (final entry in frameworkMembers.toList()..sort()) {
      final parts = entry.split('#');
      buf.writeln("  - library: '${parts[0]}'");
      if (parts[1] != '::') buf.writeln("    class: '${parts[1]}'");
      buf.writeln("    member: '${parts[2]}'");
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

  if (frameworkTypes.isNotEmpty) {
    // A type item keeps the class findable by name and nothing else: the VM
    // reads it as EntryPointPragma::kTypeOnly, which retains the class without
    // its members.
    buf
      ..writeln('')
      ..writeln('# Framework and SDK classes the app\'s own code names.')
      ..writeln('can-be-used-as-type:');
    for (final uri in frameworkTypes.keys.toList()..sort()) {
      final names = frameworkTypes[uri]!.toList()..sort();
      buf
        ..writeln("  - library: '$uri'")
        ..writeln('    class: [${names.map((n) => "'$n'").join(', ')}]');
    }
  }

  if (extendableSpecs.isNotEmpty) {
    try {
      buf.write(extendableSections(extendableSpecs));
    } on FormatException catch (e) {
      _die(e.message);
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
          'privateClassPublicMembers': privateClassPublicMembers.length,
          'privateClassesConstructible': constructorGrants.length,
          'implicitlyConstructible': implicitlyConstructible.length,
          'constructionWithheld': constructionWithheld.length,
          'refused': refused.length,
          'frameworkTypes': frameworkTypes.values.fold<int>(
            0,
            (n, s) => n + s.length,
          ),
          'frameworkMembers': frameworkMembers.length,
          'frameworkSkipped': frameworkSkipped.length,
          'extendable': extendableGrants(extendableParsed).extendable.length,
          'canBeOverridden':
              extendableGrants(extendableParsed).overridable.length,
        },
        'privateTopLevelCallable': privateMembers,
        'privateStaticsCallable': privateStatics,
        'privateInstanceCallable': instanceCallable,
        // PUBLIC members of PRIVATE classes. New category, because these used
        // to arrive inside a bare `class:` item and the manifest could not tell
        // them apart from the construction authority that came with them.
        'privateClassPublicMembers': privateClassPublicMembers,
        // NOW MEANS WHAT IT SAYS: the constructors this release explicitly
        // granted, not "every private class, because a class item grants its
        // public constructors". Empty unless --grant-constructor was passed.
        'privateClassesConstructible': constructorGrants.toList()..sort(),
        // EXPECTED EMPTY, and kept precisely so it can be checked. A non-empty
        // set here means something re-granted construction implicitly.
        'implicitlyConstructible': implicitlyConstructible,
        // The audit trail for the authority that was removed.
        'constructionWithheld': constructionWithheld,
        'refused': refused,
        // --extendable grants: classes a module may extend, and the public
        // instance members it may override (`member: null` means every public
        // instance member the class declares). Empty unless the flag was passed.
        'extendable': [
          for (final e in extendableGrants(extendableParsed).extendable)
            {'library': e.library, 'class': e.cls},
        ],
        'canBeOverridden': [
          for (final o in extendableGrants(extendableParsed).overridable)
            {'library': o.library, 'class': o.cls, 'member': o.member},
        ],
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
    ..writeln(
      '  private-class members: ${privateClassPublicMembers.length} public'
      ' (was a bare class item, which also granted construction)',
    )
    ..writeln('  private class members: ${privateClassMembers.length}')
    ..writeln(
      '  constructors granted : ${constructorGrants.length}'
      '  withheld: ${constructionWithheld.length}',
    )
    ..writeln(
      '  unresolvable (skipped): $unresolvable'
      '${unresolvable > 0 ? "  <- named in kernel, not indexable; see the "
          "LibraryIndex note in this file" : ""}',
    )
    ..writeln(
      '  framework uses       : '
      '${frameworkTypes.values.fold<int>(0, (n, s) => n + s.length)} types, '
      '${frameworkMembers.length} members, '
      '${frameworkSkipped.length} not indexable, '
      '${frameworkWalkFailures.length} declarations not walked',
    )
    ..writeln('  sdk members          : ${members.length}')
    ..writeln('  sdk libraries        : ${wholeSdk.length}');
  for (final name in frameworkSkipped.toList()..sort()) {
    stderr.writeln('  framework use not indexable: $name');
  }
  for (final failure in frameworkWalkFailures) {
    stderr.writeln('  framework walk failed: $failure');
  }
}

/// How the VM names a member of this kind, which is what the dynamic interface
/// is matched against.
String _vmName(Procedure p) => switch (p.kind) {
  ProcedureKind.Getter => 'get:${p.name.text}',
  ProcedureKind.Setter => 'set:${p.name.text}',
  _ => p.name.text,
};

/// One `--extendable` entry: `library#Class` (all public instance members
/// overridable, [member] null) or `library#Class.member`.
class ExtendableSpec {
  const ExtendableSpec(this.library, this.cls, this.member);
  final String library;
  final String cls;
  final String? member;
}

/// Parses `--extendable` values. Throws [FormatException] on a malformed one.
List<ExtendableSpec> parseExtendableSpecs(List<String> specs) {
  final out = <ExtendableSpec>[];
  for (final spec in specs) {
    final i = spec.indexOf('#');
    final bad = FormatException(
      "--extendable entry must be 'library#Class' or "
      "'library#Class.member', got: $spec",
    );
    if (i <= 0 || i == spec.length - 1) throw bad;
    final rest = spec.substring(i + 1);
    final dot = rest.indexOf('.');
    final cls = dot < 0 ? rest : rest.substring(0, dot);
    final member = dot < 0 ? null : rest.substring(dot + 1);
    if (cls.isEmpty || (member != null && member.isEmpty)) throw bad;
    out.add(ExtendableSpec(spec.substring(0, i), cls, member));
  }
  return out;
}

/// What [specs] grant, normalised: a bare `library#C` anywhere makes every
/// public instance member declared by C overridable and subsumes any
/// `library#C.m`. Sorted; duplicates collapse. Used for both the yaml and the
/// capability manifest, so they cannot disagree.
({
  List<({String library, String cls})> extendable,
  List<({String library, String cls, String? member})> overridable,
})
extendableGrants(List<ExtendableSpec> specs) {
  final whole = <String>{}; // 'library\u0000class'
  final members = <String, Set<String>>{};
  for (final s in specs) {
    final k = '${s.library}\u0000${s.cls}';
    members.putIfAbsent(k, () => <String>{});
    if (s.member == null) {
      whole.add(k);
    } else {
      members[k]!.add(s.member!);
    }
  }
  final keys = members.keys.toList()..sort();
  ({String library, String cls}) lc(String k) {
    final p = k.split('\u0000');
    return (library: p[0], cls: p[1]);
  }

  return (
    extendable: [for (final k in keys) lc(k)],
    overridable: [
      for (final k in keys)
        if (whole.contains(k))
          (library: lc(k).library, cls: lc(k).cls, member: null)
        else
          for (final m in members[k]!.toList()..sort())
            (library: lc(k).library, cls: lc(k).cls, member: m),
    ],
  );
}

/// Problems with [specs] against the kernels the generator holds; empty when
/// every spec is safe to emit. Refused, because the annotator would otherwise
/// silently do nothing (a typo, a rename in a framework bump) or skip the
/// entry (`final` and `sealed` classes are never annotated `extendable`), and
/// a release that believes a class is extendable when it is not is the
/// failure `probes/added_class.sh` shows to be silent:
///   * the class is not in any given kernel
///   * the class is `final` or `sealed`
///   * `Class.member` is not a PUBLIC INSTANCE member the class itself declares
///     (`can-be-overridden` covers only those; an inherited one needs its
///     declaring class named)
List<String> checkExtendableSpecs(
  List<ExtendableSpec> specs,
  Iterable<Component> components,
) {
  final problems = <String>[];
  Class? find(String library, String name) {
    for (final c in components) {
      for (final l in c.libraries) {
        if (l.importUri.toString() != library) continue;
        for (final cls in l.classes) {
          if (cls.name == name) return cls;
        }
      }
    }
    return null;
  }

  for (final s in specs) {
    final label = '${s.library}#${s.cls}${s.member == null ? '' : '.${s.member}'}';
    final cls = find(s.library, s.cls);
    if (cls == null) {
      problems.add('--extendable $label: no class ${s.cls} in ${s.library}');
      continue;
    }
    if (cls.isFinal || cls.isSealed) {
      problems.add(
        '--extendable $label: ${s.cls} is '
        '${cls.isFinal ? 'final' : 'sealed'}; a module cannot extend it',
      );
      continue;
    }
    final m = s.member;
    if (m == null) continue;
    final declared = cls.members.any(
      (x) =>
          x is! Constructor &&
          x.isInstanceMember &&
          !x.name.isPrivate &&
          x.name.text == m,
    );
    if (!declared) {
      problems.add(
        '--extendable $label: ${s.cls} declares no public instance member '
        "'$m' (inherited members need their declaring class named)",
      );
    }
  }
  return problems;
}

/// The `extendable:` and `can-be-overridden:` sections for `--extendable`
/// specs, each `library#Class` or `library#Class.member`.
///
/// `library#Class` makes the class extendable and ALL its public members
/// overridable (a `class:` item with no `member:`, per pkg/vm's
/// dynamic_interface.md); `library#Class.member` names one overridable member
/// and still makes the class extendable. Output is sorted so a run is
/// reproducible. Returns the empty string for no specs. Throws
/// [FormatException] on a malformed spec.
String extendableSections(List<String> specs) {
  final g = extendableGrants(parseExtendableSpecs(specs));
  if (g.extendable.isEmpty) return '';
  final byLib = <String, List<String>>{};
  for (final e in g.extendable) {
    (byLib[e.library] ??= []).add(e.cls);
  }
  final out = StringBuffer()
    ..writeln('')
    ..writeln('# --extendable: classes a patch module may extend.')
    ..writeln('extendable:');
  for (final lib in byLib.keys.toList()..sort()) {
    final names = byLib[lib]!..sort();
    out
      ..writeln("  - library: '$lib'")
      ..writeln('    class: [${names.map((n) => "'$n'").join(', ')}]');
  }
  out
    ..writeln('')
    ..writeln('can-be-overridden:');
  for (final o in g.overridable) {
    out
      ..writeln("  - library: '${o.library}'")
      ..writeln("    class: '${o.cls}'");
    if (o.member != null) out.writeln("    member: '${o.member}'");
  }
  return out.toString();
}

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
  --no-private-classes     skip private CLASSES and their members, keeping the
                           top-level private shape only
  --private-dill <path>    enumerate PRIVATE members from this kernel instead of
                           from --dill. --dill is the --aot prepass, already
                           tree-shaken, so a private member nothing in the
                           release calls is gone before it can be named -- and
                           starting to call one is exactly what a patch may do
  --policy <p1|p2|p3>      which private shapes to retain. p2 is the product
                           default: app-private members AND the private classes
                           required to make those members patch-targetable.
                           p3 grants the members without the classes and is
                           recorded NON-VIABLE -- its grants are inert, because
                           a patch cannot attach to a method of a class the
                           release did not retain
  --extendable <l#C[.m]>   repeatable, OFF by default: emit `extendable:` for
                           class C and `can-be-overridden:` for all its public
                           members (or only member m), so a patch module may
                           declare a class extending an AOT class. Costs AOT
                           devirtualization on C; see probes/added_class.sh.
                           A bare l#C also subsumes any l#C.m. Only members C
                           itself declares are covered, not inherited ones
                           (name the declaring class). Refused: a class not in
                           the kernels, a final or sealed class, a member C does
                           not declare. Recorded in --manifest
  --no-framework-uses      do not retain the framework and SDK classes and
                           members the app's own code uses. Without them a
                           patch naming one (BuildContext in a build()
                           signature) fails at load
  --platform <dill>        the platform --private-dill was compiled against;
                           with it the framework-use walk reads one complete
                           kernel
  --framework-members <s>  which of those members: all (default; leaves out
                           dart: instance members reached through code, whose
                           implementations fan out across the SDK), calls
                           (also leaves out fields named only by constants),
                           none (classes only), with-sdk-instance (everything;
                           +10% on probes/fw_use_binding.sh). For measuring
  --manifest <path>        write the CAPABILITY MANIFEST: what this release
                           actually granted, per target. Not derivable by
                           reading the emitted yaml, because a `class:` item
                           also grants an implicit public constructor that
                           appears in none of its lines. The patch side accepts
                           a private reference against this file
''');
}

/// The classes and members outside the app that the app's own code names:
/// in types, supertypes, calls, field accesses, tear-offs and constants.
///
/// References that are not bound in the kernel being walked are skipped: the
/// non-AOT kernel does not carry the SDK.
///
/// Private names are skipped except inside constants. App code cannot call
/// another library's private member, but a constant names every field of its
/// class, private ones included, and the loader looks each one up
/// (`const TextStyle(...)` names `_package`; `Curves.linear` is a `_Linear`).
///
/// No override calls `super`: kernel's own `visitChildren` dereferences each
/// target, which throws on an unbound one, so each visits its children itself.
class _FrameworkUseCollector extends RecursiveVisitor {
  _FrameworkUseCollector(this.isApp);

  final bool Function(Library) isApp;
  final failures = <String>[];
  final classes = <Class>{};
  final members = <Member>{};
  final _viaCode = <Member>{};
  final _inConstants = <Member>{};

  /// Fields named ONLY by a constant's field values, never read or called.
  Set<Member> get constantFields => members.difference(_viaCode);

  /// `dart:` instance members reached only through code, never named by a
  /// constant. Left out: an SDK interface member such as `Iterable.iterator`
  /// is implemented across the SDK, and retaining it keeps every
  /// implementation (+10 % on the host probe, see fw_use_binding.sh).
  Set<Member> get sdkInstanceCalls => {
    for (final m in members)
      if (m.enclosingLibrary.importUri.isScheme('dart') &&
          m.enclosingClass != null &&
          m.isInstanceMember &&
          !_inConstants.contains(m))
        m,
  };
  final _seenConstants = <Constant>{};

  /// Walks [lib] one declaration at a time, so a node this visitor does not
  /// handle costs that declaration's uses, never the whole interface.
  void walk(Library lib) {
    void guarded(String what, void Function() visit) {
      try {
        visit();
      } catch (error) {
        failures.add('${lib.importUri}#$what: $error');
      }
    }

    for (final m in [...lib.procedures, ...lib.fields]) {
      guarded(m.name.text, () => m.accept(this));
    }
    for (final c in lib.classes) {
      guarded(c.name, () => c.accept(this));
    }
  }

  bool _outside(Library lib) {
    if (isApp(lib)) return false;
    // dart:_internal and friends: nothing a patch spells.
    return !lib.importUri.toString().startsWith('dart:_');
  }

  void _class(Reference? ref, {bool allowPrivate = false}) {
    final cls = ref?.node;
    if (cls is! Class || !_outside(cls.enclosingLibrary)) return;
    if (!allowPrivate && cls.name.startsWith('_')) return;
    classes.add(cls);
  }

  void _member(
    Reference? ref, {
    bool allowPrivate = false,
    bool fromConstant = false,
  }) {
    final m = ref?.node;
    if (m is! Member || !_outside(m.enclosingLibrary)) return;
    if (!allowPrivate && m.name.isPrivate) return;
    // Synthetic lowerings carry names no patch writes and no index holds.
    if (m.name.text.contains('#')) return;
    members.add(m);
    if (fromConstant) {
      _inConstants.add(m);
    } else {
      _viaCode.add(m);
    }
  }

  @override
  void visitInterfaceType(InterfaceType node) {
    _class(node.classReference);
    // Not super: InterfaceType.visitChildren dereferences the class, which
    // throws on an unbound one.
    for (final t in node.typeArguments) {
      t.accept(this);
    }
  }

  @override
  void visitSupertype(Supertype node) {
    _class(node.className);
    for (final t in node.typeArguments) {
      t.accept(this);
    }
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    _member(node.targetReference);
    node.arguments.accept(this);
  }

  @override
  void visitStaticGet(StaticGet node) {
    _member(node.targetReference);
  }

  @override
  void visitStaticSet(StaticSet node) {
    _member(node.targetReference);
    node.value.accept(this);
  }

  @override
  void visitStaticTearOff(StaticTearOff node) {
    _member(node.targetReference);
  }

  @override
  void visitConstructorInvocation(ConstructorInvocation node) {
    _member(node.targetReference);
    final target = node.targetReference.node;
    if (target is Constructor) _class(target.enclosingClass.reference);
    node.arguments.accept(this);
  }

  @override
  void visitConstructorTearOff(ConstructorTearOff node) {
    _member(node.targetReference);
  }

  @override
  void visitRedirectingFactoryTearOff(RedirectingFactoryTearOff node) {
    _member(node.targetReference);
  }

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    _member(node.interfaceTargetReference);
    node.receiver.accept(this);
    node.arguments.accept(this);
  }

  @override
  void visitInstanceGetterInvocation(InstanceGetterInvocation node) {
    _member(node.interfaceTargetReference);
    node.receiver.accept(this);
    node.arguments.accept(this);
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    _member(node.interfaceTargetReference);
    node.receiver.accept(this);
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    _member(node.interfaceTargetReference);
    node.receiver.accept(this);
    node.value.accept(this);
  }

  @override
  void visitInstanceTearOff(InstanceTearOff node) {
    _member(node.interfaceTargetReference);
    node.receiver.accept(this);
  }

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    _member(node.interfaceTargetReference);
    node.arguments.accept(this);
  }

  @override
  void visitSuperPropertyGet(SuperPropertyGet node) {
    _member(node.interfaceTargetReference);
  }

  @override
  void visitSuperPropertySet(SuperPropertySet node) {
    _member(node.interfaceTargetReference);
    node.value.accept(this);
  }

  @override
  void visitSuperInitializer(SuperInitializer node) {
    _member(node.targetReference);
    node.arguments.accept(this);
  }

  @override
  void visitRedirectingInitializer(RedirectingInitializer node) {
    _member(node.targetReference);
    node.arguments.accept(this);
  }

  @override
  void visitEqualsCall(EqualsCall node) {
    _member(node.interfaceTargetReference);
    node.left.accept(this);
    node.right.accept(this);
  }

  @override
  void visitTypedefType(TypedefType node) {
    // Not super: visitChildren dereferences the typedef.
    for (final t in node.typeArguments) {
      t.accept(this);
    }
  }

  @override
  void visitFunctionNode(FunctionNode node) {
    // Not super: visitChildren dereferences a redirecting factory's target.
    for (final t in node.typeParameters) {
      t.accept(this);
    }
    for (final v in node.positionalParameters) {
      v.accept(this);
    }
    for (final v in node.namedParameters) {
      v.accept(this);
    }
    node.returnType.accept(this);
    node.emittedValueType?.accept(this);
    final redirect = node.redirectingFactoryTarget;
    if (redirect != null) {
      _member(redirect.targetReference);
      for (final t in redirect.typeArguments ?? const <DartType>[]) {
        t.accept(this);
      }
    }
    node.body?.accept(this);
  }

  @override
  void visitExtensionType(ExtensionType node) {
    for (final t in node.typeArguments) {
      t.accept(this);
    }
  }

  @override
  void visitConstantExpression(ConstantExpression node) {
    _constant(node.constant);
    node.type.accept(this);
  }

  void _constant(Constant c) {
    if (!_seenConstants.add(c)) return;
    switch (c) {
      case InstanceConstant():
        _class(c.classReference, allowPrivate: true);
        for (final entry in c.fieldValues.entries) {
          _member(entry.key, allowPrivate: true, fromConstant: true);
          _constant(entry.value);
        }
        for (final t in c.typeArguments) {
          t.accept(this);
        }
      case ListConstant():
        c.typeArgument.accept(this);
        c.entries.forEach(_constant);
      case SetConstant():
        c.typeArgument.accept(this);
        c.entries.forEach(_constant);
      case MapConstant():
        c.keyType.accept(this);
        c.valueType.accept(this);
        for (final e in c.entries) {
          _constant(e.key);
          _constant(e.value);
        }
      case RecordConstant():
        c.recordType.accept(this);
        c.positional.forEach(_constant);
        c.named.values.forEach(_constant);
      case StaticTearOffConstant():
        _member(c.targetReference, allowPrivate: true);
      case ConstructorTearOffConstant():
        _member(c.targetReference, allowPrivate: true);
      case InstantiationConstant():
        _constant(c.tearOffConstant);
        for (final t in c.types) {
          t.accept(this);
        }
      case RedirectingFactoryTearOffConstant():
        _member(c.targetReference, allowPrivate: true);
      case TypedefTearOffConstant():
        _constant(c.tearOffConstant);
        for (final t in c.types) {
          t.accept(this);
        }
      case TypeLiteralConstant():
        c.type.accept(this);
      default:
        break;
    }
  }
}
