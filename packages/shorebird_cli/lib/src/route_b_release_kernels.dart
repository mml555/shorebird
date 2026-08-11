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
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';

/// A reference to a [RouteBReleaseKernelBuilder] instance.
final routeBReleaseKernelBuilderRef = create(RouteBReleaseKernelBuilder.new);

/// The [RouteBReleaseKernelBuilder] available in the current zone.
RouteBReleaseKernelBuilder get routeBReleaseKernelBuilder =>
    read(routeBReleaseKernelBuilderRef);

/// Runs the cell's frontend.
typedef RouteBKernelRunner =
    ProcessResult Function(String executable, List<String> arguments);

/// Build options that change kernel semantics and cannot be forwarded to
/// `gen_kernel` faithfully.
///
/// `--dart-define-from-file` is the one that matters: Flutter parses `.json`
/// and `.env` shapes with its own rules, and reimplementing that parsing to
/// expand it into `-D` flags would be exactly the hand-reconstruction this
/// avoids. A release using it stays a perfectly good release — it simply
/// cannot be patched, and the patch side says so by name.
const routeBUnforwardableOptions = ['--dart-define-from-file'];

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
  static List<String>? forwardedArgs(List<String> buildArgs) {
    final forwarded = <String>[];
    for (final arg in buildArgs) {
      final unforwardable = routeBUnforwardableOptions.any(
        (option) => arg == option || arg.startsWith('$option='),
      );
      if (unforwardable) return null;

      // Flutter spells these --dart-define=K=V; gen_kernel spells them -DK=V.
      // Same values, same order, one translation in one place.
      if (arg.startsWith('--dart-define=')) {
        forwarded.add('-D${arg.substring('--dart-define='.length)}');
      } else if (arg.startsWith('--enable-experiment=')) {
        forwarded.add(arg);
      }
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
    RouteBKernelRunner run = Process.runSync,
  }) {
    final extraArgs = forwardedArgs(buildArgs);
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
      // The only intentional difference from the release's own compilation.
      '--no-aot',
      '--no-link-platform',
      '--packages',
      packageConfig.path,
      ...registrantArgs,
      ...extraArgs,
      '-o',
      outputFile.path,
      // Absolute. Flutter's --target is relative to the project root, but
      // gen_kernel resolves a relative path against the CWD, which is wherever
      // `shorebird release` was invoked from. Left relative it reports
      // "No 'main' method found", which reads like a broken app.
      p.isAbsolute(entrypoint)
          ? entrypoint
          : p.join(projectRoot.path, entrypoint),
    ]);

    if (result.exitCode != 0 || !outputFile.existsSync()) {
      logger.warn(
        '''Could not compile the kernel a patch would be built against (exit ${result.exitCode}); patches for this release will be refused.
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
  /// walk does not visit. On the reference app that is 250 members, and
  /// **every single one** is a `get:`/`set:` — the 70 that were genuine (a
  /// missing Dart plugin registrant) were all methods, and they are what this
  /// check caught on its first real run. A whole missing library, a wrong
  /// entrypoint, a wrong package config or a wrong target all still surface
  /// here, because none of those lose only accessors.
  bool agreesWith({
    required RouteBCompiler compiler,
    required File importKernel,
    required File aotKernel,
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
        '''Could not check the two release kernels against each other ($error); patches for this release will be refused.''',
      );
      return false;
    }

    final missing = coverage.added.where((key) {
      final selector = key.split('#').last;
      return !selector.contains('get:') && !selector.contains('set:');
    }).toList();
    if (missing.isEmpty) return true;

    logger.warn(
      '''The two kernels this release produced do not describe the same program: ${missing.length} member(s) the release compiled are missing from the kernel a patch would be built against, starting with ${missing.first}.

Patches for this release will be refused.''',
    );
    return false;
  }
}
