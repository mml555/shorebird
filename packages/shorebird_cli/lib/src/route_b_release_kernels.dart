// Route B (selfhost): producing the release's SECOND kernel, and proving it
// describes the same program as the first.
//
// A release owes the producer two kernels, because they answer different
// questions:
//
//   release_app.dill     AOT/TFA, emitted by `flutter build ipa`  -> coverage
//   release_import.dill  --no-aot --no-link-platform              -> bytecode
//
// The second is not optional and not interchangeable: `dart2bytecode
// --import-dill` crashes its CFE on the AOT kernel
// (`DillExtensionBuilder`, reproduced 2026-08-10), and `flutter build ipa`
// emits no other kernel.
//
// WHY THE FRONTEND COMES FROM THE CELL
//
// "Generate it at release time, so the ambient toolchain is the release
// toolchain" is true today and is exactly the kind of ambient invariant this
// project keeps removing. Resolving `gen_kernel` from the release's engine hash
// makes it structural: both kernels are provably from one frontend lineage, and
// no machine's PATH or checkout can change that.
//
// WHY THE INPUTS ARE FORWARDED, NOT REBUILT
//
// The non-AOT kernel needs the same semantic inputs as the release — package
// config, entrypoint, target, defines, experiments — differing ONLY in the AOT
// and platform-linking mode. Anything reconstructed by hand is a chance to
// reconstruct it differently. So the release's own argument list is forwarded,
// and any option that cannot be forwarded faithfully makes this decline to
// produce a kernel at all rather than produce a plausible wrong one.
//
// And because "forwarded correctly" is still a promise, [agreesWith] turns it
// into a check: every member of the AOT kernel must exist in the import kernel.
// A wrong entrypoint, a wrong package config or a wrong target all break that.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/dart_define_from_file.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

/// A reference to a [RouteBReleaseKernelBuilder] instance.
final routeBReleaseKernelBuilderRef = create(RouteBReleaseKernelBuilder.new);

/// The [RouteBReleaseKernelBuilder] available in the current zone.
RouteBReleaseKernelBuilder get routeBReleaseKernelBuilder =>
    read(routeBReleaseKernelBuilderRef);

/// Runs the cell's frontend.
typedef RouteBKernelRunner =
    ProcessResult Function(String executable, List<String> arguments);

