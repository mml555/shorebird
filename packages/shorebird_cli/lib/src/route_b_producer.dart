// cspell:words ungated
//
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
// That covers the shape proven on hardware: a self-contained declaration, and
// an instance member lowered so its receiver is an explicit parameter.
//
// A PRIVATE NAME is now carried, under two conditions that are checked here and
// nowhere else:
//
//   1 the release's own capability manifest granted that exact member, and the
//     private class enclosing it (see route_b_capabilities.dart); and
//   2 every private identifier in the emitted declaration is one of those
//     granted accesses.
//
// The second condition exists because `--resolve-private-names-in-library`
// makes EVERY private name in the replacement resolvable, not only the ones the
// analyzer classified. Without it, a private name the gate never saw would
// compile and then fail to bind on a device -- the exact silent failure this
// path is organised against. So an unrecognized private identifier refuses the
// target by name.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/route_b_capabilities.dart';
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

/// Whether [declaration] reads the compile-time environment directly.
///
/// The three `fromEnvironment` constructors are the ONLY expressions whose value
/// comes from the `-D` flags handed to the replacement compiler. Anything else a
/// replacement references — including the app's own `const` declarations —
/// resolves through the import kernel, which carries the release's real values.
///
/// Deliberately a TEXTUAL check and deliberately conservative: it fires on the
/// constructor name wherever it appears, so a replacement that merely mentions
/// it in a comment is refused too. That is the safe direction for a check whose
/// false negative is a silently wrong constant and whose false positive is a
/// named refusal the user can act on.
bool _readsCompileTimeEnvironment(String declaration) =>
    declaration.contains('String.fromEnvironment') ||
    declaration.contains('int.fromEnvironment') ||
    declaration.contains('bool.fromEnvironment');

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
  ///
  /// [capabilities] is the release's own capability manifest. Null means the
  /// release published none, which is not permission: a private reference is
  /// then refused for want of evidence.
  Uint8List produce({
    required RouteBCompiler compiler,
    required RouteBCoverage coverage,
    required File importKernel,
    required String releaseBuildId,
    required Directory workingDirectory,
    required Directory projectRoot,
    RouteBCapabilities? capabilities,
    RouteBBuildConfig? buildConfig,
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
      final lowering = coverage.lowering[key];
      final declaration = lowering != null
          ? _lower(key, source, lowering, capabilities)
          : _slice(key, source);
      // G4.1c link 2, the LEGACY case. A release cut before injected defines
      // were recorded cannot be given them retroactively — the values came from
      // a build that is over — so a replacement compiled against it would bake
      // Dart's DEFAULT for any injected define it reads, while the release around
      // it holds Flutter's real value. Both are literals by then, so nothing
      // downstream can notice.
      //
      // REFUSED NARROWLY, and the narrowness is a mechanism argument rather than
      // a kindness: a replacement that reads the app's own const resolves it
      // through the IMPORT KERNEL, which does carry the injected defines since
      // G4.1c. The only expression that compiles against these `-D` flags is a
      // `String.fromEnvironment` (or its int/bool siblings) written in the
      // replacement source ITSELF. So refusing every patch to a pre-record
      // release would strand releases that have a perfectly correct answer —
      // release 95 and every one before it — to protect against a construct
      // almost none of them contain.
      if (_readsCompileTimeEnvironment(declaration) &&
          buildConfig != null &&
          !buildConfig.recordsInjectedDefines) {
        throw RouteBUnsupportedTarget(
          key,
          'its replacement reads the compile-time environment, and this release '
          'predates the record of the defines Flutter injected into it. The '
          'replacement would compile against a default value while the release '
          'holds a different one, and nothing downstream could detect it. Cut a '
          'new release with a current CLI and patch that instead',
        );
      }
      // ONLY WHERE A GRANTED PRIVATE REFERENCE IS ACTUALLY CARRIED. The flag
      // changes how the whole compile resolves private names, so it is not free
      // to pass everywhere: a target that needs nothing private compiles under
      // exactly the rules already proven on device, and an older cell that does
      // not know the flag keeps working for those targets.
      final resolvesPrivateNames =
          lowering?.accesses.any((a) => a.privateTarget != null) ?? false;
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
        // G4.1: THE RELEASE'S DEFINES, threaded into the replacement's own
        // compilation. `const String.fromEnvironment` resolves at compile time, so
        // without these a replacement reading a define would silently bake in the
        // DEFAULT while the release around it holds the real value -- a divergence
        // no runtime check can see, because both are literals by then.
        //
        // Emitted in sorted key order because order is not semantic (measured by
        // probes/g41_define_semantics.sh), which also makes the recorded compile
        // command reproducible.
        //
        // The patcher has already refused a mismatch before reaching here, so these
        // are the release's values and the patch's values at once.
        ...?buildConfig?.compilerArgs,
        // The CFE resolves the replacement's private names AS IF it were the
        // target library, which is what makes `self._controller` mean the app's
        // member rather than an unresolvable name in a synthetic library.
        // Rung D proved this on host; the release must still have retained the
        // member, which is what the manifest gate above establishes.
        if (resolvesPrivateNames) ...[
          '--resolve-private-names-in-library',
          targetLibrary,
        ],
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
  String _lower(
    String key,
    RouteBSourceSpan span,
    RouteBLowering lowering,
    RouteBCapabilities? capabilities,
  ) {
    if (lowering.unsupported.isNotEmpty) {
      throw RouteBUnsupportedTarget(key, lowering.unsupported.join('; '));
    }

    // WHAT THE RELEASE ACTUALLY GRANTED, asked per access. The analyzer reports
    // a private access with the key the release would have had to grant; it
    // does not decide, because the manifest is a per-release artifact and the
    // analyzer ships in a cell resolved by engine hash.
    //
    // Checked BEFORE any edit is computed, so a refused patch never produces a
    // half-lowered source file for someone to find later and wonder about.
    for (final access in lowering.accesses) {
      final target = access.privateTarget;
      if (target == null) continue;
      if (capabilities == null) {
        // No manifest is not permission. A release built before the manifest
        // existed granted nothing provable, and guessing on its behalf is the
        // failure this whole path is organised against: it would compile and
        // then throw NoSuchMethodError on a device.
        throw RouteBUnsupportedTarget(
          key,
          'references the private member `${access.member}`, and this release '
          'published no capability manifest — so there is no evidence it was '
          'retained. Re-release with a toolchain that records one.',
        );
      }
      final refusal = capabilities.refuseInstanceMember(
        library: target.library,
        className: target.className,
        member: target.name,
      );
      if (refusal != null) {
        throw RouteBUnsupportedTarget(
          key,
          describeRouteBRefusal(refusal, access.member),
        );
      }
    }

    // Code units, not bytes: the analyzer's offsets index the decoded source.
    final source = utf8.decode(
      File.fromUri(Uri.parse(span.fileUri)).readAsBytesSync(),
    );

    // ONE EDIT PER OFFSET. `label += 'X'` reports a read and a write at the same
    // identifier, and two insertions there would produce `self.self.label`. The
    // analyzer refuses that, so reaching here means the two disagree — which is
    // exactly when a silent wrong edit is most likely.
    final seen = <int>{};
    for (final access in lowering.accesses) {
      if (!seen.add(access.offset)) {
        throw RouteBUnsupportedTarget(
          key,
          'uses `${access.member}` twice at one position, which cannot be '
          'rewritten as a single edit',
        );
      }
    }

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
    if (close < 0) {
      throw RouteBUnsupportedTarget(
        key,
        'its parameter list is not closed',
      );
    }
    // G3.7: the target's OWN parameters stay, and the receiver goes in FRONT of
    // them. The existing list is copied verbatim -- exactly as the argument list
    // of a call is copied verbatim -- so nothing here reconstructs Dart syntax:
    // no types are parsed, no defaults are interpreted, no names are rewritten.
    //
    // The analyzer refuses named parameters, optional positionals and generics,
    // matching the compiler contract clause for clause, so a non-empty list
    // reaching this point is a list of required positionals. A separator is
    // needed only when there is something to separate from.
    final existingParams = source.substring(open + 1, close).trim();
    final separator = existingParams.isEmpty ? '' : ', ';
    // A PRIVATE receiver class cannot be WRITTEN here at all. Dart privacy is
    // library-scoped and the replacement is its own library, so `_FooState self`
    // resolves to nothing and the compile fails with "Type not found" -- after
    // the analyzer already said `accept`, because the analyzer reports the class
    // name without asking whether a foreign library could name it.
    //
    // `dynamic` sidesteps the question rather than answering it: the front end
    // accepts any member name on a dynamic receiver with no privacy test, so the
    // private class name never has to appear. The cost is that every access on
    // `self` becomes a dynamic call resolved by name at run time instead of an
    // interface call resolved at compile time.
    //
    // Only for a private class. A public receiver keeps its concrete type, so
    // every spelling already proven on device lowers to byte-identical source.
    //
    // `dynamic` alone does NOT make private MEMBERS reachable: `self._x` would
    // compile and then fail at run time, because the module's library key is
    // not the app's. What closes that is `--resolve-private-names-in-library`
    // (G3.6e), passed above only for a target whose private accesses the
    // release manifest granted. Two separate mechanisms, both required:
    // `dynamic` lets the private class go unnamed, the flag makes the private
    // MEMBER mean the app's. See PARITY.md §3, `G3.6c`/`G3.6e`/`G3.6b`.
    final receiverType = lowering.receiverType.startsWith('_')
        ? 'dynamic'
        : lowering.receiverType;
    edits.add((open + 1, 0, '$receiverType self$separator'));

    for (final access in lowering.accesses) {
      // The edit below inserts or replaces a receiver prefix immediately before
      // the identifier, which suits a read and a zero-argument call alike. A
      // kind added later may not work that way, so refuse rather than guess --
      // the analyzer and the producer are versioned together for this reason,
      // and this is the backstop when that pairing is somehow wrong.
      if (!const {'get', 'set', 'invoke'}.contains(access.kind)) {
        throw RouteBUnsupportedTarget(
          key,
          'uses the receiver in a way this lowering does not know how to '
          'rewrite (`${access.kind}` on `${access.member}`)',
        );
      }
      // The argument list, if any, is not touched: the edit below inserts or
      // replaces a prefix immediately BEFORE the identifier, and everything
      // after it is the source's own text. `helper('x')`, `helper(a, b: 1)`,
      // `helper<T>(x)` all come across unchanged, and a receiver use inside the
      // arguments is its own reported access -- `helper(label)` becomes
      // `self.helper(self.label)` because both offsets are rewritten.
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

    // THE BACKSTOP FOR THE COMPILER FLAG. Every private access above was
    // checked against the release's manifest, but the flag that makes them
    // resolvable is not per-access: it applies to the whole compile. So a
    // private name of any other shape -- a private TYPE in the signature, a
    // private top-level function, a private static, a private local -- would
    // also resolve, ungated, and fail on the device instead of here.
    //
    // Checked on the emitted text rather than by enumerating Kernel node kinds,
    // because the text is what the compiler will read and there is no long tail
    // of node types to keep in step. Unrecognized means REFUSED, so a shape
    // nobody has thought of yet is loud rather than plausible.
    final granted = {
      for (final a in lowering.accesses)
        if (a.privateTarget != null) a.member,
    };
    // The declaration's own name may be private -- patching `_helper` is
    // ordinary -- and it is a declaration here, not a reference.
    final own = key.split('#').last.split('.').last;
    for (final name in _privateIdentifiers(text)) {
      if (granted.contains(name) || name == own) continue;
      throw RouteBUnsupportedTarget(
        key,
        'its body names `$name`, a private identifier this analysis did not '
        'resolve to a member the release granted. Private references are '
        'carried only when the release manifest shows the exact member was '
        'retained.',
      );
    }
    return text;
  }

  /// Every private identifier in [text] that could be a reference.
  ///
  /// Comments are dropped: a private name in a doc comment is not a reference,
  /// and `/// Reads [_controller].` must not refuse a patch.
  ///
  /// A string literal is dropped ONLY if it cannot interpolate. `'a_b'` is
  /// text; `'${_controller}'` is a reference, and masking it would hide the one
  /// thing this scan exists to catch. A raw string is kept for the same reason
  /// in reverse -- it cannot interpolate, but keeping it only ever refuses,
  /// which is the safe direction.
  static Set<String> _privateIdentifiers(String text) {
    final code = StringBuffer();
    var i = 0;
    while (i < text.length) {
      if (text.startsWith('//', i)) {
        while (i < text.length && text[i] != '\n') {
          i++;
        }
        continue;
      }
      if (text.startsWith('/*', i)) {
        // Dart block comments nest, so a depth count is not paranoia.
        var depth = 1;
        i += 2;
        while (i < text.length && depth > 0) {
          if (text.startsWith('/*', i)) {
            depth++;
            i += 2;
          } else if (text.startsWith('*/', i)) {
            depth--;
            i += 2;
          } else {
            i++;
          }
        }
        continue;
      }
      final c = text[i];
      if (c == "'" || c == '"') {
        final delim = text.startsWith(c * 3, i) ? c * 3 : c;
        var j = i + delim.length;
        final content = StringBuffer();
        while (j < text.length && !text.startsWith(delim, j)) {
          if (text[j] == r'\') {
            j += 2;
            continue;
          }
          content.write(text[j]);
          j++;
        }
        i = j < text.length ? j + delim.length : text.length;
        if (content.toString().contains(r'$')) code.write(content);
        continue;
      }
      code.write(c);
      i++;
    }
    return _privateIdentifier
        .allMatches(code.toString())
        .map((m) => m[0]!)
        // `_` and `__` are wildcard parameters, not names.
        .where((n) => n.replaceAll('_', '').isNotEmpty)
        .toSet();
  }

  /// A private identifier, anchored so `my_var` does not read as `_var`.
  static final _privateIdentifier = RegExp(
    r'(?<![A-Za-z0-9_$])_[A-Za-z0-9_$]*',
  );

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
