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

      final targetLibrary = key.split('#').first;
      // An INSTANCE target is lowered: its receiver becomes an explicit first
      // parameter, which the entry-point contract allows exactly one of. A
      // static target keeps the fast path — the slice is already valid as a
      // top-level function.
      final declaration = coverage.lowering.containsKey(key)
          ? _lower(key, source, coverage.lowering[key]!)
          : _slice(key, source);
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

  /// The declaration, rewritten so the receiver is an explicit parameter.
  ///
  /// KERNEL DECIDED MEANING; this only supplies syntax. Every offset comes from
  /// the analyzer, which resolved each access against the program — a local
  /// named `label`, a top-level `label`, and a static `Cls.label` are different
  /// Kernel nodes and never appear here, so no name resolution is re-derived.
  ///
  /// Two spellings reach this, and they are the SAME Kernel node:
  ///
  ///     String value() => label;         ->  insert `self.` before `label`
  ///     String value() => this.label;    ->  replace `this.` with `self.`
  ///
  /// Which one it is can only be answered from the source text, because the
  /// synthesized `ThisExpression` carries the access's own offset rather than
  /// one of its own.
  String _lower(String key, RouteBSourceSpan span, RouteBLowering lowering) {
    if (lowering.unsupported.isNotEmpty) {
      throw RouteBUnsupportedTarget(key, lowering.unsupported.join('; '));
    }

    // Code units, not bytes: the analyzer's offsets index the decoded source.
    final source = utf8.decode(
      File.fromUri(Uri.parse(span.fileUri)).readAsBytesSync(),
    );

    // (offset, replacedLength, text), applied right-to-left so earlier offsets
    // stay valid.
    final edits = <(int, int, String)>[];

    // The receiver parameter goes into the method's own parameter list, found
    // by scanning from the NAME — an annotation's parentheses come earlier and
    // would otherwise match first.
    final open = source.indexOf('(', lowering.nameOffset);
    if (open < 0 || open >= span.end) {
      throw RouteBUnsupportedTarget(
        key,
        'its parameter list could not be found',
      );
    }
    final close = source.indexOf(')', open);
    if (close < 0 || source.substring(open + 1, close).trim().isNotEmpty) {
      // The analyzer already refuses methods with parameters; this catches a
      // disagreement between the two rather than silently producing a method
      // with two.
      throw RouteBUnsupportedTarget(
        key,
        'its parameter list is not empty, which the lowering cannot extend',
      );
    }
    edits.add((open + 1, 0, '${lowering.receiverType} self'));

    for (final access in lowering.accesses) {
      const explicit = 'this.';
      final start = access.offset - explicit.length;
      if (start >= span.start &&
          start < source.length &&
          source.substring(start, access.offset) == explicit) {
        edits.add((start, explicit.length, 'self.'));
        continue;
      }
      // `this` written with unusual spacing (`this . label`) would otherwise be
      // rewritten to `this .self.label`. Refuse rather than guess: it is rare,
      // and a wrong lowering compiles and then misbehaves on a device.
      var back = access.offset - 1;
      while (back >= 0 &&
          (source[back] == ' ' ||
              source[back] == '\n' ||
              source[back] == '\r' ||
              source[back] == '\t')) {
        back--;
      }
      if (back >= 0 && source[back] == '.') {
        throw RouteBUnsupportedTarget(
          key,
          'reads `${access.member}` through a receiver this lowering cannot '
          'rewrite safely',
        );
      }
      edits.add((access.offset, 0, 'self.'));
    }

    edits.sort((a, b) => b.$1.compareTo(a.$1));
    var text = source.substring(span.start, span.end);
    for (final (offset, length, replacement) in edits) {
      final at = offset - span.start;
      text = text.replaceRange(at, at + length, replacement);
    }
    return text;
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
