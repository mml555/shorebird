// Copyright (c) 2026, the Shorebird self-host fork.
//
// analyze_coverage.dart -- Route B step 3, producer half: the target manifest
// and the change classification, as ONE artifact the CLI can run.
//
// WHY THIS EXISTS AS A CELL ARTIFACT AND NOT AS CLI CODE
//
// `shorebird patch` cannot read a dill. `package:kernel` is not obtainable:
// the copy on pub.dev is the abandoned pre-null-safety publication
// (sdk: '>=1.8.0 <3.0.0'), the vended Flutter SDK ships no `pkg/` at all, and
// the live package exists only inside an engine checkout. Reimplementing the
// kernel binary reader in the CLI would mean reimplementing `Printer` too,
// since the member diff is defined as printed-AST equality.
//
// That constraint points the same way the provenance work already did. The
// kernel binary format is versioned and must match the frontend that emitted
// the dill, so the analyzer belongs to the RELEASE's toolchain, not to the
// machine running the patch. It ships in the compiler cell, beside
// dart2bytecode.aot, resolved by the release's engine hash.
//
// WHAT THIS IS A TRANSCRIPTION OF
//
// identity/gen_target_manifest.dart  -- target identity + reachability
// packaging/build_patch.dart         -- kernel diff + classification + verdict
//
// Those two are left untouched, deliberately. They are the reference
// implementation, and `coverage/parity.sh` runs both them and this against the
// same kernel pair and fails on any field that differs. If they shared code the
// harness would prove nothing; the transcription risk IS what it checks.
//
// Reason strings are copied verbatim. A reason is not decoration: "unsupported
// dispatch-table call" and "target unreachable" send you to opposite places --
// one to compiler coverage, the other to retention.
//
// cspell:words devirtualize devirtualizes dartaotruntime unlowered
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:_fe_analyzer_shared/src/scanner/scanner.dart' show scanString;
import 'package:_fe_analyzer_shared/src/scanner/token.dart';
import 'package:dart2bytecode/bytecode_serialization.dart'
    show BufferedReader, LinkReader;
import 'package:dart2bytecode/declarations.dart' as bytecode show Component;
import 'package:dart2bytecode/recognized_methods.dart' show RecognizedMethods;
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/text/ast_to_text.dart';
import 'package:kernel/type_environment.dart';

/// Bump when a consumer would have to change. The CLI refuses a version it does
/// not know rather than reading fields that may have moved -- the `*.vmcode`
/// filename convention is the cautionary tale for unversioned contracts.
///
/// 7: a private receiver access is REPORTED as an access carrying its manifest
///    key, where 6 refused it outright. A version-6 consumer reading a
///    version-7 document would see the access with no `unsupported` reason
///    beside it and lower it unconditionally -- accepting a private reference
///    the release may never have retained. That is exactly the silent-accept
///    this contract is versioned to prevent, so the bump is mandatory.
///
/// 8 (G3.7): a method with its own REQUIRED POSITIONAL parameters is no longer
///    `unsupported`. The entry-point contract now permits any number of them
///    (`bytecode_generator.dart`, patch `0006`), so the receiver no longer has to
///    be the only parameter. The bump is mandatory in the same way 7's was, and
///    in the opposite direction: a version-7 CONSUMER would still be refusing
///    these targets while a version-8 document reports them as lowerable, so the
///    two would disagree about what a release can accept. Named parameters,
///    optional positionals and generics stay `unsupported` here, matching the
///    compiler contract exactly -- the analyzer must never report a shape the
///    compiler will reject, because the refusal would then arrive at compile time
///    with a message about bytecode rather than about the patch.
///
/// 10: a genuine `SuperMethodInvocation` is REPORTED as a `superInvocations`
///     entry carrying its source-site identity, where 9 collapsed it into the
///     `unsupported` reason `calls \`super.x()\``. A version-9 consumer reading
///     a version-10 document would see a lowering with no `unsupported` reason
///     and conclude the body is fully lowerable, which is why this is a version
///     bump and not an additive field.
///
///     `super` GETTERS and SETTERS stay `unsupported`, unchanged.
///
///     WHAT IS DELIBERATELY NOT REPORTED: the resolved super target, its
///     declaring class, its signature, and the call site's argument count.
///     Each has been disqualified as a cross-boundary authority by measurement
///     -- the target's canonical owner is renamed by AOT mixin deduplication
///     (`super0/s2a/`), and TFA can rewrite `super.tag('a', 7)` to zero
///     arguments in this very kernel (`super0/s2b0/`). The source is the
///     authority for shape; the replacement compiler's own kernel is the
///     authority for the target.
///
/// 11: a super site now carries its resolved `target` as a SOURCE PROVENANCE
///     tuple, and each changed instance method carries `releaseSuperTargets` --
///     the same tuple for every super target the RELEASE version of that method
///     already direct-called.
///
///     Version 10 deliberately reported NO resolved target, because a target's
///     canonical owner is renamed by AOT mixin deduplication and is not portable
///     (`super0/s2a/`). What 2A.2 measured as portable is the narrower tuple
///     `fileUri | fileOffset | name | kind`, and 2B.1f showed the product needs
///     it: the release-evidence gate compares TARGETS, because a call SITE moves
///     when the patch edits around it.
///
///     So the exact-key assertion changes deliberately rather than the
///     prohibition being weakened silently. Still never reported: the canonical
///     owner, the synthetic mixin-application name, and any argument count.
/// 12: a body's constructions of a PRIVATE class are reported as
///     `privateConstructions`, each carrying the manifest key the release would
///     have had to grant.
///
///     THE PARITY GAP D-PRODUCER-DEMAND-1 MEASURED. A version-11 document says
///     nothing about them, so a consumer reads a body that constructs
///     `_CustomFocusBuilder`, sees an empty `unsupported`, and calls it
///     admissible -- while the producer, which scans the source for private
///     identifiers, refuses it. Both were right about their own evidence and
///     they disagreed, which is the definition of a measurement gap rather than
///     a bug in either.
///
///     REPORTED, NOT REFUSED, and that is the same division of labour version 7
///     established for private member accesses: the manifest is a per-release
///     artifact and this tool ships in a cell resolved by engine hash, so it
///     states the fact and the holder of the manifest decides. Under policy p2 a
///     private class is retained so its members can be patch-targeted while its
///     construction is withheld separately -- measured on one real release as
///     119 withheld against zero constructible -- so the answer genuinely
///     depends on the manifest and cannot be decided here.
///
///     The bump is mandatory for the reason 10's was: a version-11 consumer
///     would read a version-12 document, see no field it recognises, and admit a
///     construction the release never granted.
/// 13: each changed method also carries `releasePrivateConstructions` -- the
///     same measurement, taken on the RELEASE's version of that same method.
///
///     Version 12 reported only the CANDIDATE's constructions, which is not
///     enough to admit one. A release-wide manifest contains `_Private.new`
///     whenever ANY released method constructed it, so a patch that introduces
///     that construction into a method which never performed it would pass a
///     program-wide check while having no evidence behind it. This is the
///     constructor equivalent of the exact-super same-method rule, and it needs
///     the same per-method evidence.
///
///     ABSENT / EMPTY / POPULATED are three different answers, as they are for
///     `releaseSuperTargets`. Absent means the base could not be examined and
///     nothing was measured -- a consumer must refuse rather than assume.
///     Empty is a measurement: the release version of this method constructed
///     none.
///
///     The bump is mandatory for the usual reason: a version-12 consumer would
///     read a version-13 document, find only the candidate list it already
///     understands, and admit a construction with no same-method evidence.
/// 14: edits a patch cannot carry are no longer invisible.
///
///     Two blind spots, both measured on an iPhone release on 2026-11-15:
///
///     - Constant values. A member was compared by its printed form, and the
///       kernel printer writes a constant as `#C1`, not as its value, so a
///       body whose only edit was `const Text('a')` -> `const Text('b')` read
///       as unchanged and the patch was refused as inert. Members now print
///       with their constants' values, so such an edit is a changed member and
///       ships like any other body edit: the literal is in the replacement's
///       own source.
///     - Fields and constructors. Only procedures were compared, so a changed
///       field initializer, `const` or constructor was never seen. These are
///       reported in `declarations` and refuse the patch: a patch replaces
///       method bodies and the release keeps its own. A `const` is no
///       exception, though its uses are inlined. The patch compiler evaluates
///       constants against the RELEASE's kernel, so a replaced body that names
///       an edited `const` still reads the release's value -- measured: an
///       iPhone printed `KT1` after a patch changing it to `KT2` shipped.
///     - Class headers. `extends`, `with`, `implements` and type parameters
///       were not compared. Tree shaking folds a type test where it can, so an
///       `implements` edit surfaced as a changed body that shipped, while the
///       release's class still answered the test the old way. Headers are a
///       `class` declaration and refuse the patch.
///
///     The bump is mandatory: a version-13 consumer meeting the new rejection
///     category would refuse to parse it, which is safe, but one that skipped
///     unknown categories would ship the patch the analyzer refused.
///
/// 15: `--carry <key>` analyzes an UNCHANGED member as if it had changed, and
///     the document lists such members under `carried`, apart from `changed`.
///     Every member analyzed, changed or carried, gets a `callers` entry: the
///     app members whose bodies (closures included) name it, or name a member
///     it overrides, in the patched kernel, including constructors and field
///     initializers, which no patch can carry (see `_callers`).
///
///     WHY. A target can have no call site left in the release because its
///     callers inlined it, or because TFA folded its result into them. The
///     release's code then runs the old body inside each caller whatever the
///     patch attaches to the target. Replacing those callers too, unchanged,
///     makes them call the new body. The producer asks the release probe which
///     members hold an inlined copy and, for a folded target, carries these
///     callers.
///
///     The bump is mandatory: a version-14 analyzer exits 2 on `--carry`, so a
///     consumer must know which document it holds before it passes one.
///
/// 16: an `added` member may be a HELPER, and ship. A top-level function or
///     getter the patch introduces is accepted when everything that calls it is
///     part of the patch, because the patch then carries its source: the
///     producer appends it to each replacement library that needs it. The
///     document gains `helpers`, `unusedHelpers` and, for each helper, a
///     `sources` span and a `callers` entry. `added` still lists EVERY new
///     member (the release-kernel agreement check reads it that way); the
///     rejections of category `added` are now only the ones that stay refused,
///     each with its own reason.
///
///     WHY. Until now any new function made the whole patch unrepresentable,
///     though a replacement library can hold more than the one entry
///     declaration (measured on host: public and private helpers, helpers with
///     arguments, closures, chains, and calls into the release all bind and
///     run). Helpers are the narrowest slice of "a patch may add a function"
///     that needs no change to the release.
///
///     WHAT STAYS REFUSED, each with a reason: a class member (static or
///     instance), because a sliced `Cls.helper()` would bind to the release's
///     class, which lacks it; a setter or operator; an extension member; a
///     member with no usable source span or declared in a `part` file; and any
///     function with a caller that is not a changed member or an accepted
///     helper, since that caller is the release's own code and cannot see it.
///     A helper nothing in the patch reaches is NOT refused: it is listed in
///     `unusedHelpers` and not shipped.
///
///     A new function used as a VALUE (torn off, including inside a constant)
///     is refused: each replacement library carries its own copy, so a
///     tear-off taken in one patched function is not identical to one taken
///     in another, and `removeListener` of the second would remove nothing.
///     Constants are now walked for tear-offs everywhere `_References` runs,
///     so a `const [f]` or a default value naming a member is a reference to
///     it in `callers` too; before 16 it was not seen.
///
///     The bump is mandatory: a version-15 consumer reads `added` as "all
///     refused", and a consumer that wrongly trusted a version-16 document
///     would have no `helpers` to slice, so the two must be told apart.
///
/// 17. A new INSTANCE METHOD of an existing app class is a helper too, when
///     only patched code calls it. `helpers` then holds keys like
///     `lib#_HomeState._buildHeader`, and each gets its own `lowering` entry
///     (the same one an instance target gets), because the producer emits it
///     as a top-level function taking its receiver as argument 0, exactly like
///     a lowered target.
///
///     A call to such a helper from a lowered body is reported as an access of
///     kind `helperCall`, at the identifier's offset: `_m(a)` / `this._m(a)`
///     becomes `_m(self, a)`. It carries no `private` key, since the helper is
///     declared by the replacement itself and nothing is asked of the release.
///
///     WHAT QUALIFIES: a non-static METHOD (not a getter, setter or operator)
///     of a class that exists in the release and is not a mixin; with a body;
///     in the library's own file; that overrides nothing and is overridden by
///     nothing in EITHER kernel (a call by selector from AOT code, or on a
///     subclass, would miss the copy); whose name no top-level declaration of
///     its library uses (the shipped function would shadow it); and whose
///     every use is a call with implicit `this` or `this.` from an instance
///     member of the SAME class that is a changed/carried member or another
///     such helper. A call on another receiver, a super call, a dynamic call
///     of the same name or a tear-off refuses it, with the reason.
///
///     STILL REFUSED: static methods, instance getters, setters and operators.
///
///     The bump is mandatory for the reason 16's was: a version-16 consumer
///     would read `lib#Cls.m` in `helpers` as a top-level function.
///
/// 18. Every member the patch would carry, changed, carried or helper, reports
///     the EXTERNAL symbols its body names, under `externalReferences`: the
///     members and classes the replacement's bytecode will ask the loader to
///     find by name in the release's snapshot, and the loader ABORTS THE
///     PROCESS on one it cannot find (`bytecode_reader.cc`, `Unable to find
///     library/class/field/function`). Nothing is decided here: whether the
///     RELEASE kept a symbol is a per-release fact (its dynamic interface and
///     capability manifest), and this tool ships in a cell resolved by engine
///     hash, so, as for 7 and 12, it states the fact and the holder of the
///     release's files decides (`route_b_retention.dart`).
///
///     WHAT IS REPORTED, mirroring what `gen_dynamic_interface.dart`'s
///     `_FrameworkUseCollector` retained from the release's own code, so a
///     symbol is reported exactly when the release would have had to retain it
///     from its own source: static, top-level and constructor targets and
///     tear-offs, field and getter/setter targets, instance members the
///     body calls (an `instance` entry; the CLI checks those only for
///     non-`dart:` classes, as the generator does), classes named by an
///     `is`/`as`, a type literal, a type argument, a constant, or the
///     signature of the carried function or one of its closures, and the
///     members and classes named by a constant. Not reported: a reference to
///     a helper the patch itself carries, a class that is the enclosing class
///     of the member being analyzed, `dart:_`-private libraries (nothing a
///     patch spells and nothing an interface can hold) and the declared type of
///     a local variable.
///
///     A body this tool could not walk reports one `unanalyzed` entry instead
///     of a partial list: an incomplete list read as complete would be a
///     silent accept.
///
///     The bump is mandatory for the reason 12's was: a version-17 document
///     has no list, and a consumer cannot tell "nothing referenced" from "not
///     measured" unless the version says which it holds.
///
/// Version 20 adds `inlined` to an `instance` reference: the opcode name(s)
/// (`AddInt`, `CompareIntLt`, ... joined by `|` when sites differ) the patch's
/// bytecode compiler emits for EVERY site of that member in the body, so no
/// member is looked up when it runs. Never set in a body with a `super.` call:
/// the producer rewrites those to `as dynamic`. It is decided by
/// dart2bytecode's own `RecognizedMethods` (imported, so the condition is one
/// copy: both operands statically exactly `int`, or exactly `double`), and set
/// only when no site of the member is a real call.
/// A document below 20 never has it.
///
/// Version 21 adds `signatureTypes` to a `lowering` entry: the INFERRED type of
/// each positional parameter and of the return, as source the replacement
/// library can write (`int`, `List<String>?`, `dynamic`), or null where the type
/// cannot be named there. The producer lowers an instance member to a top-level
/// function, which overrides nothing, so a parameter or return type the source
/// omitted (inherited from the overridden member) would become `dynamic` in the
/// lowered form; the producer writes these types in, or refuses. A document
/// below 21 never has them, and `inlined` is not believed below 21.
///
/// Version 22 reports a `lowering` for an INSTANCE member of a named,
/// non-generic extension (a getter or a method; never a setter, operator or
/// tear-off). Kernel already compiles one to a static procedure whose first
/// parameter is the receiver (`#this`), so the lowered form is the same
/// top-level function a class member becomes. The entry gains `extension` (the
/// extension's name, which the producer needs to write `Ext(self).sibling` and
/// to qualify the extension's statics), `receiverType` is the written on-type,
/// and `signatureTypes` leaves the receiver out. Three access kinds are new:
/// `receiver` (a bare `this`, offset at the token), `extensionGet` and
/// `extensionInvoke` (a call of a sibling instance member of the same
/// extension, which Kernel resolves statically, offset at its identifier).
/// A document below 22 never has an `extension` entry, and its scope report
/// still refuses every instance extension member.
///
/// Version 23 adds `receiverLibrary` and `receiverClass` to the
/// `Iterable.get:iterator` reference of a `for-in`: the class of the loop
/// iterable's static type, when it is an interface type other than `Iterable`
/// (`for (final s in shapes)` over a `List<Shape>` names `dart:core` `List`).
/// The loop asks the RUNTIME receiver for `iterator` by selector, and that
/// receiver is an instance of a subtype of the static type, so the per-release
/// check need only look at those classes, not at every `Iterable` of the
/// release (Flutter's `ObserverList` has no compiled `iterator` in a release
/// that never iterates one). One entry per receiver class, so two loops over a
/// `List` and a `Set` report both; a loop whose iterable is `dynamic`, a type
/// parameter or an extension type reports the entry without them, which the
/// CLI reads as before. A document below 23 never has them.
///
/// The fields are read from the lowered loop a real dill holds (the VM's
/// for-in lowering leaves a synthetic `:sync-for-iterator` variable initialized
/// with the iterable's `iterator`), so no version bump was needed to fill them:
/// the CLI reads a version-23 document's fields the same way, whoever wrote it.
///
/// Version 24 reports an `await` as a call of `Future.then`: the VM awaits a
/// `_Future` without calling `then`, but any other `Future` (a Flutter
/// `TickerFuture`, a user class) has its `then` called by selector
/// (`_SuspendState._awaitUserDefinedFuture`), and no source token names it.
/// The entry is `dart:async` `Future` `then`, with `receiverLibrary` and
/// `receiverClass` when the operand's static type is a class other than
/// `Future` (`await controller.forward()` names `TickerFuture`). An operand
/// that cannot be a `Future` (`await 1`, a record, a function, or a class no
/// `Future` subtype shares a subtype with, such as a `Model`) reports
/// nothing. `dynamic`, `FutureOr`, `Object?`, a type parameter or an extension
/// type reports the entry with no receiver. A class or interface reports one
/// entry per class that is a subtype of both it and `Future`, taken from the
/// patched component and from the release's (`Pingable` with `class Slow
/// implements Pingable, Future` names `Slow`, even when the patch deletes
/// `Slow`), and nothing when there is none. When the release's kernel cannot
/// be asked (it carries no platform) the entry is not narrowed. A document
/// below 24 never has them.
///
/// The same entry is reported
/// for the other places the VM calls `then` on a foreign future that the body
/// spells: a `return e` in an `async` body, `Completer.complete(e)`,
/// `Future.value(e)`, `Stream.fromFuture(e)`, `e.asStream()`, `Future.wait`,
/// `Future.any`, `Stream.fromFutures`, the `.wait` extensions of iterables and
/// records, and `Future.ignore()` and `Future.onError(...)`, called or torn
/// off. NOT reported: a `Future` returned by a callback (`then`,
/// `whenComplete`, `catchError`, `Future.delayed`, `Future.doWhile`,
/// `Future.forEach`, `Future.microtask`, `timeout(onTimeout:)`,
/// `Stream.asyncMap`), `StreamController.addStream`, and any other SDK or
/// package code that calls `then` on a future it was given.
///
/// Version 25 narrows the operand that is provably a `_Future`: a call of a
/// statically resolved `async` function, static method, extension method or
/// `super` method, or of the `Future` constructors that return a `_Future`
/// (`Future.delayed`, `Future.value`, `Future.sync`, `Future.microtask`,
/// `Future()`). It reports the entry with `receiverClass` `_Future`, which the
/// CLI's kept check does not take for a hazard (awaiting a `_Future` never calls
/// `then`), where 24 reported the unnarrowed `Future.then`, so a release that
/// allocates a `TickerFuture` with no compiled `then` no longer refuses
/// `await fetch()`. An `await` of an interface call (`obj.fetch()`, which an
/// override may answer with another `Future`), a variable, a parameter or a
/// field is reported as in 24. A document below 25 never has the narrowing.
const analysisVersion = 25;

/// How the VM names a member of a given kind. ONE place, so no caller has to
/// know it. Verbatim from gen_target_manifest.dart.
String vmMemberName(String name, String kind) => switch (kind) {
  'getter' => 'get:$name',
  'setter' => 'set:$name',
  _ => name,
};