/// The SDK members a release retains by NAME, so a future patch may call them.
///
/// Curated and small, on purpose. Probe A0 measured a named member at
/// +0.006-0.009 % of the snapshot; a whole `dart:core` library item was
/// measured at **+310 %**, a four-fold snapshot, because it keeps every public
/// member of every public class and AOT can no longer tree-shake any of them.
/// That option stays reachable through the generator's `--sdk-libraries` for
/// debugging and is never product behaviour.
///
/// This list is therefore a BUDGET, not a wish. Widen it from evidence about
/// what real patches call — every release pays for every name here, forever,
/// and the release reports the tax so a widening cannot go unnoticed.
const routeBRetainedSdkMembers = <String>[
  // Spike B's canonical failure: the first replacement body ever written died
  // on `print` (bytecode_reader.cc:1172).
  'dart:core#print',
  // Probe A0's shape, and the one the device gate actually needed.
  'dart:core#DateTime.now',
  'dart:core#DateTime.get:millisecondsSinceEpoch',
  'dart:core#identical',
  // The cheap set: Map, Set, String, num/int/double members and a few
  // Iterable/List ones. Together +1.8 % of the AOT snapshot on the airgap app
  // (6,560,960 B baseline), so every release keeps them.
  'dart:core#Map.addAll',
  'dart:core#Map.clear',
  'dart:core#Map.removeWhere',
  'dart:core#Map.get:isNotEmpty',
  'dart:core#Set.addAll',
  'dart:core#Set.remove',
  'dart:core#Set.removeWhere',
  'dart:core#Set.clear',
  'dart:core#Set.toSet',
  'dart:core#String.endsWith',
  'dart:core#String.indexOf',
  'dart:core#String.substring',
  'dart:core#String.padLeft',
  'dart:core#String.compareTo',
  'dart:core#String.*',
  'dart:core#String.get:isNotEmpty',
  'dart:core#String.get:length',
  'dart:core#num./',
  'dart:core#num.%',
  'dart:core#num.abs',
  'dart:core#num.round',
  'dart:core#num.floor',
  'dart:core#num.ceil',
  'dart:core#num.truncate',
  'dart:core#num.clamp',
  'dart:core#num.toInt',
  'dart:core#num.toStringAsFixed',
  'dart:core#num.get:isNegative',
  'dart:core#num.compareTo',
  'dart:core#int.abs',
  'dart:core#int.round',
  'dart:core#int.floor',
  'dart:core#int.ceil',
  'dart:core#int.truncate',
  'dart:core#int.get:isEven',
  'dart:core#int.get:isOdd',
  'dart:core#double.+',
  'dart:core#double.-',
  'dart:core#double.*',
  'dart:core#double.%',
  'dart:core#double./',
  'dart:core#double.~/',
  'dart:core#double.abs',
  'dart:core#double.round',
  'dart:core#double.floor',
  'dart:core#double.ceil',
  'dart:core#double.truncate',
  'dart:core#double.unary-',
  'dart:core#Iterable.get:isEmpty',
  'dart:core#Iterable.get:isNotEmpty',
  'dart:core#Iterable.join',
  'dart:core#List.clear',
  'dart:core#List.sublist',
  // `then` on every allocated `Future` subtype, so a patch may `await` one.
  // Awaiting a `_Future` goes through `_Future._thenAwait`, but awaiting any
  // other `Future` calls its `then`, and the analysis cannot tell them apart
  // from the static type, so it checks every `await` on a `Future` as a call
  // of `then` (analysis 24). Every Material app allocates `TickerFuture`, and
  // nothing in it calls `TickerFuture.then`, so without this key the kept
  // check refused every patch that changes or carries an `await` (#289).
  'dart:async#Future.then',
  // The other members `TickerFuture` overrides, for the same reason: a call
  // on a `Future` value is checked against every `Future` subtype the release
  // allocates, and `timeout` has no `await` form to fall back on (#289).
  // Measured on the shapes app at cell 9995f957: +4,416 B of snapshot
  // (+0.108 %) for the three (ios-cell-9995f957-future-members).
  'dart:async#Future.catchError',
  'dart:async#Future.whenComplete',
  'dart:async#Future.timeout',
];

/// The SDK members kept only when the app opts in with
/// [routeBKeepCollectionMethodsKey] in its checked-in shorebird.yaml.
///
/// Each costs about +2 % of the AOT snapshot (all 21 together, +9 %), because
/// the member is copied into every typed-data list class (the typed-data list
/// mixins each get their own copy). Measured on the airgap app, whose baseline
/// is 6,560,960 B; with the cheap set as well, all 74 keys (before the
/// `Future` members) are +10.7 %.
const routeBHeavySdkMembers = <String>[
  'dart:core#Iterable.map',
  'dart:core#Iterable.any',
  'dart:core#Iterable.every',
  'dart:core#Iterable.contains',
  'dart:core#Iterable.forEach',
  'dart:core#Iterable.fold',
  'dart:core#Iterable.reduce',
  'dart:core#Iterable.take',
  'dart:core#Iterable.skip',
  'dart:core#Iterable.firstWhere',
  'dart:core#Iterable.elementAt',
  'dart:core#Iterable.get:last',
  'dart:core#List.addAll',
  'dart:core#List.sort',
  'dart:core#List.indexOf',
  'dart:core#List.insert',
  'dart:core#List.removeWhere',
  'dart:core#List.+',
  'dart:core#Iterable.toList',
  'dart:core#Iterable.where',
  'dart:core#Iterable.toSet',
];

/// The checked-in shorebird.yaml key that keeps [routeBHeavySdkMembers].
const routeBKeepCollectionMethodsKey = 'keep_sdk_collection_methods';

/// The SDK members a release keeps, given whether the app opted in to the
/// heavy set.
List<String> routeBSdkMembersFor({required bool keepCollectionMethods}) => [
  ...routeBRetainedSdkMembers,
  if (keepCollectionMethods) ...routeBHeavySdkMembers,
];

