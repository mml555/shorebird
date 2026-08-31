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

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/route_b_abi.dart';
import 'package:shorebird_cli/src/route_b_binding.dart';
import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_container.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_super_source.dart';
import 'package:shorebird_cli/src/route_b_survival.dart';

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

/// A lowered replacement: the declaration, plus anything the library needs
/// ABOVE the entry-point pragma.
///
/// The preamble exists because the direct-super intrinsic is a second top-level
/// declaration, and only one declaration in the library may carry
/// `dyn-module:entry-point`.
class _Lowered {
  const _Lowered(this.declaration, {this.preamble = ''});

  /// The replacement declaration itself.
  final String declaration;

  /// Emitted before the entry-point pragma. Empty for almost every target.
  final String preamble;
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

  /// The generated helper a `super.member()` call is rewritten into.
  ///
  /// NOT a product surface and not reachable from user code: the producer emits
  /// both the declaration and the call, and `dart2bytecode` recognises it by
  /// the PRAGMA rather than by this name, so the spelling carries no authority.
  /// Its
  /// body throws, so a compiler that did not lower it fails loudly instead of
  /// running something plausible.
  static const _superIntrinsicName = r'$routeBSuper';

  /// The declaration, emitted only for a replacement that needs it.
  static const _superIntrinsicDeclaration = '''
@pragma('shorebird:direct-super')
Object? $_superIntrinsicName(
  Object receiver,
  String originLibrary,
  String originClass,
  String originMember,
  String originMemberKind,
  int siteOffset,
  String superMember,
  String expectedTargetFileUri,
  int expectedTargetFileOffset,
  String expectedTargetName,
  String expectedTargetKind,
) => throw StateError('Route B direct-super intrinsic was not lowered');
''';

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
  ///
  /// [releaseEvidence] is P4.4's layer 1, measured from the release the patch
  /// will be published against. When supplied, the container carries a binding
  /// naming it and one receipt per replaced member, and a shape change or an
  /// unestablished shape refuses here. Null means no binding is recorded, which
  /// only a host harness should ever want.
  ///
  /// [survival] is P4.1's gate: for every target, whether a supported
  /// invocation site SURVIVED compilation in the exact release artifact. Null
  /// means no gate was supplied, and the caller is then asserting that this
  /// prerequisite is checked elsewhere or does not apply -- the patcher passes
  /// one that answers UNKNOWN rather than omitting it, because an absent gate
  /// is indistinguishable from a gate that passed.
  Uint8List produce({
    required RouteBCompiler compiler,
    required RouteBCoverage coverage,
    required File importKernel,
    required String releaseBuildId,
    required Directory workingDirectory,
    required Directory projectRoot,
    RouteBCapabilities? capabilities,
    RouteBBuildConfig? buildConfig,
    RouteBSurvivalOracle? survival,
    RouteBReleaseEvidence? releaseEvidence,
    RouteBCompileRunner run = Process.runSync,
  }) {
    // Every changed member that can land, in a stable order so the container is
    // reproducible byte-for-byte from the same inputs.
    final selectors = [...coverage.representable, ...coverage.conditional]
      ..sort();

    // P4.1 -- ASKED ONCE, for every target, before anything is generated.
    //
    // Batched deliberately: the probe decodes a multi-megabyte profile, and a
    // per-target invocation would decode it once per target. Asked BEFORE the
    // loop so a refusal happens before any source is written, and so the
    // binding is verified once for the whole patch rather than per target.
    final survivalVerdicts = survival == null ? null : survival(selectors);

    workingDirectory.createSync(recursive: true);
    final targets = <RouteBPatchTarget>[];
    final receipts = <RouteBTargetReceipt>[];
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
      // NEVER A PLATFORM LIBRARY. The flag below is passed exactly this
      // value, and a `dart:` target would ask the front
      // end for the PLATFORM's private namespace rather than an application
      // library's — a strictly wider grant than "compile as if part of the
      // library being replaced".
      //
      // The compiler refuses this too, as of 2026-08-25 (`0005`, arm A5 of
      // `probes/p1_private_scope_controls.sh`, which found that it did NOT).
      // This guard is here anyway and deliberately: it holds on a cell built
      // before that fix, it refuses by target name instead of failing inside a
      // compile, and a patch has no business replacing a member of `dart:`
      // whatever the compiler allows.
      if (targetLibrary.startsWith('dart:')) {
        throw RouteBUnsupportedTarget(
          key,
          'targets a platform library; a patch may only replace members of the '
          'application',
        );
      }
      // An INSTANCE target is lowered: its receiver becomes an explicit first
      // parameter, which the entry-point contract allows exactly one of. A
      // static target keeps the fast path — the slice is already valid as a
      // top-level function.
      // P4.2 — THE TARGET'S OWN GRANT, checked before anything is lowered.
      //
      // Every other capability check here is about a member the replacement
      // BODY references. This one is about the member being REPLACED, and
      // without it the failure lands as far right as it can: the patch
      // publishes, the device downloads it, and the engine refuses at ATTACH
      // with a message about attachment rather than about capability.
      //
      // Only a private enclosing class is checked — a `library:` item already
      // covers a public class's public members. A top-level target has no
      // enclosing class and takes the private-member path instead.
      final selector = key.contains('#') ? key.split('#').last : '';
      final dot = selector.indexOf('.');
      if (capabilities != null && dot > 0) {
        final refusal = capabilities.refuseTarget(
          library: targetLibrary,
          className: selector.substring(0, dot),
          member: selector.substring(dot + 1),
        );
        if (refusal != null) {
          throw RouteBUnsupportedTarget(
            key,
            describeRouteBRefusal(refusal, selector),
          );
        }
      }

      // P4.1 -- THE TARGET'S CALL SITE, in the release that will receive this.
      //
      // Distinct from every capability check above, which asks what the release
      // GRANTED. This asks what the release still CONTAINS: a target whose
      // every invocation was folded away is granted, resolvable, attachable,
      // and inert. The engine reports `applied 1/1 targets` for it, so the
      // runtime cannot tell an operator what a static fact can.
      if (survivalVerdicts != null) {
        final verdict = survivalVerdicts[key];
        if (verdict == null) {
          // The oracle was asked about this key and did not answer. Not a pass.
          throw RouteBUnsupportedTarget(
            key,
            'the release probe returned no verdict for it, and an unanswered '
            'prerequisite is not a satisfied one',
          );
        }
        if (!verdict.permitsPublication) {
          throw RouteBUnsupportedTarget(
            key,
            describeRouteBSurvivalRefusal(key, verdict),
          );
        }
      }

      // P4.4 -- THE SHAPE, not just the identity.
      //
      // Every patched member "changed"; that is the point. This asks whether
      // its SIGNATURE changed, which is a different question with the opposite
      // answer: the release's compiled call sites carry the release's own
      // argument descriptor, so attaching a replacement with a different arity
      // hands them a function they cannot call correctly, and nothing after
      // publication can notice. A selector string cannot express this, which is
      // why the receipt carries the two signatures rather than a name.
      final signature = coverage.signatures[key];
      if (releaseEvidence != null) {
        if (signature == null) {
          throw RouteBUnsupportedTarget(
            key,
            '${RouteBBindingProblem.signatureNotEstablished.wire} the '
            'analysis recorded no signature for it on either side, so whether '
            'its shape changed could not be established. Not established is '
            'not unchanged',
          );
        }
        if (signature.changed) {
          throw RouteBUnsupportedTarget(
            key,
            '${RouteBBindingProblem.signatureChanged.wire} the release has '
            '${signature.release} and this patch declares '
            '${signature.patch}. A replacement must have the same shape as '
            'the member it replaces',
          );
        }
      }

      final lowering = coverage.lowering[key];
      final lowered = lowering != null
          ? _lower(key, source, lowering, capabilities)
          : _Lowered(_slice(key, source));
      final declaration = lowered.declaration;
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
      // THE TARGET LIBRARY'S OWN IMPORTS, not just the target library.
      //
      // Dart imports are NOT transitive. A body referencing anything the target
      // library IMPORTS -- `appFlavor` from package:flutter/services.dart, a
      // widget, a `jsonEncode` -- does not compile in a library that imports
      // only the target, and the failure arrives as a bare
      // "the bytecode compiler refused its replacement body (exit 254)".
      //
      // Found 2026-08-26 by the P6 flavor arm, on a body whose only unusual
      // feature was reading Flutter's `appFlavor`. P1/P2 never hit it because
      // those bodies touched only the target's own members and dart:core, which
      // is auto-imported. Almost any real patch would.
      final inherited = _inheritedImports(key, source.fileUri);
      final library = File(p.join(workingDirectory.path, 'replacement_$i.dart'))
        ..writeAsStringSync(
          '${inherited.map((d) => '$d\n').join()}'
          "import '$targetLibrary';\n\n"
          // The intrinsic declaration goes BEFORE the entry-point pragma: that
          // pragma must land on the replacement, and exactly one declaration in
          // the library may carry it.
          '${lowered.preamble}'
          '$entryPointPragma\n$declaration\n',
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
      // P4.4 layer 2. Written per target and never rolled up: the survival
      // verdict is only about the artifact it was measured on, so the digest it
      // was measured against travels WITH the verdict rather than beside it.
      if (releaseEvidence != null) {
        final dotted = selector.indexOf('.');
        receipts.add(
          RouteBTargetReceipt(
            library: targetLibrary,
            className: dotted > 0 ? selector.substring(0, dotted) : null,
            member: dotted > 0 ? selector.substring(dotted + 1) : selector,
            releaseSignature: signature?.release,
            replacementSignature: signature?.patch,
            capabilitiesConsumed: [
              for (final access in lowering?.accesses ?? const [])
                if (access.privateTarget case final t?)
                  '${t.library}#${t.className}#${t.name}',
            ],
            survivalResult:
                survivalVerdicts?[key]?.instrumentResult ?? 'NOT_ASKED',
            measuredAgainstArtifactSha256:
                releaseEvidence.releaseArtifactSha256,
          ),
        );
      }
      logger.detail('[route-b] compiled ${parts.last} -> ${payload.path}');
    }

    return writeRouteBContainer(
      releaseBuildId: releaseBuildId,
      targets: targets,
      // P4.4 layer 3, as an ADDITIVE header field under format version 1. The
      // device-side reader indexes the keys it knows and ignores the rest, so
      // this travels with the patch bytes -- covered by the container's own
      // hashing -- without needing a format bump the shipped engine would
      // refuse.
      binding: releaseEvidence == null
          ? null
          : RouteBPatchBinding(evidence: releaseEvidence, receipts: receipts),
    );
  }