void main(List<String> args) {
  String? basePath;
  String? patchedPath;
  String? outPath;
  // D0.2. Census mode reads ONE dill and asks the lowering contract about every
  // instance procedure in it, rather than about the members a patch changed.
  var census = false;
  String? censusPath;
  final includePrefixes = <String>[];
  // Version 15: unchanged members to analyze as if they had changed.
  final carryKeys = <String>{};
  // Probe only: carry EVERY member present on both sides (the retention sweep).
  var carryAll = false;

  // `--scan-bytecode <file>`: not an analysis. Prints which selectors the
  // compiled replacement still calls BY NAME; see [_scanBytecode].
  if (args.length == 2 && args[0] == '--scan-bytecode') {
    _scanBytecode(args[1]);
    return;
  }

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String next() {
      if (i + 1 >= args.length) _die('$a needs a value');
      return args[++i];
    }

    switch (a) {
      case '--base-dill':
        basePath = next();
      case '--patched-dill':
        patchedPath = next();
      case '--out':
        outPath = next();
      case '--include':
        includePrefixes.add(next());
      case '--carry':
        carryKeys.add(next());
      case '--carry-all':
        carryAll = true;
      case '--census':
        census = true;
      case '--dill':
        censusPath = next();
      case '-h':
      case '--help':
        print('''
Route B coverage analyzer -- classifies a kernel change against a release.

analyze_coverage --base-dill <release.dill> --patched-dill <patched.dill>
                 [--include <library-uri-prefix>]... [--out coverage.json]
                 [--carry <library#selector>]...

--carry analyzes an unchanged member as if it had changed, for a patch that must
replace callers holding an inlined or folded copy of a changed member. A key
that is not an unchanged app member present on both sides is ignored, and so
never appears under `carried`.

Writes one JSON document (stdout if --out is omitted) and always exits 0: the
verdict is data, not an exit code, so a caller cannot act on it by accident.

analyze_coverage --census --dill <app.dill>
                 [--include <library-uri-prefix>]... [--out rows.jsonl]

CENSUS MODE (D0.2). Asks the SAME lowering contract about every instance
procedure in one kernel, and writes one JSON object per line. It is a
STRUCTURAL reachability measurement over methods that EXIST -- not an estimate
of how many real patches would succeed. See the header of the reporter,
coverage/census_report.py, for what the numbers may and may not be read as.
''');
        return;
      default:
        _die('unknown argument: $a');
    }
  }
  if (census) {
    if (censusPath == null) _die('--census needs --dill');
    _runCensus(censusPath, includePrefixes, outPath);
    return;
  }
  if (basePath == null) _die('--base-dill is required');
  if (patchedPath == null) _die('--patched-dill is required');

  final base = _load(basePath);
  final patched = _load(patchedPath);
  // One hierarchy per component. The RELEASE's is what makes the release
  // evidence meaningful: it must be resolved in the kernel that was actually
  // compiled, not in the patch's.
  // LAZY, and that is load-bearing rather than a micro-optimisation.
  //
  // v11 added these two lines eagerly, which silently made a fully-LINKED base
  // kernel a precondition of EVERY analysis. The release flow's early and late
  // agreement checks pass the `--no-aot --no-link-platform` import kernel as
  // the base: its `dart:core` classes are external references with no AST, so
  // `ClassHierarchy` throws "Reference to dart:core::Object is not bound to an
  // AST node" and the analyzer exits 255. `agreesWith()` catches that, warns,
  // and returns false -- which makes the release DELETE `release_import.dill`
  // and ship unpatchable. Measured on release 140; the pre-v11 analyzer handles
  // the identical kernel at exit 0.
  //
  // Only the super-target paths need a hierarchy, and only for members that
  // actually carry a super invocation. Deferring construction means an unlinked
  // base kernel costs nothing unless something genuinely needs to resolve
  // against it -- and then it still fails loudly, at the member that needed it.
  // Whether the BASE component carries its platform. A `--no-link-platform`
  // kernel names dart:core but binds no AST for it, so any hierarchy over it
  // throws. Measured, not assumed: the class list is what ClassHierarchy walks.
  final baseIsLinked = componentIsLinked(base);
  late final baseHierarchy = ClassHierarchy(base, CoreTypes(base));
  late final patchedHierarchy = ClassHierarchy(patched, CoreTypes(patched));

  bool isApp(Library lib) {
    final uri = lib.importUri.toString();
    if (uri.startsWith('dart:')) return false;
    if (includePrefixes.isEmpty) return true;
    return includePrefixes.any(uri.startsWith);
  }

  // ---- target manifest, from the RELEASE kernel -------------------------
  //
  // The base dill, never the patched one. The manifest describes what the
  // shipped release can accept; asking the rebuilt kernel would let a change
  // vouch for itself.
  final targets = _manifest(base, isApp);

  // ---- what changed -----------------------------------------------------
  // Mixin copy names that collide in EITHER kernel, so both key and print
  // them alike; see `_comparedClasses` and `_UriPrinter`.
  final ambiguous = _ambiguousCopyNames(
    base,
  ).union(_ambiguousCopyNames(patched));
  _ambiguousCopies = ambiguous;
  final baseText = _memberText(base, isApp);
  final patchedText = _memberText(patched, isApp);
  // P4.4. The SIGNATURE, separately from the whole printed procedure.
  //
  // `_memberText` already differs when a signature changes, so a signature
  // change is reported as `changed` -- but that is indistinguishable from a body
  // edit, and the two have opposite consequences. A body edit is the point of a
  // patch; a signature change replaces a function the release's call sites
  // invoke with a DIFFERENT arity or shape, and those call sites carry the
  // release's own ArgumentsDescriptor. Nothing downstream could tell them apart
  // from here, so both sides are reported and the product decides.
  final baseSig = _memberSignature(base, isApp);
  final patchedSig = _memberSignature(patched, isApp);

  final changed = <String>[];
  final added = <String>[];
  for (final entry in patchedText.entries) {
    final before = baseText[entry.key];
    if (before == null) {
      added.add(entry.key);
    } else if (before != entry.value) {
      changed.add(entry.key);
    }
  }
  final removed = baseText.keys
      .where((k) => !patchedText.containsKey(k))
      .toList();
  changed.sort();
  added.sort();
  removed.sort();

  // Fields and constructors a patch cannot replace. Changed or new, never
  // removed: a patch that stops using a field asks nothing of the release.
  // Fields and constructor parameters present on both sides. Tree shaking
  // drops a field nothing reads, and a parameter nothing uses, so which exist
  // depends on the rest of the program; see `_constructorText`.
  final sharedFields = _keptKeys(
    base,
    isApp,
    ambiguous,
  ).intersection(_keptKeys(patched, isApp, ambiguous));
  final baseDecl = _declarationText(base, isApp, sharedFields, ambiguous);
  final patchedDecl = _declarationText(patched, isApp, sharedFields, ambiguous);
  final declarations = <Map<String, Object?>>[
    for (final entry in patchedDecl.entries)
      if (baseDecl[entry.key]?.text != entry.value.text)
        {
          'target': entry.key,
          'kind': entry.value.kind,
          'new': !baseDecl.containsKey(entry.key),
        },
  ]..sort((a, b) => (a['target']! as String).compareTo(b['target']! as String));

  // Version 15. Carried members go through everything a changed member does,
  // and stay out of `changed`, so carrying alone never makes a patch.
  if (carryAll) carryKeys.addAll(baseText.keys);
  final carried = [
    for (final key in carryKeys)
      if (!changed.contains(key) &&
          baseText.containsKey(key) &&
          patchedText.containsKey(key))
        key,
  ]..sort();
  final subjects = {...changed, ...carried};
  final callers = _callers(patched, isApp, subjects);
  // Version 16. Which new members are helpers; see `_helperPlan`.
  final plan = _helperPlan(base, patched, isApp, added, subjects);
  callers.addAll(plan.callers);

  // ---- where each changed member's new body lives ------------------------
  //
  // From the PATCHED component, because that is the body a replacement carries.
  // Emitted as a source span rather than as text: the producer has the file, and
  // a span keeps this tool free of any opinion about how the replacement library
  // is assembled.
  //
  // `Dart_RouteBActivatePatch` attaches ONE function per payload, so a producer
  // needs exactly one declaration per target -- which is what a span gives it.
  final sources = <String, Map<String, Object?>>{};
  for (final lib in patched.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    void record(String? className, Procedure p) {
      final key = '$uri#${_selector(className, p)}';
      if (!subjects.contains(key) && !plan.helpers.contains(key)) return;
      // fileStartOffset spans the declaration INCLUDING annotations;
      // fileEndOffset is the closing token. Together they are the exact
      // source a single-function replacement library needs.
      final start = p.fileStartOffset;
      final end = p.fileEndOffset;
      if (start < 0 || end < 0 || end <= start) return;
      sources[key] = {
        'fileUri': p.fileUri.toString(),
        'start': start,
        // Inclusive of the closing token, which is what makes the slice a
        // complete declaration.
        'end': end + 1,
      };
    }

    for (final p in lib.procedures) {
      record(null, p);
    }
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        record(cls.name, p);
      }
    }
  }

  // ---- implicit-`this` lowering, for INSTANCE targets --------------------
  //
  // Kernel decides MEANING; the producer's source edit supplies syntax. What is
  // emitted here is only what text cannot answer: which accesses are
  // receiver-based, what they resolve to, and where their identifier starts.
  //
  // Deliberately narrow. Anything outside the supported surface is reported as
  // an `unsupported` reason rather than lowered on a guess -- a wrong lowering
  // compiles and then misbehaves on a device, which is the failure mode this
  // whole project is organised against.
  final lowering = <String, Map<String, Object?>>{};
  // Version 17: the instance helpers a lowered body may call.
  final helperMembers = <Member>{
    for (final lib in patched.libraries.where(isApp))
      for (final cls in lib.classes)
        for (final p in cls.procedures)
          if (!p.isStatic &&
              plan.helpers.contains(
                '${lib.importUri}#${_selector(cls.name, p)}',
              ))
            p,
  };
  for (final lib in patched.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        final key = '$uri#${_selector(cls.name, p)}';
        if (!(subjects.contains(key) || plan.helpers.contains(key)) ||
            p.isStatic) {
          continue;
        }
        lowering[key] = _lowering(cls, p, patchedHierarchy, helperMembers);
        // RELEASE EVIDENCE for the SAME method (analysis version 11).
        //
        // Same-method, never program-wide: the causal argument for the target
        // having AOT code is that the RELEASE version of THIS compiled method
        // direct-called it. Evidence from an unrelated method would not support
        // that chain (`super0/s2b1f/`).
        //
        // An empty list is meaningful and is emitted: it says the release
        // version of this method direct-called nothing, so any super site the
        // patch introduces has no evidence behind it.
        //
        // Resolving a super target needs a ClassHierarchy over the BASE
        // component, which needs its platform LINKED. The release flow also
        // calls this analyzer with the `--no-link-platform` import kernel as
        // base, to ask a different question -- does the import kernel contain
        // everything the AOT kernel compiled. For that base there is no
        // hierarchy to build, and v11 crashed the whole analysis trying.
        //
        // The key is OMITTED rather than emitted empty. Empty is a claim --
        // "the release version of this method direct-called nothing" -- and
        // making that claim from a kernel we could not examine would be a
        // measurement we did not take. Absent says we did not look.
        if (baseIsLinked) {
          final releaseClass = _findClass(base, uri, cls.name);
          final releaseMember = releaseClass == null
              ? null
              : _findProcedure(releaseClass, p.name.text, p.kind);
          lowering[key]!['releaseSuperTargets'] = releaseMember == null
              ? const <Map<String, Object?>>[]
              : _superTargets(baseHierarchy, releaseClass!, releaseMember);
          // SAME-METHOD construction evidence (analysis version 13).
          //
          // The constructor equivalent of the exact-super rule. A release-wide
          // manifest can contain `_Private.new` because SOME method constructed
          // it; that is not evidence that THIS method did, and a patch that
          // newly constructs it in a method which never did would be admitted
          // by a program-wide check. So the evidence is per-method, from the
          // release's own version of this same member.
          //
          // Emitted EMPTY when the release has no such member: the claim "the
          // release version of this method constructed nothing" is exactly
          // right for a member the release did not have. OMITTED entirely when
          // the base could not be examined, which says we did not look.
          lowering[key]!['releasePrivateConstructions'] = releaseMember == null
              ? const <Map<String, Object?>>[]
              : _privateConstructions(releaseClass!, releaseMember);
        }
      }
    }
  }

  // INSTANCE MEMBERS OF EXTENSIONS (version 22). Kernel makes each a static
  // procedure of the library taking the receiver first, so the replacement is
  // the same top-level function a class member lowers to.
  for (final lib in patched.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    for (final p in lib.procedures) {
      if (!p.isExtensionMember) continue;
      final key = '$uri#${_selector(null, p)}';
      if (!subjects.contains(key)) continue;
      final found = _extensionInstanceMember(p);
      if (found == null) continue;
      lowering[key] = _extensionLowering(p, found.$1, found.$2);
      if (baseIsLinked) {
        // The same-method construction evidence of version 13, for the
        // release's own version of this member. A release without it has
        // constructed nothing here.
        Procedure? releaseMember;
        for (final rl in base.libraries) {
          if (rl.importUri.toString() != uri) continue;
          for (final rp in rl.procedures) {
            if (rp.name.text == p.name.text && rp.kind == p.kind) {
              releaseMember = rp;
            }
          }
        }
        lowering[key]!['releaseSuperTargets'] = const <Map<String, Object?>>[];
        lowering[key]!['releasePrivateConstructions'] = releaseMember == null
            ? const <Map<String, Object?>>[]
            : _privateConstructionsIn(lib, releaseMember);
      }
    }
  }

  // ---- external references, for the retention check (version 18) --------
  //
  // One entry per member the patch would carry. Each is walked in the PATCHED
  // component, because that is the body whose source the replacement slices.
  // A reference to a helper the patch carries is not external: the replacement
  // declares it.
  final carriedMembers = <Member>{};
  final carriedBodies = <String, Procedure>{};
  for (final lib in patched.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    void collect(Class? cls, Procedure p) {
      final key = '$uri#${_selector(cls?.name, p)}';
      if (plan.helpers.contains(key)) carriedMembers.add(p);
      if (subjects.contains(key) || plan.helpers.contains(key)) {
        carriedBodies[key] = p;
      }
    }

    for (final p in lib.procedures) {
      collect(null, p);
    }
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        collect(cls, p);
      }
    }
  }
  // The app's instance members by plain name, for a dynamic call's candidates
  // (analysis version 19): a call by name can land on any app class that has
  // a member of that name.
  final appMembersByName = <String, List<Member>>{};
  for (final lib in patched.libraries) {
    if (!isApp(lib)) continue;
    for (final cls in lib.classes) {
      for (final m in cls.members) {
        if (m is Constructor || !m.isInstanceMember) continue;
        (appMembersByName[m.name.text] ??= []).add(m);
      }
    }
  }
  final patchedTypes = TypeEnvironment(CoreTypes(patched), patchedHierarchy);
  final futureWorld = futureWorldFor(
    patchedTypes,
    base,
    baseHierarchy: () => baseHierarchy,
  );
  final externalReferences = <String, List<Map<String, Object?>>>{
    for (final key in carriedBodies.keys.toList()..sort())
      key: _externalReferences(
        carriedBodies[key]!,
        carriedMembers,
        appMembersByName: appMembersByName,
        types: patchedTypes,
        world: futureWorld,
      ),
  };

  // ---- classify ---------------------------------------------------------
  final reach = <String, String>{};
  final reasonFor = <String, String>{};
  for (final t in targets) {
    final key = '${t['library']}#${t['selector']}';
    reach[key] = t['reachable']! as String;
    reasonFor[key] = t['reason']! as String;
  }

  final patchable = <String>[];
  final conditional = <String>[];
  final unreachable = <String>[];
  final unknown = <String>[];
  for (final key in subjects.toList()..sort()) {
    switch (reach[key]) {
      case 'yes':
        patchable.add(key);
      case 'conditional':
        conditional.add(key);
      case 'no':
        unreachable.add(key);
      default:
        unknown.add(key);
    }
  }

  // ---- the verdict ------------------------------------------------------
  //
  // Whole-patch, never per-target: 4 changed / 3 representable / 1 rejected
  // rejects all four. Shipping the 3 would install cleanly and leave the app
  // in a state no one designed -- three functions from the patch, one from the
  // release.
  //
  // Rejection reasons are attributed PER TARGET here, where the reference tool
  // reports counts. Same rule, same strings; a count cannot tell you which
  // function to go look at.
  final rejectedAdded = [
    for (final key in added)
      if (plan.rejected.containsKey(key)) key,
  ];
  final rejections = <Map<String, Object?>>[
    for (final key in unreachable)
      {'target': key, 'category': 'unreachable', 'reason': reasonFor[key]},
    for (final key in unknown)
      {
        'target': key,
        'category': 'unknown',
        'reason':
            'not in the release manifest; unknown reachability is not '
            'the same as reachable',
      },
    for (final key in rejectedAdded)
      {'target': key, 'category': 'added', 'reason': plan.rejected[key]},
    for (final d in declarations)
      {
        'target': d['target'],
        'category': 'declaration',
        'reason': _declarationReason(
          d['kind']! as String,
          isNew: d['new']! as bool,
        ),
      },
  ];

  // Verbatim from build_patch.dart, including the order, so the harness can
  // compare the joined string against that tool's stderr.
  final reasons = <String>[];
  if (unreachable.isNotEmpty) {
    reasons.add('${unreachable.length} changed member(s) are not reachable');
  }
  if (unknown.isNotEmpty) {
    reasons.add('${unknown.length} changed member(s) are not in the manifest');
  }
  if (rejectedAdded.isNotEmpty) {
    reasons.add(
      '${rejectedAdded.length} member(s) are new and cannot be carried; a '
      'patch replaces bodies, and only a top-level function or getter, or an '
      'instance method of an existing class, used by nothing outside the '
      'patch can be added',
    );
  }

  if (declarations.isNotEmpty) {
    reasons.add(
      '${declarations.length} field(s), constant(s) or constructor(s) '
      'changed; a patch replaces method bodies only, so the release would '
      'keep its own',
    );
  }

  // Three outcomes, matching the reference tool's exit codes 0 / 3 / 4. `inert`
  // is not a failure and not a success: a patch carrying nothing installs and
  // changes nothing, which is worse than refusing because it looks like it
  // worked.
  final String verdict;
  if (changed.isEmpty &&
      rejectedAdded.isEmpty &&
      plan.helpers.isEmpty &&
      removed.isEmpty &&
      declarations.isEmpty) {
    verdict = 'inert';
  } else if (changed.isEmpty) {
    verdict = reasons.isEmpty ? 'inert' : 'reject';
  } else {
    verdict = reasons.isEmpty ? 'accept' : 'reject';
  }

  // Only for members that exist on BOTH sides: an added member has no release
  // signature to compare against, and a removed one has no replacement.
  final signatures = <String, Map<String, Object?>>{
    for (final key in subjects.toList()..sort())
      if (baseSig[key] != null && patchedSig[key] != null)
        key: {
          'release': baseSig[key],
          'patch': patchedSig[key],
          'changed': baseSig[key] != patchedSig[key],
        },
  };

  final document = {
    'analysisVersion': analysisVersion,
    'baseDill': basePath,
    'patchedDill': patchedPath,
    'targets': targets,
    'changed': changed,
    'carried': carried,
    'callers': callers,
    'added': added,
    'helpers': plan.helpers.toList()..sort(),
    'unusedHelpers': plan.unused.toList()..sort(),
    'removed': removed,
    'declarations': declarations,
    'patchable': patchable,
    'conditional': conditional,
    'unreachable': unreachable,
    'unknown': unknown,
    'sources': sources,
    'lowering': lowering,
    'externalReferences': externalReferences,
    // What the enclosing class's scope gives a copied body, per class member
    // the patch would carry. Absent on a document from an older analyzer, which
    // the producer reads as "not measured". See `enclosingScopeOf`.
    'enclosingScope': {
      for (final key in carriedBodies.keys.toList()..sort())
        if (enclosingScopeOf(carriedBodies[key]!) case final scope?) key: scope,
    },
    'signatures': signatures,
    'rejections': rejections,
    'refusalSummary': reasons.isEmpty ? null : reasons.join('; '),
    'verdict': verdict,
  };

  final json = '${const JsonEncoder.withIndent('  ').convert(document)}\n';
  if (outPath == null) {
    stdout.write(json);
  } else {
    File(outPath).writeAsStringSync(json);
  }
}

/// Verbatim from gen_target_manifest.dart, minus the file/argument handling.
List<Map<String, Object?>> _manifest(
  Component component,
  bool Function(Library) isApp,
) {
  final targets = <Map<String, Object?>>[];

  void addProcedure(Procedure p, String libraryUri, String? className) {
    final kind = switch (p.kind) {
      ProcedureKind.Getter => 'getter',
      ProcedureKind.Setter => 'setter',
      ProcedureKind.Operator => 'operator',
      ProcedureKind.Factory => 'factory',
      ProcedureKind.Method => 'method',
    };

    // Reachability, per step 1's measured inventory. A static-shaped call is
    // emitted as Route B's patchable form. An instance member is only reachable
    // where the compiler devirtualizes its call sites; where it stays
    // polymorphic the call is specialized into a dispatch-table call and no
    // patch can reach it. Which of those a given SITE is, is decided by the
    // precompiler and is not visible in this kernel -- so it is reported as
    // conditional rather than guessed at. Reporting a guess as a fact is how a
    // link percentage becomes a lie.
    final isStaticShaped = p.isStatic || className == null;
    final String reachable;
    final String reason;
    if (isStaticShaped) {
      reachable = 'yes';
      reason = 'static-shaped call; emitted as the patchable form';
    } else if (p.isAbstract) {
      reachable = 'no';
      reason = 'abstract; call sites dispatch to implementations';
    } else {
      reachable = 'conditional';
      reason =
          'instance member; reachable only where the call site devirtualizes '
          'or goes through the cid chain, not where it becomes a '
          'dispatch-table call';
    }

    targets.add({
      'library': libraryUri,
      'class': className,
      'name': p.name.text,
      'kind': kind,
      'vmName': vmMemberName(p.name.text, kind),
      'selector': className == null
          ? vmMemberName(p.name.text, kind)
          : '$className.${vmMemberName(p.name.text, kind)}',
      'reachable': reachable,
      'reason': reason,
    });
  }

  for (final lib in component.libraries.where(isApp)) {
    final libraryUri = lib.importUri.toString();
    for (final p in lib.procedures) {
      addProcedure(p, libraryUri, null);
    }
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        addProcedure(p, libraryUri, cls.name);
      }
    }
  }

  targets.sort((a, b) {
    final byLib = (a['library']! as String).compareTo(b['library']! as String);
    if (byLib != 0) return byLib;
    final byCls = ((a['class'] ?? '') as String).compareTo(
      (b['class'] ?? '') as String,
    );
    if (byCls != 0) return byCls;
    return (a['name']! as String).compareTo(b['name']! as String);
  });

  return targets;
}

Component _load(String path) {
  final c = Component();
  BinaryBuilder(File(path).readAsBytesSync()).readComponent(c);
  return c;
}