/// Build options that change kernel semantics and cannot be forwarded to
/// `gen_kernel` faithfully.
///
/// **EMPTY, and it emptied for a measured reason.** It held
/// `--dart-define-from-file`, whose presence here did more than skip a define:
/// [RouteBReleaseKernelBuilder.forwardedArgs] returning null means no prepass
/// and no import kernel, so such a release was **not patchable at all**.
///
/// The expansion now comes from `dart_define_from_file.dart` — a port of
/// Flutter's own parser that the release path CHECKS against the `DART_DEFINES`
/// Flutter wrote for that same build, declining exactly as before when the two
/// disagree. What was rejected was hand-reconstruction *trusted on sight*, and
/// that objection is answered by the check rather than by the port.
///
/// Kept in sync with `routeBUnfingerprintableOptions` in
/// `route_b_build_config.dart` by `route_b_build_config_test.dart`.
const routeBUnforwardableOptions = <String>[];

/// Whether [arg] is one of [options], in either `--opt=value` or `--opt` form.
///
/// Takes the list as a parameter for the same reason
/// [isUnfingerprintable] does: with [routeBUnforwardableOptions] empty, a test
/// that could not inject a synthetic option would be testing an unreachable
/// branch.
bool isUnforwardable(
  String arg, {
  List<String> options = routeBUnforwardableOptions,
}) => options.any((option) => arg == option || arg.startsWith('$option='));

/// {@template route_b_release_kernel_builder}
/// Produces the release's `--no-aot --no-link-platform` kernel.
/// {@endtemplate}
class RouteBReleaseKernelBuilder {
  /// {@macro route_b_release_kernel_builder}
  const RouteBReleaseKernelBuilder();

  /// Translates the release's build arguments into `gen_kernel` arguments.
  ///
  /// Returns null when the release used an option whose meaning cannot be
  /// carried across, so the caller declines rather than guesses.
  /// [flavor] is the RESOLVED flavor, and passing it is the G4.2 fix.
  ///
  /// THE BUG IT CLOSES, stated narrowly: the shipped flavored release receives
  /// FLUTTER_APP_FLAVOR, while these kernels did not — so retention and binding
  /// could be computed against a different Dart program than the one that
  /// shipped. This CLI passes flavor to `buildIpa` as a separate parameter, so
  /// it never entered `buildArgs` and could not be forwarded from there.
  ///
  /// It is synthesised rather than expected among the defines because a legal
  /// invocation can never carry it as one: Flutter exits if a user supplies
  /// FLUTTER_APP_FLAVOR via --dart-define, --dart-define-from-file, or the
  /// environment. See `probes/g42_flavor_flow.sh`, which cites each line.
  static List<String>? forwardedArgs(
    List<String> buildArgs, {
    String? flavor,
    String? workingDirectory,
    Map<String, String>? injectedDefines,
  }) {
    // FILE DEFINES FIRST, mirroring `extractDartDefines`, which emits every
    // file entry ahead of every `--dart-define`. gen_kernel is last-wins
    // (probe rule 1) and order-insensitive otherwise (rule 2), so emitting them
    // in Flutter's order is what makes a key present in both resolve the way
    // the shipped kernel resolved it.
    final expansion = DartDefineFromFileExpansion.expand(
      buildArgs,
      workingDirectory: workingDirectory,
    );
    if (!expansion.ok) return null;
    // G4.1c: the defines FLUTTER injects, which the user never typed and which
    // this list carried none of until now. Emitted first because their position
    // is unobservable -- Flutter refuses a build whose user defines collide
    // with any of these keys, so no later `-D` can ever overwrite one.
    //
    // A null map is NOT "no injected defines": it means the caller could not
    // read Flutter's answer, and callers that cannot read it decline to produce
    // a kernel at all rather than compile the wrong program quietly.
    final forwarded = [
      for (final entry in (injectedDefines ?? const <String, String>{}).entries)
        '-D${entry.key}=${entry.value}',
      for (final entry in expansion.defines.entries)
        '-D${entry.key}=${entry.value}',
    ];
    for (final arg in buildArgs) {
      if (isUnforwardable(arg)) return null;

      // Flutter spells these --dart-define=K=V; gen_kernel spells them -DK=V.
      // Same values, same order, one translation in one place.
      if (arg.startsWith('--dart-define=')) {
        forwarded.add('-D${arg.substring('--dart-define='.length)}');
      } else if (arg.startsWith('--enable-experiment=')) {
        forwarded.add(arg);
      }
    }
    // Appended last so it wins over anything already present, mirroring
    // Flutter's own xcodebuild-stage removeWhere-then-add
    // (flutter/issues/169598) and gen_kernel's last-wins duplicate handling,
    // which probes/g41_define_semantics.sh measured.
    if (flavor != null && flavor.isNotEmpty) {
      forwarded.add('-DFLUTTER_APP_FLAVOR=$flavor');
    }
    return forwarded;
  }

