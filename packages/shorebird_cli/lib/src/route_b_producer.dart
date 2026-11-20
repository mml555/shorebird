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
import 'package:shorebird_cli/src/route_b_abi.dart';
import 'package:shorebird_cli/src/route_b_binding.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_container.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_retention.dart';
import 'package:shorebird_cli/src/route_b_super_source.dart';
import 'package:shorebird_cli/src/route_b_survival.dart';

/// A reference to a [RouteBProducer] instance.
final routeBProducerRef = create(RouteBProducer.new);

/// The [RouteBProducer] available in the current zone.
RouteBProducer get routeBProducer => read(routeBProducerRef);

/// Runs the cell's bytecode compiler.
typedef RouteBCompileRunner =
    ProcessResult Function(
      String executable,
      List<String> arguments,
    );

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
  const _Lowered(
    this.declaration, {
    this.preamble = '',
    this.needsSuperVerification = false,
    this.grantedStatics = const {},
  });

  /// Private statics of the member's own class that the body spells and the
  /// manifest grants; they are why the compile resolves private names.
  final Set<String> grantedStatics;

  /// The replacement declaration itself.
  final String declaration;

  /// Emitted before the entry-point pragma. Empty for almost every target.
  final String preamble;

  /// Whether this replacement lowers a `super.` call, and therefore needs the
  /// patched verification kernel at compile time.
  final bool needsSuperVerification;
}

/// Whether [declaration] reads the compile-time environment directly.
///
/// The three `fromEnvironment` constructors are the ONLY expressions whose
/// value comes from the `-D` flags handed to the replacement compiler. Anything
/// else a replacement references — including the app's own `const` declarations
/// — resolves through the import kernel, which carries the release's real
/// values.
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

/// The part of [key] after its library: `Cls.m`, `X|s`, `X|get#g`, `get:t`.
/// Library URIs carry no `#`, so the first one splits.
String _selectorOf(String key) => key.substring(key.indexOf('#') + 1);

/// The member's own name: after the `.` of a class key, or after the `|` of an
/// extension key, without a `get:`/`set:` or `get#`/`set#` marker.
String _memberNameOf(String key) {
  final selector = _selectorOf(key);
  final bar = selector.indexOf('|');
  final raw = bar >= 0 ? selector.substring(bar + 1) : selector.split('.').last;
  return raw.replaceFirst(RegExp('^[gs]et[:#]'), '');
}

/// Why a top-level or static target's `declaration` cannot be an entry point,
/// or null when it can.
///
/// The compiler takes an entry point whose parameters are all required
/// positionals and which has no type parameters (patch 0006). Anything else
/// used to reach `dart2bytecode` and come back as a raw front-end stack trace
/// that names nothing the developer wrote. This reads the declaration's own
/// text, which is all a top-level target's coverage carries, and says nothing
/// when it cannot find the declaration (the compiler then speaks for itself).
String? routeBEntryShapeProblem(String key, String rawDeclaration) {
  // Comments, string literals and annotations are not the signature, and an
  // earlier one that holds `f(` or an apostrophe must not be read as it.
  final declaration = _codeOnly(rawDeclaration);
  final selector = _selectorOf(key);
  if (selector.startsWith('get:') || selector.startsWith('set:')) return null;
  final name = selector.split('.').last;
  if (name.isEmpty) return null;
  final match = RegExp(
    '(?<![\\w\$.])${RegExp.escape(name)}\\s*([<(])',
  ).firstMatch(declaration);
  if (match == null) return null;
  const tail =
      'A replacement is an entry point, which takes only required positional '
      'parameters and no type parameters. Cut a new release that contains '
      'this change, then patch that';
  if (match.group(1) == '<') {
    return 'it is a generic function (`$name<...>`). $tail';
  }
  var depth = 0;
  var atStart = true;
  String? quote;
  for (var i = match.end - 1; i < declaration.length; i++) {
    final c = declaration[i];
    if (quote != null) {
      // A one-character backslash literal reads better escaped than raw.
      // A one-character backslash literal reads better escaped than raw.
      // ignore: use_raw_strings
      if (c == '\\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      atStart = false;
      continue;
    }
    if (c == '(' || c == '[' || c == '{') {
      if (depth == 1 && atStart && c != '(') {
        return 'its signature has '
            '${c == '{' ? 'named' : 'optional positional'} parameters. $tail';
      }
      depth++;
      atStart = depth == 1;
      continue;
    }
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) return null;
      continue;
    }
    if (depth == 1) {
      if (c == ',') {
        atStart = true;
      } else if (c.trim().isNotEmpty) {
        atStart = false;
      }
    }
  }
  return null;
}