/// Version 15: for each key in [subjects], the app members in [c] whose bodies
/// name it -- a call, a get or set, a tear-off, a super access, an `==` -- or
/// name a member it overrides, since a call through the overridden member can
/// reach it. A dynamic access counts for every subject of its name. A
/// reference inside a closure counts for the member the closure is written in.
/// Constructors and field initializers are included under their own keys
/// (`Class.new`, `Class.name`, a top-level field's name); no patch can carry
/// them, so naming them makes the CLI refuse. Sorted, without the member
/// itself.
Map<String, List<String>> _callers(
  Component c,
  bool Function(Library) isApp,
  Set<String> subjects,
) {
  String? keyOf(Member m) {
    if (m is! Procedure) return null;
    final lib = m.enclosingLibrary;
    if (!isApp(lib)) return null;
    return '${lib.importUri}#${_selector(m.enclosingClass?.name, m)}';
  }

  // Each subject, and every member it overrides, by the member object.
  final wanted = <Member, Set<String>>{};
  for (final lib in c.libraries.where(isApp)) {
    for (final p in lib.procedures) {
      final key = keyOf(p);
      if (key != null && subjects.contains(key)) (wanted[p] ??= {}).add(key);
    }
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        final key = keyOf(p);
        if (key == null || !subjects.contains(key)) continue;
        (wanted[p] ??= {}).add(key);
        if (p.isStatic) continue;
        final seen = <Class>{};
        void up(Class k) {
          for (final s in k.supers) {
            final sc = s.classNode;
            if (!seen.add(sc)) continue;
            for (final q in sc.procedures) {
              if (q.name == p.name && q.kind == p.kind && !q.isStatic) {
                (wanted[q] ??= {}).add(key);
              }
            }
            up(sc);
          }
        }

        up(cls);
      }
    }
  }

  // A dynamic access names a member, not a target: it can reach any member of
  // that name, so it counts as a call to every subject called that.
  final byName = <String, Set<String>>{};
  for (final e in wanted.entries) {
    (byName[e.key.name.text] ??= {}).addAll(e.value);
  }

  final out = {for (final k in subjects) k: <String>{}};
  void record(String caller, TreeNode node) {
    final refs = _References();
    node.accept(refs);
    final hit = <String>{
      for (final m in refs.members) ...?wanted[m],
      for (final n in refs.dynamicNames) ...?byName[n],
    };
    for (final key in hit) {
      if (key != caller) out[key]!.add(caller);
    }
  }

  void scan(Procedure p) {
    final caller = keyOf(p);
    if (caller != null) record(caller, p.function);
  }

  // NOT ONLY PROCEDURES. A constructor's initializers and body, and a field's
  // initializer, run code too, and a folded target's old value can sit in them.
  // A patch replaces procedures only, so these callers can never be carried.
  // They are reported anyway, under their own keys: the CLI then lacks them as
  // companions and refuses the patch, naming them, instead of shipping one that
  // leaves those paths on the release's value.
  String nonProcedureKey(Library lib, Class? cls, String name) =>
      '${lib.importUri}#${cls == null ? name : '${cls.name}.$name'}';

  void scanConstructor(Library lib, Class cls, Constructor k) {
    final key = nonProcedureKey(
      lib,
      cls,
      k.name.text.isEmpty ? 'new' : k.name.text,
    );
    for (final i in k.initializers) {
      record(key, i);
    }
    record(key, k.function);
  }

  void scanField(Library lib, Class? cls, Field f) {
    final init = f.initializer;
    if (init != null) record(nonProcedureKey(lib, cls, f.name.text), init);
  }

  for (final lib in c.libraries.where(isApp)) {
    lib.procedures.forEach(scan);
    for (final f in lib.fields) {
      scanField(lib, null, f);
    }
    for (final cls in lib.classes) {
      cls.procedures.forEach(scan);
      for (final k in cls.constructors) {
        scanConstructor(lib, cls, k);
      }
      for (final f in cls.fields) {
        scanField(lib, cls, f);
      }
    }
  }
  return {for (final e in out.entries) e.key: e.value.toList()..sort()};
}

/// Version 16: what to do with each member only the patched kernel has.
class _HelperPlan {
  _HelperPlan(this.helpers, this.unused, this.rejected, this.callers);

  /// Accepted: shipped inside every replacement library that needs it.
  final Set<String> helpers;

  /// Eligible and called by nothing the patch reaches. Not shipped, not fatal.
  final Set<String> unused;

  /// Every other added member, with the reason it stays refused.
  final Map<String, String> rejected;

  /// For each helper (accepted or unused), the app members that name it.
  final Map<String, List<String>> callers;
}

/// Decides which of [added] are helpers.
///
/// A helper is a top-level method or getter, declared in its library's own file
/// with a usable source span, whose every caller is a [subjects] member or
/// another accepted helper, and which some subject reaches. The caller test is
/// the point: the release's own code cannot call a function the release lacks,
/// so a caller outside the patch means the member would be unreachable or the
/// patch would be changing code it does not carry. Callers come from the same
/// walk as version 15's (`_callers`), closures and dynamic accesses included.
_HelperPlan _helperPlan(
  Component base,
  Component patched,
  bool Function(Library) isApp,
  List<String> added,
  Set<String> subjects,
) {
  final rejected = <String, String>{};
  final candidates = <String>{};
  final addedSet = added.toSet();
  for (final lib in patched.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    void visit(Class? cls, Procedure p) {
      final key = '$uri#${_selector(cls?.name, p)}';
      if (!addedSet.contains(key)) return;
      final String? reason;
      if (cls != null) {
        reason = _instanceHelperReason(base, patched, lib, cls, p);
      } else if (p.kind != ProcedureKind.Method &&
          p.kind != ProcedureKind.Getter) {
        reason =
            'a ${p.kind == ProcedureKind.Setter ? 'setter' : 'operator'}'
            '; only a top-level function or getter can be added';
      } else if (p.isExtensionMember ||
          p.isExtensionTypeMember ||
          p.name.text.contains('|') ||
          p.name.text.contains('#')) {
        reason =
            'an extension member, which cannot be sliced out of its '
            'extension; only a top-level function or getter can be added';
      } else if (p.isAbstract || p.isExternal) {
        reason = 'abstract or external, so it has no body to carry';
      } else if (p.fileStartOffset < 0 ||
          p.fileEndOffset < 0 ||
          p.fileEndOffset <= p.fileStartOffset) {
        reason =
            'the kernel records no source span for it, so its source '
            'cannot be carried';
      } else if (p.fileUri != lib.fileUri) {
        reason =
            'declared in a `part` file, which a replacement library '
            'cannot reproduce; move it into the library file';
      } else if (p.name.isPrivate &&
          (_declarationClash(base, uri, p.name, null) ??
                  _declarationClash(patched, uri, p.name, p)) !=
              null) {
        // Version 17: a private name the producer exempts from its backstop
        // as "a helper this patch carries" must mean only the helper.
        reason =
            'its private name is also used by '
            '${_declarationClash(base, uri, p.name, null) ?? _declarationClash(patched, uri, p.name, p)}'
            '; a carried helper\'s private name must be unique in its library';
      } else {
        reason = null;
      }
      if (reason == null) {
        candidates.add(key);
      } else {
        rejected[key] = 'new member, and $reason';
      }
    }

    for (final p in lib.procedures) {
      visit(null, p);
    }
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        visit(cls, p);
      }
    }
  }
  // An added member with no procedure form (should not happen) stays refused.
  for (final key in added) {
    if (!candidates.contains(key) && !rejected.containsKey(key)) {
      rejected[key] = 'new member that this analysis cannot classify';
    }
  }

  // A helper used as a value is refused. Each replacement library carries its
  // own copy of a helper, so a tear-off taken in one patched function is not
  // identical to one taken in another: `addListener(_onTick)` in one and
  // `removeListener(_onTick)` in the other would remove nothing.
  final values = _References();
  for (final lib in patched.libraries.where(isApp)) {
    lib.accept(values);
  }
  for (final m in values.tearOffs) {
    if (m is! Procedure || m.enclosingClass != null) continue;
    final key = '${m.enclosingLibrary.importUri}#${_selector(null, m)}';
    if (candidates.remove(key)) {
      rejected[key] =
          'new member, and it is used as a value (torn off), not '
          'only called. Each patched function carries its own copy of a new '
          'function, so two copies of it would not be identical; call it '
          'instead, for example through a closure';
    }
  }

  final callers = _callers(patched, isApp, candidates);
  String libraryOf(String key) => key.split('#').first;
  // Version 17: how each instance candidate is USED, which `callers` cannot
  // say (it does not tell a call on `this` from a call on another receiver).
  final instanceMembers = <Member, String>{};
  for (final lib in patched.libraries.where(isApp)) {
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        final key = '${lib.importUri}#${_selector(cls.name, p)}';
        if (!p.isStatic && candidates.contains(key)) instanceMembers[p] = key;
      }
    }
  }
  final instanceNames = {
    for (final e in instanceMembers.entries) e.value: e.key.name.text,
  };
  final uses = _InstanceHelperUses(instanceMembers);
  if (instanceMembers.isNotEmpty) {
    for (final lib in patched.libraries.where(isApp)) {
      final uri = lib.importUri;
      for (final p in lib.procedures) {
        uses.scan(p, '$uri#${_selector(null, p)}');
      }
      for (final f in lib.fields) {
        uses.scan(f, null);
      }
      for (final cls in lib.classes) {
        for (final p in cls.procedures) {
          uses.scan(p, '$uri#${_selector(cls.name, p)}');
        }
        for (final m in <Member>[...cls.constructors, ...cls.fields]) {
          uses.scan(m, null);
        }
      }
    }
  }
  // The class a member key belongs to, or null for a top-level member.
  String? classOf(String key) {
    final selector = key.split('#').last;
    final dot = selector.indexOf('.');
    return dot < 0 ? null : selector.substring(0, dot);
  }

  // Drop a candidate with a caller outside the patch, until nothing changes: a
  // dropped helper is not part of the patch, so what only IT called loses its
  // justification too.
  final accepted = {...candidates};
  var again = true;
  while (again) {
    again = false;
    for (final key in accepted.toList()) {
      String? bad = uses.bad[key];
      // A local, parameter or local function of the helper's name in a body
      // that calls it: `this.m()` rewritten to `m(self)` would bind to it.
      final helperName = instanceNames[key];
      if (bad == null && helperName != null) {
        final shadowing = callers[key]!
            .where((c) => uses.localNames[helperName]?.contains(c) ?? false)
            .firstOrNull;
        if (shadowing != null) {
          bad =
              'a local variable, parameter or local function named '
              '`$helperName` in `$shadowing`, which calls it, would capture '
              'the call once it is rewritten';
        }
      }
      for (final c in bad != null ? const <String>[] : callers[key]!) {
        if (libraryOf(c) != libraryOf(key)) {
          bad =
              '`$c` in another library calls it; a replacement library '
              'holds one library\'s helpers';
        } else if (instanceMembers.containsValue(key) &&
            classOf(c) != classOf(key)) {
          bad =
              '`$c` calls it, and an instance method can only be called from '
              'its own class';
        } else if (!subjects.contains(c) && !accepted.contains(c)) {
          bad =
              '`$c` calls it, and that is neither a changed member nor a '
              'helper the patch can carry, so the release would call a '
              'function it does not have';
        }
        if (bad != null) break;
      }
      if (bad != null) {
        accepted.remove(key);
        rejected[key] = 'new member, and $bad';
        again = true;
      }
    }
  }

  // Reachable from a subject, through accepted helpers only.
  final reached = <String>{};
  again = true;
  while (again) {
    again = false;
    for (final key in accepted) {
      if (reached.contains(key)) continue;
      if (callers[key]!.any(
        (c) => subjects.contains(c) || reached.contains(c),
      )) {
        reached.add(key);
        again = true;
      }
    }
  }
  return _HelperPlan(reached, accepted.difference(reached), rejected, {
    for (final key in accepted) key: callers[key]!,
  });
}

/// Why [p], a member of [cls] that only the patched kernel has, cannot be an
/// instance helper; null when it can. See analysis version 17.
String? _instanceHelperReason(
  Component base,
  Component patched,
  Library lib,
  Class cls,
  Procedure p,
) {
  const tail =
      'only a top-level function or getter, or an instance method '
      'of an existing class, can be added';
  if (p.isStatic) {
    return 'a static member of `${cls.name}`; a replacement calling it would '
        "bind to the release's `${cls.name}`, which has no such member; $tail";
  }
  if (p.kind != ProcedureKind.Method) {
    return 'an instance ${switch (p.kind) {
      ProcedureKind.Getter => 'getter',
      ProcedureKind.Setter => 'setter',
      _ => 'operator',
    }} of `${cls.name}`; only an instance METHOD can be added';
  }
  if (p.isAbstract || p.isExternal) {
    return 'abstract or external, so it has no body to carry';
  }
  if (cls.isMixinDeclaration || cls.isAnonymousMixin || cls.isEnum) {
    return 'a member of ${cls.isEnum ? 'an enum' : 'a mixin'}, which is not '
        'supported; $tail';
  }
  final uri = lib.importUri.toString();
  if (_findClass(base, uri, cls.name) == null) {
    return 'a member of `${cls.name}`, which the release does not have';
  }
  // A public name is refused below, after the hierarchy check names an
  // override; uniqueness matters for the private names a helper carries.
  final clash = !p.name.isPrivate
      ? null
      : _declarationClash(base, uri, p.name, null) ??
            _declarationClash(patched, uri, p.name, p);
  if (clash != null) {
    return "its name is also used by $clash; a carried helper's private name "
        'must be unique in its library, or a reference to the other '
        'declaration could bind to the helper (or the reverse)';
  }
  for (final (label, component) in [('release', base), ('patch', patched)]) {
    final clashWith = _hierarchyClash(component, uri, cls.name, p.name);
    if (clashWith != null) {
      return 'overriding or overridden ($clashWith in the $label kernel); a '
          'call by selector would miss the copy a patch ships';
    }
  }
  if (!p.name.isPrivate) {
    return 'a PUBLIC method, which code outside this library can call by name '
        "(`jsonEncode` calls `toJson` on what it is given), and the release's "
        '`${cls.name}` has no such method; only a private instance method '
        'can be added';
  }
  if (p.fileStartOffset < 0 ||
      p.fileEndOffset < 0 ||
      p.fileEndOffset <= p.fileStartOffset) {
    return 'the kernel records no source span for it, so its source cannot be '
        'carried';
  }
  if (p.fileUri != lib.fileUri) {
    return 'declared in a `part` file, which a replacement library cannot '
        'reproduce; move it into the library file';
  }
  return null;
}

/// A description of a declaration of the library [uri] in [component], other
/// than [except], that is named [name] (same text), or null. Covers top-level
/// declarations, the members of every class, constructors and extension
/// members: a carried helper's private name has to be unique in its library.
String? _declarationClash(
  Component component,
  String uri,
  Name name,
  Member? except,
) {
  for (final lib in component.libraries) {
    if (lib.importUri.toString() != uri) continue;
    bool same(Name n) => n.text == name.text;
    for (final p in lib.procedures) {
      if (p != except && same(p.name)) return 'the top-level `${p.name.text}`';
    }
    for (final f in lib.fields) {
      if (f != except && same(f.name)) return 'the top-level `${f.name.text}`';
    }
    for (final c in lib.classes) {
      if (c.name == name.text) return 'the class `${c.name}`';
      for (final p in c.procedures) {
        if (p != except && same(p.name)) {
          return '`${c.name}.${p.name.text}`';
        }
      }
      for (final f in c.fields) {
        if (f != except && same(f.name)) return '`${c.name}.${f.name.text}`';
      }
      for (final k in c.constructors) {
        if (same(k.name)) return 'a constructor of `${c.name}`';
      }
    }
    for (final t in lib.typedefs) {
      if (t.name == name.text) return 'the typedef `${t.name}`';
    }
    for (final e in lib.extensionTypeDeclarations) {
      if (e.name == name.text) return 'the extension type `${e.name}`';
      if (e.representationName == name.text) {
        return 'the representation field of the extension type `${e.name}`';
      }
      for (final d in e.memberDescriptors) {
        if (same(d.name)) return 'a member of the extension type `${e.name}`';
      }
    }
    for (final e in lib.extensions) {
      if (e.name == name.text) return 'the extension `${e.name}`';
      for (final d in e.memberDescriptors) {
        if (same(d.name)) return 'a member of the extension `${e.name}`';
      }
    }
  }
  return null;
}

/// The supertype closure of every class of a component, computed once.
final _supersCache = Expando<Map<Class, Set<Class>?>>('route b supertypes');

/// Every class reachable up from [k], or null when one cannot be read.
Set<Class>? _supertypeClosure(Class k) {
  final out = <Class>{};
  final pending = [k];
  try {
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      for (final s in next.supers) {
        if (out.add(s.classNode)) pending.add(s.classNode);
      }
    }
  } on Object {
    return null;
  }
  return out;
}

/// A description of a class that, in [component], declares a member named
/// [name] while being a supertype or subtype of the class `uri#className`,
/// or null. A private [name] only matches a member of its own library. An
/// unlinked kernel (a supertype with no AST) answers with a refusal, since the
/// hierarchy cannot be read.
String? _hierarchyClash(
  Component component,
  String uri,
  String className,
  Name name,
) {
  final cls = _findClass(component, uri, className);
  if (cls == null) return null;
  bool declares(Class k) {
    bool same(Name n) =>
        n.text == name.text &&
        (!name.isPrivate || n.library?.importUri.toString() == uri);
    return k.procedures.any((q) => same(q.name)) ||
        k.fields.any((f) => same(f.name));
  }

  final cache = _supersCache[component] ??= {};
  Set<Class>? supers(Class k) =>
      cache.containsKey(k) ? cache[k] : cache[k] = _supertypeClosure(k);

  final up = supers(cls);
  if (up == null) return 'its supertypes could not be read';
  for (final k in up) {
    if (declares(k)) return '`${k.name}` declares `${name.text}`';
  }
  for (final lib in component.libraries) {
    if (lib.importUri.toString().startsWith('dart:')) continue;
    for (final k in lib.classes) {
      if (k == cls) continue;
      final ks = supers(k);
      if (ks == null) return 'a supertype could not be read';
      if (ks.contains(cls) && declares(k)) {
        return '`${k.name}` declares `${name.text}`';
      }
    }
  }
  return null;
}

/// Version 17: how each instance helper candidate is used. A use is valid only
/// as a call with implicit `this` (or `this.`) from an instance procedure of
/// the candidate's own class; everything else is recorded, with its reason, in
/// [bad]: a call on another receiver, a super call, a tear-off, a dynamic
/// access of the same name, or any use from a constructor, a field initializer,
/// a static or top-level member, or another class.
class _InstanceHelperUses extends RecursiveVisitor {
  _InstanceHelperUses(this.targets) {
    for (final e in targets.entries) {
      (_byName[e.key.name.text] ??= {}).add(e.value);
    }
  }

  final Map<Member, String> targets;
  final bad = <String, String>{};
  final _byName = <String, Set<String>>{};
  Member? _context;

  /// Names of the locals, parameters and local functions declared in each
  /// scanned member, by name then by member key.
  final localNames = <String, Set<String>>{};
  String? _contextKey;

  void scan(Member m, String? key) {
    _context = m;
    _contextKey = key;
    m.accept(this);
    _context = null;
    _contextKey = null;
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final name = node.variable.cosmeticName;
    final key = _contextKey;
    if (name != null && key != null && _byName.containsKey(name)) {
      (localNames[name] ??= {}).add(key);
    }
    super.visitVariableDeclaration(node);
  }

  void _flag(Member? m, String why) {
    final key = targets[m];
    if (key != null) bad.putIfAbsent(key, () => why);
  }

  void _dynamic(Name name) {
    for (final key in _byName[name.text] ?? const <String>{}) {
      bad.putIfAbsent(
        key,
        () => 'a dynamic access of `${name.text}` could reach it',
      );
    }
  }

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    final target = node.interfaceTarget;
    if (targets.containsKey(target)) {
      final context = _context;
      if (node.receiver is! ThisExpression) {
        _flag(target, 'it is called on another receiver (`other.m()`)');
      } else if (context is! Procedure ||
          context.isStatic ||
          context.enclosingClass != target.enclosingClass) {
        _flag(
          target,
          'it is called from outside an instance method of `${target.enclosingClass!.name}`',
        );
      }
    }
    super.visitInstanceInvocation(node);
  }

  @override
  void visitInstanceTearOff(InstanceTearOff node) {
    _flag(
      node.interfaceTarget,
      'it is used as a value (torn off), not only called',
    );
    super.visitInstanceTearOff(node);
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    _flag(node.interfaceTarget, 'it is read as a property');
    super.visitInstanceGet(node);
  }

  @override
  void visitInstanceGetterInvocation(InstanceGetterInvocation node) {
    _flag(node.interfaceTarget, 'it is read as a property');
    super.visitInstanceGetterInvocation(node);
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    _flag(node.interfaceTarget, 'it is assigned');
    super.visitInstanceSet(node);
  }

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    _flag(node.interfaceTarget, 'it is called through `super`');
    super.visitSuperMethodInvocation(node);
  }

  @override
  void visitSuperPropertyGet(SuperPropertyGet node) {
    _flag(node.interfaceTarget, 'it is read through `super`');
    super.visitSuperPropertyGet(node);
  }

  @override
  void visitDynamicInvocation(DynamicInvocation node) {
    _dynamic(node.name);
    super.visitDynamicInvocation(node);
  }

  @override
  void visitDynamicGet(DynamicGet node) {
    _dynamic(node.name);
    super.visitDynamicGet(node);
  }

  @override
  void visitDynamicSet(DynamicSet node) {
    _dynamic(node.name);
    super.visitDynamicSet(node);
  }
}

/// Every member a body names, closures included, and the names it accesses
/// dynamically.
class _References extends RecursiveVisitor {
  final members = <Member>{};
  final dynamicNames = <String>{};

  @override
  void visitEqualsCall(EqualsCall node) {
    members.add(node.interfaceTarget);
    super.visitEqualsCall(node);
  }

  @override
  void visitDynamicInvocation(DynamicInvocation node) {
    dynamicNames.add(node.name.text);
    super.visitDynamicInvocation(node);
  }

  @override
  void visitDynamicGet(DynamicGet node) {
    dynamicNames.add(node.name.text);
    super.visitDynamicGet(node);
  }

  @override
  void visitDynamicSet(DynamicSet node) {
    dynamicNames.add(node.name.text);
    super.visitDynamicSet(node);
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    members.add(node.target);
    super.visitStaticInvocation(node);
  }

  @override
  void visitStaticGet(StaticGet node) {
    members.add(node.target);
    super.visitStaticGet(node);
  }

  @override
  void visitStaticSet(StaticSet node) {
    members.add(node.target);
    super.visitStaticSet(node);
  }

  /// Members used as a value (torn off) rather than called, constants
  /// included. A subset of [members].
  final tearOffs = <Member>{};

  @override
  void visitStaticTearOff(StaticTearOff node) {
    members.add(node.target);
    tearOffs.add(node.target);
    super.visitStaticTearOff(node);
  }