  /// The import directives of the library being patched, for the replacement
  /// to reuse.
  ///
  /// Only `dart:` and `package:` imports are carried. A RELATIVE import is
  /// REFUSED rather than dropped: copied verbatim it would resolve against the
  /// replacement's own directory, and rewritten to a file URI it would make the
  /// CFE see one library twice -- once by package URI and once by file URI --
  /// whose declarations then collide. Dropping it silently would reproduce the
  /// original failure with a message about bytecode instead of about imports.
  List<String> _inheritedImports(String key, String fileUri) {
    final file = File(Uri.parse(fileUri).toFilePath());
    if (!file.existsSync()) return const [];
    final directives = <String>[];
    // Scanned rather than parsed: the producer has no analyzer, and an import
    // directive is terminated by `;`. Combinators and prefixes are carried
    // VERBATIM, because they are part of the resolution the body was written
    // against.
    for (final match in RegExp(
      r'''^\s*import\s+(['"])([^'"]+)\1[^;]*;''',
      multiLine: true,
    ).allMatches(file.readAsStringSync())) {
      final uri = match.group(2)!;
      if (uri.startsWith('dart:') || uri.startsWith('package:')) {
        directives.add(match.group(0)!.trim());
      } else {
        throw RouteBUnsupportedTarget(
          key,
          'the library it lives in has a RELATIVE import '
          '(`${match.group(0)!.trim()}`), and a replacement cannot reuse one: '
          'copied as-is it resolves against a different directory, and '
          'rewritten to a file URI it makes the compiler see that library '
          'twice. Convert it to a `package:` import and cut a new release',
        );
      }
    }
    return directives;
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
  _Lowered _lower(
    String key,
    RouteBSourceSpan span,
    RouteBLowering lowering,
    RouteBCapabilities? capabilities,
  ) {
    // ANALYSIS VERSION 10: `super.member()`, admitted from the SOURCE.
    if (lowering.unsupported.isNotEmpty) {
      // P4.3. The analyzer's wording is kept verbatim -- it is the part that
      // says which shape -- with a STABLE code in front of it. The prose may be
      // copy-edited; the code is the contract, so a caller or a test can pin the
      // boundary without pinning the sentence.
      final reason = lowering.unsupported.join('; ');
      final label = routeBAbiLabel(reason);
      throw RouteBUnsupportedTarget(
        key,
        label != null
            ? '$label $reason'
            // A shape-shaped reason this build has no name for is a MAPPING GAP,
            // not permission. It still refuses, and it says which it is, so the
            // gap cannot be mistaken for a new supported shape.
            : isRouteBAbiReason(reason)
            ? '${RouteBAbiCode.unclassified.wire}(unrecognised) $reason'
            : reason,
      );
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

    // SUPER SITES, admitted here and rewritten below.
    //
    // Three authorities, and this is the middle one. The analyzer said a
    // genuine super operation is at this offset; the SOURCE says whether it
    // was written with arguments (the AOT kernel cannot -- TFA rewrites
    // `super.tag('a', 7)` to zero arguments there, measured in
    // `super0/s2b0/`); and `dart2bytecode` re-establishes both the shape and
    // the target in its own kernel, independently of anything decided here.
    //
    // ALL OR NOTHING PER TARGET. A method with two super calls where only
    // one is supportable refuses entirely: emitting a partly-lowered body
    // would leave a `super` in a synthetic top-level function, and the
    // whole-patch rule makes one unrepresentable member reject the patch
    // anyway.
    final superEdits = <(int, int, String)>[];
    if (lowering.superInvocations.isNotEmpty) {
      final origin = lowering.origin;
      if (origin == null) {
        throw RouteBUnsupportedTarget(
          key,
          'the analyzer reported a super invocation without the origin '
          'identity the replacement compiler needs to resolve it',
        );
      }
      for (final site in lowering.superInvocations) {
        if (site.kind != 'method') {
          throw RouteBUnsupportedTarget(
            key,
            'super `${site.kind}` access to `${site.member}` is not supported',
          );
        }
        final args = routeBSuperCallArgs(
          source: source,
          offset: site.offset,
          member: site.member,
        );
        switch (args) {
          case RouteBSuperArgs.hasArguments:
            throw RouteBUnsupportedTarget(
              key,
              'super.${site.member}(…) is written with arguments, and only a '
              'zero-argument super call is supported',
            );
          case RouteBSuperArgs.unverifiable:
            // Fail-closed, and its own message: an unreadable site is not the
            // same finding as a site read and rejected.
            throw RouteBUnsupportedTarget(
              key,
              'the source shape of super.${site.member} could not be verified '
              'at offset ${site.offset}, so it is refused rather than lowered '
              'on a guess',
            );
          case RouteBSuperArgs.zeroArguments:
            break;
        }
        // NARROW-V1 COMPILED-TARGET GATE. Proven in `super0/s2b1f/`.
        //
        // A `DirectCall` needs the target to have EXECUTABLE AOT CODE, and
        // retention does not imply that: a mixin-application member can be
        // retained by name, resolve fine, and abort the app at
        // `compiler.cc:1152: Attempt to compile function …` because AOT
        // emitted no code for it (`super0/s2b1e/`).
        //
        // There is no general way to ask whether a function was compiled. What
        // there is, is one causal chain: the RELEASE version of THIS method
        // direct-called the target, so AOT had to compile it. So the evidence
        // is same-method and the comparison is on the target's PROVENANCE,
        // never on the call site — the site moves when the patch edits it,
        // which `super0/s2b1f/` control 1 measures (988 -> 1005, same target).
        //
        // An ordinary superclass target that the release never super-called
        // would in fact work (`super0/s2b1d/` arm D). It is refused anyway:
        // this gate carries evidence, not inferences from class shape. A
        // needless
        // refusal is a cost; an abort inside a user's app is not acceptable.
        final target = site.target;
        if (target == null) {
          throw RouteBUnsupportedTarget(
            key,
            'the analyzer reported super.${site.member}() with no resolved '
            'target, so there is no evidence the release compiled one',
          );
        }
        if (!lowering.releaseSuperTargets.contains(target)) {
          throw RouteBUnsupportedTarget(
            key,
            'super.${site.member}() resolves to a target this release never '
            'direct-called from `${origin.member}`, so there is no evidence it '
            'has executable code in the release. Route B carries a super call '
            'only when the released version of the same method already made '
            'one to the same target',
          );
        }

        final callSpan = routeBSuperCallSpan(
          source: source,
          offset: site.offset,
          member: site.member,
        );
        if (callSpan == null || callSpan.start < span.start ||
            callSpan.end > span.end) {
          throw RouteBUnsupportedTarget(
            key,
            'the super.${site.member}() call at offset ${site.offset} is not '
            'inside the declaration being replaced',
          );
        }
        superEdits.add((
          callSpan.start,
          callSpan.end - callSpan.start,
          // ORIGIN IDENTITY, verbatim from the analyzer. `originMemberKind`
          // travels because a class may hold a method, a getter and a setter of
          // one name, and the compiler resolves on name AND kind.
          // The ANALYZER's resolved target travels with the site, so the
          // compiler can prove it arrived at the same declaration
          // independently. Provenance only: no canonical owner, no arity.
          '$_superIntrinsicName('
              '@RECEIVER@, '
              "'${origin.library}', "
              "'${origin.className}', "
              "'${origin.member}', "
              "'${origin.memberKind}', "
              '${site.offset}, '
              "'${site.member}', "
              "'${target.fileUri}', "
              '${target.fileOffset}, '
              "'${target.name}', "
              "'${target.kind}') as dynamic",
        ));
      }
    }

    // CAPTURE-AVOIDING RECEIVER NAME (D-HYGIENE). The declaration below is
    // copied verbatim into a new lexical scope that also holds the receiver
    // parameter this producer generates. If the author's own source already
    // binds that name — a local, a closure parameter, the target's own
    // parameter — every inserted receiver reference resolves to THEIR binding
    // instead of the receiver, and the result compiles, packs into a container
    // and executes with different semantics. Measured, not supposed:
    // `selfhost/engine/route_b/coverage/hygiene/RESULT.md`, four of five
    // controls accepted and wrong.
    //
    // So the name is allocated to be fresh with respect to every byte being
    // copied, before any edit is computed.
    final receiverName = _freshReceiverName(
      source.substring(span.start, span.end),
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
    // The super rewrites were collected before the receiver name existed, since
    // the name depends on the whole declaration's text -- including the `super`
    // calls. Substituted now rather than re-scanning.
    for (final (offset, length, text) in superEdits) {
      edits.add((offset, length, text.replaceAll('@RECEIVER@', receiverName)));
    }

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
    edits.add((open + 1, 0, '$receiverType $receiverName$separator'));

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
        edits.add((start, explicit.length, '$receiverName.'));
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
      // A SIMPLE `$identifier` INTERPOLATION NEEDS BRACES, and getting this
      // wrong is invisible until a user reads the screen.
      //
      // Inserting a bare prefix here yields `'$self._field'`, which Dart parses
      // as "interpolate `self`, then the literal text `._field`" -- so the
      // receiver's toString() is rendered followed by the member name. It
      // compiles, attaches, executes, and renders
      //
      //   NEW-Instance of '_FooState'._field-...
      //
      // which is exactly what shipped to a device on 2026-08-25. Nothing failed
      // anywhere; only reading the screen caught it. See
      // selfhost/fixtures/privatestate_app/evidence/VERDICT.md.
      //
      // `${...}` was always safe, which is why one of three accesses in that
      // specimen worked. So the fix is to rewrite `$NAME` as `${self.NAME}`
      // rather than to refuse: `'$_count'` is an everyday Flutter spelling and
      // refusing it would cost more reach than the bug costs.
      final dollar = access.offset - 1;
      if (dollar >= span.start && source[dollar] == r'$') {
        // A `$$` escape is not an interpolation. Refuse rather than reason about
        // it -- it cannot appear in a receiver access this analyzer reported, so
        // reaching here means the two disagree.
        if (dollar - 1 >= span.start && source[dollar - 1] == r'$') {
          throw RouteBUnsupportedTarget(
            key,
            'reads `${access.member}` inside an escaped `\$\$` sequence, which '
            'this lowering will not rewrite',
          );
        }
        // Replace `$NAME` with `${self.NAME}`: one edit, spanning the `$` and the
        // identifier, so nothing after the identifier is touched.
        edits.add((
          dollar,
          1 + access.member.length,
          '\${$receiverName.${access.member}}',
        ));
        continue;
      }
      edits.add((access.offset, 0, '$receiverName.'));
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
    return _Lowered(
      text,
      preamble: superEdits.isEmpty ? '' : '$_superIntrinsicDeclaration\n',
    );
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
  /// A receiver parameter name that does not occur anywhere in [declaration].
  ///
  /// D-HYGIENE. The producer copies the author's declaration verbatim into a
  /// scope that also holds a receiver parameter it invents, then inserts
  /// references to that parameter at offsets inside the copied text. That is
  /// only sound if the invented name is FRESH with respect to the text being
  /// copied. It was not: `self` was hardcoded, and four of five hygiene
  /// controls produced accepted, compiling, publishable replacements whose
  /// inserted receiver references bound to the author's own `self`.
  ///
  /// The test is deliberately a plain substring scan of the whole declaration,
  /// comments and string literals included, and it is not a scope model. It
  /// over-triggers: a method mentioning "self" in a comment, or named
  /// `selfTest`, gets a generated name it did not need. **That direction is
  /// free.** The other direction is a patch that runs and means something else,
  /// so the scan must not be narrowed to "real" bindings — deciding which
  /// occurrences bind is exactly the scope analysis this repair avoids.
  ///
  /// `self` is kept when it is provably absent, so every target that lowers
  /// correctly today keeps producing byte-identical source and bytecode. Only a
  /// declaration that could collide pays anything.
  ///
  /// NOT private. A `_`-prefixed generated name would be caught by
  /// [_privateIdentifiers] below — the backstop that refuses any private
  /// identifier the release did not grant — and closing the hole by carving
  /// an exemption into a safety check is how safety checks stop working. The
  /// property that matters is freshness, not the spelling.
  @visibleForTesting
  static String freshReceiverNameForTesting(String declaration) =>
      _freshReceiverName(declaration);

  static String _freshReceiverName(String declaration) {
    if (!declaration.contains(_defaultReceiverName)) {
      return _defaultReceiverName;
    }
    // Unbounded on purpose. Each iteration rules out one more spelling, and a
    // declaration can only contain finitely many, so this terminates. A capped
    // loop would need an answer for "what if the cap is reached", and the only
    // safe answer is to refuse — which is a failure mode invented by the cap.
    for (var i = 0; ; i++) {
      final candidate = 'shorebirdReceiver$i';
      if (!declaration.contains(candidate)) return candidate;
    }
  }

  /// Kept when the declaration provably cannot capture it, so already-proven
  /// targets lower to byte-identical source.
  static const _defaultReceiverName = 'self';

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
