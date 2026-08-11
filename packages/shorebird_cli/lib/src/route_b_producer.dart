// Route B (selfhost): turning an accepted coverage verdict into a container.
//
// ONE TARGET, ONE PAYLOAD. Not a design preference — the runtime contract.
// `Dart_RouteBActivatePatch` does:
//
//     loaded = loader.LoadBytecode();        // ONE Function from the payload
//     target.AttachBytecode(loaded.GetBytecode());
//
// so a payload carrying a whole program has nothing to select from. Two other
// shapes were measured and rejected: compiling the patched app's own entrypoint
// against `--import-dill` crashes on the library collision
// (`kernel_generator_impl.dart:179`), and compiling it under an aliased package
// name compiles but still loads as a single function. The synthetic
// single-function library is the shape the device gate already proved.
//
// WHAT THIS DOES AND DOES NOT SUPPORT
//
// It emits, per changed target, a replacement library holding exactly that
// declaration, sliced from the patch's own source at the span the analyzer
// reports, and compiled against the release's import kernel.
//
// That covers the shape proven on hardware: a self-contained declaration. It
// does NOT yet cover a body that references other app symbols, an instance
// member (which cannot be redeclared in another library), or a private name
// (`_foo` is library-scoped identity, not spelling). Those are runtime and
// compiler-contract questions to be probed on device, in that order, and until
// they are answered this refuses by name rather than emitting something
// plausible.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_container.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';

/// A reference to a [RouteBProducer] instance.
final routeBProducerRef = create(RouteBProducer.new);

/// The [RouteBProducer] available in the current zone.
RouteBProducer get routeBProducer => read(routeBProducerRef);

/// Runs the cell's bytecode compiler.
typedef RouteBCompileRunner =
    ProcessResult Function(String executable, List<String> arguments);

/// A target the producer cannot turn into a payload, and why.
class RouteBUnsupportedTarget implements Exception {
  /// {@macro route_b_unsupported_target}
  RouteBUnsupportedTarget(this.target, this.reason);

  /// `library#selector`.
  final String target;

  /// Why, in the same voice as the coverage rejection reasons.
  final String reason;

  @override
  String toString() => '$target: $reason';
}

/// {@template route_b_producer}
/// Compiles replacement bodies and packs them into an SBRBPTCH container.
/// {@endtemplate}
class RouteBProducer {
  /// {@macro route_b_producer}
  const RouteBProducer();

  /// The annotation that makes a declaration loadable as a dynamic module
  /// entry point, which is how an attached function is entered.
  static const entryPointPragma = "@pragma('dyn-module:entry-point')";

  /// Produces the container for [coverage] against the release identified by
  /// [releaseBuildId].
  ///
  /// [workingDirectory] receives the generated sources and payloads; they are
  /// kept rather than cleaned so a failed patch can be inspected.
  Uint8List produce({
    required RouteBCompiler compiler,
    required RouteBCoverage coverage,
    required File importKernel,
    required String releaseBuildId,
    required Directory workingDirectory,
    required Directory projectRoot,
    RouteBCompileRunner run = Process.runSync,
  }) {
    // Every changed member that can land, in a stable order so the container is
    // reproducible byte-for-byte from the same inputs.
    final selectors = [...coverage.representable, ...coverage.conditional]
      ..sort();

    workingDirectory.createSync(recursive: true);
    final targets = <RouteBPatchTarget>[];
    for (var i = 0; i < selectors.length; i++) {
      final key = selectors[i];
      final source = coverage.sources[key];
      if (source == null) {
        throw RouteBUnsupportedTarget(
          key,
          'the analysis reports no source span for it, so its replacement '
          'body cannot be isolated',
        );
      }

      final declaration = _slice(key, source);
      final targetLibrary = key.split('#').first;
      // IMPORT THE TARGET'S OWN LIBRARY. A replacement body may reference other
      // members of the library it replaces a function in, and a synthetic
      // library that imports nothing cannot see them:
      //
      //   Error: Method not found: 'routeBHelper'
      //
      // The local declaration shadows the imported one of the same name, so
      // importing the library the target lives in is safe as well as necessary.
      final library = File(p.join(workingDirectory.path, 'replacement_$i.dart'))
        ..writeAsStringSync(
          "import '$targetLibrary';\n\n$entryPointPragma\n$declaration\n",
        );
      final payload = File(
        p.join(workingDirectory.path, 'replacement_$i.bytecode'),
      );

      final result = run(compiler.runtime.path, [
        compiler.compilerSnapshot.path,
        // The FLUTTER platform and the RELEASE's import kernel. Both from the
        // cell resolved by the release's engine hash, so the bytecode is bound
        // against the program that actually shipped.
        '--platform',
        compiler.flutterPlatformDill.path,
        '--target',
        'flutter',
        '--import-dill',
        importKernel.path,
        // Needed for the `import` above to resolve a package: URI.
        '--packages',
        p.join(projectRoot.path, '.dart_tool', 'package_config.json'),
        '-o',
        payload.path,
        library.path,
      ]);
      if (result.exitCode != 0 || !payload.existsSync()) {
        // Deliberately distinct from a coverage rejection: coverage said this
        // target CAN be carried, so a failure here is the compiler's, and
        // conflating the two sends someone to change their Dart when the
        // problem is the toolchain.
        throw RouteBUnsupportedTarget(
          key,
          'the bytecode compiler refused its replacement body '
          '(exit ${result.exitCode})\n${result.stderr}',
        );
      }

      final parts = key.split('#');
      targets.add(
        RouteBPatchTarget(
          library: parts.first,
          selector: parts.last,
          bytecode: payload.readAsBytesSync(),
        ),
      );
      logger.detail('[route-b] compiled ${parts.last} -> ${payload.path}');
    }

    return writeRouteBContainer(
      releaseBuildId: releaseBuildId,
      targets: targets,
    );
  }

  /// The declaration's source text, from the patch's own file.
  String _slice(String key, RouteBSourceSpan span) {
    final file = File.fromUri(Uri.parse(span.fileUri));
    if (!file.existsSync()) {
      throw RouteBUnsupportedTarget(
        key,
        'its source file ${span.fileUri} is not on disk',
      );
    }
    // CODE UNITS, not bytes. The kernel's offsets index the DECODED source, so
    // byte-slicing drifts by (utf8 length - code-unit length) of everything
    // before the declaration. Measured on the fixture: three non-ASCII
    // characters in the comments above `routeBValue` put the slice 6 bytes
    // early, which produced a replacement library starting mid-word ("dart.")
    // and truncated before its closing `;`. dart2bytecode then refused it with
    // exit 254 and no stderr — a failure that says nothing about its cause.
    final source = utf8.decode(file.readAsBytesSync());
    if (span.end > source.length || span.start < 0) {
      throw RouteBUnsupportedTarget(
        key,
        'its recorded source span runs past the end of ${span.fileUri}',
      );
    }
    return source.substring(span.start, span.end);
  }
}