  // A tear-off inside a constant (`const [helper]`, a default value) is a
  // reference too. Version 16: before it, these were not seen at all.
  @override
  void visitConstantExpression(ConstantExpression node) {
    _constant(node.constant, <Constant>{});
    super.visitConstantExpression(node);
  }

  void _constant(Constant c, Set<Constant> seen) {
    if (!seen.add(c)) return;
    switch (c) {
      case StaticTearOffConstant():
        members.add(c.target);
        tearOffs.add(c.target);
      case InstantiationConstant():
        _constant(c.tearOffConstant, seen);
      case ListConstant():
        for (final e in c.entries) {
          _constant(e, seen);
        }
      case SetConstant():
        for (final e in c.entries) {
          _constant(e, seen);
        }
      case MapConstant():
        for (final e in c.entries) {
          _constant(e.key, seen);
          _constant(e.value, seen);
        }
      case InstanceConstant():
        for (final v in c.fieldValues.values) {
          _constant(v, seen);
        }
      case RecordConstant():
        for (final v in c.positional) {
          _constant(v, seen);
        }
        for (final v in c.named.values) {
          _constant(v, seen);
        }
      default:
        break;
    }
  }

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    members.add(node.interfaceTarget);
    super.visitInstanceInvocation(node);
  }

  @override
  void visitInstanceGetterInvocation(InstanceGetterInvocation node) {
    members.add(node.interfaceTarget);
    super.visitInstanceGetterInvocation(node);
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    members.add(node.interfaceTarget);
    super.visitInstanceGet(node);
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    members.add(node.interfaceTarget);
    super.visitInstanceSet(node);
  }

  @override
  void visitInstanceTearOff(InstanceTearOff node) {
    members.add(node.interfaceTarget);
    super.visitInstanceTearOff(node);
  }

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    final target = node.interfaceTarget;
    members.add(target);
    super.visitSuperMethodInvocation(node);
  }

  @override
  void visitSuperPropertyGet(SuperPropertyGet node) {
    members.add(node.interfaceTarget);
    super.visitSuperPropertyGet(node);
  }

  @override
  void visitSuperPropertySet(SuperPropertySet node) {
    members.add(node.interfaceTarget);
    super.visitSuperPropertySet(node);
  }
}

/// `library#selector` -> a stable textual form of the member.
///
/// Printed from the kernel AST rather than hashed from the binary: the binary
/// carries offsets and canonical-name indices that shift when unrelated code
/// moves, which would report the whole program as changed after a one-line
/// edit. Verbatim from build_patch.dart.
Map<String, String> _memberText(Component c, bool Function(Library) isApp) {
  final out = <String, String>{};
  for (final lib in c.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    for (final p in lib.procedures) {
      out['$uri#${_selector(null, p)}'] = _text(p);
    }
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        out['$uri#${_selector(cls.name, p)}'] = _text(p);
      }
    }
  }
  return out;
}

/// `library#Class.name` -> the printed declaration, for what a patch cannot
/// replace: fields, `const` included, constructors and class headers.
///
/// A Route B patch replaces procedure bodies. A field's initializer runs once,
/// from the release's code, and a constructor is not a procedure the release
/// can redirect. An edit to either used to be invisible here -- this tool only
/// compared procedures -- so it was reported as "nothing changed" when it stood
/// alone and dropped without a word when it rode along with other edits, which
/// shipped a patch that did not do what its source said.
///
/// A `const` is kept apart as its own kind, because the reason differs. Its
/// value is inlined at every use, so it might look carried by the members that
/// use it. It is not: the patch compiler resolves the name against the
/// RELEASE's kernel and inlines the release's value. A device printed the old
/// value of an edited `const` from a replaced body that named it.
///
/// This sees a `const` only where the release kept the declaration. A Route B
/// release is built with a dynamic interface that retains the app's libraries
/// whole, so the app's `const`s are kept. A dependency's `const` that tree
/// shaking removed from both kernels is not seen here, and neither is an app
/// `const` in a kernel built without that dynamic interface: a known gap.
///
/// The unnamed constructor is keyed `new`, as the capability manifest spells
/// it.
Map<String, ({String kind, String text})> _declarationText(
  Component c,
  bool Function(Library) isApp,
  Set<String> sharedFields,
  Set<String> ambiguous,
) {
  final out = <String, ({String kind, String text})>{};
  // A class another class extends, mixes in or implements is named as a type,
  // so tree shaking cannot have stripped its header; see `_classHeaderText`.
  // As references, not classes: a release's import kernel is built with
  // --no-link-platform, so `dart:core::Object` and every other SDK supertype is
  // a reference with no class behind it, and asking it for one throws.
  final supertypes = <Reference>{
    for (final lib in c.libraries)
      for (final cls in lib.classes)
        for (final s in [
          ?cls.supertype,
          ?cls.mixedInType,
          ...cls.implementedTypes,
        ])
          s.className,
  };
  for (final lib in c.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    for (final f in lib.fields) {
      out['$uri#${f.name.text}'] = (kind: _fieldKind(f), text: _text(f));
    }
  }
  for (final (:cls, :key, :isMixinCopy) in _comparedClasses(
    c,
    isApp,
    ambiguous,
  )) {
    final header = _classHeaderText(cls, supertypes.contains(cls.reference));
    if (header != null) {
      out[key] = (kind: 'class', text: header);
    }
    for (final f in cls.fields) {
      out['$key.${f.name.text}'] = (kind: _fieldKind(f), text: _text(f));
    }
    for (final k in cls.constructors) {
      final name = k.name.text.isEmpty ? 'new' : k.name.text;
      out['$key.$name'] = (
        kind: 'constructor',
        text: _constructorText(k, key, sharedFields),
      );
    }
    if (isMixinCopy) {
      // The procedure diff above walks app libraries only, so a mixin's
      // methods are compared here. A body the shaker made unreachable on
      // this side says nothing about the source, so it is left out.
      for (final m in cls.procedures) {
        final text = _text(m);
        if (text.contains(_tfaRemovedCode)) continue;
        out['$key.${_selector(null, m)}'] = (kind: 'mixin member', text: text);
      }
    }
  }
  return out;
}

const _mixinLibrary = 'dart:mixin_deduplication';
const _tfaRemovedCode =
    'Attempt to execute code removed by Dart AOT compiler (TFA)';

/// Every class whose declarations are compared, with the key it is reported
/// under.
///
/// App classes, and the classes AOT made of mixin applications. Before tree
/// shaking, the VM's mixin transformation copies a mixin's fields, methods and
/// field initializers into each class that applies it, and deduplicates those
/// into `dart:mixin_deduplication`. That copy is the code that runs: an edit to
/// a mixin's field initializer or method body shows only there, and a patch
/// cannot replace it. So those classes are compared too, and any change in
/// them refuses the patch.
///
/// Their names carry a counter, `_MixinApplication0&Base&M`, that shifts when
/// another mixin application comes or goes, so the key drops it:
/// `dart:mixin_deduplication#&Base&M`. The type arguments it applies are
/// added, `&Object&M<dart:core::int>`, so `M<int>` and `M<String>` keep
/// their own keys when their classes are reordered.
///
/// A name that still collides -- `_B` and `M` declared in two libraries --
/// in either kernel ([ambiguous]) is keyed in both by what the copy applies,
/// each class named with its library: `&_B&M@(package:a/a.dart::_B & ...)`.
/// Never by position: when tree shaking drops one of two copies from one
/// kernel, a survivor numbered `~2` in one kernel and `~1` in the other is
/// compared with the wrong copy.
Iterable<({Class cls, String key, bool isMixinCopy})> _comparedClasses(
  Component c,
  bool Function(Library) isApp,
  Set<String> ambiguous,
) sync* {
  for (final lib in c.libraries.where(isApp)) {
    for (final cls in lib.classes) {
      yield (cls: cls, key: '${lib.importUri}#${cls.name}', isMixinCopy: false);
    }
  }
  final seen = <String, int>{};
  for (final cls in _mixinCopies(c)) {
    final stem = _copyStem(cls, ambiguous);
    // AOT deduplicates identical applications, so two copies with one
    // identity should not exist; if they do, they stay apart.
    final n = seen[stem] = (seen[stem] ?? 0) + 1;
    yield (
      cls: cls,
      key: '$_mixinLibrary#$stem${n == 1 ? '' : '~$n'}',
      isMixinCopy: true,
    );
  }
}

/// How a mixin copy is keyed and printed: [_applicationName], plus what it
/// applies when that name is [ambiguous].
String _copyStem(Class cls, Set<String> ambiguous) {
  final name = _applicationName(cls);
  return ambiguous.contains(name) ? '$name@${_applicationIdentity(cls)}' : name;
}

/// The names [_ambiguousCopyNames] finds in either kernel of this run, for
/// [_UriPrinter], which has no other way to learn them.
var _ambiguousCopies = <String>{};

Iterable<Class> _mixinCopies(Component c) => [
  for (final lib in c.libraries)
    if ('${lib.importUri}' == _mixinLibrary) ...lib.classes,
];

/// Mixin copy names ([_applicationName]) that two copies share in [c].
Set<String> _ambiguousCopyNames(Component c) {
  final counts = <String, int>{};
  for (final cls in _mixinCopies(c)) {
    final name = _applicationName(cls);
    counts[name] = (counts[name] ?? 0) + 1;
  }
  return {
    for (final MapEntry(:key, :value) in counts.entries)
      if (value > 1) key,
  };
}

/// A mixin copy's name without AOT's counter, plus the type arguments it
/// applies: `&Object&M<dart:core::int>`.
String _applicationName(Class cls) {
  final arguments = [
    ...?cls.supertype?.typeArguments,
    ...?cls.mixedInType?.typeArguments,
    // An eliminated application implements the mixin instead.
    for (final t in cls.implementedTypes) ...t.typeArguments,
  ];
  return cls.name.replaceFirst(RegExp(r'^_MixinApplication\d+'), '') +
      (arguments.isEmpty
          ? ''
          : '<${arguments.map((t) => _typeText(t, copyStems: false)).join(', ')}>');
}

/// What a mixin copy applies, with each class named by its library, so two
/// copies whose names collide (`_B` and `M` declared in two libraries) are
/// told apart the same way in both kernels.
String _applicationIdentity(Class cls) {
  String ref(Reference r) => switch (r.node) {
    final Class c when '${c.enclosingLibrary.importUri}' == _mixinLibrary =>
      _applicationIdentity(c),
    _ => _classId(r),
  };
  final applied = [
    if (cls.supertype case final s?) ref(s.className),
    if (cls.mixedInType case final m?) ref(m.className),
    for (final t in cls.implementedTypes) ref(t.className),
  ];
  return '(${applied.join(' & ')})';
}

/// The class [r] names, as `<library URI>::<name>`, without needing the class.
///
/// A release's import kernel is built with --no-link-platform, so a class from
/// the SDK (`dart:core::Object`, which nearly every class extends) is a
/// reference with no node, and `Supertype.classNode` throws on it. Its
/// canonical name still says which class it is.
String _classId(Reference r) {
  if (r.node case final Class c) {
    return '${c.enclosingLibrary.importUri}::${c.name}';
  }
  final name = r.canonicalName;
  final library = name?.parent;
  if (name == null || library == null) {
    _die('a class reference with neither a class nor a canonical name');
  }
  return '${library.name}::${name.name}';
}

/// [t] as text. Inside a copy's own name ([_applicationName]) a type can be
/// the copy's own type parameter, and naming that names the copy again, so
/// there copies keep AOT's name, with the counter dropped.
String _typeText(DartType t, {bool copyStems = true}) {
  final buffer = StringBuffer();
  _UriPrinter(buffer, copyStems: copyStems).writeType(t);
  return _unnumbered(buffer.toString());
}

/// Printed text with AOT's mixin application counter dropped. References to a
/// copy already print as its key ([_UriPrinter]); what is left is a copy's own
/// name in its header, which would otherwise change whenever reordering two
/// class declarations renumbers the copies.
String _unnumbered(String text) =>
    text.replaceAll(_mixinApplicationCounter, '_MixinApplication&');

final _mixinApplicationCounter = RegExp(r'_MixinApplication\d+&');

/// A class's header -- modifiers, type parameters, `extends`, `with`,
/// `implements` -- or null when tree shaking stripped it.
///
/// A patch cannot change a class's place in the hierarchy: a replaced body that
/// asks `x is T` is answered by the release's classes. Worse, tree shaking
/// folds such a test where it can, so an `implements` edit can surface only as
/// a changed body that then ships, and on the device the release's class gives
/// the old answer.
///
/// Tree shaking also rewrites headers by use. A class no type names is stripped
/// to `extends Object`, its interfaces and type parameters cleared, and a class
/// never allocated is marked abstract. So `abstract` and the enum flag are left
/// out, being the allocator's verdict rather than the source's, and a stripped
/// header returns null. Null on the patched side skips the class: the patch
/// stopped naming it, which is valid. Null on the release side only reads as a
/// class the release does not have, and is refused as one: the patch starts
/// naming a class whose hierarchy the release threw away, so the release
/// cannot answer type tests against it. A class
/// another class extends, mixes in or implements is named as a type, so it is
/// never read as stripped. The cost is one blind case: a class no other class
/// builds on, never allocated (tree shaking marks those abstract), whose edit
/// leaves it extending only `Object` with no interfaces or type parameters.
String? _classHeaderText(Class cls, bool isSupertype) {
  final stripped =
      !isSupertype &&
      cls.isAbstract &&
      cls.supertype != null &&
      _classId(cls.supertype!.className) == 'dart:core::Object' &&
      cls.implementedTypes.isEmpty &&
      cls.typeParameters.isEmpty &&
      cls.mixedInType == null;
  if (stripped) return null;
  final buffer = StringBuffer();
  final printer = _UriPrinter(buffer)
    ..writeModifier(cls.isSealed, 'sealed')
    ..writeModifier(cls.isBase, 'base')
    ..writeModifier(cls.isInterface, 'interface')
    ..writeModifier(cls.isFinal, 'final')
    ..writeModifier(cls.isMixinClass, 'mixin')
    ..writeModifier(cls.isMixinDeclaration, 'mixin-declaration')
    ..writeWord('class')
    ..writeWord(cls.name)
    ..writeTypeParameterList(cls.typeParameters);
  if (cls.supertype case final supertype?) {
    printer
      ..writeSpaced('extends')
      ..visitSupertype(supertype);
  }
  if (cls.mixedInType case final mixin?) {
    printer
      ..writeSpaced('with')
      ..visitSupertype(mixin);
  }
  if (cls.implementedTypes.isNotEmpty) {
    printer
      ..writeSpaced('implements')
      ..writeList(cls.implementedTypes, printer.visitSupertype);
  }
  return _unnumbered(buffer.toString());
}

/// Every field key, `library#Class.name` or `library#name`, and every
/// constructor parameter key, `library#Class.constructor(parameter)`.
Set<String> _keptKeys(
  Component c,
  bool Function(Library) isApp,
  Set<String> ambiguous,
) => {
  for (final lib in c.libraries.where(isApp))
    for (final f in lib.fields) '${lib.importUri}#${f.name.text}',
  for (final (:cls, :key, isMixinCopy: _) in _comparedClasses(
    c,
    isApp,
    ambiguous,
  )) ...[
    for (final f in cls.fields) '$key.${f.name.text}',
    for (final k in cls.constructors)
      for (final p in [
        ...k.function.positionalParameters,
        ...k.function.namedParameters,
      ])
        _parameterKey(key, k, p),
  ],
};

// A parameter is keyed by its name. A rename therefore drops it from the
// shared set and its default is not compared there, which is safe: the renamed
// parameter's uses in the initializers and body print differently, so the
// constructor still reads as changed.
String _parameterKey(String classKey, Constructor k, FunctionParameter p) =>
    '$classKey.${k.name.text.isEmpty ? 'new' : k.name.text}'
    '(${p.cosmeticName})';

/// A constructor as `_text` prints it, except for what tree shaking does to
/// the storage of a field that only one side keeps.
///
/// When nothing reads a field, the AOT tree shaker removes it. An initializer
/// that may have side effects is kept as a nameless local; one that cannot is
/// removed outright:
///
///     release  : A::x = compute(), A::y = y, ...
///     patch    : int #t1 = compute(), ...
///
/// The patch's source never touched the constructor -- it stopped reading `x`
/// and `y` somewhere else -- and printing it raw refused that valid patch as a
/// changed constructor. So an initializer of a field that is not on both
/// sides, and a nameless local, are printed as `dropped = <value>` when the
/// value may have side effects, and left out when it cannot, by the shaker's
/// own test. The value of a kept one is still compared, so an edited
/// initializer is still seen.
///
/// Tree shaking also removes a parameter nothing uses, and stops passing it at
/// every call site. So only the parameters both sides keep are printed, with
/// their types and defaults: a default runs in the release's constructor, so
/// an edited one is an edit the release would not carry. A parameter the patch
/// newly passes needs no check here, because the patch is compiled against
/// the release's declarations and a call the release's constructor cannot
/// take fails to compile.
///
/// Every initializer is printed in its own position, one per line. Field
/// initializers from declarations are lowered into the constructor in
/// declaration order, so the order is the order side effects run in, and a
/// reordering is an edit the release would not carry.
String _constructorText(
  Constructor k,
  String classKey,
  Set<String> sharedFields,
) {
  // null: printed as it is. Otherwise the value whose storage is dropped.
  Expression? droppedValue(Initializer i) => switch (i) {
    FieldInitializer(:final field, :final value)
        when !sharedFields.contains('$classKey.${field.name.text}') =>
      value,
    LocalInitializer(:final variable)
        when variable.cosmeticName == null && variable.initializer != null =>
      variable.initializer,
    _ => null,
  };
  final buffer = StringBuffer();
  final printer = _UriPrinter(buffer)
    ..writeAnnotationList(k.annotations)
    ..writeModifier(k.isExternal, 'external')
    ..writeModifier(k.isConst, 'const')
    ..writeWord('constructor')
    ..writeName(k.name)
    ..writeSymbol('(');
  for (final p in [
    ...k.function.positionalParameters,
    ...k.function.namedParameters,
  ]) {
    if (sharedFields.contains(_parameterKey(classKey, k, p))) {
      printer
        ..writeVariable(p)
        ..writeSymbol(';');
    }
  }
  printer.writeSymbol(')');
  if (k.function.body case final body?) {
    buffer.write('\nbody ');
    printer.writeNode(body);
  }
  for (final i in k.initializers) {
    final dropped = droppedValue(i);
    if (dropped == null) {
      buffer.write('\ninitializer ');
      printer.writeNode(i);
    } else if (_mayHaveSideEffects(dropped)) {
      buffer.write('\ndropped = ');
      printer.writeExpression(dropped);
    }
  }
  final named = printer.syntheticNames.constants.map;
  for (var i = 0; i < named.length; i++) {
    printer.writeNode(named.keys.elementAt(i));
  }
  return _unnumbered(buffer.toString());
}

/// The AOT tree shaker's own test for whether it may delete an expression it
/// no longer needs the value of: `mayHaveSideEffects` in
/// `pkg/vm/lib/transformations/type_flow/utils.dart`. Copied, not imported,
/// to keep this tool on `package:kernel` alone. Keep it in step with the copy
/// in the Dart tree the release was built from.
bool _mayHaveSideEffects(Expression node) {
  if (node is BasicLiteral ||
      node is ConstantExpression ||
      node is ThisExpression) {
    return false;
  }
  if (node is VariableGet && !node.variable.isLate) {
    return false;
  }
  if (node is StaticGet) {
    final target = node.target;
    if (target is Field && !target.isLate) {
      final initializer = target.initializer;
      if (initializer == null ||
          initializer is BasicLiteral ||
          initializer is ConstantExpression) {
        return false;
      }
    }
  }
  return true;
}

String _fieldKind(Field f) => f.isConst ? 'constant' : 'field';

/// Why a field or constructor edit refuses the patch, in the user's terms.
String _declarationReason(String kind, {required bool isNew}) {
  if (isNew) {
    return 'this $kind is not in the release -- it is new, or the release '
        'tree-shook it because nothing used it -- and a patch cannot add one';
  }
  return switch (kind) {
    'constant' =>
      'this constant changed; a patch is compiled against the release\'s '
          'declarations, so code naming it would still read the old value',
    'field' =>
      'this field\'s initializer or declaration changed; a patch replaces '
          'method bodies only, so the release keeps its own initial value',
    'mixin member' =>
      'this member of a mixin changed; AOT copies a mixin\'s members into '
          'each class that applies it, and a patch cannot replace those '
          'copies',
    'class' =>
      'this class\'s header -- extends, with, implements, type parameters or '
          'modifiers -- changed; a patch replaces method bodies only, so type '
          'tests still see the release\'s class',
    _ =>
      'this constructor, an instance field initializer it runs, or a '
          'constant argument that every caller passes it changed; a patch '
          'replaces method bodies only, so the release keeps running its own',
  };
}

String _selector(String? className, Procedure p) {
  final name = switch (p.kind) {
    ProcedureKind.Getter => 'get:${p.name.text}',
    ProcedureKind.Setter => 'set:${p.name.text}',
    _ => p.name.text,
  };
  return className == null ? name : '$className.$name';
}

/// `library#selector` -> a stable identity for the member's SIGNATURE only.
///
/// Deliberately not the printed procedure: that includes the body, so it changes
/// on every patch and could never answer "did the shape change?". Built from the
/// pieces a call site actually depends on -- arity, which positionals are
/// required, the named parameters BY NAME, type-parameter count, and the return
/// and parameter types -- so a reordering of named parameters (which callers do
/// not see) does not read as a change, while adding one does.
Map<String, String> _memberSignature(
  Component c,
  bool Function(Library) isApp,
) {
  final out = <String, String>{};
  for (final lib in c.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    for (final p in lib.procedures) {
      out['$uri#${_selector(null, p)}'] = _signature(p);
    }
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        out['$uri#${_selector(cls.name, p)}'] = _signature(p);
      }
    }
  }
  return out;
}

String _signature(Procedure p) {
  final f = p.function;
  String type(DartType t) {
    final buffer = StringBuffer();
    _UriPrinter(buffer).writeType(t);
    return buffer.toString();
  }

  final positional = [
    for (var i = 0; i < f.positionalParameters.length; i++)
      '${i < f.requiredParameterCount ? '' : '?'}'
          '${type(f.positionalParameters[i].type)}',
  ];
  // Sorted by name: callers pass named arguments by name, so their ORDER in the
  // declaration is not part of the contract and must not read as a change.
  final named = [
    for (final n in [
      ...f.namedParameters,
    ]..sort((a, b) => a.parameterName.compareTo(b.parameterName)))
      '${n.isRequired ? 'required ' : ''}${n.parameterName}:${type(n.type)}',
  ];
  return '<${f.typeParameters.length}>(${positional.join(',')}'
      '${named.isEmpty ? '' : '{${named.join(',')}}'})'
      '->${type(f.returnType)}';
}