/// [source] with comments and annotations removed and every string literal
/// reduced to `''`, so that a scan for a signature sees only code.
///
/// Not a Dart parser: it knows line and (nested) block comments, single,
/// double and triple quoted strings, raw strings, `\` escapes and `${}`
/// interpolation, which is what can hide a quote, a bracket or a name.
String _codeOnly(String source) {
  final out = StringBuffer();
  var i = 0;
  bool isWord(String c) => RegExp(r'[\w$]').hasMatch(c);
  while (i < source.length) {
    final c = source[i];
    if (source.startsWith('//', i)) {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (source.startsWith('/*', i)) {
      var depth = 0;
      while (i < source.length) {
        if (source.startsWith('/*', i)) {
          depth++;
          i += 2;
        } else if (source.startsWith('*/', i)) {
          depth--;
          i += 2;
          if (depth == 0) break;
        } else {
          i++;
        }
      }
      out.write(' ');
      continue;
    }
    final raw =
        c == 'r' &&
        i + 1 < source.length &&
        (source[i + 1] == "'" || source[i + 1] == '"') &&
        (i == 0 || !isWord(source[i - 1]));
    if (c == "'" || c == '"' || raw) {
      i = _skipString(source, raw ? i + 1 : i, raw: raw);
      out.write("''");
      continue;
    }
    if (c == '@' && i + 1 < source.length && isWord(source[i + 1])) {
      i++;
      while (i < source.length && (isWord(source[i]) || source[i] == '.')) {
        i++;
      }
      var j = i;
      while (j < source.length && source[j].trim().isEmpty) {
        j++;
      }
      if (j < source.length && source[j] == '(') {
        var depth = 0;
        for (; j < source.length; j++) {
          final d = source[j];
          if (d == "'" || d == '"') {
            j = _skipString(source, j, raw: false) - 1;
          } else if (d == '(') {
            depth++;
          } else if (d == ')' && --depth == 0) {
            j++;
            break;
          }
        }
        i = j;
      }
      out.write(' ');
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// The index just past the string literal that opens at [start].
int _skipString(String s, int start, {required bool raw}) {
  final q = s[start];
  final triple = s.startsWith(q * 3, start);
  var i = start + (triple ? 3 : 1);
  while (i < s.length) {
    final c = s[i];
    // A one-character backslash literal reads better escaped than raw.
    // ignore: use_raw_strings
    if (!raw && c == '\\') {
      i += 2;
      continue;
    }
    if (!raw && c == r'$' && i + 1 < s.length && s[i + 1] == '{') {
      var depth = 0;
      for (; i < s.length; i++) {
        final d = s[i];
        if (d == "'" || d == '"') {
          i = _skipString(s, i, raw: false) - 1;
        } else if (d == '{') {
          depth++;
        } else if (d == '}' && --depth == 0) {
          i++;
          break;
        }
      }
      continue;
    }
    if (triple ? s.startsWith(q * 3, i) : c == q) {
      return i + (triple ? 3 : 1);
    }
    if (!triple && c == '\n') return i;
    i++;
  }
  return s.length;
}

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
  ///
  /// The receiver is `dynamic`, not `Object`. The compiler requires the
  /// receiver argument to be exactly the entry point's parameter 0, and any
  /// implicit cast around it breaks that. When a private receiver class was
  /// written `dynamic self`, an `Object` parameter wrapped it in `self as
  /// Object`, and every `super` call in a private class -- every State's
  /// `initState` and `dispose` -- was refused on the iPhone (exit 255,
  /// "receiver is not parameter 0 of the entry point"). The receiver is now
  /// typed with its own class, which an `Object` parameter would take as a
  /// plain upcast; `dynamic` stays because it takes any spelling with no cast.
  static const _superIntrinsicDeclaration =
      '''
@pragma('shorebird:direct-super')
Object? $_superIntrinsicName(
  dynamic receiver,
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
  /// [retention] is what the release's dynamic interface kept, and it is asked
  /// about every external symbol the analysis (version 18 or later) says a
  /// target, or a helper it needs, names. Null means the release has no
  /// readable interface, which refuses such an analysis rather than waving it
  /// through: a symbol that cannot be shown to be kept is not kept. An earlier
  /// analysis lists no symbols, so there is nothing to ask and nothing changes
  /// for a release whose compiler cell predates it.
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
    required File releaseImportKernel,
    required String releaseBuildId,
    required Directory workingDirectory,
    required Directory projectRoot,
    RouteBCapabilities? capabilities,
    RouteBBuildConfig? buildConfig,
    RouteBSurvivalOracle? survival,
    RouteBReleaseEvidence? releaseEvidence,
    RouteBCompileRunner run = Process.runSync,
    File? patchedVerificationKernel,
    RouteBRetention? retention,
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
    final selectorSet = selectors.toSet();

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
      final selector = key.contains('#') ? _selectorOf(key) : '';
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
        // A COPY OF IT ELSEWHERE. Code that inlined the target, or folded
        // its result, runs the release's body without a call site; replacing
        // that code too is what makes the edit run on every path. The rule is
        // routeBCompanionsFor, shared with the loop that carries them.
        final companions = routeBCompanionsFor(
          verdict,
          callers: coverage.releaseCallersOf(key),
        );
        if (companions == null) {
          throw RouteBUnsupportedTarget(
            key,
            describeRouteBSurvivalRefusal(key, verdict),
          );
        }
        final missing = companions.difference(selectorSet).toList()..sort();
        if (missing.isNotEmpty) {
          throw RouteBUnsupportedTarget(
            key,
            describeRouteBMissingCompanions(
              missing,
              canCarry: coverage.canCarry,
            ),
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

      // RETENTION -- did the release KEEP everything this body names? Asked
      // before anything is lowered or compiled: the compiler would happily
      // compile a name the release's snapshot lacks, and the bytecode loader
      // would then abort the process on it. The helpers this target needs are
      // part of its replacement library, so what they name counts here too.
      if (coverage.externalReferences != null) {
        final unkept = retention == null
            ? routeBNoInterfaceReason
            : retention.refusalForTarget(coverage, key);
        if (unkept != null) throw RouteBUnsupportedTarget(key, unkept);
      }

      final lowering = coverage.lowering[key];
      // An entry point the compiler cannot take is refused HERE, in words,
      // rather than by dart2bytecode with a stack trace. A lowered target was
      // already checked by the analyzer (it refuses named parameters, optional
      // positionals and generics for those); a top-level or static target was
      // not, and reaches the compiler as written.
      if (lowering == null) {
        // An extension instance member takes its receiver first. Carried as
        // written it would be a top-level function of one parameter fewer than
        // the `Ext|get#x(#this)` it replaces, so a missing lowering is a
        // refusal, never a fall-through.
        if (_scopeOf(key, coverage)?.extensionInstance ?? false) {
          throw RouteBUnsupportedTarget(
            key,
            'it is an instance member of an extension, and the analysis '
            'reported no lowering for it',
          );
        }
        if (routeBEntryShapeProblem(key, _slice(key, source))
            case final problem?) {
          throw RouteBUnsupportedTarget(key, problem);
        }
      }
      final lowered = lowering != null
          ? _lower(
              key,
              source,
              lowering,
              capabilities,
              compiler,
              patchedVerificationKernel,
              _helperNamesCalledBy(key, coverage),
              _scopeOf(key, coverage),
            )
          : _Lowered(
              topLevelForm(
                _qualifiedStaticSlice(key, source, _scopeOf(key, coverage)),
              ),
            );
      // HELPERS this target transitively needs, as source, after the entry.
      final neededHelpers = _neededHelpers(key, coverage);
      // The lowering of each needed INSTANCE helper (analysis version 17): it
      // is compiled in this replacement, so what it reaches counts here.
      final helperLowerings = [
        for (final h in neededHelpers)
          if (coverage.lowering[h] case final RouteBLowering l) l,
      ];
      // Whether this target compiles with private names resolved against the
      // release's library; see where `--resolve-private-names-in-library` is
      // passed. A PRIVATE RECEIVER CLASS is a private reference too: the
      // receiver parameter is written with its class's own name (see the
      // lowering), and `_FooState` is spelled in the replacement only if the
      // front end resolves it in the target library.
      final resolvesBeforeHelpers =
          [?lowering, ...helperLowerings].any(
            (l) =>
                l.accesses.any((a) => a.privateTarget != null) ||
                (l.privateConstructions?.isNotEmpty ?? false) ||
                l.receiverType.startsWith('_'),
          ) ||
          // A static target of a private class that now names its class to
          // qualify a static (`_Cls.k`) spells a private name too.
          _qualifiesPrivateClass(_scopeOf(key, coverage)) ||
          // A granted private static of the member's own class (lowered
          // targets only; see `_ownStaticGranted`). Not widened for a static
          // target, whose body has no private-name scan.
          lowered.grantedStatics.isNotEmpty ||
          // G5. A PRIVATE TOP-LEVEL FUNCTION the release holds (`_fmt(x)`)
          // is a private name of the target's library, and the replacement
          // library cannot spell it without the flag:
          //
          //   Error: Method not found: '_fmt'.
          //
          // `_namesGrantedPrivateTopLevel` switches the resolution on only when
          // the target names such a function and the release manifest lists
          // it. The flag then lets every private name of the library
          // resolve, not just that one; the private-name backstop in `_lower`
          // is what refuses an ungranted private name in a lowered target.
          _namesGrantedPrivateTopLevel(coverage, [
            key,
            ...neededHelpers,
          ], capabilities);
      // The granted private statics of the instance helpers, which are
      // compiled in this replacement and so need the flag like the entry's.
      final helperGrantedStatics = <String>{};
      final helperText = _helperSources(
        key,
        neededHelpers,
        coverage,
        capabilities,
        compiler,
        patchedVerificationKernel,
        resolvesPrivateNames: resolvesBeforeHelpers,
        grantedStatics: helperGrantedStatics,
      );
      // Instance helpers exist only from analysis version 17, which is also
      // where `_helperSources` stops refusing on this flag, so deciding it
      // after the helpers are lowered changes no refusal there.
      final resolvesPrivateNames =
          resolvesBeforeHelpers || helperGrantedStatics.isNotEmpty;
      // A target with no lowering (a static or top-level one) has no private-
      // name backstop of its own, and with private names resolved against the
      // release library every private name in its body would resolve. Scan it
      // whenever the final flag is on, whatever turned it on.
      if (lowering == null && resolvesPrivateNames) {
        _refuseUngrantedPrivateNames(
          key,
          _slice(key, source),
          _scopeOf(key, coverage),
          {
            ..._helperNamesCalledBy(key, coverage),
            ..._grantedPrivateTopLevelNames(coverage, [
              key,
              ...neededHelpers,
            ], capabilities),
          },
          capabilities,
        );
      }
      // THE ENTRY HIDES WHATEVER OF ITS OWN NAME THE HELPERS MEAN. A class or
      // extension member becomes a top-level function of the same name in the
      // replacement, and a declaration there shadows a top-level of the
      // library, an imported function or class, or a type of that name. Every
      // helper the
      // replacement carries was written against the library, so one that
      // spells that name would now reach the entry. Judged on the helpers'
      // text, wherever the name could come from; a helper that merely names
      // the member is refused too, which is the safe direction.
      if (lowered.declaration.isNotEmpty &&
          (_selectorOf(key).contains('.') || _selectorOf(key).contains('|')) &&
          helperText.isNotEmpty) {
        final entryName = _helperName(key);
        // `$name` is an interpolation of it, so only a word character before
        // or after ends a match. A `$` inside the name is part of it, and a
        // neighbouring one only over-refuses. An operator has no such
        // spelling.
        final escaped = RegExp.escape(entryName);
        final hides = RegExp('(?<!\\w)$escaped(?!\\w)');
        if (RegExp(r'^[\w$]+$').hasMatch(entryName) &&
            hides.hasMatch(helperText)) {
          throw RouteBUnsupportedTarget(
            key,
            'its replacement is a top-level function named `$entryName`, '
            'which hides anything of that name the new functions this patch '
            'carries mean, and they spell it. Rename one of them',
          );
        }
      }
      final declaration = lowered.declaration;
      // G4.1c link 2, the LEGACY case. A release cut before injected defines
      // were recorded cannot be given them retroactively — the values came from
      // a build that is over — so a replacement compiled against it would bake
      // Dart's DEFAULT for any injected define it reads, while the release
      // around it holds Flutter's real value. Both are literals by then, so
      // nothing downstream can notice.
      //
      // REFUSED NARROWLY, and the narrowness is a mechanism argument rather
      // than a kindness: a replacement that reads the app's own const resolves
      // it through the IMPORT KERNEL, which does carry the injected defines
      // since G4.1c. The only expression that compiles against these `-D` flags
      // is a `String.fromEnvironment` (or its int/bool siblings) written in the
      // replacement source ITSELF. So refusing every patch to a pre-record
      // release would strand releases that have a perfectly correct answer —
      // release 95 and every one before it — to protect against a construct
      // almost none of them contain.
      if (_readsCompileTimeEnvironment('$declaration\n$helperText') &&
          buildConfig != null &&
          !buildConfig.recordsInjectedDefines) {
        throw RouteBUnsupportedTarget(
          key,
          'its replacement reads the compile-time environment, and this '
          'release predates the record of the defines Flutter injected into '
          'it. The replacement would compile against a default value while '
          'the release holds a different one, and nothing downstream could '
          'detect it. Cut a new release with a current CLI and patch that '
          'instead',
        );
      }
      // ONLY WHERE A GRANTED PRIVATE REFERENCE IS ACTUALLY CARRIED. The flag
      // changes how the whole compile resolves private names, so it is not free
      // to pass everywhere: a target that needs nothing private compiles under
      // exactly the rules already proven on device, and an older cell that does
      // not know the flag keeps working for those targets.
      //
      // A private CONSTRUCTION is a private reference too. `_Boxed(x)` names a
      // class private to the target library, and the replacement is compiled as
      // a separate synthetic library, so without this flag the CFE cannot see
      // the name at all:
      //
      //   Error: Method not found: '_Boxed'.
      //
      // Retention and the manifest grant make the constructor EXIST and be
      // CALLABLE in the shipped program; they do nothing about whether the
      // replacement library may SPELL it. Those are separate problems, and this
      // gate only ever solved the second for member accesses. Found by Gate 6F,
      // the first positive private-construction patch to reach the compiler:
      // exit 254 with the grant for `_Boxed.new` present in the manifest.
      //
      // Not a broadening of the admission rule. Admission -- same-method
      // release evidence AND a manifest grant, per construction -- has already
      // run and refused the whole patch before this point (Gate 6E). This
      // decides only how a body that was already admitted gets spelled.
      //
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
          '$entryPointPragma\n$declaration\n'
          // Helpers never carry the entry-point pragma: exactly one
          // declaration in the library may.
          '$helperText',
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
        // BINDING. The RELEASE's kernel, always: this is the shipped program
        // the whole replacement resolves against, which is why it is not
        // swapped for the patched one when a super call is present.
        '--import-dill',
        releaseImportKernel.path,
        // VERIFICATION ONLY, and only when a super call is being lowered. Never
        // merged into the binding universe by the compiler; it exists so the
        // patched BODY can be checked against itself rather than against a
        // different source version (2B.1c-SITE).
        if (lowered.needsSuperVerification) ...[
          '--patched-verification-dill',
          patchedVerificationKernel!.path,
        ],
        // G4.1: THE RELEASE'S DEFINES, threaded into the replacement's own
        // compilation. `const String.fromEnvironment` resolves at compile time,
        // so without these a replacement reading a define would silently bake
        // in the DEFAULT while the release around it holds the real value -- a
        // divergence no runtime check can see, because both are literals by
        // then.
        //
        // Emitted in sorted key order because order is not semantic (measured
        // by probes/g41_define_semantics.sh), which also makes the recorded
        // compile command reproducible.
        //
        // The patcher has already refused a mismatch before reaching here, so
        // these are the release's values and the patch's values at once.
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
        // BOTH STREAMS. dart2bytecode prints front-end diagnostics -- the
        // `Error: ...` lines that say what is wrong with the body -- to
        // STDOUT, and only crashes reach stderr. Showing stderr alone left a
        // bare exit code for every ordinary compile error.
        final output = [
          '${result.stdout}'.trim(),
          '${result.stderr}'.trim(),
        ].where((s) => s.isNotEmpty).join('\n');
        throw RouteBUnsupportedTarget(
          key,
          'the bytecode compiler refused its replacement body '
          '(exit ${result.exitCode})${output.isEmpty ? '' : '\n$output'}',
        );
      }

      // FAIL-CLOSED CHECK OF THE `inlined` CLAIM, against what was compiled.
      //
      // The analysis marks an SDK operator `inlined` (an opcode, no lookup) by
      // predicting what dart2bytecode does with the PATCHED kernel. The
      // compiler is fed something else: this producer's lowered form, where an
      // operand's static type can differ in a way no list of rewrites is sure
      // to cover (`super` becomes `as dynamic`, an omitted override type, ...).
      // So correctness must not rest on that prediction: the compiled payload
      // is
      // read, and a flag survives only where it holds no call by that name. A
      // payload that cannot be read drops every flag, which is the normal check
      // (a refusal, unless the device list or the release's own snapshot vouch
      // for the member).
      if (retention != null &&
          _hasInlinedReference(coverage, [key, ...neededHelpers])) {
        final calls = _selectorsCalledByName(compiler, payload, run);
        final unkept = retention.refusalForTarget(
          coverage,
          key,
          inlinedHolds: (r) => calls != null && !calls.contains(r.member),
        );
        if (unkept != null) {
          final why = calls == null
              ? 'could not be read to check it'
              : 'still looks it up by name';
          throw RouteBUnsupportedTarget(
            key,
            '$unkept. The analysis expected the compiler to turn it into an '
            'opcode, but the compiled replacement $why',
          );
        }
      }

      // The selector is everything after the FIRST `#`: an extension getter's
      // VM name is `Ext|get#name`, and its last `#`-part, `name`, is not a
      // function of the library (the device refused it as target-missing).
      targets.add(
        RouteBPatchTarget(
          library: targetLibrary,
          selector: _selectorOf(key),
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
            capabilitiesConsumed: {
              for (final access in [
                ...?lowering?.accesses,
                for (final l in helperLowerings) ...l.accesses,
              ])
                if (access.privateTarget case final t?)
                  '${t.library}#${t.className}#${t.name}',
            }.toList(),
            survivalResult:
                survivalVerdicts?[key]?.instrumentResult ?? 'NOT_ASKED',
            measuredAgainstArtifactSha256:
                releaseEvidence.releaseArtifactSha256,
          ),
        );
      }
      logger.detail(
        '[route-b] compiled ${_selectorOf(key)} -> ${payload.path}',
      );
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

  /// The helpers `key` reaches: named by its body, or by a helper that is, per
  /// the analysis' `callers`.
  /// Whether any of [keys] names a private top-level member of its own
  /// library that the release's manifest lists in `privateTopLevelCallable`.
  ///
  /// Only the manifest can say so: no manifest, no switch, and retention has
  /// already refused the reference by then.
  static bool _namesGrantedPrivateTopLevel(
    RouteBCoverage coverage,
    Iterable<String> keys,
    RouteBCapabilities? capabilities,
  ) => _grantedPrivateTopLevelNames(coverage, keys, capabilities).isNotEmpty;

  /// The private top-level names [keys] reach that the manifest grants.
  static Set<String> _grantedPrivateTopLevelNames(
    RouteBCoverage coverage,
    Iterable<String> keys,
    RouteBCapabilities? capabilities,
  ) {
    if (capabilities == null) return const {};
    final references = coverage.externalReferences;
    if (references == null) return const {};
    return {
      for (final k in keys)
        for (final r in references[k] ?? const <RouteBExternalReference>[])
          if (r.kind == 'top-level' &&
              r.isPrivate &&
              !r.viaConstant &&
              r.member != null &&
              capabilities.topLevelCallable.contains(
                '${r.library}#${r.member}',
              ))
            r.member!,
    };
  }

  Set<String> _neededHelpers(String key, RouteBCoverage coverage) =>
      coverage.helpersNeededBy(key);

  /// A helper's simple name: `lib#_f` and `lib#Cls._f` are both `_f`. The last
  /// `.` splits the class from the member because a class name cannot contain
  /// one; the analysis proves the name is unique in its library, so a text
  /// match on it can only mean the helper.
  static String _helperName(String key) => _memberNameOf(key);

  /// The names of the helpers [key] calls. They are declared in the
  /// replacement library itself, not the release's, so the private-name
  /// backstop does not apply to them; `_helperSources` decides whether a
  /// private one may ship.
  Set<String> _helperNamesCalledBy(String key, RouteBCoverage coverage) => {
    for (final helper in coverage.helpers)
      if (coverage.callers?[helper]?.contains(key) ?? false)
        _helperName(helper),
  };

  /// The source of every helper in [needed], for appending to a replacement
  /// library, in sorted order so the output is reproducible.
  ///
  /// A helper is a function the patch adds (analysis version 16, and from 17 an
  /// instance method of an existing class). The release has no such function,
  /// so a replacement can only call it if the library carries its source. Each
  /// replacement gets its own copy, so two targets using one helper do not
  /// share it (a tear-off of it is not identical across them).
  ///
  /// A top-level helper is copied as written. An INSTANCE helper is lowered
  /// exactly as an instance target is (`_lower`): a top-level function whose
  /// first parameter is the receiver, with its receiver accesses rewritten, its
  /// private accesses checked against the release's manifest and its
  /// unsupported shapes refused. Its callers pass the receiver (see
  /// `helperCall` in `_lower`).
  ///
  /// PRIVATE NAMES. A target that reaches release-private members compiles
  /// with `--resolve-private-names-in-library`, so private names resolve as if
  /// in the release's library. Measured on host (probes/added_method.sh,
  /// `st_*` arms): a new private method on a private class, and a new private
  /// top-level function, still bind to the replacement's own declaration, and
  /// naming an ungranted release-private member from a helper is refused here.
  /// So a private helper is allowed; what its text may name is limited to the
  /// other helpers this patch carries, and for an instance helper also the
  /// private accesses its own lowering reported and the manifest granted. A
  /// helper named like a top-level declaration of its library is refused by
  /// the analysis. A top-level helper's text may name no other private
  /// identifier: a dynamic `d._secret` would compile and fail on the device.
  String _helperSources(
    String key,
    Set<String> needed,
    RouteBCoverage coverage,
    RouteBCapabilities? capabilities,
    RouteBCompiler compiler,
    File? patchedVerificationKernel, {
    required bool resolvesPrivateNames,
    required Set<String> grantedStatics,
  }) {
    final buffer = StringBuffer();
    for (final helper in needed.toList()..sort()) {
      final span = coverage.sources[helper];
      if (span == null) {
        throw RouteBUnsupportedTarget(
          key,
          'it needs the new function `${_helperName(helper)}`, and the '
          'analysis reports no source span for it',
        );
      }
      final text = _slice(key, span);
      final name = _helperName(helper);
      // Its own annotations are copied with it, and exactly one declaration in
      // the library may be the entry point.
      if (text.contains('dyn-module:entry-point')) {
        throw RouteBUnsupportedTarget(
          key,
          'it needs the new function `$name`, which is annotated as a dynamic '
          "module entry point; only the patch's replacement may be one",
        );
      }
      if (_selectorOf(helper).contains('.')) {
        final lowered = _lowerInstanceHelper(
          key,
          helper,
          coverage,
          capabilities,
          compiler,
          patchedVerificationKernel,
        );
        grantedStatics.addAll(lowered.grantedStatics);
        buffer
          ..writeln()
          ..writeln(lowered.declaration);
        continue;
      }
      // Before analysis version 17 nothing showed that a private name binds
      // to the helper when private names resolve against the release's
      // library, so a version 16 document keeps rung 1's refusal. From 17 the
      // analysis proves a helper's private name is unique in its library.
      if (resolvesPrivateNames &&
          coverage.analysisVersion < routeBInstanceHelpersAnalysisVersion) {
        if (name.replaceFirst(RegExp('^[gs]et:'), '').startsWith('_') ||
            _privateIdentifiers(text).isNotEmpty) {
          throw RouteBUnsupportedTarget(
            key,
            'it needs the new function `$name`, which names a private '
            'identifier, and this target is compiled with private names '
            "resolved against the release's library because it reaches a "
            'private member of the release. A private name could then bind to '
            'a member the release never granted. Make the helper public and '
            'free of private names',
          );
        }
      }
      // Private names in a helper must be helpers the library carries. Any
      // other one is a release-private name or a local: the first cannot bind
      // in the replacement library (a dynamic `d._secret` would compile and
      // fail on the device), and the second is refused with it rather than
      // told apart from it.
      // Only the helpers THIS helper calls (and itself, for recursion): a
      // helper of another library, or one it does not call, is not in scope
      // here, so a private name equal to its name means some other member.
      final carried = {
        ..._helperNamesCalledBy(helper, coverage),
        _helperName(helper),
      };
      for (final private in _privateIdentifiers(text)) {
        if (carried.contains(private)) continue;
        throw RouteBUnsupportedTarget(
          key,
          'it needs the new function `$name`, which names `$private`, a '
          'private identifier that is not a new function this patch carries. '
          'A new function may name private members only if they are other new '
          'functions',
        );
      }
      buffer
        ..writeln()
        ..writeln(text);
    }
    return buffer.toString();
  }

  /// The top-level function an instance helper becomes; see `_helperSources`.
  _Lowered _lowerInstanceHelper(
    String key,
    String helper,
    RouteBCoverage coverage,
    RouteBCapabilities? capabilities,
    RouteBCompiler compiler,
    File? patchedVerificationKernel,
  ) {
    final name = _selectorOf(helper);
    Never refuse(String why) => throw RouteBUnsupportedTarget(
      key,
      'it needs the new method `$name`, which $why',
    );
    if (coverage.analysisVersion < routeBInstanceHelpersAnalysisVersion) {
      refuse('this analysis predates instance helpers');
    }
    final lowering = coverage.lowering[helper];
    if (lowering == null) {
      refuse('the analysis gives no lowering for, so it cannot be carried');
    }
    if (lowering.superInvocations.isNotEmpty) {
      refuse('calls `super`, which a new method has no release version of');
    }
    try {
      return _lower(
        helper,
        coverage.sources[helper]!,
        lowering,
        capabilities,
        compiler,
        patchedVerificationKernel,
        _helperNamesCalledBy(helper, coverage),
        _scopeOf(helper, coverage),
      );
    } on RouteBUnsupportedTarget catch (e) {
      // The reason is the lowering's own, with the helper named in front.
      refuse('cannot be lowered: ${e.reason}');
    }
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
    RouteBCompiler compiler,
    File? patchedVerificationKernel,
    Set<String> helperNames,
    RouteBEnclosingScope? scope,
  ) {
    // ANALYSIS VERSION 10: `super.member()`, admitted from the SOURCE.
    if (lowering.unsupported.isNotEmpty) {
      // P4.3. The analyzer's wording is kept verbatim -- it is the part that
      // says which shape -- with a STABLE code in front of it. The prose may be
      // copy-edited; the code is the contract, so a caller or a test can pin
      // the boundary without pinning the sentence.
      final reason = lowering.unsupported.join('; ');
      final label = routeBAbiLabel(reason);
      throw RouteBUnsupportedTarget(
        key,
        label != null
            ? '$label $reason'
            // A shape-shaped reason this build has no name for is a MAPPING
            // GAP, not permission. It still refuses, and it says which it is,
            // so the gap cannot be mistaken for a new supported shape.
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

    // AND THE CALLER MUST HAVE SUPPLIED THE PATCHED BODY TO VERIFY AGAINST.
    //
    // Null is correct for an ordinary patch and an error here: without it the
    // compiler would have nothing to check the patched site against, and the
    // only other kernel available is the release's — the exact substitution
    // 2B.1c-SITE showed producing silent wrong semantics.
    if (lowering.superInvocations.isNotEmpty &&
        patchedVerificationKernel == null) {
      throw RouteBUnsupportedTarget(
        key,
        'a `super.` call was admitted but no patched verification kernel was '
        'supplied, so the patched call site cannot be verified',
      );
    }

    // THE CELL MUST BE ABLE TO COMPILE WHAT THIS ADMITS.
    //
    // Checked before any super work, and fail-closed: analysis v11 describes
    // super sites, and a cell whose dart2bytecode predates 0017 would take the
    // intrinsic and either not recognise it (the throwing body runs) or verify
    // it against the wrong body. The capability is asked of the compiler
    // binary, not read from a metadata line.
    if (lowering.superInvocations.isNotEmpty &&
        !compiler.supportsDirectSuperDualKernel) {
      throw RouteBUnsupportedTarget(
        key,
        'this release resolves a compiler cell that does not implement '
        'routeBDirectSuperDualKernelV1, so a `super.` call cannot be carried. '
        'Cut a new release with a current engine and patch that instead',
      );
    }

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
        // ABSENT evidence and EMPTY evidence both refuse, and must say
        // different things. "The analyzer did not look" sends a reader at the
        // release pipeline; "the release called nothing" sends them at the
        // patch. Reporting the second when the first is true would send them
        // to the wrong place with confident wording.
        final releaseTargets = lowering.releaseSuperTargets;
        if (releaseTargets == null) {
          throw RouteBUnsupportedTarget(
            key,
            'the analyzer did not measure what the release version of '
            '`${origin.member}` direct-called, so there is no evidence either '
            'way for super.${site.member}(). This is a missing measurement, '
            'not a negative result',
          );
        }
        if (!releaseTargets.contains(target)) {
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
        if (callSpan == null ||
            callSpan.start < span.start ||
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
          // PARENTHESISED: `as` binds looser than `+`, so a bare
          // `1 + $routeBSuper(...) as dynamic` casts the whole sum and does not
          // compile (`Object?` is not a `num`).
          '($_superIntrinsicName('
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
              "'${target.kind}') as dynamic)",
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

    // ONE EDIT PER OFFSET. `label += 'X'`, `count++` and `maybe ??= 'Z'`
    // report a read AND a write at the same identifier, because one token does
    // both. One receiver prefix there is the whole rewrite --
    // `self.label += 'X'` reads and writes the same member the original did --
    // while two insertions would produce `self.self.label`. So a position
    // carrying exactly one read and one write of ONE member gets one edit.
    // Anything else sharing a position -- a third access, two reads, two
    // members -- means the analyzer and this producer disagree about the
    // source, which is exactly when a silent wrong edit is likeliest.
    final edited = <int, RouteBReceiverAccess>{};
    final paired = <int>{};
    for (final access in lowering.accesses) {
      final first = edited[access.offset];
      if (first == null) {
        edited[access.offset] = access;
        continue;
      }
      const readWrite = {'get', 'set'};
      if (!paired.add(access.offset) ||
          first.member != access.member ||
          first.kind == access.kind ||
          !readWrite.contains(first.kind) ||
          !readWrite.contains(access.kind)) {
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

    // THE RECEIVER KEEPS ITS CLASS'S OWN TYPE, private or not.
    //
    // A private class is written by name too: `_FooState self`. The replacement
    // is its own library, so that name resolves only because
    // `--resolve-private-names-in-library` is passed for a private receiver
    // (see `resolvesPrivateNames`), the same front-end scope that makes
    // `self._x` mean the app's member.
    //
    // This used to lower a private receiver to `dynamic`, which made every
    // access on `self` a DYNAMIC call. The AOT runtime refuses a dynamic call
    // to any member the release did not mark dynamically callable, and a
    // release marks almost nothing that way, so on a device a patched
    // `initState` calling `_start()` died with "Class '_HomeState' has no
    // instance method '_start'" (1.0.0+8, patch 3). The dynamic type also
    // spread: `self._count + 1` was a dynamic `+` on an int, refused the same
    // way. In Flutter that was most patches, because a State class is private
    // by convention.
    //
    // Typed, the front end resolves every access statically, exactly as it did
    // when the body was compiled inside the class: an interface call bound to
    // the release member, with no dynamic-call check at run time. The class
    // itself always exists in the release, because the target being replaced
    // is one of its members.
    //
    // Inserted as a PLACEHOLDER and substituted only after the private-name
    // backstop below has scanned the text. Granting the class name to the
    // backstop instead would admit it at every position, so `_FooState()`, a
    // tear-off or a static on the class would pass ungated. The placeholder
    // cannot match a private identifier (`_TYPE` follows a letter).
    final receiverParameter = '$_receiverTypePlaceholder $receiverName';
    // An INSTANCE MEMBER OF AN EXTENSION (analysis version 22) is lowered like
    // a class member: Kernel already makes it a static procedure whose first
    // parameter is the receiver, so the replacement is `Ret name(OnType self,
    // ...)`. What differs is the key's shape, the spelling of a sibling call
    // (an explicit `Ext(self).sibling`) and the bare receiver.
    final extensionName = lowering.extensionName;
    if (extensionName == null && _selectorOf(key).contains('|')) {
      throw RouteBUnsupportedTarget(
        key,
        'it is an extension member, and the analysis does not name its '
        'extension',
      );
    }
    if (extensionName != null) {
      _refuseExtensionCapture(
        key,
        extensionName,
        source.substring(span.start, span.end),
      );
    }
    if (extensionName != null &&
        !_selectorOf(key).startsWith('$extensionName|')) {
      throw RouteBUnsupportedTarget(
        key,
        'the analysis names the extension `$extensionName` for it, which is '
        'not the extension of its key',
      );
    }

    // AN INSTANCE GETTER has no parameter list to put the receiver in, and
    // scanning for one would find the first `(` of its BODY: `get label =>
    // compute(x)` would become `compute(Thing self, x)`. In the VM a getter
    // is a one-parameter function named `get:label` -- the parameter is the
    // receiver -- and the device resolves the target by that name, so the
    // replacement is the same one-parameter function as for a method:
    // `String get label => x` becomes `String label(Thing self) => x`.
    final selector = key.contains('#') ? _selectorOf(key) : key;
    final getterName = selector.contains('.get:')
        ? selector.substring(selector.indexOf('.get:') + '.get:'.length)
        : extensionName != null && selector.contains('|get#')
        ? selector.substring(selector.indexOf('|get#') + '|get#'.length)
        : null;
    if (getterName != null) {
      final nameEnd = lowering.nameOffset + getterName.length;
      if (nameEnd > span.end ||
          source.substring(lowering.nameOffset, nameEnd) != getterName) {
        throw RouteBUnsupportedTarget(
          key,
          'its name `$getterName` is not where the analyzer reported it',
        );
      }
      var back = lowering.nameOffset;
      while (back > span.start && _isBlank(source.codeUnitAt(back - 1))) {
        back--;
      }
      const keyword = 'get';
      final keywordStart = back - keyword.length;
      if (back == lowering.nameOffset ||
          keywordStart < span.start ||
          source.substring(keywordStart, back) != keyword ||
          (keywordStart > 0 &&
              _isIdentifierPart(source.codeUnitAt(keywordStart - 1)))) {
        throw RouteBUnsupportedTarget(
          key,
          'its `get` keyword could not be found ahead of its name',
        );
      }
      final written = _returnTypeToWrite(
        key,
        source,
        span.start,
        keywordStart,
        lowering.signatureTypes,
      );
      edits
        ..add((
          keywordStart,
          lowering.nameOffset - keywordStart,
          written == null ? '' : '$written ',
        ))
        ..add((nameEnd, 0, '($receiverParameter)'));
    } else {
      // The receiver parameter goes into the method's own parameter list, found
      // by scanning from the NAME — an annotation's parentheses come earlier
      // and would otherwise match first.
      final open = source.indexOf('(', lowering.nameOffset);
      if (open < 0 || open >= span.end) {
        throw RouteBUnsupportedTarget(
          key,
          'its parameter list could not be found',
        );
      }
      final listed = _parameterList(source, open, span.end);
      if (listed == null) {
        throw RouteBUnsupportedTarget(key, 'its parameter list is not closed');
      }
      // G3.7: the target's OWN parameters stay, and the receiver goes in FRONT
      // of them. The existing list is copied as written -- exactly as the
      // argument list of a call is copied -- so no default is interpreted and
      // no
      // name is rewritten.
      //
      // The one thing added is a TYPE the source left out. Dart takes an
      // omitted
      // parameter or return type from the member being overridden, and the
      // lowered form is a top-level function, which overrides nothing: left
      // alone, `a` in `@override Object? f(a) => a + 1` becomes `dynamic` and
      // the `+` a lookup by name. The analysis reports the inferred types
      // (analysis 21) and they are written in; one that cannot be named in the
      // replacement library refuses the target.
      //
      // The analyzer refuses named parameters, optional positionals and
      // generics, so what is here is a list of required positionals. A
      // separator is needed only when there is something to separate from.
      final separator = listed.parameters.isEmpty ? '' : ', ';
      final typeEdits = _parameterTypeEdits(
        key,
        source,
        listed.parameters,
        lowering.signatureTypes,
      );
      var receiverEditLength = 0;
      var receiverEditText = '$receiverParameter$separator';
      // An edit at the same offset as the receiver's would tie in the sort, so
      // it is folded into the receiver's own.
      for (final e in [...typeEdits]) {
        if (e.$1 == open + 1) {
          receiverEditLength = e.$2;
          receiverEditText += e.$3;
          typeEdits.remove(e);
        }
      }
      edits
        ..add((open + 1, receiverEditLength, receiverEditText))
        ..addAll(typeEdits);
      final returnWritten = _returnTypeToWrite(
        key,
        source,
        span.start,
        lowering.nameOffset,
        lowering.signatureTypes,
      );
      if (returnWritten != null) {
        edits.add((lowering.nameOffset, 0, '$returnWritten '));
      }
    }

    for (final access in edited.values) {
      // The edit below inserts or replaces a receiver prefix immediately before
      // the identifier, which suits a read and a zero-argument call alike. A
      // kind added later may not work that way, so refuse rather than guess --
      // the analyzer and the producer are versioned together for this reason,
      // and this is the backstop when that pairing is somehow wrong.
      if (!const {'get', 'set', 'invoke', 'helperCall'}.contains(access.kind) &&
          !(extensionName != null &&
              const {
                'receiver',
                'extensionGet',
                'extensionInvoke',
              }.contains(access.kind))) {
        throw RouteBUnsupportedTarget(
          key,
          'uses the receiver in a way this lowering does not know how to '
          'rewrite (`${access.kind}` on `${access.member}`)',
        );
      }
      // THE BARE RECEIVER of an extension member: `this` as a value, an
      // argument or `$this`. It is the `#this` parameter, which the lowered
      // function names `self`. The token is checked rather than assumed: an
      // implicit use has none, and rewriting at the wrong place would compile.
      if (access.kind == 'receiver') {
        final end = access.offset + 'this'.length;
        // `$this` in a string: the `$` before the token is the interpolation,
        // and a `$` after it ends the token (`'$a$this$b'`), where in code
        // either would be part of one identifier.
        final interpolated =
            access.offset > span.start &&
            source.codeUnitAt(access.offset - 1) == 0x24;
        bool partOfToken(int unit) =>
            _isIdentifierPart(unit) && !(interpolated && unit == 0x24);
        if (access.offset < span.start ||
            end > span.end ||
            !source.startsWith('this', access.offset) ||
            (end < source.length && partOfToken(source.codeUnitAt(end))) ||
            (!interpolated &&
                _isIdentifierPart(source.codeUnitAt(access.offset - 1)))) {
          throw RouteBUnsupportedTarget(
            key,
            'uses the receiver where its source has no `this` (offset '
            '${access.offset}), so it cannot be rewritten',
          );
        }
        final dollar = access.offset - 1;
        if (dollar >= span.start && source[dollar] == r'$') {
          // `$this` is an interpolation of the receiver: `${self}`.
          edits.add((dollar, 1 + 'this'.length, '\${$receiverName}'));
        } else {
          edits.add((access.offset, 'this'.length, receiverName));
        }
        continue;
      }
      // A sibling of the same extension is applied explicitly, so it cannot
      // resolve to another extension of the same member name that the
      // replacement library has in scope.
      final prefix = access.kind.startsWith('extension')
          ? '$extensionName($receiverName).'
          : '$receiverName.';
      // A CALL TO A NEW INSTANCE METHOD (analysis version 17). The helper is a
      // top-level function taking the receiver first, so `_m(a)` and
      // `this._m(a)` both become `_m(self, a)`: the `(` after the name gains
      // the receiver, and an explicit `this.` goes. The argument list is
      // otherwise copied verbatim. The `(` is replaced rather than inserted
      // after, so that a receiver use that starts the argument list
      // (`_m(label)`, whose own edit sits at the next offset) cannot collide
      // with it.
      if (access.kind == 'helperCall') {
        final nameEnd = access.offset + access.member.length;
        if (nameEnd > span.end ||
            source.substring(access.offset, nameEnd) != access.member) {
          throw RouteBUnsupportedTarget(
            key,
            'its call to `${access.member}` is not where the analyzer '
            'reported it',
          );
        }
        var open = nameEnd;
        while (open < span.end && _isBlank(source.codeUnitAt(open))) {
          open++;
        }
        if (open >= span.end || source[open] != '(') {
          throw RouteBUnsupportedTarget(
            key,
            'its call to `${access.member}` is not written as a plain call '
            '(a type argument list or a tear-off), which this lowering '
            'will not rewrite',
          );
        }
        var after = open + 1;
        while (after < span.end && _isBlank(source.codeUnitAt(after))) {
          after++;
        }
        final empty = after < span.end && source[after] == ')';
        edits.add((open, 1, empty ? '($receiverName' : '($receiverName, '));
        const explicitThis = 'this.';
        final thisStart = access.offset - explicitThis.length;
        if (thisStart >= span.start &&
            source.substring(thisStart, access.offset) == explicitThis) {
          edits.add((thisStart, explicitThis.length, ''));
        } else {
          var back = access.offset - 1;
          while (back >= 0 && _isBlank(source.codeUnitAt(back))) {
            back--;
          }
          if (back >= 0 && source[back] == '.') {
            throw RouteBUnsupportedTarget(
              key,
              'calls `${access.member}` through a receiver this lowering '
              'cannot rewrite safely',
            );
          }
        }
        continue;
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
        edits.add((start, explicit.length, prefix));
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
        // A `$$` escape is not an interpolation. Refuse rather than reason
        // about it -- it cannot appear in a receiver access this analyzer
        // reported, so reaching here means the two disagree.
        if (dollar - 1 >= span.start && source[dollar - 1] == r'$') {
          throw RouteBUnsupportedTarget(
            key,
            'reads `${access.member}` inside an escaped `\$\$` sequence, which '
            'this lowering will not rewrite',
          );
        }
        // Replace `$NAME` with `${self.NAME}`: one edit, spanning the `$` and
        // the identifier, so nothing after the identifier is touched.
        edits.add((
          dollar,
          1 + access.member.length,
          '\${$prefix${access.member}}',
        ));
        continue;
      }
      edits.add((access.offset, 0, prefix));
    }

    // THE CLASS SCOPE THE LOWERING DROPS. Written with a placeholder for the
    // class name, which is substituted after the private-name backstop below
    // for the reason the receiver type's placeholder is.
    edits
      ..addAll(
        _staticQualification(
          key,
          source,
          span,
          scope,
          _classQualifierPlaceholder,
          instance: true,
        ),
      )
      ..sort((a, b) => b.$1.compareTo(a.$1));
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

    // PRIVATE CONSTRUCTIONS, when the analyzer measured them (version 12).
    //
    // A replacement declaration is recompiled whole, so a private class the
    // body constructs is a class the PATCH constructs -- and a release retains
    // a private class's constructor only if its manifest granted it. Policy p2
    // retains such a class so its MEMBERS can be patch-targeted while
    // withholding construction separately, so members being granted says
    // nothing about the constructor.
    //
    // Null means a version-11 document, which cannot say. The text backstop
    // below then refuses the class name as an unresolved private identifier,
    // exactly as it did before: older releases stay patchable on the older,
    // less precise path rather than being newly rejected or newly admitted.
    final constructions = lowering.privateConstructions;
    if (constructions != null) {
      // TWO CONDITIONS, both load-bearing, and neither implies the other.
      //
      //   1 the RELEASE's version of THIS SAME METHOD already constructed the
      //     exact constructor, and
      //   2 the release's manifest retained that exact constructor.
      //
      // The manifest alone is not enough. It is release-WIDE, so it contains
      // `_Private.new` whenever any released method constructed it — and a
      // patch that newly introduces that construction into a method which
      // never performed it would pass a program-wide check with no evidence
      // behind it. This is the constructor equivalent of the exact-super
      // same-method rule.
      final releaseEvidence = lowering.releasePrivateConstructions;
      for (final construction in constructions) {
        if (releaseEvidence == null) {
          // A version-11 or version-12 document, or a version-13 one whose
          // base could not be examined. Nothing was measured, so nothing may
          // be admitted on it — absence is not permission.
          throw RouteBUnsupportedTarget(
            key,
            'its body constructs the private class '
            '`${construction.className}`, and this analysis did not measure '
            'what the RELEASE version of this method constructed. Without that '
            'evidence the construction cannot be carried.',
          );
        }
        if (!releaseEvidence.any((c) => c.key == construction.key)) {
          throw RouteBUnsupportedTarget(
            key,
            'its body constructs `${construction.className}`, which the '
            'RELEASE version of this same method never constructed. A patch '
            'may reuse a private construction the released method already '
            'performed; it may not introduce a new one, even where some other '
            'released method constructed it.',
          );
        }
        if (capabilities == null) {
          throw RouteBUnsupportedTarget(
            key,
            'its body constructs the private class '
            '`${construction.className}`, and this release published no '
            'capability manifest — so there is no evidence its constructor was '
            'retained.',
          );
        }
        if (!capabilities.classesConstructible.contains(construction.key)) {
          throw RouteBUnsupportedTarget(
            key,
            'its body constructs `${construction.className}`, whose '
            'constructor `${construction.key}` this release did not retain. '
            "Granting the class's members is not the same grant: a patch "
            'that constructs it would fail to bind.',
          );
        }
        // Both conditions met, so the text backstop must not refuse the same
        // name again.
        granted.add(construction.className);
      }
    }
    // The declaration's own name may be private -- patching `_helper` is
    // ordinary -- and it is a declaration here, not a reference. A getter's or
    // setter's selector is `get:_name`, and the text says `_name`.
    final own = _memberNameOf(key);
    final grantedStatics = <String>{};
    for (final entry in _privateIdentifierCounts(text).entries) {
      final name = entry.key;
      if (granted.contains(name) || name == own || helperNames.contains(name)) {
        continue;
      }
      // A private static of the member's own class (method, accessor, field or
      // const), written unqualified: the class scope qualifies it, and the
      // release's manifest grants it by the same `library#Class#name` key as
      // an instance member. Exempt by OCCURRENCE: every spelling of the name
      // must be one the analysis reported, so `Other._k`, `d._k` and another
      // library's member of that name are not covered by the grant.
      if (_ownStaticGranted(name, entry.value, key, scope, capabilities)) {
        grantedStatics.add(name);
        continue;
      }
      throw RouteBUnsupportedTarget(
        key,
        'its body names `$name`, a private identifier this analysis did not '
        'resolve to a member the release granted. Private references are '
        'carried only when the release manifest shows the exact member was '
        'retained.',
      );
    }
    // The receiver parameter's type, now that the scan above has run. Exactly
    // one placeholder must be present: the one inserted above. Any other count
    // means the author's own text spelled it, and a substitution could land in
    // the wrong place.
    if (_receiverTypePlaceholder.allMatches(text).length != 1) {
      throw RouteBUnsupportedTarget(
        key,
        'its source contains `$_receiverTypePlaceholder`, which the producer '
        'reserves for the receiver parameter',
      );
    }
    text = text
        .replaceFirst(_receiverTypePlaceholder, lowering.receiverType)
        // The extension's own name for its statics; the class is the receiver.
        .replaceAll(
          _classQualifierPlaceholder,
          extensionName ?? lowering.receiverType,
        );
    return _Lowered(
      text,
      preamble: superEdits.isEmpty ? '' : '$_superIntrinsicDeclaration\n',
      needsSuperVerification: superEdits.isNotEmpty,
      grantedStatics: grantedStatics,
    );
  }

  /// Stands in for the class name where a static is qualified, until the
  /// private-name scan has run; see the lowering.
  static const _classQualifierPlaceholder = '@CLASS_QUALIFIER@';

  /// The class scope of [key], from the analysis; null for a member that is not
  /// a class or extension member.
  ///
  /// A document with no `enclosingScope` at all (the analyzer always writes
  /// one, `{}` at minimum) predates this report, and a class or extension
  /// member cannot be shown safe without it: an unqualified static of its class
  /// would be looked up among top-level names in the replacement. That is
  /// refused, not guessed from other fields.
  RouteBEnclosingScope? _scopeOf(String key, RouteBCoverage coverage) {
    final selector = _selectorOf(key);
    if (!selector.contains('.') && !selector.contains('|')) return null;
    final scopes = coverage.enclosingScope;
    if (scopes == null) {
      throw RouteBUnsupportedTarget(
        key,
        'it is a class or extension member, and this analysis does not report '
        'the scope it was written in, so a static of its class cannot be '
        'shown to mean the same thing in the replacement library. Re-cut the '
        'release with a current toolchain and patch that',
      );
    }
    final scope = scopes[key];
    if (scope == null) {
      throw RouteBUnsupportedTarget(
        key,
        'the analysis reports no class scope for it, so a static of its '
        'class cannot be shown to mean the same thing in the replacement '
        'library',
      );
    }
    return scope;
  }

  /// Whether every spelling of the private [name] ([occurrences] of it in the
  /// emitted code) is a use of a private static of [scope]'s class that the
  /// analysis reported unqualified, and the manifest grants that static.
  ///
  /// The class is the member's own, hence in the target's library. The key is
  /// the one instance members use, `library#Class#name`, looked up in the
  /// statics the release kept (`get:`/`set:` for an accessor; a bare name is a
  /// method or a field).
  static bool _ownStaticGranted(
    String name,
    int occurrences,
    String key,
    RouteBEnclosingScope? scope,
    RouteBCapabilities? capabilities,
  ) {
    if (scope == null || capabilities == null) return false;
    final uses = [
      for (final r in scope.staticReferences)
        if (r.member == name) r,
    ];
    // The analysis lists only unqualified uses. Any other spelling of the name
    // (`Other._k`, `d._k`) makes the counts differ.
    // A compound use (`_n++`) may be reported as a get and a set at one
    // offset; that is one spelling.
    if (uses.isEmpty ||
        uses.map((r) => r.offset).toSet().length != occurrences) {
      return false;
    }
    final library = key.split('#').first;
    final prefix = '$library#${scope.className}#';
    bool granted(String member) =>
        capabilities.staticsCallable.contains('$prefix$member') &&
        !capabilities.skipped.any(
          (s) =>
              s == '$prefix$member' ||
              s.startsWith('$prefix$member ') ||
              s == '$library#${scope.className}' ||
              s.startsWith('$library#${scope.className} '),
        );
    return uses.every(
      (r) => switch (r.kind) {
        'get' => granted(name) || granted('get:$name'),
        'set' => granted(name) || granted('set:$name'),
        _ => granted(name),
      },
    );
  }

  /// Refuses a private name in [text] (a target with no lowering, as written)
  /// other than: its own declaration, a name in [exempt] (a new function the
  /// patch carries, a private top-level function the manifest grants), each
  /// only where written UNQUALIFIED, or a private static of its own class that
  /// the manifest grants and the analysis reported at every spelling. A name
  /// after a `.` (`other._f()`) is never covered by an exemption.
  static void _refuseUngrantedPrivateNames(
    String key,
    String text,
    RouteBEnclosingScope? scope,
    Set<String> exempt,
    RouteBCapabilities? capabilities,
  ) {
    final own = _memberNameOf(key);
    for (final entry in _privateIdentifierCounts(text).entries) {
      final name = entry.key;
      if ((name == own || exempt.contains(name)) &&
          !_spelledQualified(text, name)) {
        continue;
      }
      if (_ownStaticGranted(name, entry.value, key, scope, capabilities)) {
        continue;
      }
      throw RouteBUnsupportedTarget(
        key,
        'its body names `$name`, a private identifier this analysis did not '
        'resolve to a member the release granted, and the target is compiled '
        'with private names resolved against the release library. Private '
        'references are carried only when the release manifest shows the '
        'exact member was retained.',
      );
    }
  }

  /// Whether [name] is spelled after a `.` (`o._f`, `o?._f`, `o.._f`) in the
  /// code of [text].
  static bool _spelledQualified(String text, String name) {
    final code = _strippedCode(text);
    for (final m in _privateIdentifier.allMatches(code)) {
      if (m[0] != name) continue;
      var i = m.start - 1;
      while (i >= 0 && code[i].trim().isEmpty) {
        i--;
      }
      if (i >= 0 && code[i] == '.') return true;
    }
    return false;
  }

  static bool _qualifiesPrivateClass(RouteBEnclosingScope? scope) =>
      scope != null &&
      scope.className.startsWith('_') &&
      scope.staticReferences.isNotEmpty;

  /// A static member's source with each unqualified use of a static of its own
  /// class written `Class.name`.
  String _qualifiedStaticSlice(
    String key,
    RouteBSourceSpan span,
    RouteBEnclosingScope? scope,
  ) {
    final slice = _slice(key, span);
    if (scope == null) return slice;
    final source = utf8.decode(
      File.fromUri(Uri.parse(span.fileUri)).readAsBytesSync(),
    );
    final edits = _staticQualification(
      key,
      source,
      span,
      scope,
      scope.className,
      instance: false,
    )..sort((a, b) => b.$1.compareTo(a.$1));
    var text = slice;
    for (final (offset, length, replacement) in edits) {
      final at = offset - span.start;
      text = text.replaceRange(at, at + length, replacement);
    }
    return text;
  }

  /// The edits that write [qualifier] in front of every unqualified use of a
  /// static of the member's own class.
  ///
  /// THE ANALYZER DECIDES which uses those are, from Kernel's resolution and
  /// the front end's token stream: it lists only the uses written without a
  /// qualifier, each at the offset of its identifier. This only checks that the
  /// text at each offset is exactly that name and inserts the prefix. Anything
  /// else, or any problem the analyzer reported, refuses.
  List<(int, int, String)> _staticQualification(
    String key,
    String source,
    RouteBSourceSpan span,
    RouteBEnclosingScope? scope,
    String qualifier, {
    required bool instance,
  }) {
    if (scope == null) return const [];
    if (scope.problems.isNotEmpty) {
      throw RouteBUnsupportedTarget(
        key,
        'its class scope cannot be carried: ${scope.problems.first}',
      );
    }
    if (instance && scope.usedTypeParameters.isNotEmpty) {
      throw RouteBUnsupportedTarget(
        key,
        'its body uses the class type parameter '
        '`${scope.usedTypeParameters.first}`, which is not in scope in the '
        'top-level function a replacement is, and a top-level type of that '
        'name would be bound instead',
      );
    }
    final edits = <(int, int, String)>[];
    // `_n++` and `_n += 1` may be reported twice (a get and a set) at one
    // offset; the qualifier goes in once.
    final seen = <int, (String, bool)>{};
    for (final ref in scope.staticReferences) {
      final earlier = seen[ref.offset];
      if (earlier != null) {
        if (earlier != (ref.member, ref.interpolated)) {
          throw RouteBUnsupportedTarget(
            key,
            'two different uses (`${earlier.$1}`, `${ref.member}`) are '
            'reported at offset ${ref.offset}, so they cannot be qualified',
          );
        }
        continue;
      }
      seen[ref.offset] = (ref.member, ref.interpolated);
      final end = ref.offset + ref.member.length;
      final dollar = ref.offset - 1;
      if (ref.offset < span.start ||
          end > span.end ||
          !source.startsWith(ref.member, ref.offset) ||
          (end < source.length &&
              _isIdentifierPart(source.codeUnitAt(end)) &&
              // A `$` after an interpolated name starts the next one.
              !(ref.interpolated && source.codeUnitAt(end) == 0x24)) ||
          (ref.interpolated &&
              (dollar < span.start || source[dollar] != r'$'))) {
        throw RouteBUnsupportedTarget(
          key,
          'its use of the static `${ref.member}` is not where the analyzer '
          'reported it (offset ${ref.offset}), so it cannot be qualified',
        );
      }
      if (ref.interpolated) {
        // `$k` would read `$C` followed by `.k`: it needs braces.
        edits.add((
          dollar,
          1 + ref.member.length,
          '\${$qualifier.${ref.member}}',
        ));
      } else {
        edits.add((ref.offset, 0, '$qualifier.'));
      }
    }
    return edits;
  }

  /// Whether any reference of [keys] is marked `inlined`.
  static bool _hasInlinedReference(
    RouteBCoverage coverage,
    List<String> keys,
  ) => keys.any(
    (k) =>
        coverage.externalReferences?[k]?.any((r) => r.inlined != null) ?? false,
  );

  /// The member names the compiled replacement at [payload] looks up at run
  /// time (every interface and dynamic call), read by the cell's own analyzer
  /// with the compiler's own bytecode reader. Null when it could not be read:
  /// an analyzer without the mode, a payload it cannot parse, or one with no
  /// function in it. "Could not read" is never "calls nothing".
  static Set<String>? _selectorsCalledByName(
    RouteBCompiler compiler,
    File payload,
    ProcessResult Function(String executable, List<String> arguments) run,
  ) {
    try {
      final result = run(compiler.runtime.path, [
        compiler.analyzer.path,
        '--scan-bytecode',
        payload.path,
      ]);
      if (result.exitCode != 0) return null;
      final lines = '${result.stdout}'.trim().split('\n');
      final json = jsonDecode(lines.last);
      if (json is! Map<String, dynamic> ||
          json['functions'] is! int ||
          (json['functions'] as int) < 1 ||
          // A call line the scan could not read: the list is then a subset.
          json['unparsed'] != 0 ||
          json['calls'] is! List) {
        return null;
      }
      return (json['calls'] as List).whereType<String>().toSet();
    } on Object {
      return null;
    }
  }

  /// The return type to write ahead of a lowered member's name, or null when
  /// nothing needs writing.
  ///
  /// Needed only when the source omitted it (Dart then takes it from the member
  /// being overridden, which the lowered function no longer overrides) and the
  /// inferred type is not `dynamic`. The prefix is the source from the start of
  /// the
  /// declaration to just before the name (or the `get` keyword).
  static String? _returnTypeToWrite(
    String key,
    String source,
    int start,
    int end,
    RouteBSignatureTypes? types,
  ) {
    if (types == null || types.returnType == 'dynamic') return null;
    final omitted = end < start || end > source.length
        ? null
        : _returnTypeOmitted(source.substring(start, end));
    if (omitted == false) return null;
    final inferred = types.returnType;
    if (omitted == null || inferred == null) {
      throw RouteBUnsupportedTarget(
        key,
        'its return type is not written in the source, and the type it '
        'inherits from the member it overrides (${inferred ?? 'one the '
                'replacement cannot name'}) cannot be written into the lowered '
        'function, which would otherwise take `dynamic`. Write the return type',
      );
    }
    return inferred;
  }

  /// Whether the declaration prefix [prefix] has no return type: only comments,
  /// annotations and modifiers. Null when it cannot be told (a trailing
  /// `operator`, or an annotation this does not parse).
  static bool? _returnTypeOmitted(String prefix) {
    final masked = _maskComments(prefix);
    final start = _skipAnnotations(masked, 0);
    if (start == null) return null;
    final words = masked.substring(start).trim().split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    if (words.contains('operator')) return null;
    const modifiers = {'static', 'external', 'covariant', 'abstract'};
    return words.every(modifiers.contains);
  }

  /// [text] with every comment replaced by spaces of the same length, so
  /// offsets into it are offsets into the source.
  static String _maskComments(String text) {
    final out = StringBuffer();
    var i = 0;
    while (i < text.length) {
      if (text.startsWith('//', i)) {
        while (i < text.length && text[i] != '\n') {
          out.write(' ');
          i++;
        }
      } else if (text.startsWith('/*', i)) {
        final end = text.indexOf('*/', i + 2);
        final stop = end < 0 ? text.length : end + 2;
        for (; i < stop; i++) {
          out.write(text[i] == '\n' ? '\n' : ' ');
        }
      } else {
        out.write(text[i]);
        i++;
      }
    }
    return '$out';
  }

  /// The index after any annotations at the start of [masked] (from [from]), or
  /// null when one cannot be parsed.
  static int? _skipAnnotations(String masked, int from) {
    var i = from;
    final name = RegExp(r'@\s*[A-Za-z_$][\w$]*(?:\s*\.\s*[A-Za-z_$][\w$]*)*');
    while (true) {
      while (i < masked.length && _isBlank(masked.codeUnitAt(i))) {
        i++;
      }
      if (i >= masked.length || masked[i] != '@') return i;
      final m = name.matchAsPrefix(masked, i);
      if (m == null) return null;
      i = m.end;
      var j = i;
      while (j < masked.length && _isBlank(masked.codeUnitAt(j))) {
        j++;
      }
      if (j < masked.length && masked[j] == '(') {
        final close = _closing(masked, j);
        if (close == null) return null;
        i = close + 1;
      }
    }
  }

  /// The index of the bracket closing the one at [open], skipping strings, or
  /// null when it is not closed.
  static int? _closing(String text, int open, [int? limit]) {
    var depth = 0;
    final end = limit ?? text.length;
    for (var i = open; i < end; i++) {
      final c = text[i];
      if (c == "'" || c == '"') {
        i++;
        while (i < end && text[i] != c) {
          if (text[i] == r'\') i++;
          i++;
        }
      } else if (c == '(' || c == '[' || c == '{' || c == '<') {
        depth++;
      } else if (c == ')' || c == ']' || c == '}' || c == '>') {
        // `=>` is not a closing angle bracket.
        if (c == '>' && i > 0 && text[i - 1] == '=') continue;
        depth--;
        if (depth == 0) return i;
      }
    }
    return null;
  }

  /// The parameters of the list opening at [open], split on top-level commas
  /// (commas inside `<>`, `()`, `[]`, `{}` belong to a type), and where it
  /// closes. Null when it is not closed before [limit].
  static ({List<(int, int)> parameters, int close})? _parameterList(
    String source,
    int open,
    int limit,
  ) {
    final masked = _maskComments(source.substring(0, limit));
    final close = _closing(masked, open);
    if (close == null) return null;
    final ranges = <(int, int)>[];
    var depth = 0;
    var from = open + 1;
    for (var i = open + 1; i < close; i++) {
      final c = masked[i];
      if (c == "'" || c == '"') {
        i++;
        while (i < close && masked[i] != c) {
          if (masked[i] == r'\') i++;
          i++;
        }
      } else if (c == '(' || c == '[' || c == '{' || c == '<') {
        depth++;
      } else if (c == ')' || c == ']' || c == '}' || c == '>') {
        if (c == '>' && masked[i - 1] == '=') continue;
        depth--;
      } else if (c == ',' && depth == 0) {
        ranges.add((from, i));
        from = i + 1;
      }
    }
    ranges.add((from, close));
    return (
      parameters: [
        for (final r in ranges)
          if (masked.substring(r.$1, r.$2).trim().isNotEmpty) r,
      ],
      close: close,
    );
  }

  /// The edits that write the INFERRED type of each parameter whose type the
  /// source left out; see the call site. Empty without analysis 21's types.
  static List<(int, int, String)> _parameterTypeEdits(
    String key,
    String source,
    List<(int, int)> parameters,
    RouteBSignatureTypes? types,
  ) {
    if (types == null) return [];
    if (types.params.length != parameters.length) {
      throw RouteBUnsupportedTarget(
        key,
        'its parameter list does not match the analysis '
        '(${parameters.length} written, ${types.params.length} reported)',
      );
    }
    final untyped = RegExp(
      r'^(covariant\s+)?(?:(final|var)\s+)?([A-Za-z_$][\w$]*)$',
    );
    final edits = <(int, int, String)>[];
    for (var i = 0; i < parameters.length; i++) {
      final inferred = types.params[i];
      if (inferred == 'dynamic') continue;
      final (start, end) = parameters[i];
      final masked = _maskComments(source.substring(start, end));
      final first = _skipAnnotations(masked, 0);
      final match = first == null
          ? null
          : untyped.firstMatch(masked.substring(first).trim());
      // A written type, however complicated, is copied as it is.
      if (first != null && match == null) continue;
      if (first == null || inferred == null) {
        throw RouteBUnsupportedTarget(
          key,
          'its parameter `${masked.trim()}` has no written type, and the type '
          'it inherits (${inferred ?? 'one the replacement cannot name'}) '
          'cannot be written into the lowered function, which would otherwise '
          'take `dynamic`. Write the parameter type',
        );
      }
      final name = match!.group(3)!;
      final nameAt = start + masked.lastIndexOf(name);
      if (match.group(2) == 'var') {
        final varAt = start + masked.indexOf(RegExp(r'\bvar\b'), first);
        edits.add((varAt, 'var'.length, inferred));
      } else {
        edits.add((nameAt, 0, '$inferred '));
      }
    }
    return edits;
  }

  /// Every private identifier in `text` that could be a reference.
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

  /// Refuses a member whose own names would capture `Ext(self)` or `Ext.k`,
  /// which the lowering writes: a parameter, local or function named like the
  /// extension, or an entry function named like it (a lowercase extension whose
  /// member has its own name, `extension stars on int { int stars() }`, becomes
  /// a top-level `stars` that hides the extension).
  static void _refuseExtensionCapture(
    String key,
    String extensionName,
    String declaration,
  ) {
    final selector = _selectorOf(key);
    final bar = selector.indexOf('|');
    var member = bar < 0 ? selector : selector.substring(bar + 1);
    if (member.startsWith('get#')) member = member.substring('get#'.length);
    if (member == extensionName) {
      throw RouteBUnsupportedTarget(
        key,
        'its replacement would be a top-level function named `$extensionName`, '
        'which hides the extension of that name that its body is written '
        'against',
      );
    }
    final code = _strippedCode(declaration);
    final pattern = RegExp(
      '(?<![\\w\$])${RegExp.escape(extensionName)}(?![\\w\$])',
    );
    const usesOfAValue = {
      'return', 'await', 'throw', 'in', 'is', 'as', 'else', 'case', 'yield', //
      'new', 'const',
    };
    for (final m in pattern.allMatches(code)) {
      var after = m.end;
      while (after < code.length && code[after] == ' ') {
        after++;
      }
      final next = after < code.length ? code[after] : '';
      var before = m.start;
      while (before > 0 && code[before - 1] == ' ') {
        before--;
      }
      var wordStart = before;
      while (wordStart > 0 &&
          _isIdentifierPart(code.codeUnitAt(wordStart - 1))) {
        wordStart--;
      }
      final prev = code.substring(wordStart, before);
      final declares = prev.isNotEmpty && !usesOfAValue.contains(prev);
      final bareName = next != '.' && next != '(' && next != '<';
      if (declares || bareName) {
        throw RouteBUnsupportedTarget(
          key,
          'it spells `$extensionName`, the name of its extension, as a '
          'parameter, a local or a value, which would capture the explicit '
          '`$extensionName(...)` and `$extensionName.` the replacement writes',
        );
      }
    }
  }

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

  /// How many times each private name is spelled in the code of [text]
  /// (comments and literal text of strings excluded).
  @visibleForTesting
  static Map<String, int> privateIdentifierCountsForTesting(String text) =>
      _privateIdentifierCounts(text);

  static Set<String> _privateIdentifiers(String text) =>
      _privateIdentifierCounts(text).keys.toSet();

  /// [text] with comments and the literal parts of strings dropped. What is
  /// left is the code, including every interpolation (`$_x`, `${...}`, nested
  /// strings too), each interpolated identifier set apart by spaces.
  static String _strippedCode(String text) {
    final code = StringBuffer();
    _stripInto(text, 0, code, inInterpolation: false);
    return code.toString();
  }

  /// Strips from [start] into [code]; returns where it stopped. Inside an
  /// interpolation it stops after the `}` that closes it.
  static int _stripInto(
    String text,
    int start,
    StringBuffer code, {
    required bool inInterpolation,
  }) {
    var i = start;
    var depth = 0;
    while (i < text.length) {
      if (text.startsWith('//', i)) {
        while (i < text.length && text[i] != '\n') {
          i++;
        }
        continue;
      }
      if (text.startsWith('/*', i)) {
        // Dart block comments nest, so a depth count is not paranoia.
        var level = 1;
        i += 2;
        while (i < text.length && level > 0) {
          if (text.startsWith('/*', i)) {
            level++;
            i += 2;
          } else if (text.startsWith('*/', i)) {
            level--;
            i += 2;
          } else {
            i++;
          }
        }
        continue;
      }
      final c = text[i];
      if (c == "'" || c == '"') {
        // A raw string (`r'...'`) has no escapes and no interpolation.
        final raw =
            i > 0 &&
            text[i - 1] == 'r' &&
            (i < 2 || !RegExp(r'[A-Za-z0-9_$]').hasMatch(text[i - 2]));
        final delim = text.startsWith(c * 3, i) ? c * 3 : c;
        var j = i + delim.length;
        while (j < text.length && !text.startsWith(delim, j)) {
          if (!raw && text[j] == r'\') {
            j += 2;
            continue;
          }
          if (!raw && text[j] == r'$') {
            if (text.startsWith(r'${', j)) {
              code.write(' ');
              j = _stripInto(text, j + 2, code, inInterpolation: true);
              code.write(' ');
              continue;
            }
            final id = RegExp(
              '[A-Za-z_][A-Za-z0-9_]*',
            ).matchAsPrefix(text, j + 1);
            if (id != null) {
              code.write(' ${id[0]} ');
              j = id.end;
              continue;
            }
          }
          j++;
        }
        i = j < text.length ? j + delim.length : text.length;
        continue;
      }
      if (inInterpolation) {
        if (c == '{') {
          depth++;
        } else if (c == '}') {
          if (depth == 0) return i + 1;
          depth--;
        }
      }
      code.write(c);
      i++;
    }
    return i;
  }

  /// How many times each private name is spelled in the code of [text].
  static Map<String, int> _privateIdentifierCounts(String text) {
    final counts = <String, int>{};
    for (final m in _privateIdentifier.allMatches(_strippedCode(text))) {
      final n = m[0]!;
      // `_` and `__` are wildcard parameters, not names.
      if (n.replaceAll('_', '').isEmpty) continue;
      counts[n] = (counts[n] ?? 0) + 1;
    }
    return counts;
  }

  /// Stands in for the receiver parameter's type until the private-name scan
  /// has run; see the lowering.
  static const _receiverTypePlaceholder = '@RECEIVER_TYPE@';

  /// A private identifier, anchored so `my_var` does not read as `_var`.
  static final _privateIdentifier = RegExp(
    r'(?<![A-Za-z0-9_$])_[A-Za-z0-9_$]*',
  );

  /// [declaration] as the replacement library declares it: at top level.
  ///
  /// A class's static member is sliced with its `static` modifier, which is a
  /// compile error outside a class, so dart2bytecode refused every static
  /// method with exit 254. Annotations ahead of the modifier are kept, and
  /// skipped by a scan rather than a pattern: an annotation's arguments nest
  /// (`@Foo(Bar())`), take type arguments (`@Foo<int>()`) and hold strings
  /// with brackets in them (`@Foo(')')`).
  @visibleForTesting
  static String topLevelForm(String declaration) {
    final at = _modifierPosition(declaration);
    if (at < 0) return declaration;
    var end = at + 'static'.length;
    while (end < declaration.length && _isSpace(declaration, end)) {
      end++;
    }
    return declaration.replaceRange(at, end, '');
  }

  /// Where [declaration]'s leading `static` starts, past whitespace, comments
  /// and annotations; -1 when it does not start with one.
  static int _modifierPosition(String declaration) {
    var i = 0;
    while (true) {
      i = _skipTrivia(declaration, i);
      if (i >= declaration.length || declaration[i] != '@') break;
      i++;
      while (i < declaration.length &&
          _nameCharacter.hasMatch(declaration[i])) {
        i++;
      }
      i = _skipTrivia(declaration, i);
      if (i < declaration.length && declaration[i] == '<') {
        i = _skipBalanced(declaration, i, '<', '>');
        i = _skipTrivia(declaration, i);
      }
      if (i < declaration.length && declaration[i] == '(') {
        i = _skipBalanced(declaration, i, '(', ')');
      }
      if (i < 0) return -1;
    }
    return _staticWord.matchAsPrefix(declaration, i) == null ? -1 : i;
  }

  static final _nameCharacter = RegExp(r'[\w$.]');
  static final _staticWord = RegExp(r'static(?![\w$])');

  static bool _isSpace(String s, int i) => ' \t\r\n'.contains(s[i]);

  /// Past whitespace and comments from [from].
  static int _skipTrivia(String s, int from) {
    var i = from;
    while (i < s.length) {
      if (_isSpace(s, i)) {
        i++;
      } else if (s.startsWith('//', i)) {
        final eol = s.indexOf('\n', i);
        i = eol < 0 ? s.length : eol + 1;
      } else if (s.startsWith('/*', i)) {
        final close = s.indexOf('*/', i + 2);
        i = close < 0 ? s.length : close + 2;
      } else {
        break;
      }
    }
    return i;
  }

  /// Past the bracket at [from] and everything up to its partner, skipping
  /// strings; -1 when it never closes.
  static int _skipBalanced(String s, int from, String open, String close) {
    var i = from;
    var depth = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == "'" || c == '"') {
        final quote = s.startsWith(c * 3, i) ? c * 3 : c;
        i += quote.length;
        while (i < s.length && !s.startsWith(quote, i)) {
          i += s[i] == r'\' ? 2 : 1;
        }
        i += quote.length;
        continue;
      }
      if (c == open) depth++;
      if (c == close && --depth == 0) return i + 1;
      i++;
    }
    return -1;
  }

  static bool _isBlank(int c) =>
      c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

  static bool _isIdentifierPart(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      c == 0x5F ||
      c == 0x24;

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