  /// Generates the import kernel for [entrypoint], or returns null with a
  /// warning explaining why the release will not be patchable.
  File? build({
    required RouteBCompiler compiler,
    required Directory projectRoot,
    required String entrypoint,
    required List<String> buildArgs,
    required File outputFile,
    String? flavor,
    Map<String, String>? injectedDefines,
    RouteBKernelRunner run = Process.runSync,
  }) => _compile(
    compiler: compiler,
    projectRoot: projectRoot,
    entrypoint: entrypoint,
    buildArgs: buildArgs,
    outputFile: outputFile,
    flavor: flavor,
    injectedDefines: injectedDefines,
    // The only intentional difference from the release's own compilation.
    modeArgs: const ['--no-aot', '--no-link-platform'],
    run: run,
  );

  File? _compile({
    required RouteBCompiler compiler,
    required Directory projectRoot,
    required String entrypoint,
    required List<String> buildArgs,
    required File outputFile,
    required List<String> modeArgs,
    required RouteBKernelRunner run,
    String? flavor,
    Map<String, String>? injectedDefines,
  }) {
    final extraArgs = forwardedArgs(
      buildArgs,
      flavor: flavor,
      injectedDefines: injectedDefines,
    );
    if (extraArgs == null) {
      logger.warn(
        '''This release uses ${routeBUnforwardableOptions.join(', ')}, whose values cannot be carried into the kernel a patch would be compiled against. Patches for it will be refused.''',
      );
      return null;
    }

    final packageConfig = File(
      p.join(projectRoot.path, '.dart_tool', 'package_config.json'),
    );
    if (!packageConfig.existsSync()) {
      logger.warn(
        '''Could not find ${packageConfig.path}; patches for this release will be refused.''',
      );
      return null;
    }

    // Flutter adds three arguments whenever the build generated a Dart plugin
    // registrant, and the release kernel therefore contains it and everything
    // it pulls in. Omitting them cost 320 members on the first real run, caught
    // by [agreesWith] rather than by a device. Derived from the build's own
    // generated file at the path Flutter puts it, and spelled the way
    // `compile.dart` spells it -- not invented here.
    final registrant = File(
      p.join(
        projectRoot.path,
        '.dart_tool',
        'flutter_build',
        'dart_plugin_registrant.dart',
      ),
    );
    final registrantArgs = <String>[
      if (registrant.existsSync()) ...[
        '--source',
        registrant.uri.toString(),
        '--source',
        'package:flutter/src/dart_plugin_registrant.dart',
        '-Dflutter.dart_plugin_registrant=${registrant.uri}',
      ],
    ];

    outputFile.parent.createSync(recursive: true);
    final result = run(compiler.runtime.path, [
      compiler.frontend.path,
      // The FLUTTER platform, from the cell. Not vm_platform.dill, and not one
      // found on this machine: bytecode compiled against a different platform
      // does not bind, and that failure surfaces on device.
      '--platform',
      compiler.flutterPlatformDill.path,
      '--target',
      'flutter',
      ...modeArgs,
      '--packages',
      packageConfig.path,
      ...registrantArgs,
      ...extraArgs,
      '-o',
      outputFile.path,
      // Absolute AND canonical. Flutter's --target is relative to the project
      // root, but gen_kernel resolves a relative path against the CWD, which is
      // wherever `shorebird release` was invoked from. Left relative it reports
      // "No 'main' method found", which reads like a broken app.
      //
      // `p.normalize` is the Windows half and it is not cosmetic. Flutter
      // supplies POSIX-style targets — `lib/main.dart` — so on Windows a bare
      // join yields `C:\…\project\lib/main.dart`, mixing separators inside one
      // path. The invariant this restores: a path this code builds for a
      // downstream compiler is canonical for the host platform, so callers and
      // tests never have to normalize what we hand them.
      p.normalize(
        p.isAbsolute(entrypoint)
            ? entrypoint
            : p.join(projectRoot.path, entrypoint),
      ),
    ]);

    if (result.exitCode != 0 || !outputFile.existsSync()) {
      logger.warn(
        '''
Could not compile the kernel a patch would be built against (exit ${result.exitCode}); patches for this release will be refused.
${result.stderr}''',
      );
      return null;
    }

    return outputFile;
  }