/// The printed member, followed by the VALUE of every constant it uses.
///
/// The kernel printer writes a constant as a reference, `#C1`, and prints the
/// values only in a component-wide table. A member printed alone therefore
/// read the same whether its `const Text('a')` said 'a' or 'b', and whether the
/// top-level `const` it inlines held one value or another. A release compiles
/// every use of a `const` to its value, so an edit to a constant IS an edit to
/// each member that uses it, and has to read as one.
///
/// The table is walked until it stops growing: printing one constant names the
/// constants inside it (`Box{v: #C2}`), and those must be printed too.
String _text(Member m) {
  final buffer = StringBuffer();
  final printer = _UriPrinter(buffer)..writeNode(m);
  final named = printer.syntheticNames.constants.map;
  for (var i = 0; i < named.length; i++) {
    printer.writeNode(named.keys.elementAt(i));
  }
  return _unnumbered(buffer.toString());
}

/// A [Printer] that names every library by its import URI.
///
/// A bare [Printer] has no import table, so it names a library without a
/// `library` directive `#lib1`, `#lib2`, in the order it meets them -- and
/// every member is printed by a fresh one. Two classes `X` from `a.dart` and
/// `b.dart` then print alike, and a body or header that swaps one for the
/// other reads as unchanged. The import URI is the same in both kernels and
/// unique, so it names each library the same way every time.
///
/// AOT's mixin copies are renamed the same way; see [getClassName].
class _UriPrinter extends Printer {
  _UriPrinter(super.sink, {this.copyStems = true});

  final bool copyStems;

  /// A mixin copy prints as its key does ([_copyStem]), not as AOT named it:
  /// the counter in `_MixinApplication0&Object&M` says nothing, and dropping it
  /// alone would print copies of `M<int>` and `M<String>` alike.
  @override
  String getClassName(Class node) =>
      copyStems && '${node.enclosingLibrary.importUri}' == _mixinLibrary
      ? _copyStem(node, _ambiguousCopies)
      : super.getClassName(node);

  @override
  String getLibraryReference(Reference reference) => switch (reference.node) {
    final Library library => '${library.importUri}',
    _ => super.getLibraryReference(reference),
  };
}

Never _die(String message) {
  stderr.writeln('error: $message');
  exit(2);
}

/// D0.2 -- the structural body census.
///
/// WHY THIS LIVES HERE AND NOT IN A SECOND TOOL. `_lowering` IS the product's
/// refusal contract: the ABI clauses, the receiver traversal, the same-offset
/// read/write collision, the private-capability reporting. A census that
/// reimplemented any of it would drift from the thing it claims to measure, and
/// would drift silently. So census mode calls the same function the patch path
/// calls, over a different set of members.
///
/// WHAT THE DENOMINATOR IS, stated so a reader cannot mistake it:
///
///   every INSTANCE `Procedure` on a class in an included library, that has a
///   body to replace
///
/// Excluded, with the count reported so the exclusion is visible rather than
/// silent: static procedures (the lowering does not apply -- there is no
/// receiver to lower), abstract and external procedures (no body), and
/// procedures with no usable source span.
///
/// WHAT IT DOES NOT RUN. `_lowering` is one stage of several. Reachability and
/// retention are per-release facts held in a manifest this tool does not have;
/// the producer's own source-text refusals (`this . label` spacing, an escaped
/// `\$\$`) need the file and the edit; the bytecode compiler gets the last word.
/// A row saying `lowerable` means THIS stage raised no objection, and nothing
/// more.
void _runCensus(String path, List<String> includePrefixes, String? outPath) {
  final component = _load(path);
  final censusHierarchy = ClassHierarchy(component, CoreTypes(component));
  // THE SAME PRECONDITION THE NORMAL PATH APPLIES (version 11). A base kernel
  // whose `dart:core` carries no classes is unlinked, and `releaseSuperTargets`
  // cannot be computed from it. Absent is not empty: the key is OMITTED rather
  // than reported as `[]`, so a consumer can tell "the release direct-called
  // nothing" from "nobody measured".
  final censusIsLinked = component.libraries.any(
    (l) => l.importUri.toString() == 'dart:core' && l.classes.isNotEmpty,
  );
  bool isApp(Library lib) {
    final uri = lib.importUri.toString();
    if (uri.startsWith('dart:')) return false;
    if (includePrefixes.isEmpty) return true;
    return includePrefixes.any(uri.startsWith);
  }

  // Source files are read once and cached: a census over a real app asks about
  // thousands of procedures spread over hundreds of files.
  final sourceCache = <String, String?>{};
  String? sourceOf(Uri uri) => sourceCache.putIfAbsent(uri.toString(), () {
    try {
      final file = File.fromUri(uri);
      if (!file.existsSync()) return null;
      return utf8.decode(file.readAsBytesSync());
    } on Object {
      return null;
    }
  });

  // IS THIS FILE GENERATED. Reported per row so a corpus dominated by codegen
  // cannot be mistaken for a corpus dominated by hand-written code.
  //
  // BY THE MARKER, NOT BY THE FILENAME. A `.g.dart` filter looked sufficient
  // until localsend: its flutter_rust_bridge bindings are named
  // `frb_generated.dart` and `rust/api/*.dart`, carry the standard marker, and
  // are committed to the repository -- and they turned out to hold 101 of the
  // 108 `this` escapes that the first reading of that corpus ranked first. A
  // hand-maintained list of filename patterns is a filter that has to be
  // rediscovered per corpus, which is another way of saying it is tuned.
  //
  // THE CONVENTION, NOT A LIST OF TOOLS. There is no single marker: build_runner
  // writes `GENERATED CODE - DO NOT MODIFY BY HAND`, flutter_rust_bridge writes
  // `@generated`, slang writes `Generated file. Do not edit.`. Enumerating them
  // is a list that has to grow every time a new corpus arrives -- which is how
  // localsend's 18,193 slang getters survived the first filter.
  //
  // So the test is the SHAPE of the convention: the file's head says it was
  // generated AND says not to edit it. That is what every one of those tools
  // actually agrees on.
  //
  // A convention is not a guarantee. A generated file that declares nothing is
  // counted as hand-written, which is the safe direction: it under-excludes
  // rather than quietly removing real code. Both views are reported either way.
  final generatedCache = <String, bool>{};
  bool isGenerated(Uri uri) => generatedCache.putIfAbsent(uri.toString(), () {
    final text = sourceOf(uri);
    if (text == null) return false;
    final head = (text.length > 2048 ? text.substring(0, 2048) : text)
        .toLowerCase();
    if (head.contains('@generated')) return true;
    return head.contains('generated') &&
        (head.contains('do not edit') || head.contains('do not modify'));
  });

  final rows = <Map<String, Object?>>[];
  var skippedStatic = 0;
  var skippedNoBody = 0;
  var skippedNoSpan = 0;

  for (final lib in component.libraries.where(isApp)) {
    final uri = lib.importUri.toString();
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        if (p.isStatic) {
          skippedStatic++;
          continue;
        }
        if (p.isAbstract || p.isExternal || p.function.body == null) {
          skippedNoBody++;
          continue;
        }
        final start = p.fileStartOffset;
        final end = p.fileEndOffset;
        if (start < 0 || end < 0 || end <= start) {
          skippedNoSpan++;
          continue;
        }

        final lowering = _lowering(cls, p, censusHierarchy);
        final unsupported = (lowering['unsupported']! as List).cast<String>();
        final accesses = (lowering['accesses']! as List).length;

        // WHY THE `this` REFUSAL FIRED, which its own reason string cannot say.
        //
        // "uses `this` other than to read a member" is ONE reason covering
        // shapes with nothing in common. In real Flutter code it turns out to be
        // dominated by implicit METHOD TEAR-OFFS -- `onPressed: _handleTap`,
        // `bgBuilder: _buildBg` -- where `this` is the receiver of an
        // InstanceTearOff and the lowered spelling is the same textual edit as a
        // read. That is a different mechanism, and a different cost, from
        // `vsync: this`, where the receiver itself escapes into someone else's
        // hands. Ranking them as one category picks the wrong feature.
        //
        // So the census classifies each unconsumed `this` by its PARENT node and
        // reports the raw Kernel node name -- a shape nobody has looked at yet
        // appears under its own name instead of hiding in an `other` row.
        //
        // MEASUREMENT ONLY. It takes no part in the refusal, which is
        // `_lowering`'s and is unchanged. The consumption rule is not restated
        // either: a second `_ReceiverUses` is run and its own `consumed` set is
        // read, so there is one definition of "consumed".
        final probe = _ReceiverUses();
        p.function.accept(probe);
        final everyThis = _ThisExpressions();
        p.function.accept(everyThis);
        final parents = <String, int>{};
        for (final t in everyThis.found) {
          if (probe.consumed.contains(t)) continue;
          final name = t.parent?.runtimeType.toString() ?? 'none';
          parents[name] = (parents[name] ?? 0) + 1;
        }

        // D-HYGIENE, reported as METADATA and never as a refusal. Capture-
        // avoiding receiver naming closed that defect, so a declaration
        // spelling `self` is lowered correctly -- it just costs an alpha-
        // rename. Counting it as unsupported would put a solved problem back
        // into the blocker ranking; not counting it at all would leave no way
        // to tell how often the mechanism is exercised.
        //
        // The test mirrors the producer's allocator exactly: a plain substring
        // scan of the whole declaration, comments and strings included. It
        // over-triggers in the same direction, for the same reason.
        final text = sourceOf(p.fileUri);
        final span = (text != null && end + 1 <= text.length)
            ? text.substring(start, end + 1)
            : null;

        rows.add({
          'target': '$uri#${_selector(cls.name, p)}',
          'kind': p.kind.name,
          'private': p.name.text.startsWith('_'),
          'accesses': accesses,
          // The analyzer now DESCRIBES super instead of refusing it (v10), but
          // the shipping product still cannot lower it. The census measures the
          // product's surface, so a reported super site keeps counting as a
          // blocker here -- otherwise D0.2/D0.4's banked numbers would move with
          // no change in what a user can actually patch.
          'superInvocations': (lowering['superInvocations']! as List).length,
          'lowerable':
              unsupported.isEmpty &&
              (lowering['superInvocations']! as List).isEmpty,
          'unsupported': unsupported,
          // null when the source file could not be read, so "no rename needed"
          // and "not known" are never conflated.
          'needsAlphaRename': span == null ? null : span.contains('self'),
          'generated': isGenerated(p.fileUri),
          'unconsumedThisParents': parents,
          // D-CENSUS-2, MEASUREMENT ONLY. Nothing below takes part in a
          // refusal; `lowerable` above is unchanged, so D0.2/D0.4's banked
          // numbers stay comparable.
          //
          // The file, so the SOURCE-SHAPE classifier can find the call. It is
          // deliberately not classified here: "zero source arguments" is the
          // product's rule and lives in the product's own fail-closed scanner
          // (`route_b_super_source.dart`). Restating it in this tool would be a
          // second definition free to drift from the one that admits patches.
          'fileUri': p.fileUri.toString(),
          // Every super site with its resolved target, not just how many.
          'superSites': lowering['superInvocations'],
          // The method's private-class constructions. Emitted so a RELEASE can
          // derive exactly which private constructors its own methods depend
          // on, without a second implementation of the measurement living in
          // the interface generator. One definition, two readers.
          'privateConstructions': lowering['privateConstructions'],
          // What the RELEASE version of THIS method direct-called. In a census
          // the corpus IS the release, which the header records as
          // `releaseIsSelf`; see the reporter for what that does and does not
          // license.
          if (censusIsLinked)
            'releaseSuperTargets': _superTargets(censusHierarchy, cls, p),
        });
      }
    }
  }

  rows.sort(
    (a, b) => (a['target']! as String).compareTo(b['target']! as String),
  );

  final buffer = StringBuffer()
    ..writeln(
      jsonEncode({
        // 2: rows carry `fileUri`, `superSites` (each with its resolved
        // target) and `releaseSuperTargets`. Additive -- `lowerable` and every
        // version-1 field mean exactly what they did.
        'censusVersion': 2,
        'dill': path,
        // The corpus is its own release. A census has one kernel, so
        // `releaseSuperTargets` answers "does the release direct-call the
        // target its own super site names", never "would a NEW super call in a
        // patch be admissible".
        'releaseIsSelf': true,
        'censusIsLinked': censusIsLinked,
        'include': includePrefixes,
        'considered': rows.length,
        'skippedStatic': skippedStatic,
        'skippedNoBody': skippedNoBody,
        'skippedNoSpan': skippedNoSpan,
        'analysisVersion': analysisVersion,
      }),
    );
  for (final row in rows) {
    buffer.writeln(jsonEncode(row));
  }
  if (outPath == null) {
    stdout.write(buffer.toString());
  } else {
    File(outPath).writeAsStringSync(buffer.toString());
  }
}

/// Reads a compiled replacement (`.bytecode`) with the SAME bytecode reader the
/// compiler ships with, and prints one JSON line:
///
///   {"functions": <n>, "calls": ["+", "unary-", ...]}
///
/// `calls` is every member name the bytecode looks up at run time: the operand
/// of every InterfaceCall, UncheckedInterfaceCall, InstantiatedInterfaceCall
/// and DynamicCall, read from the constant pool entries the opcodes point at
/// (`[1] = InterfaceCall 'dart:core::num::+', ...`). The patcher uses it to check an `inlined` claim against what
/// was really compiled, where the analyzer could only predict it (the analyzer
/// reads the patched kernel, the compiler reads the producer's lowered form).
/// The disassembly text is parsed, so a count of zero functions is reported as
/// is and the caller treats it as "could not read": never as "calls nothing".
void _scanBytecode(String path) {
  final text = bytecode.Component.read(
    BufferedReader(LinkReader(), File(path).readAsBytesSync()),
  ).toString();
  stdout.writeln(jsonEncode(scanBytecodeText(text)));
}

/// The scan of one bytecode component's text: `functions`, `unparsed` (call
/// lines the selector regex did not read) and the sorted `calls` selectors.
Map<String, Object?> scanBytecodeText(String text) {
  final calls = <String>{};
  final call = RegExp(
    r"\[\d+\]\s+=\s+\w*(?:Interface|Dynamic)Call\w*\s+'([^']+)'",
  );
  var parsed = 0;
  for (final m in call.allMatches(text)) {
    parsed++;
    final name = m.group(1)!;
    // `dart:core::num::+` for an interface call, a bare `+` for a dynamic one.
    final at = name.lastIndexOf('::');
    calls.add(at < 0 ? name : name.substring(at + 2));
  }
  // Self-check, independent of the strict regex above. A constant-pool entry
  // is a line shaped `[n] = Kind ...` (loosely: a number, then `=` or `:`);
  // its kind is the token right after that, so a type or a name elsewhere
  // (`Closure f (VoidCallback cb)`) is never taken for one. A call kind other
  // than a direct, external or FFI call (which carry no selector) that the
  // strict regex did not read means the text format changed under it.
  final entry = RegExp(r'^\s*\[?\d+\]?\s*[=:]\s*(\w+)', multiLine: true);
  var counted = 0;
  for (final m in entry.allMatches(text)) {
    final kind = m.group(1)!;
    if (!kind.endsWith('Call')) continue;
    if (kind == 'DirectCall' || kind == 'ExternalCall' || kind == 'FfiCall') {
      continue;
    }
    counted++;
  }
  var unparsed = counted - parsed;
  // The entry shape itself may have changed. An instruction that calls by
  // selector (`InterfaceCall  CP#5, 2`) refers to a pool entry, so when such
  // instructions exist and no entry was read at all, nothing was read.
  final byName = RegExp(
    r'^\s+(?:\w*Interface|Dynamic)Call\w*\s+CP#',
    multiLine: true,
  ).allMatches(text).length;
  if (byName > 0 && parsed == 0 && unparsed < byName) unparsed = byName;
  final functions = RegExp(r'^Function ', multiLine: true).allMatches(text);
  return {
    'functions': functions.length,
    'unparsed': unparsed,
    'calls': calls.toList()..sort(),
  };
}

/// [type] as source the replacement library can write, or null when it cannot.
///
/// The replacement imports the target library and what that library imports, so
/// only names that resolve there with certainty are written: `dynamic`, `void`,
/// a public class of `dart:core` or of the target's own library (not shadowed
/// by a declaration of the target's library), with type arguments written the
/// same way. A class type parameter, a function or record type, a typedef, a
/// private class and a class of any other library are null: not nameable, so
/// the producer refuses a target whose omitted type would need one.
String? _writableType(DartType type, Library target) {
  switch (type) {
    case DynamicType():
      return 'dynamic';
    case VoidType():
      return 'void';
    case InterfaceType():
      final cls = type.classNode;
      final lib = cls.enclosingLibrary;
      final name = cls.name;
      if (name.startsWith('_')) return null;
      final isCore = lib.importUri.toString() == 'dart:core';
      if (isCore) {
        if (target.classes.any((c) => c.name == name) ||
            target.typedefs.any((t) => t.name == name)) {
          return null;
        }
      } else if (lib != target) {
        return null;
      }
      // Core's own names lose to an explicit import; the target's own are
      // ambiguous in the replacement, which imports both.
      if (_importedNameClashes(target, name)) return null;
      final nullable = switch (type.declaredNullability) {
        Nullability.nullable => '?',
        Nullability.nonNullable => '',
        _ => null,
      };
      if (nullable == null) return null;
      final args = <String>[];
      for (final a in type.typeArguments) {
        final w = _writableType(a, target);
        if (w == null) return null;
        args.add(w);
      }
      return '$name${args.isEmpty ? '' : '<${args.join(', ')}>'}$nullable';
    default:
      return null;
  }
}

bool _importsAccountedFor(Library target) {
  final bytes = target.enclosingComponent?.uriToSource[target.fileUri]?.source;
  if (bytes == null || bytes.isEmpty) return target.dependencies.isNotEmpty;
  final source = utf8.decode(bytes, allowMalformed: true);
  final directives = RegExp(
    r'^\s*(?:import|export)\s',
    multiLine: true,
  ).allMatches(source).length;
  return target.dependencies.length >= directives;
}

/// For the analyzer's unit test.
String? writableTypeForTesting(DartType type, Library target) =>
    _writableType(type, target);

/// True when an unprefixed import of [target] (any combinators ignored, which
/// only makes this refuse more) exposes a declaration called [name] other than
/// the one in `dart:core`: an explicit import beats the implicit `dart:core`
/// one, so writing [name] in the replacement would bind to it.
bool _importedNameClashes(Library target, String name) {
  // Fail closed when the kernel's record of the imports cannot be trusted: the
  // dependency list must not be shorter than the source's own directives, and
  // an empty list with no source to compare against proves nothing.
  if (!_importsAccountedFor(target)) return true;
  final seen = <Library>{};
  bool exposes(Library lib) {
    if (!seen.add(lib)) return false;
    if (lib.importUri.toString() == 'dart:core') return false;
    if (lib.classes.any((c) => c.name == name) ||
        lib.typedefs.any((t) => t.name == name) ||
        lib.extensionTypeDeclarations.any((t) => t.name == name) ||
        lib.additionalExports.any((r) => r.canonicalName?.name == name)) {
      return true;
    }
    // Re-exports, followed to the end, combinators ignored.
    return lib.dependencies.any((d) => d.isExport && exposes(d.targetLibrary));
  }

  return target.dependencies.any(
    (d) => d.isImport && d.name == null && exposes(d.targetLibrary),
  );
}

/// Accesses sharing one source offset that are not one read and one write of
/// one member; see the comment in `_lowering` on why that pair is one edit.
List<String> _offsetCollisions(List<_Access> accesses) {
  final unsupported = <String>[];
  final byOffset = <int, List<_Access>>{};
  for (final a in accesses) {
    byOffset.putIfAbsent(a.offset, () => []).add(a);
  }
  for (final entry in byOffset.entries) {
    // Exactly one read and one write: a third access, or two of one kind, is
    // not something a compound assignment produces.
    final readWriteOfOne =
        entry.value.length == 2 &&
        entry.value.map((a) => a.member).toSet().length == 1 &&
        entry.value.map((a) => a.kind).toSet().containsAll(const {
          'get',
          'set',
        });
    if (entry.value.length > 1 && !readWriteOfOne) {
      final kinds = entry.value.map((a) => a.kind).join('+');
      unsupported.add(
        'reads and writes `${entry.value.first.member}` in one expression '
        '($kinds), which this lowering cannot rewrite as a single edit',
      );
    }
  }
  return unsupported;
}

/// The extension and descriptor [p] is an INSTANCE member of, or null: a static
/// member, a tear-off (`Ext|get#m` of a method `m`, whose descriptor names it
/// as `tearOffReference`), an extension type member, or a procedure no
/// descriptor claims.
(Extension, ExtensionMemberDescriptor)? _extensionInstanceMember(Procedure p) {
  final bar = p.name.text.indexOf('|');
  if (bar < 0 || !p.isExtensionMember) return null;
  final name = p.name.text.substring(0, bar);
  for (final e in p.enclosingLibrary.extensions) {
    if (e.name != name) continue;
    for (final d in e.memberDescriptors) {
      if (!d.isStatic && d.memberReference == p.reference) return (e, d);
    }
  }
  return null;
}

/// The version 22 lowering of [p] when it is an instance member of an
/// extension, else null. The same document `main` writes, for tests and for
/// `gen_scope_fixture.dart`.
Map<String, Object?>? extensionLoweringOf(Procedure p) {
  final found = _extensionInstanceMember(p);
  return found == null ? null : _extensionLowering(p, found.$1, found.$2);
}

/// The receiver of an extension member's body, as [_ReceiverUses] needs it.
class _ExtensionReceiver {
  _ExtensionReceiver(this.thisVariable, this.name, this.members, this.tearOffs);

  /// The `#this` parameter every instance member of an extension takes first.
  final Variable thisVariable;
  final String name;

  /// The extension's own instance members by procedure.
  final Map<TreeNode, ExtensionMemberDescriptor> members;

  /// The procedures that are tear-offs of those methods.
  final Set<TreeNode> tearOffs;
}

/// Version 22: [_lowering] for an instance member of a named extension.
///
/// Kernel compiles `String get stars => ...` in `extension Stars on int` to the
/// static procedure `Stars|get#stars(int #this)`, so the replacement is the
/// top-level function a class member lowers to, `String stars(int self)`, and
/// every use of `#this` becomes `self`. A call of a SIBLING instance member is
/// already a static call with `#this` first; it is reported so the producer
/// writes `Stars(self).sibling(...)`, an explicit application, which cannot
/// resolve to another extension that happens to be in scope.
Map<String, Object?> _extensionLowering(
  Procedure p,
  Extension ext,
  ExtensionMemberDescriptor descriptor,
) {
  final unsupported = <String>[];
  final library = p.enclosingLibrary;
  final name = ext.name;
  final function = p.function;
  if (name.contains('#')) {
    unsupported.add('it is a member of an unnamed extension');
  } else if (name.startsWith('_')) {
    unsupported.add(
      'it is a member of the private extension `$name`, which a replacement '
      'library cannot name',
    );
  }
  if (ext.typeParameters.isNotEmpty) {
    unsupported.add(
      'it is a member of the generic extension `$name`, and a replacement '
      'does not declare the extension\'s type parameters',
    );
  }
  switch (descriptor.kind) {
    case ExtensionMemberKind.Getter || ExtensionMemberKind.Method:
      break;
    default:
      unsupported.add(
        'it is an extension ${descriptor.kind.name.toLowerCase()}, and only '
        'a getter or a method of an extension is carried',
      );
  }
  final positional = function.positionalParameters;
  if (positional.isEmpty || positional.first.cosmeticName != '#this') {
    unsupported.add('its receiver parameter could not be identified');
    return {
      'receiverType': 'dynamic',
      'extension': name,
      'nameOffset': p.fileOffset,
      'accesses': const <Object>[],
      'privateConstructions': const <Object>[],
      'superInvocations': const <Object>[],
      'unsupported': unsupported,
    };
  }
  final receiver = positional.first;
  if (function.namedParameters.isNotEmpty) {
    unsupported.add('the method takes named parameters');
  }
  if (function.requiredParameterCount != positional.length) {
    unsupported.add('the method takes optional positional parameters');
  }
  if (ext.typeParameters.isEmpty && function.typeParameters.isNotEmpty) {
    unsupported.add('the method is generic');
  }
  final receiverType = _writableType(receiver.type, library);
  if (receiverType == null) {
    unsupported.add(
      'its receiver type `${_typeLabel(receiver.type)}` cannot be written in '
      'the replacement library: it must be a public class of dart:core or of '
      'this library',
    );
  }

  final members = <TreeNode, ExtensionMemberDescriptor>{};
  final tearOffs = <TreeNode>{};
  for (final d in ext.memberDescriptors) {
    if (d.isStatic) continue;
    final m = d.memberReference?.node;
    if (m != null) members[m] = d;
    final t = d.tearOffReference?.node;
    if (t != null) tearOffs.add(t);
  }
  final visitor = _ReceiverUses(
    const {},
    _ExtensionReceiver(receiver, name, members, tearOffs),
  );
  function.accept(visitor);
  unsupported
    ..addAll(visitor.unsupported)
    ..addAll(_offsetCollisions(visitor.accesses));

  return {
    'receiverType': receiverType ?? 'dynamic',
    'extension': name,
    'nameOffset': p.fileOffset,
    'signatureTypes': {
      'params': [
        for (final v in positional.skip(1)) _writableType(v.type, library),
      ],
      'returnType': _writableType(function.returnType, library),
    },
    'accesses': [
      for (final a in visitor.accesses)
        {
          'offset': a.offset,
          'member': a.member,
          'kind': a.kind,
          if (a.private != null) 'private': a.private,
        },
    ],
    'privateConstructions': _privateConstructionsIn(library, p),
    'superInvocations': const <Object>[],
    'unsupported': unsupported,
  };
}

String _typeLabel(DartType type) => type is InterfaceType
    ? type.classNode.name
    : switch (type) {
        FunctionType() => 'a function type',
        TypeParameterType() => 'a type parameter',
        RecordType() => 'a record type',
        _ => 'a type of this kind',
      };

/// What a producer needs to turn an instance method into a static replacement
/// taking its receiver as argument 0.
///
/// The supported surface is ONE form: a public instance getter read off `this`,
/// spelled either `label` or `this.label` -- which are the same Kernel node, so
/// only the source text distinguishes them and only the producer needs to care.
Map<String, Object?> _lowering(
  Class cls,
  Procedure p,
  ClassHierarchy hierarchy, [
  Set<Member> helperMembers = const {},
]) {
  final unsupported = <String>[];

  final function = p.function;
  // G3.7: the method's OWN required positional parameters are now supported. The
  // entry-point contract permits any number of them, so the receiver no longer has
  // to be the only parameter, and the producer copies the source's parameter list
  // verbatim while inserting the receiver in front of it.
  //
  // These three stay refused, and each mirrors a clause of the compiler contract
  // rather than a separate opinion. Keeping them aligned is the point: an analyzer
  // that reported a shape the compiler rejects would move the refusal from patch
  // time to compile time, where the message talks about bytecode instead of about
  // the patch.
  if (function.namedParameters.isNotEmpty) {
    unsupported.add('the method takes named parameters');
  }
  if (function.requiredParameterCount != function.positionalParameters.length) {
    // Their default values live in the AOT function the replacement stands in
    // for, and nothing carries them across.
    unsupported.add('the method takes optional positional parameters');
  }
  if (function.typeParameters.isNotEmpty) {
    unsupported.add('the method is generic');
  }

  final visitor = _ReceiverUses(helperMembers);
  function.accept(visitor);
  unsupported.addAll(visitor.unsupported);

  // ONE SOURCE TOKEN, ONE EDIT. `label += 'X'`, `count++` and
  // `maybe ??= 'Z'` each report a read AND a write at the SAME offset, because
  // one identifier is doing both jobs. One receiver prefix rewrites both:
  // `self.label += 'X'` reads and writes the member the original did, and the
  // producer emits one edit for such a position. `_count += 1` inside a
  // setState closure, the most common shape in a Flutter app, is this.
  //
  // Anything else sharing an offset -- two members, two reads, a third
  // access, or a call -- is refused: that is not a shape this lowering has
  // been shown to rewrite. Measured on the host front end: `this._a += 2`,
  // `this.b++`, `++this.b`, `this._c ??= 4` and `_d += 2` inside a closure all
  // put the read and the write at the member NAME, so an explicit `this.` is
  // still one edit (the producer replaces `this.` with the receiver).
  // `label = label + 'Y'` is untouched by this -- measured at two distinct
  // offsets, because it really is two tokens.
  unsupported.addAll(_offsetCollisions(visitor.accesses));

  return {
    'receiverType': cls.name,
    // ORIGIN IDENTITY (analysis version 10). What the replacement compiler needs
    // to find this method again in ITS OWN kernel and re-derive the super target
    // there. Stable source-level facts only.
    //
    // `memberKind` is carried alongside the name rather than assumed: a class
    // may hold a method, a getter and a setter of the same name, so name + class
    // is not an identity. Cheap now; an implicit assumption later.
    'origin': {
      'library': cls.enclosingLibrary.importUri.toString(),
      'class': cls.name,
      'member': p.name.text,
      'memberKind': p.kind.name,
    },
    // Where the producer starts looking for the parameter list. Kernel puts
    // `fileOffset` on the NAME, and an annotation like @pragma('...') contains
    // parentheses of its own, so scanning from the declaration start would find
    // the wrong ones.
    'nameOffset': p.fileOffset,
    'signatureTypes': {
      'params': [
        for (final v in function.positionalParameters)
          _writableType(v.type, cls.enclosingLibrary),
      ],
      'returnType': _writableType(function.returnType, cls.enclosingLibrary),
    },
    'accesses': [
      for (final a in visitor.accesses)
        {
          'offset': a.offset,
          'member': a.member,
          'kind': a.kind,
          if (a.private != null) 'private': a.private,
        },
    ],
    // Private-class constructions (version 12). Reported with the manifest key
    // the release would have had to grant, exactly as a private member access
    // is; the consumer holding the manifest decides.
    // ONLY the method's OWN library. Dart privacy is library-scoped, so a
    // private class NAMED in this body can only be declared here -- and that is
    // also exactly what the producer's source scan can see. Without this filter
    // the list fills with SDK internals the compiler synthesised, such as
    // `dart:core#_GrowableList._literal1` from a list literal: not named in any
    // source, not the app's to grant, and not something the producer refuses on.
    'privateConstructions': _privateConstructions(cls, p),
    // Genuine `super.member()` sites. An EMPTY list is the common case and the
    // only one a producer without direct-super support may proceed on.
    'superInvocations': [
      for (final site in visitor.superInvocations)
        {
          'offset': site.offset,
          'member': site.member,
          'kind': site.kind,
          // The RESOLVED target, as provenance only (analysis version 11).
          // Null when nothing resolves: reported rather than omitted, because a
          // site with no target is a finding and not an absence.
          'target': _provenance(
            cls.superclass == null
                ? null
                : hierarchy.getDispatchTarget(
                    cls.superclass!,
                    site.member.startsWith('_')
                        ? Name(site.member, cls.enclosingLibrary)
                        : Name(site.member),
                  ),
          ),
        },
    ],
    'unsupported': unsupported,
  };
}

/// The class of that name in [component], or null.
Class? _findClass(Component component, String libraryUri, String name) {
  for (final lib in component.libraries) {
    if (lib.importUri.toString() != libraryUri) continue;
    for (final cls in lib.classes) {
      if (cls.name == name) return cls;
    }
  }
  return null;
}

/// The procedure of that name AND KIND, or null.
///
/// Kind is required, not incidental: a class may hold a method, a getter and a
/// setter of one name, so a name alone is not an identity.
Procedure? _findProcedure(Class cls, String name, ProcedureKind kind) {
  for (final p in cls.procedures) {
    if (p.name.text == name && p.kind == kind) return p;
  }
  return null;
}

/// SOURCE PROVENANCE of a member, as the only portable cross-kernel identity.
///
/// No enclosing class: including it would reimport the transformed identity that
/// AOT mixin deduplication renames. Dart has no overloading, so a file offset
/// plus a name and kind identifies exactly one declaration.
Map<String, Object?>? _provenance(Member? m) => m == null
    ? null
    : {
        'fileUri': m.fileUri.toString(),
        'fileOffset': m.fileOffset,
        'name': m.name.text,
        'kind': m is Procedure ? m.kind.name : m.runtimeType.toString(),
      };

/// Every super target [p] direct-calls, resolved with [hierarchy].
///
/// Used on the RELEASE side to record what that version of the method already
/// required AOT to compile — which is the whole basis of the narrow-v1
/// admission rule (`super0/s2b1f/`).
List<Map<String, Object?>> _superTargets(
  ClassHierarchy hierarchy,
  Class cls,
  Procedure p,
) {
  final visitor = _ReceiverUses();
  p.function.accept(visitor);
  final superclass = cls.superclass;
  if (superclass == null) return const [];
  final out = <Map<String, Object?>>[];
  for (final site in visitor.superInvocations) {
    final name = site.member.startsWith('_')
        ? Name(site.member, cls.enclosingLibrary)
        : Name(site.member);
    final resolved = hierarchy.getDispatchTarget(superclass, name);
    final provenance = _provenance(resolved);
    if (provenance != null) out.add(provenance);
  }
  return out;
}

/// Every private-class construction in [p]'s body, keyed as the manifest keys
/// it, and scoped to [cls]'s own library.
///
/// ONE definition, used for the candidate body and for the RELEASE's version of
/// the same method. Measuring the two sides with different code is how an
/// evidence rule quietly stops comparing like with like.
List<Map<String, Object?>> _privateConstructions(Class cls, Procedure p) =>
    _privateConstructionsIn(cls.enclosingLibrary, p);

/// [_privateConstructions] for a member that has no class (an extension's).
List<Map<String, Object?>> _privateConstructionsIn(
  Library library,
  Procedure p,
) {
  final visitor = _ReceiverUses();
  p.function.accept(visitor);
  final own = library.importUri.toString();
  return [
    for (final c in visitor.privateConstructions)
      if (c.library == own)
        {
          'offset': c.offset,
          'library': c.library,
          'class': c.className,
          'constructor': c.ctor,
          'key': c.key,
        },
  ];
}

/// A construction of a private class inside a body.
class _PrivateConstruction {
  _PrivateConstruction(this.offset, this.library, this.className, this.ctor);
  final int offset;
  final String library;
  final String className;
  final String ctor;

  /// The manifest key, spelled as gen_dynamic_interface spells it.
  String get key => '$library#$className.$ctor';
}

/// A genuine `super.member()` site: where it is, and what it names.
///
/// Deliberately NOT the resolved target, its owner, or its arity. See the
/// `analysisVersion` 10 note.
class _SuperSite {
  _SuperSite(this.offset, this.member, this.kind);
  final int offset;
  final String member;
  final String kind;
}

class _Access {
  _Access(this.offset, this.member, this.kind, {this.private});
  final int offset;
  final String member;
  final String kind;

  /// Set when [member] is private, naming what the release would have had to
  /// retain for this access to bind. Null for a public access.
  ///
  /// The analyzer does NOT decide whether the release retained it. It cannot:
  /// the capability manifest is a per-release artifact and this tool ships in
  /// the compiler cell, resolved by engine hash. So it reports the key and the
  /// CLI matches it against the manifest the release actually published.
  final Map<String, Object?>? private;
}

/// The manifest key for a private member reached off the receiver.
///
/// Resolved from the interface target rather than from the enclosing class of
/// the method being patched, because `this._controller` may be DECLARED on a
/// superclass in the same library -- and the manifest keys a member under the
/// class that declares it. Guessing the patched class would refuse a member
/// that was in fact granted.
///
/// The name follows `LibraryIndex`: a Field is keyed BARE, a Procedure carries
/// the VM's `get:`/`set:` disambiguation. That is the same rule
/// gen_dynamic_interface.dart applied when it emitted the manifest, and the two
/// have to agree exactly or every lookup misses.
Map<String, Object?>? _privateKey(Member? target) {
  if (target == null) return null;
  final cls = target.enclosingClass;
  if (cls == null) return null;
  final name = target is Procedure
      ? switch (target.kind) {
          ProcedureKind.Getter => 'get:${target.name.text}',
          ProcedureKind.Setter => 'set:${target.name.text}',
          _ => target.name.text,
        }
      : target.name.text;
  return {
    'library': target.enclosingLibrary.importUri.toString(),
    'class': cls.name,
    'name': name,
  };
}

/// Whether [c] carries its platform. A `--no-link-platform` kernel names
/// `dart:core` but binds no AST for it, so no hierarchy can be built over it.
bool componentIsLinked(Component c) => c.libraries.any(
  (l) => l.importUri.toString() == 'dart:core' && l.classes.isNotEmpty,
);

/// The world the patch is analyzed against: the patched component and the
/// release's [base]. The one construction, called by the analyzer's `main` and
/// by its tests. [baseHierarchy] reuses an already (lazily) built hierarchy.
FutureWorld futureWorldFor(
  TypeEnvironment patchedTypes,
  Component base, {
  ClassHierarchy Function()? baseHierarchy,
}) => FutureWorld(
  patchedTypes,
  base: base,
  baseIsLinked: componentIsLinked(base),
  baseHierarchy: baseHierarchy,
);

/// The classes that can be a `Future` at run time, for the closed-world check
/// of `await` and its kin (analysis version 24): the patched component's, and
/// the release's when its kernel can be asked. A class the patch deletes or
/// renames still runs in the release, so the patched component alone is not
/// the world.
class FutureWorld {
  /// [base] is the release's component, or null when there is none to ask.
  /// With a [base] that [baseIsLinked] does not hold for (it carries no
  /// platform, so no hierarchy can be built over it), nothing is narrowed.
  /// [baseHierarchy] builds the release's hierarchy on first use.
  FutureWorld(
    this.patched, {
    this.base,
    this.baseIsLinked = true,
    ClassHierarchy Function()? baseHierarchy,
  }) : _baseHierarchy = baseHierarchy;

  final TypeEnvironment patched;
  final Component? base;
  final bool baseIsLinked;
  final ClassHierarchy Function()? _baseHierarchy;

  late final ClassHierarchySubtypes? _patchedSubtypes = _subtypesOf(
    patched.hierarchy,
  );
  late final ClassHierarchy _baseWorld =
      _baseHierarchy?.call() ?? ClassHierarchy(base!, CoreTypes(base!));
  late final CoreTypes _baseCore = CoreTypes(base!);
  late final ClassHierarchySubtypes? _baseSubtypes = _subtypesOf(_baseWorld);
  late final Map<String, Class> _baseClasses = {
    for (final lib in base!.libraries)
      for (final c in lib.classes) _key(c): c,
  };

  late final Set<String> _baseClassNames = {
    for (final c in _baseClasses.values) c.name,
  };

  static String _key(Class c) => '${c.enclosingLibrary.importUri}#${c.name}';

  static ClassHierarchySubtypes? _subtypesOf(ClassHierarchy h) =>
      h is ClosedWorldClassHierarchy ? h.computeSubtypesInformation() : null;

  /// The subtypes of [cls] (a class of the patched component) that are
  /// `Future`s, from the patched component and the release, or null when the
  /// world cannot say.
  List<Class>? futureSubtypes(Class cls) {
    final subtypes = _patchedSubtypes;
    if (subtypes == null) return null;
    final found = <String, Class>{};
    final future = patched.coreTypes.futureClass;
    for (final sub in subtypes.getSubtypesOf(cls)) {
      if (patched.hierarchy.isSubInterfaceOf(sub, future)) {
        found[_key(sub)] = sub;
      }
    }
    if (base != null) {
      if (!baseIsLinked) return null;
      final baseSubtypes = _baseSubtypes;
      if (baseSubtypes == null) return null;
      final baseCls = _baseClasses[_key(cls)];
      // No class of that library and name in the release. A class the patch
      // adds has no release subtype, so the patched ones are the answer; but
      // a release class of the same name under another library URI is the
      // same class seen under a moved URI, whose release subtypes cannot be
      // found, so the world cannot say. Matching by name alone is deliberately
      // coarse: a new class that shares a name with an unrelated release class
      // is refused too, which over-refuses but never drops a report.
      if (baseCls == null && _baseClassNames.contains(cls.name)) return null;
      if (baseCls != null) {
        final baseFuture = _baseCore.futureClass;
        for (final sub in baseSubtypes.getSubtypesOf(baseCls)) {
          if (_baseWorld.isSubInterfaceOf(sub, baseFuture)) {
            found.putIfAbsent(_key(sub), () => sub);
          }
        }
      }
    }
    return found.values.toList();
  }
}

/// The external symbols [p]'s body names, as data (analysis version 18).
///
/// A walk failure yields ONE `unanalyzed` entry and nothing else: a partial list
/// would read as a complete one.
///
/// [types] is the type environment of the component [p] lives in. With it, an
/// operator site the bytecode compiler turns into an opcode is marked
/// `inlined` (analysis version 20); without it nothing is.
///
/// [world] answers which classes can be a `Future` (analysis version 24). With
/// none, an `await` of a class or interface is not narrowed: the unnarrowed
/// entry is reported.
List<Map<String, Object?>> externalReferencesOf(
  Procedure p,
  Set<Member> carried, {
  Map<String, List<Member>> appMembersByName = const {},
  TypeEnvironment? types,
  FutureWorld? world,
}) => _externalReferences(
  p,
  carried,
  appMembersByName: appMembersByName,
  types: types,
  world: world,
);

List<Map<String, Object?>> _externalReferences(
  Procedure p,
  Set<Member> carried, {
  Map<String, List<Member>> appMembersByName = const {},
  TypeEnvironment? types,
  FutureWorld? world,
}) {
  final context = types == null ? null : StaticTypeContext(p, types);
  final uses = _ExternalUses(
    carried,
    p.enclosingClass,
    p.enclosingLibrary,
    appMembersByName,
    recognized: context == null ? null : RecognizedMethods(context),
    staticTypes: context,
    futureWorld: world,
  );
  try {
    p.function.accept(uses);
    if (uses.hasSuper) {
      for (final r in uses.found.values) {
        r.remove('inlined');
      }
    }
  } catch (error) {
    return [
      {'kind': 'unanalyzed', 'reason': 'the body could not be walked: $error'},
    ];
  }
  return [for (final k in uses.found.keys.toList()..sort()) uses.found[k]!];
}

/// What a class (or extension) member's body takes from its enclosing SCOPE,
/// which a replacement library does not have.
///
/// A replacement is a top-level function in a library that imports the target
/// library, so an unqualified `k` meaning the enclosing class's `static k` is
/// looked up among the library's top-level names instead, and a same-named
/// top-level `k` wins without any diagnostic. Kernel resolved the name
/// correctly; the source text did not say how.
///
/// Kernel decides WHICH names are statics of the enclosing declaration, and the
/// front end's own token stream decides whether each is already written with a
/// qualifier, so nothing here walks characters. The document says only what the
/// producer has to do:
///
/// `staticReferences`: each use of an own static that is written WITHOUT a
/// qualifier, with the offset of its identifier token and whether it is the
/// `$name` form of an interpolation. A use after `.` or `?.` is left out. A
/// static const that Kernel folded into a constant has no static node left; it
/// is reported (kind `constant`) only where the token at the folded
/// expression's offset IS that static's name.
///
/// `problems`: reasons this member cannot be carried safely. A spelling of an
/// own static that no reported use accounts for (inside a folded constant
/// collection, a map key, a local named like it), a use that is not at its
/// identifier, a mixin application copy, an instance member of an extension
/// type, a tear-off, an
/// unnamed extension. Non-empty means refuse.
///
/// `usedTypeParameters`: class type parameters the body mentions. They are not
/// in scope in a top-level function.
///
/// Null for a member outside a class or extension. [source] is the declaring
/// file's text (read from disk when omitted).
Map<String, Object?>? enclosingScopeOf(Procedure p, {String? source}) {
  final owner = _ScopeOwner.of(p);
  if (owner == null) return null;
  final problems = <String>[...owner.problems];
  final uses = _ScopeUses(owner);
  try {
    p.function.accept(uses);
  } catch (error) {
    problems.add('the body could not be walked: $error');
  }
  final references = <Map<String, Object?>>[];
  if (problems.isEmpty) {
    String? text = source;
    if (text == null) {
      try {
        final file = File.fromUri(p.fileUri);
        if (file.existsSync()) {
          text = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
        }
      } catch (_) {}
    }
    if (text == null) {
      problems.add('its source file could not be read to place the statics');
    } else {
      _placeStatics(owner, p, uses, text, references, problems);
    }
  }
  return {
    'class': owner.name,
    'staticReferences': references,
    'usedTypeParameters': uses.typeParameters.toList()..sort(),
    'problems': problems,
    // An instance member of an extension takes its receiver first, so a
    // consumer that finds no `lowering` for it must refuse, not carry it as a
    // top-level function of the wrong arity.
    if (_extensionInstanceMember(p) != null) 'extensionInstance': true,
  };
}