  /// Compile the release's own AOT kernel, WITHOUT building the app.
  ///
  /// The dynamic interface has to be generated from a kernel, and the kernel a
  /// release ships is produced by `flutter build ipa` — which is the circle.
  /// This breaks it with a kernel-only prepass rather than by building the
  /// whole IPA twice and discarding one: the extra cost is a frontend
  /// compilation, not an Xcode archive.
  File? buildPrepass({
    required RouteBCompiler compiler,
    required Directory projectRoot,
    required String entrypoint,
    required List<String> buildArgs,
    required File outputFile,
    String? flavor,
    Map<String, String>? injectedDefines,
    RouteBKernelRunner run = Process.runSync,
  }) => _compile(
    compiler: compiler,
    projectRoot: projectRoot,
    entrypoint: entrypoint,
    buildArgs: buildArgs,
    flavor: flavor,
    injectedDefines: injectedDefines,
    outputFile: outputFile,
    // --aot, because the interface should describe what a RELEASE contains.
    // A non-AOT kernel lists members AOT would tree-shake, and retaining those
    // would pay for symbols the release never had.
    modeArgs: const ['--aot'],
    run: run,
  );

  /// The exact private constructors this release's own methods construct.
  ///
  /// Asked of the analyzer in CENSUS mode, over the same `--aot` prepass kernel
  /// the interface is generated from, so the set describes the code this
  /// release actually ships.
  ///
  /// NEVER FATAL, and deliberately quiet about it. A cell whose analyzer does
  /// not report constructions, an analyzer that fails, or output this build
  /// cannot parse all yield an EMPTY list — which reproduces the previous
  /// behaviour exactly: nothing is granted, so nothing is newly constructible.
  /// A release that retains less is narrower; a release that fails to build is
  /// not a release.
  List<String> _deriveConstructorGrants({
    required RouteBCompiler compiler,
    required File prepassKernel,
    required String packageName,
    required Directory workingDirectory,
    required RouteBKernelRunner run,
  }) {
    final census = File(
      p.join(workingDirectory.path, 'release_constructions.jsonl'),
    );
    try {
      final result = run(compiler.runtime.path, [
        compiler.analyzer.path,
        '--census',
        '--dill',
        prepassKernel.path,
        '--include',
        ...routeBAppIncludePrefixes(packageName),
        '--out',
        census.path,
      ]);
      if (result.exitCode != 0 || !census.existsSync()) {
        logger.detail(
          "Route B: could not enumerate this release's private constructions "
          '(exit ${result.exitCode}); no constructors will be retained.',
        );
        return const [];
      }
      final keys = <String>{};
      for (final line in census.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) continue;
        final constructions = decoded['privateConstructions'];
        if (constructions is! List) continue;
        for (final entry in constructions) {
          if (entry is Map<String, dynamic> && entry['key'] is String) {
            keys.add(entry['key']! as String);
          }
        }
      }
      // Sorted so a release is reproducible from the same inputs.
      final sorted = keys.toList()..sort();
      if (sorted.isNotEmpty) {
        logger.detail(
          'Route B: retaining ${sorted.length} private constructor(s) this '
          "release's own methods construct.",
        );
      }
      return sorted;
    } on Object catch (error) {
      logger.detail(
        'Route B: private-construction enumeration failed ($error); no '
        'constructors will be retained.',
      );
      return const [];
    }
  }

  /// Generate the dynamic interface a release declares its retention with.
  ///
  /// Returns the file, or null with a warning. Never fatal: a release that
  /// cannot declare retention is still a good release, it simply cannot be
  /// patched with a body that names anything.
  File? generateDynamicInterface({
    required RouteBCompiler compiler,
    required File prepassKernel,
    required File outputFile,
    List<String> sdkMembers = routeBRetainedSdkMembers,
    String? appPackageName,
    File? privateEnumerationKernel,
    File? manifestFile,
    RouteBKernelRunner run = Process.runSync,
  }) {
    outputFile.parent.createSync(recursive: true);

    // APP-ONLY BREADTH, and it is not optional. Without --include the generator
    // treats EVERY non-`dart:` library as "the app" -- 598 library items on the
    // acceptance fixture, the breadth measured at +275% in measure_real_app.sh.
    //
    // It got worse than expensive. Since the generator began emitting private
    // classes and private class members by default, all-libraries breadth
    // produces an interface that DOES NOT BUILD: it names class members that
    // exist in the `--aot` prepass this reads but not in the pre-transform
    // component the annotator indexes. That arm is recorded as DOES NOT BUILD
    // in PARITY.md, and this call site was generating exactly it.
    //
    // So the prefix is a correctness requirement, not a size tuning knob. If
    // the package name is unavailable the interface is not generated at all: an
    // unpatchable release is a good release, one that cannot be built is not.
    final packageName = appPackageName ?? shorebirdEnv.getPubspecYaml()?.name;
    if (packageName == null || packageName.isEmpty) {
      logger.warn(
        "Could not determine this app's package name, so this release's "
        'retention interface was not generated; patches for it will only be '
        'able to replace bodies that name nothing.',
      );
      return null;
    }

    // EXACT CONSTRUCTOR RETENTION, derived from this release's OWN methods.
    //
    // A patch may reuse a private construction only when the released version
    // of that same method already performed it, so the release has to retain
    // exactly those constructors — no more, and not by hand. Deriving it here
    // is what makes it product behaviour instead of a step in a qualification
    // notebook.
    //
    // The measurement comes from the ANALYZER, in census mode, because the
    // analyzer already computes it for the patch path. The interface generator
    // does not read bodies at all, and teaching it to would put a second
    // definition of "what does this method construct" in the tree, free to
    // drift from the one that admits patches.
    //
    // A cell whose analyzer predates this reports nothing, the grant list is
    // empty, and the release is exactly what it was before: narrower, not
    // broken.
    final constructorGrants = _deriveConstructorGrants(
      compiler: compiler,
      prepassKernel: prepassKernel,
      packageName: packageName,
      workingDirectory: outputFile.parent,
      run: run,
    );

    List<String> arguments({required bool withPlatform}) => [
      compiler.interfaceGenerator.path,
      '--dill',
      prepassKernel.path,
      '--out',
      outputFile.path,
      // The app's own libraries, whole. Everything outside this prefix is the
      // framework and the SDK, handled by the named-member list below.
      '--include',
      ...routeBAppIncludePrefixes(packageName),
      // PRIVATE ENUMERATION SOURCE, and it is a correctness choice before it is
      // a breadth one.
      //
      // Without this the private list comes from the `--aot` prepass, where TFA
      // has already tree-shaken anything unreachable -- so a private member the
      // release does not itself call cannot be named, and a patch whose purpose
      // is to start calling one fails at load. Worse, the prepass has also had
      // fields lowered into accessors, so it yields names like `get:_file` that
      // the annotator's pre-transform component does not have, which fails the
      // WHOLE interface (measured on a real app: ThrottledSaveLoadMixin).
      //
      // The caller supplies this only when the import kernel has been checked
      // against the prepass. If they disagree the caller passes null and the
      // release falls back to prepass-only enumeration -- a NARROWER release,
      // not a failed one.
      if (privateEnumerationKernel != null) ...[
        '--private-dill',
        privateEnumerationKernel.path,
        // The platform that kernel was compiled against (see _compile). Read
        // under it, the kernel's `dart:` references bind, so the generator can
        // walk it whole for the framework and SDK names app code uses, which a
        // patch resolves by name on device.
        if (withPlatform) ...[
          '--platform',
          compiler.flutterPlatformDill.path,
        ],
      ],
      // THE CHOSEN POLICY, named rather than implied. P2 retains app-private
      // members AND the private classes required to make those members
      // patch-targetable. The second half is not optional: P3 withheld it and
      // its member grants were operationally inert, because a patch cannot
      // attach to a method of a class the release did not retain.
      '--policy',
      'p2',
      // THE CAPABILITY MANIFEST, which is what the analyzer accepts against.
      // Emitted by the generator rather than derived by reading the YAML back,
      // because a `class:` item grants an implicit public constructor that
      // appears in no line of the interface -- so a reader would understate
      // what the release granted.
      if (manifestFile != null) ...[
        '--manifest',
        manifestFile.path,
      ],
      // BY NAME. The generator also accepts --sdk-libraries, which retains a
      // whole library; that was measured at +310% and is not product behaviour.
      // One at a time, spelled `library#Class.name`, exactly as the generator
      // and the capability manifest spell them.
      for (final grant in constructorGrants) ...['--grant-constructor', grant],
      '--sdk-members',
      sdkMembers.join(','),
    ];

    var result = run(
      compiler.runtime.path,
      arguments(withPlatform: privateEnumerationKernel != null),
    );
    // A cell minted before the generator took --platform rejects it as an
    // unknown argument. Its generator walks both kernels instead, which is
    // what it did before, so run it the old way rather than lose the interface.
    if (result.exitCode == 2 &&
        '${result.stderr}'.contains('unknown argument: --platform')) {
      result = run(compiler.runtime.path, arguments(withPlatform: false));
    }
    if (result.exitCode != 0 || !outputFile.existsSync()) {
      logger.warn(
        '''
Could not generate this release's retention interface (exit ${result.exitCode}); patches for it will only be able to replace bodies that name nothing.
${result.stderr}''',
      );
      return null;
    }
    return outputFile;
  }

  /// Whether [importKernel] describes the same program as [aotKernel].
  ///
  /// Forwarding the release's inputs correctly is a promise; this is the check.
  /// The analyzer reports a member present in the second kernel and absent from
  /// the first as `added`, so running it with the import kernel as the base
  /// asks exactly the right question: does the import kernel contain everything
  /// the release actually compiled?
  ///
  /// A wrong entrypoint, a wrong package config, a wrong target or a missing
  /// define all show up here, at release time, instead of as bytecode that
  /// fails to bind on someone's phone.
  ///
  /// Tree-shaking makes the reverse untrue and uninteresting: the AOT kernel is
  /// a subset, so members the import kernel has and the AOT kernel dropped are
  /// expected.
  ///
  /// Accessors are excluded, on evidence rather than to make this pass. AOT
  /// lowering materializes a field's implicit getter and setter as real
  /// procedures; a non-AOT kernel leaves them as fields, which the analyzer's
  /// walk does not visit. On the reference app that is 250 members, and **every
  /// single one** is a `get:`/`set:` — the 70 that were genuine (a missing Dart
  /// plugin registrant) were all methods, and they are what this check caught
  /// on its first real run. A whole missing library, a wrong entrypoint, a
  /// wrong package config or a wrong target all still surface here, because
  /// none of those lose only accessors. [consequence] completes the sentence a
  /// disagreement prints. It exists because this check now runs at two
  /// different points with two different outcomes: late, against the real
  /// release kernel, where disagreement means patches are refused; and early,
  /// against the prepass, where it only means private enumeration falls back to
  /// the prepass and the release is narrower. Printing "patches will be
  /// refused" for the second would be a lie that sends the reader looking for a
  /// broken release.
  bool agreesWith({
    required RouteBCompiler compiler,
    required File importKernel,
    required File aotKernel,
    String consequence = 'patches for this release will be refused',
    RouteBCoverageAnalyzer analyzer = const RouteBCoverageAnalyzer(),
  }) {
    final RouteBCoverage coverage;
    try {
      coverage = analyzer.analyze(
        compiler: compiler,
        baseDill: importKernel,
        patchedDill: aotKernel,
      );
    } on Exception catch (error) {
      logger.warn(
        '''Could not check the two release kernels against each other ($error); $consequence.''',
      );
      return false;
    }

    final missing = coverage.added.where((key) {
      // `.last` is right: an extension getter is a real procedure in both
      // kernels, so it is checked like any other name.
      final selector = key.split('#').last;
      return !selector.contains('get:') && !selector.contains('set:');
    }).toList();
    if (missing.isEmpty) return true;

    logger.warn(
      '''
The two kernels this release produced do not describe the same program: ${missing.length} member(s) the release compiled are missing from the kernel a patch would be built against, starting with ${missing.first}.

${consequence.substring(0, 1).toUpperCase()}${consequence.substring(1)}.''',
    );
    return false;
  }
}