/// The most recently scanned source and its tokens, so the members of one file
/// are not each scanned again.
String? _scannedSource;
List<Token> _scannedTokens = const [];

List<Token> _tokensOf(String source) {
  if (!identical(source, _scannedSource) && source != _scannedSource) {
    final tokens = <Token>[];
    for (
      Token t = scanString(source).tokens;
      t.type != TokenType.EOF;
      t = t.next!
    ) {
      tokens.add(t);
    }
    _scannedSource = source;
    _scannedTokens = tokens;
  }
  return _scannedTokens;
}

bool _isQualifier(Token? t) =>
    t != null &&
    (t.type == TokenType.PERIOD || t.type == TokenType.QUESTION_PERIOD);

void _placeStatics(
  _ScopeOwner owner,
  Procedure p,
  _ScopeUses uses,
  String source,
  List<Map<String, Object?>> references,
  List<String> problems,
) {
  final tokens = _tokensOf(source);
  final byOffset = {for (final t in tokens) t.charOffset: t};
  final accounted = <int>{};
  final seen = <int>{};
  for (final (offset, member, kind) in uses.references) {
    var t = byOffset[offset];
    if (t == null || t.lexeme != member) {
      // `k ??= v` reports its write at the operator; the read of `k` before it
      // is reported at the identifier and is the one that is placed.
      if (kind == 'set' &&
          t != null &&
          t.type.isAssignmentOperator &&
          t.previous?.lexeme == member) {
        continue;
      }
      // A folded constant whose source did not spell this name (a literal, or a
      // qualified one) is not a use of it.
      if (kind == 'constant') continue;
      problems.add(
        'its use of the static `$member` is not at an identifier of that name '
        '(offset $offset), so it cannot be qualified',
      );
      continue;
    }
    accounted.add(t.charOffset);
    if (_isQualifier(t.previous)) continue;
    if (!seen.add(t.charOffset)) continue;
    references.add({
      'offset': t.charOffset,
      'member': member,
      'kind': kind,
      if (t.previous?.type == TokenType.STRING_INTERPOLATION_IDENTIFIER)
        'interpolated': true,
    });
  }
  // A SPELLING NO USE ACCOUNTS FOR. Walk the member's own tokens, tracking the
  // innermost bracket, and refuse any identifier that is the name of an own
  // static, is not qualified, and was not placed above. `name:` is an argument
  // label only directly inside parentheses; in a `{` or `[` it is a map key.
  final stack = <TokenType>[];
  for (final t in tokens) {
    if (t.charOffset < p.fileStartOffset) continue;
    if (t.charOffset > p.fileEndOffset) break;
    final type = t.type;
    if (type == TokenType.OPEN_PAREN ||
        type == TokenType.OPEN_SQUARE_BRACKET ||
        type == TokenType.OPEN_CURLY_BRACKET ||
        type == TokenType.STRING_INTERPOLATION_EXPRESSION) {
      stack.add(type);
      continue;
    }
    if ((type == TokenType.CLOSE_PAREN ||
            type == TokenType.CLOSE_SQUARE_BRACKET ||
            type == TokenType.CLOSE_CURLY_BRACKET) &&
        stack.isNotEmpty) {
      stack.removeLast();
      continue;
    }
    if (!owner.staticNames.contains(t.lexeme) || !t.isIdentifier) continue;
    if (accounted.contains(t.charOffset) ||
        t.charOffset == p.fileOffset ||
        _isQualifier(t.previous)) {
      continue;
    }
    final label =
        stack.isNotEmpty &&
        stack.last == TokenType.OPEN_PAREN &&
        t.next?.type == TokenType.COLON &&
        (t.previous?.type == TokenType.OPEN_PAREN ||
            t.previous?.type == TokenType.COMMA);
    if (label) continue;
    problems.add(
      'its body spells `${t.lexeme}`, which is also a static of `${owner.name}`, '
      'where no use of that static is reported to qualify (offset '
      '${t.charOffset}): in the replacement library a top-level `${t.lexeme}` '
      'would be bound instead. Write `${owner.name}.${t.lexeme}`',
    );
    break;
  }
}

/// The class or extension whose scope a member's body is written in.
class _ScopeOwner {
  _ScopeOwner(this.name, this.staticNames, this.own, this.constants, this.cls)
    : problems = [];

  /// The name to qualify with.
  final String name;
  final Set<String> staticNames;

  /// The static name [m] is, if it is an own static of this scope.
  final String? Function(Member m) own;
  final List<(String, Constant)> constants;
  final Class? cls;
  final List<String> problems;

  static _ScopeOwner? of(Procedure p) {
    final cls = p.enclosingClass;
    if (cls != null) {
      final statics = <String>{
        for (final m in cls.members)
          if (m is! Constructor && !m.isInstanceMember) m.name.text,
      };
      final owner = _ScopeOwner(
        cls.name,
        statics,
        (m) =>
            !m.isInstanceMember &&
                m is! Constructor &&
                !(m is Procedure && m.isFactory) &&
                identical(m.enclosingClass, cls)
            ? m.name.text
            : null,
        [
          for (final f in cls.fields)
            if (f.isStatic && f.isConst && f.initializer is ConstantExpression)
              (f.name.text, (f.initializer! as ConstantExpression).constant),
        ],
        cls,
      );
      if (cls.name.contains('&') || cls.name.contains('#')) {
        owner.problems.add(
          'it is a member of the synthetic class `${cls.name}`, a mixin '
          'application copy, whose scope is not the written one',
        );
      }
      return owner;
    }
    final bar = p.name.text.indexOf('|');
    if (bar < 0 || !(p.isExtensionMember || p.isExtensionTypeMember)) {
      return null;
    }
    final extName = p.name.text.substring(0, bar);
    final library = p.enclosingLibrary;
    // (name, isStatic, member reference) of the declaration's members.
    final descriptors = <(String, bool, Reference?)>[];
    // Tear-offs (`Ext|get#m` of a method `m`), which no descriptor claims as
    // its member.
    final tearOffs = <Reference>{};
    var isExtensionType = false;
    for (final e in library.extensions) {
      if (e.name == extName) {
        for (final d in e.memberDescriptors) {
          descriptors.add((d.name.text, d.isStatic, d.memberReference));
          if (d.tearOffReference != null) tearOffs.add(d.tearOffReference!);
        }
      }
    }
    for (final e in library.extensionTypeDeclarations) {
      if (e.name == extName) {
        isExtensionType = true;
        for (final d in e.memberDescriptors) {
          descriptors.add((d.name.text, d.isStatic, d.memberReference));
          if (d.tearOffReference != null) tearOffs.add(d.tearOffReference!);
        }
      }
    }
    final statics = {
      for (final (n, isStatic, _) in descriptors)
        if (isStatic) n,
    };
    final owner = _ScopeOwner(
      extName,
      statics,
      (m) {
        if (m.enclosingClass != null) return null;
        final n = m.name.text;
        if (!n.startsWith('$extName|')) return null;
        final rest = n.substring(extName.length + 1);
        return statics.contains(rest) ? rest : null;
      },
      [
        for (final f in library.fields)
          if (f.isConst &&
              f.name.text.startsWith('$extName|') &&
              f.initializer is ConstantExpression &&
              statics.contains(f.name.text.substring(extName.length + 1)))
            (
              f.name.text.substring(extName.length + 1),
              (f.initializer! as ConstantExpression).constant,
            ),
      ],
      null,
    );
    if (extName.contains('#')) {
      owner.problems.add('it is a member of an unnamed extension');
    }
    final self = descriptors.where((d) => d.$3 == p.reference).toList();
    if (self.isEmpty) {
      owner.problems.add(
        tearOffs.contains(p.reference)
            ? 'it is the tear-off of an extension method, which has no source '
                  'of its own'
            : 'its extension member could not be identified',
      );
    } else if (!self.first.$2 && isExtensionType) {
      // An instance member of an extension TYPE: its receiver is the
      // representation value, which a replacement does not rebuild. An
      // instance member of an extension is carried from analysis 22
      // (`_extensionLowering`).
      owner.problems.add(
        'it is an instance member of the extension type `$extName`, which a '
        'replacement does not carry',
      );
    }
    return owner;
  }
}

class _ScopeUses extends RecursiveVisitor {
  _ScopeUses(this.owner);

  final _ScopeOwner owner;
  final references = <(int, String, String)>[];
  final typeParameters = <String>{};

  void _static(Member m, int offset, String kind) {
    final name = owner.own(m);
    if (name != null) references.add((offset, name, kind));
  }

  @override
  void visitStaticGet(StaticGet node) {
    _static(node.target, node.fileOffset, 'get');
    super.visitStaticGet(node);
  }

  @override
  void visitStaticSet(StaticSet node) {
    _static(node.target, node.fileOffset, 'set');
    super.visitStaticSet(node);
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    _static(node.target, node.fileOffset, 'invoke');
    super.visitStaticInvocation(node);
  }

  @override
  void visitStaticTearOff(StaticTearOff node) {
    _static(node.target, node.fileOffset, 'tearoff');
    super.visitStaticTearOff(node);
  }

  @override
  void visitConstantExpression(ConstantExpression node) {
    final constant = node.constant;
    // A static torn off in a constant context is folded to a constant too.
    if (constant is StaticTearOffConstant) {
      _static(constant.target, node.fileOffset, 'tearoff');
    }
    for (final (name, value) in owner.constants) {
      if (value == constant) {
        references.add((node.fileOffset, name, 'constant'));
      }
    }
    super.visitConstantExpression(node);
  }

  @override
  void visitTypeParameterType(TypeParameterType node) {
    final parameter = node.parameter;
    if (owner.cls != null &&
        identical(parameter.parent, owner.cls) &&
        parameter.name != null) {
      typeParameters.add(parameter.name!);
    }
    super.visitTypeParameterType(node);
  }
}

/// Every symbol a body asks the loader to find by name.
///
/// The twin of `gen_dynamic_interface.dart`'s `_FrameworkUseCollector`, on
/// purpose: that collector decided what the release retained from its own code,
/// and this one asks the same question of the patch's code. Where they differ
/// the difference is stated: this one skips a local's declared type (the
/// collector keeps it as a type) and does not walk class headers (a patch
/// carries only procedure bodies).
class _ExternalUses extends RecursiveVisitor {
  _ExternalUses(
    this.carried,
    this.owner,
    this.ownerLibrary,
    this.appMembersByName, {
    this.recognized,
    this.staticTypes,
    this.futureWorld,
  });

  /// The classes that can be a `Future`, for [_thenOf]; null asks nothing.
  final FutureWorld? futureWorld;

  /// The body's static types (analysis version 23): the receiver class of a
  /// `for-in`. Null when the caller has no type environment.
  final StaticTypeContext? staticTypes;

  /// dart2bytecode's own rule for which calls become opcodes (analysis version
  /// 20); null when the caller has no type environment.
  final RecognizedMethods? recognized;

  /// The app's instance members by plain name; see [_dynamic].
  final Map<String, List<Member>> appMembersByName;

  /// Members the patch itself carries; naming one is not an external use.
  final Set<Member> carried;

  /// The class of the member being analyzed. Its own retention is the target
  /// grant's question (`refuseTarget`), not this one's.
  final Class? owner;

  /// The library of the member being analyzed. A private name is scoped to its
  /// library, so a source token can name a private symbol of THIS library only;
  /// a private symbol of any other library in a body is something the compiler
  /// introduced (the AOT kernel lowers a list literal to
  /// `_GrowableList._literal1`, for one), which no interface retains and no
  /// source spells. Those are not reported, unless a constant names them: the
  /// release's own generator kept those (`allowPrivate`), and a constant's
  /// private field is looked up by name like any other.
  final Library ownerLibrary;

  final found = <String, Map<String, Object?>>{};

  /// Whether the body contains a `super.` call, getter or setter. The producer
  /// does not give dart2bytecode this kernel: it rewrites each one to
  /// `$routeBSuper(...) as dynamic` (route_b_producer.dart, `_lower`), so an
  /// operand derived from a super member is `dynamic` there however it is
  /// typed here (`super.n + 1`, `1 + super.m()`, `var x = super.n; x + 1`).
  /// No `inlined` is reported for a body that has one.
  bool hasSuper = false;
  final _seenConstants = <Constant>{};

  bool _skipLibrary(Library lib) {
    final uri = lib.importUri.toString();
    // `dart:_internal` and friends: nothing a patch spells, and nothing an
    // interface can name, so requiring it would refuse every `for` loop.
    return uri.startsWith('dart:_');
  }

  void _class(Reference? ref, {bool viaConstant = false}) {
    final cls = ref?.node;
    if (cls is! Class || identical(cls, owner)) return;
    if (_skipLibrary(cls.enclosingLibrary)) return;
    if (cls.name.startsWith('_') &&
        !viaConstant &&
        !identical(cls.enclosingLibrary, ownerLibrary)) {
      return;
    }
    if (cls.name.contains('&') || cls.name.contains('#')) return;
    final library = cls.enclosingLibrary.importUri.toString();
    found['class|$library|${cls.name}'] = {
      'kind': 'class',
      'library': library,
      'class': cls.name,
      'member': null,
      'private': cls.name.startsWith('_'),
      if (viaConstant) 'viaConstant': true,
    };
  }

  void _member(
    Reference? ref, {
    bool viaConstant = false,
    bool tearOff = false,
    String? inlined,
  }) {
    final m = ref?.node;
    if (m is! Member || carried.contains(m)) return;
    if (_skipLibrary(m.enclosingLibrary)) return;
    final cls = m.enclosingClass;
    if (cls != null && (cls.name.contains('&') || cls.name.contains('#'))) {
      return;
    }
    // A `#` name is a compiler synthetic and nothing a patch spells, EXCEPT an
    // extension getter, setter or tear-off (`Ext|get#wait`): that one is
    // spelled by `record.wait` and looked up by name at load, and the loader
    // aborts the process when the release lacks it. It is reported like any
    // top-level member so the CLI can refuse it (no interface lists one).
    if (m.name.text.contains('#') &&
        !(m is Procedure && (m.isExtensionMember || m.isExtensionTypeMember))) {
      return;
    }
    final isPrivate = m.name.isPrivate || (cls?.name.startsWith('_') ?? false);
    if (isPrivate &&
        !viaConstant &&
        !identical(m.enclosingLibrary, ownerLibrary)) {
      return;
    }
    final library = m.enclosingLibrary.importUri.toString();
    final String kind;
    if (m is Constructor || (m is Procedure && m.isFactory)) {
      kind = 'constructor';
    } else if (cls == null) {
      kind = 'top-level';
    } else if (m.isInstanceMember) {
      kind = 'instance';
    } else {
      kind = 'static';
    }
    // The VM's names, which are the interface's: an accessor is `get:`/`set:`.
    var name = m is Procedure
        ? vmMemberName(m.name.text, switch (m.kind) {
            ProcedureKind.Getter => 'getter',
            ProcedureKind.Setter => 'setter',
            _ => 'method',
          })
        : m.name.text;
    // A tear-off needs a method extractor the AOT compiler emits only where
    // some code tears that selector off, so it is its own key.
    if (tearOff) name = 'tearoff:$name';
    final key = '$kind|$library|${cls?.name}|$name|${viaConstant ? 'c' : 'd'}';
    final seen = found[key];
    if (seen != null) {
      // `inlined` holds only while EVERY site of the member is an opcode: a
      // later real call clears it.
      final had = seen['inlined'] as String?;
      if (inlined == null || had == null) {
        seen.remove('inlined');
      } else {
        // Sites of one key can be different opcodes (`num::<` for an int pair
        // and for a double pair): every one is named, sorted.
        seen['inlined'] = ({
          ...had.split('|'),
          ...inlined.split('|'),
        }.toList()..sort()).join('|');
      }
      return;
    }
    found[key] = {
      'kind': kind,
      'library': library,
      'class': cls?.name,
      'member': name,
      'private': isPrivate,
      if (viaConstant) 'viaConstant': true,
      if (inlined != null) 'inlined': inlined,
    };
  }

  @override
  void visitInterfaceType(InterfaceType node) {
    _class(node.classReference);
    // Not super: the default dereferences the class.
    for (final t in node.typeArguments) {
      t.accept(this);
    }
  }

  @override
  void visitTypedefType(TypedefType node) {
    for (final t in node.typeArguments) {
      t.accept(this);
    }
  }

  @override
  void visitExtensionType(ExtensionType node) {
    for (final t in node.typeArguments) {
      t.accept(this);
    }
  }

  // A local's declared (or inferred) type is not a reference the bytecode is
  // known to emit; a PARAMETER's is, because it is part of the function's
  // signature (the first `build()` patch on a device died on `BuildContext`).
  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    node.initializer?.accept(this);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    node.function.accept(this);
  }

  @override
  void visitFunctionNode(FunctionNode node) {
    // The twin of the collector's, minus a redirecting factory (a patch carries
    // procedure bodies, never a factory header). A type parameter's bound and
    // an async function's emitted value type are part of the signature the
    // loader reads, exactly as a parameter's type is.
    for (final t in node.typeParameters) {
      t.accept(this);
    }
    for (final v in [...node.positionalParameters, ...node.namedParameters]) {
      v.type.accept(this);
      v.initializer?.accept(this);
    }
    node.returnType.accept(this);
    node.emittedValueType?.accept(this);
    _asyncMarkers.add(node.asyncMarker);
    try {
      node.body?.accept(this);
    } finally {
      _asyncMarkers.removeLast();
    }
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    _member(node.targetReference);
    _thenChains(node.target, node.arguments, null);
    node.arguments.accept(this);
  }

  @override
  void visitStaticGet(StaticGet node) => _member(node.targetReference);

  @override
  void visitStaticSet(StaticSet node) {
    _member(node.targetReference);
    node.value.accept(this);
  }

  @override
  void visitStaticTearOff(StaticTearOff node) => _member(node.targetReference);

  @override
  void visitConstructorInvocation(ConstructorInvocation node) {
    _member(node.targetReference);
    node.arguments.accept(this);
  }

  @override
  void visitConstructorTearOff(ConstructorTearOff node) =>
      _member(node.targetReference);

  @override
  void visitRedirectingFactoryTearOff(RedirectingFactoryTearOff node) =>
      _member(node.targetReference);

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    // Asked of dart2bytecode's own function, on the same node kind its
    // generator asks it of (`_genMethodInvocation`), so the two cannot differ.
    final opcode = recognized?.specializedBytecodeFor(node);
    _member(
      node.interfaceTargetReference,
      inlined: opcode == null ? null : opcode.name.substring(1),
    );
    _thenChains(node.interfaceTarget, node.arguments, node.receiver);
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
    if (_isLoweredForInIterator(node)) {
      // The VM's for-in lowering (pkg/vm, before the dill is written) leaves
      // no ForInStatement: the loop is `synthesized Iterator
      // :sync-for-iterator = <iterable>.iterator` and a `moveNext` loop.
      // This is the one place a dill names the iterable's static type.
      _sdk(
        'dart:core',
        'Iterable',
        'get:iterator',
        receiver: _iterableReceiver(node.receiver),
      );
    } else {
      _member(node.interfaceTargetReference);
    }
    node.receiver.accept(this);
  }

  /// Whether [node] is the `iterator` read the for-in lowering initializes
  /// its synthetic `:sync-for-iterator` variable with. A miss falls back to
  /// [_member], the entry with no receiver, which the CLI reads as every
  /// `Iterable`: never a narrower answer than the truth.
  bool _isLoweredForInIterator(InstanceGet node) {
    final parent = node.parent;
    if (parent is! Variable || parent.cosmeticName != ':sync-for-iterator') {
      return false;
    }
    final target = node.interfaceTarget;
    return target.name.text == 'iterator' &&
        target.enclosingClass?.name == 'Iterable' &&
        target.enclosingLibrary.importUri.toString() == 'dart:core';
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    _member(node.interfaceTargetReference);
    node.receiver.accept(this);
    node.value.accept(this);
  }

  @override
  void visitInstanceTearOff(InstanceTearOff node) {
    _member(node.interfaceTargetReference, tearOff: true);
    node.receiver.accept(this);
  }

  // A call dispatched by name, with no interface target: whether the release
  // kept the selector for the receiver's runtime class cannot be known here.
  // Reported as `dynamic` with the selector (analysis version 19), plus every
  // app class that has a member of that name, which the CLI answers with the
  // interface like any other app member.
  void _dynamic(String plain, String vmName) {
    found['dynamic||null|$vmName|d'] = {
      'kind': 'dynamic',
      'library': '',
      'class': null,
      'member': vmName,
      'private': false,
    };
    for (final m in appMembersByName[plain] ?? const <Member>[]) {
      _member(m.reference);
    }
  }

  @override
  void visitDynamicInvocation(DynamicInvocation node) {
    _dynamic(node.name.text, node.name.text);
    node.receiver.accept(this);
    node.arguments.accept(this);
  }

  @override
  void visitDynamicGet(DynamicGet node) {
    _dynamic(node.name.text, 'get:${node.name.text}');
    node.receiver.accept(this);
  }

  @override
  void visitDynamicSet(DynamicSet node) {
    _dynamic(node.name.text, 'set:${node.name.text}');
    node.receiver.accept(this);
    node.value.accept(this);
  }

  // `for (x in xs)` asks the receiver's class for `iterator`, `moveNext` and
  // `current` by selector, and no source token names them. [receiver] is the
  // class of the iterable's static type (analysis version 23), one entry each.
  // A real dill carries the lowered form (see [visitInstanceGet]); the
  // ForInStatement below is the unlowered form.
  void _sdk(String library, String cls, String member, {Class? receiver}) {
    final receiverLibrary = receiver?.enclosingLibrary.importUri.toString();
    final suffix = receiver == null ? '' : '|$receiverLibrary#${receiver.name}';
    found['instance|$library|$cls|$member|d$suffix'] = {
      'kind': 'instance',
      'library': library,
      'class': cls,
      'member': member,
      'private': false,
      if (receiver != null) 'receiverLibrary': receiverLibrary,
      if (receiver != null) 'receiverClass': receiver.name,
    };
  }

  /// The class of [iterable]'s static type when it is an interface type other
  /// than `Iterable` itself, else null (no narrowing: every `Iterable`).
  Class? _iterableReceiver(Expression iterable) {
    final context = staticTypes;
    if (context == null) return null;
    final DartType type;
    try {
      type = iterable.getStaticType(context);
    } on Object {
      // Not knowing the type narrows nothing; it is not a walk failure.
      return null;
    }
    // A nullable static type is not a class the CLI can narrow to.
    if (type is! InterfaceType ||
        type.declaredNullability != Nullability.nonNullable) {
      return null;
    }
    final cls = type.classNode;
    if (cls.name == 'Iterable' &&
        cls.enclosingLibrary.importUri.toString() == 'dart:core') {
      return null;
    }
    return cls;
  }

  /// Whether [operand] is a call whose result is a `_Future` whatever the
  /// program does (analysis version 25): the callee is resolved statically, so
  /// no override can answer with another `Future`, and it is an `async`
  /// function (which always returns a `_Future`) or a `Future` constructor
  /// that returns one. An interface call is not: `obj.fetch()` can reach an
  /// override that returns a `TickerFuture`.
  static bool _isProvablyFuture(Expression operand) {
    final Member target;
    if (operand is StaticInvocation) {
      target = operand.target;
    } else if (operand is SuperMethodInvocation) {
      final t = operand.interfaceTarget;
      if (t == null) return false;
      target = t;
    } else {
      return false;
    }
    if (target is! Procedure) return false;
    if (target.function.asyncMarker == AsyncMarker.Async) return true;
    // The constructors of `Future` that return a `_Future`: `Future()` has the
    // empty name.
    return target.isFactory &&
        _isCore(target, 'dart:async', 'Future') &&
        const {'', 'delayed', 'value', 'sync', 'microtask'}.contains(
          target.name.text,
        );
  }

  /// The async markers of the function bodies being walked, innermost last:
  /// only a `return e` in an `async` body hands `e` to the completer.
  final _asyncMarkers = <AsyncMarker>[];

  /// Reports a call of `Future.then` the VM makes on the value of [operand]
  /// (analysis version 24): an `await` of it, a `return` of it from an
  /// `async` body, or an SDK API that chains it (`Completer.complete`,
  /// `Future.value`, `Stream.fromFuture`, `asStream`). The VM does this by
  /// selector for any `Future` that is not a `_Future`, and no source token
  /// names it.
  ///
  /// A static type that is a `Future` subtype names that class as the
  /// receiver. A type that cannot be a `Future` (a record, a function, `Null`,
  /// `int`, `String`, ...) reports nothing; every other type reports the entry
  /// with no receiver, which the CLI reads as every `Future` the release holds.
  void _thenOf(Expression operand) {
    // `await for` is lowered to `await it.moveNext()` and `await it.cancel()`
    // on a `_StreamIterator`, whose futures are always `_Future`s.
    if (operand is InstanceInvocation &&
        (operand.name.text == 'moveNext' || operand.name.text == 'cancel') &&
        _isCore(operand.interfaceTarget, 'dart:async', '_StreamIterator')) {
      return;
    }
    final context = staticTypes;
    if (context != null && _isProvablyFuture(operand)) {
      final futureImpl = context.typeEnvironment.coreTypes.index.tryGetClass(
        'dart:async',
        '_Future',
      );
      if (futureImpl != null) {
        _sdk('dart:async', 'Future', 'then', receiver: futureImpl);
        return;
      }
    }
    DartType? type;
    if (context != null) {
      try {
        type = operand.getStaticType(context);
      } on Object {
        // Not knowing the type narrows nothing: the entry is still reported.
        type = null;
      }
    }
    final receivers = <Class>[];
    if (context != null && type != null) {
      if (type is RecordType ||
          type is FunctionType ||
          type is NullType ||
          type is NeverType) {
        return;
      }
      if (type is InterfaceType) {
        final cls = type.classNode;
        final env = context.typeEnvironment;
        final futureClass = env.coreTypes.futureClass;
        if (env.hierarchy.isSubInterfaceOf(cls, futureClass)) {
          if (cls != futureClass) receivers.add(cls);
        } else if (cls != env.coreTypes.objectClass) {
          // Closed world: a value of this static type is a `Future` only if
          // some class is a subtype of both (`class Slow implements Pingable,
          // Future`). The classes are the patched component's and the
          // release's (a class the patch deletes still runs there); none:
          // it cannot be one. A world that cannot say reports unnarrowed.
          final subs = futureWorld?.futureSubtypes(cls);
          if (subs == null) {
            _sdk('dart:async', 'Future', 'then');
            return;
          }
          if (subs.isEmpty) return;
          receivers.addAll(subs);
        }
      }
    }
    if (receivers.isEmpty) {
      _sdk('dart:async', 'Future', 'then');
    } else {
      for (final r in receivers) {
        _sdk('dart:async', 'Future', 'then', receiver: r);
      }
    }
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    _thenOf(node.operand);
    super.visitAwaitExpression(node);
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    final value = node.expression;
    if (value != null &&
        _asyncMarkers.isNotEmpty &&
        _asyncMarkers.last == AsyncMarker.Async) {
      _thenOf(value);
    }
    super.visitReturnStatement(node);
  }

  static bool _isCore(Member target, String library, String cls) =>
      target.enclosingClass?.name == cls &&
      target.enclosingLibrary.importUri.toString() == library;

  /// The SDK calls that chain a `Future` argument with its `then` (analysis
  /// version 24). `Future.wait` and `Future.any` take an iterable of futures
  /// whose element type is not read, so they report the unnarrowed entry.
  void _thenChains(Member target, Arguments arguments, Expression? receiver) {
    final name = target.name.text;
    // `[a, b].wait` and `(a, b).wait` are `dart:async` extension getters,
    // which have no enclosing class.
    if (target.enclosingClass == null &&
        target.enclosingLibrary.importUri.toString() == 'dart:async' &&
        RegExp(
          r'^(FutureIterable|FutureRecord\d+)\|get#wait$',
        ).hasMatch(name)) {
      _sdk('dart:async', 'Future', 'then');
      return;
    }
    // `ticker.ignore()` and `ticker.onError(...)`, and their tear-offs
    // (`FutureExtensions|get#ignore`), call the receiver's `then` when it is
    // not a `_Future`; the extension is a static call with the receiver as its
    // first argument.
    if (target.enclosingClass == null &&
        target.enclosingLibrary.importUri.toString() == 'dart:async' &&
        RegExp(r'^FutureExtensions\|(get#)?(ignore|onError)$').hasMatch(name) &&
        arguments.positional.isNotEmpty) {
      _thenOf(arguments.positional.first);
      return;
    }
    if (_isCore(target, 'dart:async', 'Future')) {
      if (name == 'wait' || name == 'any') {
        _sdk('dart:async', 'Future', 'then');
      } else if (name == 'value' && arguments.positional.isNotEmpty) {
        _thenOf(arguments.positional.first);
      } else if (name == 'asStream' && receiver != null) {
        _thenOf(receiver);
      }
    } else if (_isCore(target, 'dart:async', 'Stream')) {
      if (name == 'fromFuture' && arguments.positional.isNotEmpty) {
        _thenOf(arguments.positional.first);
      } else if (name == 'fromFutures') {
        _sdk('dart:async', 'Future', 'then');
      }
    } else if (_isCore(target, 'dart:async', 'Completer') &&
        name == 'complete' &&
        arguments.positional.isNotEmpty) {
      _thenOf(arguments.positional.first);
    }
  }

  @override
  void visitForInStatement(ForInStatement node) {
    if (node.isAsync) {
      _sdk('dart:async', 'Stream', 'listen');
    } else {
      _sdk(
        'dart:core',
        'Iterable',
        'get:iterator',
        receiver: _iterableReceiver(node.iterable),
      );
      _sdk('dart:core', 'Iterator', 'moveNext');
      _sdk('dart:core', 'Iterator', 'get:current');
    }
    super.visitForInStatement(node);
  }

  @override
  void visitEqualsCall(EqualsCall node) {
    _member(node.interfaceTargetReference);
    node.left.accept(this);
    node.right.accept(this);
  }

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    hasSuper = true;
    _member(node.interfaceTargetReference);
    node.arguments.accept(this);
  }

  @override
  void visitSuperPropertyGet(SuperPropertyGet node) {
    hasSuper = true;
    _member(node.interfaceTargetReference);
  }

  @override
  void visitSuperPropertySet(SuperPropertySet node) {
    hasSuper = true;
    _member(node.interfaceTargetReference);
    node.value.accept(this);
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
        _class(c.classReference, viaConstant: true);
        for (final entry in c.fieldValues.entries) {
          _member(entry.key, viaConstant: true);
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
        _member(c.targetReference, viaConstant: true);
      case ConstructorTearOffConstant():
        _member(c.targetReference, viaConstant: true);
      case RedirectingFactoryTearOffConstant():
        _member(c.targetReference, viaConstant: true);
      case InstantiationConstant():
        _constant(c.tearOffConstant);
        for (final t in c.types) {
          t.accept(this);
        }
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

/// Every `ThisExpression` in a body, for the census to classify.
///
/// Census-only. It makes no decision; `_lowering` has already made it.
class _ThisExpressions extends RecursiveVisitor {
  final found = <ThisExpression>[];

  @override
  void visitThisExpression(ThisExpression node) => found.add(node);
}

/// Every use of the receiver, and a reason for each one that is not supported.
class _ReceiverUses extends RecursiveVisitor {
  _ReceiverUses([this.helperMembers = const {}, this.extension]);

  /// Set when the body is an instance member of an extension (analysis version
  /// 22): its receiver is the `#this` parameter rather than a `this`.
  final _ExtensionReceiver? extension;

  /// `VariableGet`s of the extension receiver already accounted for.
  final consumedVariables = <VariableGet>{};

  bool _isReceiver(Expression e) =>
      e is ThisExpression ||
      (extension != null &&
          e is VariableGet &&
          identical(e.variable, extension!.thisVariable));

  void _consume(Expression e) {
    if (e is ThisExpression) {
      consumed.add(e);
    } else if (e is VariableGet) {
      consumedVariables.add(e);
    }
  }

  /// Version 17: instance helpers the patch carries. A call to one is a
  /// `helperCall` access: it is rewritten to pass the receiver, not prefixed
  /// with it.
  final Set<Member> helperMembers;

  final accesses = <_Access>[];
  final unsupported = <String>[];

  /// Genuine `super.member()` sites, as STRUCTURE rather than as a refusal
  /// string (analysis version 10).
  final superInvocations = <_SuperSite>[];

  /// Constructions of a PRIVATE class in the body (analysis version 12).
  ///
  /// The parity gap D-PRODUCER-DEMAND-1 measured. A replacement declaration is
  /// recompiled whole, so `_CustomFocusBuilder(...)` in the body becomes a
  /// construction the PATCH performs -- and the release retains a private
  /// class's constructor only if its manifest granted it. Under policy p2,
  /// private classes are retained so their members can be PATCH-TARGETED, and
  /// construction is withheld separately: on one real release, 119 withheld and
  /// zero constructible.
  ///
  /// REPORTED, never refused here, exactly like a private member access: the
  /// manifest is a per-release artifact and the analyzer ships in a cell
  /// resolved by engine hash, so the decision belongs to the consumer holding
  /// the manifest.
  final privateConstructions = <_PrivateConstruction>[];

  /// `ThisExpression` nodes already accounted for as the receiver of a
  /// supported access. Without this every `label` reports twice: once as the
  /// InstanceGet and once as its own synthesized receiver.
  ///
  /// Readable rather than private because the D0.2 census classifies the
  /// UNCONSUMED remainder, and restating the consumption rule there would be
  /// two definitions of one thing.
  final consumed = <ThisExpression>{};

  /// Record one receiver access.
  ///
  /// PRIVATE IS REPORTED HERE, NOT REFUSED. Rung D proved a synthetic
  /// replacement library CAN name a private member of the release, given
  /// `--resolve-private-names-in-library` and a release that retained it. The
  /// second half is a per-release fact recorded in that release's capability
  /// manifest, and this tool ships in the compiler cell resolved by engine
  /// hash -- so it reports the key and the CLI matches it against the manifest
  /// the release actually published.
  ///
  /// A private member whose key cannot be resolved is REFUSED, not reported:
  /// an access with no key is indistinguishable from a public one downstream,
  /// and that is the one direction where the mistake is silent.
  void _record(int offset, String name, String kind, Member? target) {
    if (!name.startsWith('_')) {
      accesses.add(_Access(offset, name, kind));
      return;
    }
    final key = _privateKey(target);
    if (key == null) {
      unsupported.add(
        '${_phrase(kind)} the private member `$name`, which resolves to no '
        'declaration this analysis can name -- so no release manifest can '
        'show it was retained',
      );
      return;
    }
    accesses.add(_Access(offset, name, kind, private: key));
  }

  static String _phrase(String kind) => switch (kind) {
    'set' => 'assigns to',
    'invoke' => 'calls',
    _ => 'reads',
  };

  @override
  void visitInstanceGet(InstanceGet node) {
    final receiver = node.receiver;
    if (_isReceiver(receiver)) {
      _consume(receiver);
      _record(node.fileOffset, node.name.text, 'get', node.interfaceTarget);
    }
    node.visitChildren(this);
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    final receiver = node.receiver;
    if (_isReceiver(receiver)) {
      _consume(receiver);
      // A write is the same lexical shape as a read: the offset is on the
      // identifier and everything after it -- `= <whatever>` -- is the
      // source's own text. The right-hand side is carried across untouched,
      // and any receiver use INSIDE it is its own reported access, so
      // `label = label + 'Y'` becomes `self.label = self.label + 'Y'`.
      _record(node.fileOffset, node.name.text, 'set', node.interfaceTarget);
    }
    node.visitChildren(this);
  }

  @override
  void visitSuperPropertySet(SuperPropertySet node) {
    // Refused for the same reason `super.foo()` is: a synthetic top-level
    // function has no `super`, and `self.foo = ...` would not mean the same
    // thing. Without this the generated library simply fails to compile, which
    // is loud but says nothing useful.
    unsupported.add('assigns to `super.${node.name.text}`');
    node.visitChildren(this);
  }

  /// An operator is not written `this.op(...)`: its offset is on the operator
  /// token, so a member-prefix edit there would be wrong. In an extension the
  /// receiver of `this + 1` is reported as the bare `this` it is.
  static bool _isOperator(String name) =>
      name == 'unary-' || !RegExp(r'^[A-Za-z_$]').hasMatch(name);

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    final receiver = node.receiver;
    if (extension != null && _isOperator(node.name.text)) {
      node.visitChildren(this);
      return;
    }
    if (_isReceiver(receiver)) {
      _consume(receiver);
      // ARGUMENTS NEED NO PERMISSION. The producer's edit inserts a receiver
      // prefix immediately before this identifier and copies everything after
      // it verbatim, so the argument list -- positional, named, generic,
      // nested, however spelled -- is carried across as source text and never
      // interpreted. There is nothing about it for the lowering to get wrong,
      // and so nothing to gate on.
      //
      // Receiver uses INSIDE the arguments are a different matter, and they
      // are handled by the ordinary recursion: `helper(label)` reports two
      // accesses and becomes `self.helper(self.label)`.
      if (helperMembers.contains(node.interfaceTarget)) {
        accesses.add(_Access(node.fileOffset, node.name.text, 'helperCall'));
        node.visitChildren(this);
        return;
      }
      _record(node.fileOffset, node.name.text, 'invoke', node.interfaceTarget);
    }
    node.visitChildren(this);
  }

  @override
  void visitInstanceGetterInvocation(InstanceGetterInvocation node) {
    if (_isReceiver(node.receiver)) {
      _consume(node.receiver);
      unsupported.add('invokes the getter `${node.name.text}` on the receiver');
    }
    node.visitChildren(this);
  }

  @override
  void visitSuperPropertyGet(SuperPropertyGet node) {
    unsupported.add('reads `super.${node.name.text}`');
    node.visitChildren(this);
  }

  @override
  void visitConstructorInvocation(ConstructorInvocation node) {
    _recordPrivateConstruction(node.target, node.fileOffset);
    node.visitChildren(this);
  }

  @override
  void visitVariableGet(VariableGet node) {
    // A bare use of the extension receiver: `this` as a value, `$this`, or an
    // argument. The producer replaces the token with `self` and checks that
    // the source has `this` there; an implicit one has no such token.
    final ext = extension;
    if (ext != null &&
        identical(node.variable, ext.thisVariable) &&
        !consumedVariables.contains(node)) {
      accesses.add(_Access(node.fileOffset, 'this', 'receiver'));
    }
    super.visitVariableGet(node);
  }

  /// Whether [e] reads [receiver], directly or through a `let` variable
  /// (a cascade or null-aware call binds the receiver to one first).
  static bool _mentionsReceiver(Expression e, Variable receiver) {
    final finder = _ReceiverFinder(receiver);
    e.accept(finder);
    return finder.found;
  }

  /// A call that passes the extension receiver first: a sibling instance
  /// member of the same extension (reported), or another extension's member or
  /// a tear-off (refused). Returns whether it handled [node].
  bool _extensionCall(StaticInvocation node) {
    final ext = extension;
    if (ext == null || node.arguments.positional.isEmpty) return false;
    final first = node.arguments.positional.first;
    final target = node.target;
    if (first is! VariableGet || !identical(first.variable, ext.thisVariable)) {
      // `this..m()`, `this?.m()` and `(this + 1).m()` apply an extension to
      // something built from the receiver. The replacement would keep the
      // call's own spelling and resolve it in another library, where a private
      // extension is not visible and a same-named public one could be bound.
      // Only the plain receiver is rewritten, so these are refused.
      if (target.isExtensionMember &&
          target.function.positionalParameters.isNotEmpty &&
          target.function.positionalParameters.first.cosmeticName == '#this' &&
          _mentionsReceiver(first, ext.thisVariable)) {
        unsupported.add(
          'calls the extension member `${target.name.text}` on an expression '
          'built from the receiver (a cascade, a null-aware call or a '
          'parenthesised expression), which a replacement does not rewrite',
        );
      }
      return false;
    }
    final own = ext.members[target];
    final isTearOff = ext.tearOffs.contains(target);
    if (own == null &&
        !isTearOff &&
        !target.isExtensionMember &&
        !target.isExtensionTypeMember) {
      return false;
    }
    consumedVariables.add(first);
    final name = own?.name.text ?? target.name.text;
    if (isTearOff) {
      unsupported.add('tears off the extension method of `${ext.name}`');
    } else if (own == null) {
      unsupported.add(
        'applies the extension `${target.name.text.split('|').first}` to the '
        'receiver, which the replacement library cannot be shown to resolve '
        'the same way',
      );
    } else if (name.startsWith('_')) {
      unsupported.add(
        'calls the private member `$name` of the extension `${ext.name}`',
      );
    } else if (own.kind == ExtensionMemberKind.Getter) {
      accesses.add(_Access(node.fileOffset, name, 'extensionGet'));
    } else if (own.kind == ExtensionMemberKind.Method) {
      accesses.add(_Access(node.fileOffset, name, 'extensionInvoke'));
    } else {
      unsupported.add(
        'uses the extension ${own.kind.name.toLowerCase()} `$name` on the '
        'receiver',
      );
    }
    for (final a in node.arguments.positional.skip(1)) {
      a.accept(this);
    }
    for (final a in node.arguments.named) {
      a.accept(this);
    }
    return true;
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    if (_extensionCall(node)) return;
    // Factory constructors are StaticInvocations whose target is a factory
    // Procedure; they construct just as surely as a generative constructor.
    final target = node.target;
    if (target.isFactory) {
      _recordPrivateConstruction(target, node.fileOffset);
    }
    node.visitChildren(this);
  }

  /// Keyed as the MANIFEST keys it -- `library#Class.constructor`, with the
  /// unnamed constructor spelled `new`, which is what
  /// gen_dynamic_interface emits under `constructionWithheld` and
  /// `privateClassesConstructible`. The two must agree exactly or every lookup
  /// misses.
  void _recordPrivateConstruction(Member target, int offset) {
    final cls = target.enclosingClass;
    if (cls == null) return;
    // Private to its LIBRARY, which is what `_` means in Dart and what the
    // manifest enumerates. A public class needs no grant.
    if (!cls.name.startsWith('_')) return;
    final ctor = target.name.text.isEmpty ? 'new' : target.name.text;
    privateConstructions.add(
      _PrivateConstruction(
        offset,
        cls.enclosingLibrary.importUri.toString(),
        cls.name,
        ctor,
      ),
    );
  }

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    // REPORTED, not refused. The producer decides admission from the SOURCE and
    // the replacement compiler re-establishes the target and the shape in its
    // own kernel; this tool's job is to say that a genuine super operation is
    // here and where it is.
    //
    // The offset is the site's own, measured to be identical in the AOT and
    // import kernels (`super0/s2b0/`), which is what makes it usable as the key
    // the other two stages read from.
    superInvocations.add(_SuperSite(node.fileOffset, node.name.text, 'method'));
    node.visitChildren(this);
  }

  @override
  void visitThisExpression(ThisExpression node) {
    // ONE CONSTRUCT, ONE REPORT. The CFE puts a synthesized `this` inside every
    // `super` node -- proven on a probe whose source contains no `this` at all
    // (`super0/`) -- so before version 10 a single `super.dispose()` produced
    // TWO refusals: the super one, and this one. That double-reporting is what
    // made `super` look like it had 0% marginal unlock in the first D0.2
    // reading while inflating the `this` category with 43 methods that were
    // really super calls.
    //
    // It is the super operation's own receiver, and the super handling above has
    // already accounted for it.
    final parent = node.parent;
    if (parent is SuperMethodInvocation ||
        parent is SuperPropertyGet ||
        parent is SuperPropertySet) {
      return;
    }
    // A `this` that is not the receiver of a supported access -- passed as an
    // argument, captured by a closure, stored. Each is its own question.
    if (!consumed.contains(node)) {
      unsupported.add('uses `this` other than to read a member');
    }
  }
}

/// Finds a read of [receiver], following `let` variables to what they hold.
class _ReceiverFinder extends RecursiveVisitor {
  _ReceiverFinder(this.receiver);

  final Variable receiver;
  bool found = false;

  @override
  void visitVariableGet(VariableGet node) {
    if (identical(node.variable, receiver)) {
      found = true;
    } else if (node.variable.initializer case final Expression init) {
      init.accept(this);
    }
  }
}
