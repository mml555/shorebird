// Route B (selfhost): reading the coverage analysis, and deciding what to say.
//
// The analysis itself is NOT here and cannot be. It has to read a dill, which
// needs `package:kernel`, which is unobtainable outside an engine checkout: the
// copy on pub.dev is the abandoned pre-null-safety publication, and the vended
// Flutter SDK ships no `pkg/` at all. It also has to read a dill emitted by the
// RELEASE's frontend, and the kernel binary format is versioned — so the
// analyzer belongs to the release's toolchain for the same reason dart2bytecode
// does, and travels in the same cell.
//
// What lives here is everything downstream of that: parsing the analyzer's
// output, and turning a verdict into something a person can act on. That is a
// small surface and a dangerous one — mapping `conditional` to "representable",
// or losing which target was rejected, would be indistinguishable from the
// analyzer being wrong. `selfhost/engine/route_b/coverage/parity.sh` runs the
// untouched host tools, this analyzer, and this parser over one corpus and
// fails on any field that differs.
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:scoped_deps/scoped_deps.dart';

import 'package:shorebird_cli/src/route_b_compiler.dart';

/// A reference to a [RouteBCoverageAnalyzer] instance.
final routeBCoverageAnalyzerRef = create(RouteBCoverageAnalyzer.new);

/// The [RouteBCoverageAnalyzer] available in the current zone.
RouteBCoverageAnalyzer get routeBCoverageAnalyzer =>
    read(routeBCoverageAnalyzerRef);

/// The analyzer contract this build understands.
///
/// Refused rather than best-effort parsed: a cell is resolved by the release's
/// engine hash, so an unknown version means the CLI and the release's toolchain
/// disagree about the format, and reading fields that may have moved is how you
/// get a confident wrong answer.
///
/// 7 added `private` to a receiver access: version 6 refused a private member
/// outright, and 7 reports it with the manifest key the release must have
/// granted. Reading a 7 document as a 6 would see the access with no
/// `unsupported` reason and lower it unconditionally, which is the silent
/// accept this gate exists for.
///
/// 10 reports a genuine `super.member()` as a `superInvocations` entry instead
/// of the `unsupported` reason version 9 emitted. That is the same shape of
/// hazard in the other direction: a version-9 consumer reading a version-10
/// document would find a lowering with NO `unsupported` reason and conclude the
/// body is fully lowerable. So this build refuses a version it does not know,
/// and — until the producer can emit a direct-super replacement — refuses any
/// reported super site too. See [RouteBLowering.superInvocations].
///
/// 11 adds the resolved `target` of a super site and the
/// `releaseSuperTargets` the RELEASE version of the same method already
/// direct-called, both as SOURCE PROVENANCE tuples. A version-10 consumer
/// would read a v11 document, see the super sites it already understands,
/// and admit one with no release evidence behind it — a patch that aborts
/// inside the app rather than one that refuses.
const supportedRouteBAnalysisVersion = 11;

/// Every analyzer version this build can decode, and nothing else.
///
/// A RANGE would be wrong. Versions are not ordered capabilities: 10 removed a
/// refusal string that 9 emitted, and a decoder that accepted "anything >= 11"
/// would read a future document whose meaning it has never seen. Membership of
/// this set is a statement that a decode path EXISTS below, and unknown stays
/// REFUSED.
///
/// Each version's absent fields keep their own meaning; see
/// [RouteBLowering.privateConstructions] for the asymmetry that matters.
const knownRouteBAnalysisVersions = {
  11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, //
};

/// The first analyzer version that compares fields, `const`s, constructors and
/// class headers. An older analyzer reads an edit to one as unchanged, so a
/// patch carrying it alongside body edits ships without it.
const routeBDeclarationsAnalysisVersion = 14;

/// The first analyzer version that takes `--carry` and reports `callers`.
const routeBCarryAnalysisVersion = 15;

/// The first analyzer version that accepts an added top-level function as a
/// helper and reports `helpers`. An older analyzer lists every new member as a
/// rejection, and this build keeps refusing them for such a cell.
const routeBHelpersAnalysisVersion = 16;

/// The first analyzer version that also accepts a new INSTANCE METHOD of an
/// existing class as a helper, with its own `lowering` and `helperCall`
/// accesses. A version-16 document never lists one: its analyzer refuses them.
const routeBInstanceHelpersAnalysisVersion = 17;

/// The first analyzer version that reports the external symbols each carried
/// body names (`externalReferences`), which is what the retention check reads.
/// A version-17 document has no such list, so a patch analyzed by it cannot be
/// checked and is accepted as it always was; see `RouteBRetention`.
const routeBRetentionAnalysisVersion = 18;

/// The first analyzer version that reports what a body asks for BY NAME with no
/// declared target: a call, get or set on a `dynamic` receiver (kind
/// `dynamic`, the selector as `member`), an instance tear-off (member
/// `tearoff:<name>`), extension and extension-type members (`Ext|get#x`), the
/// `iterator`/`moveNext`/`current` calls of a `for-in`, and a use that is both
/// direct and through a constant as two entries. A document below it cannot
/// show any of those, so the patcher refuses it unless the developer opts out
/// (`--allow-unchecked-sdk-calls`).
const routeBSelectorCallsAnalysisVersion = 19;

/// The first analyzer version that marks an `instance` reference `inlined`:
/// every site of that member in the body is an opcode the patch's bytecode
/// compiler emits (`AddInt`, `CompareIntLt`, ...), decided by dart2bytecode's
/// own `RecognizedMethods`, so the member is never looked up when it runs. A
/// document below it never has the field, and one that carries it anyway is
/// not believed.
///
/// 21, not 20: version 20 predicted the flag from the patched kernel, where an
/// override's omitted parameter type is the inherited one, while the producer
/// lowers the member to a function that overrides nothing. Version 21 reports
/// the inferred signature so the producer can write it in (`signatureTypes`).
const routeBInlinedOpsAnalysisVersion = 21;

/// The first analyzer version that reports a `lowering` for an INSTANCE member
/// of a named, non-generic extension (a getter or a method), carrying
/// `extension`. Below it the analyzer's scope report refuses every such member,
/// so a release built with an older cell keeps refusing them.
const routeBExtensionReceiverAnalysisVersion = 22;

/// The first analyzer version that names the receiver class of a `for-in`
/// (`receiverLibrary`, `receiverClass` on its `Iterable.get:iterator`
/// reference): the class of the loop iterable's static type. The per-release
/// check then asks only the release's subtypes of that class for `iterator`,
/// not every `Iterable` it holds. A document below it never has the fields,
/// and one that carries them anyway is not believed.
const routeBForInReceiverAnalysisVersion = 23;

/// The first analyzer version that reports an `await` as a call of
/// `Future.then` (on `dart:async` `Future`, with `receiverClass` when the
/// operand's static type is a `Future` subtype). The VM awaits a `_Future`
/// without `then`, but calls the `then` of any other `Future` by selector, so
/// `await controller.forward()` needs the release to have compiled
/// `TickerFuture.then`. A document below it cannot show any `await`, so a
/// release whose snapshot allocates a `Future` subtype with no compiled `then`
/// refuses its patches unless the developer opts out; see
/// `RouteBRetention.awaitUnchecked`.
const routeBAwaitAnalysisVersion = 24;

/// The first analyzer version that marks an `await` (or `return`) of a
/// provable `_Future` (a call of a statically resolved `async` function, or
/// `Future.value`, or `Future.delayed` with no computation): its
/// `Future.then` entry carries `receiverLibrary` `dart:async` and
/// `receiverClass` `_Future`. The VM chains a `_Future` without calling
/// `then`, so the kept check lets that entry through. A document below it
/// never has the marking, and one that carries it anyway is not believed.
const routeBProvableFutureAnalysisVersion = 25;

/// A construction of a private class inside a replaced body.
///
/// [key] is spelled exactly as the release's capability manifest spells it —
/// `library#Class.constructor`, with the unnamed constructor as `new` — so a
/// grant can be looked up without re-deriving the format.
class RouteBPrivateConstruction {
  /// Creates a [RouteBPrivateConstruction].
  const RouteBPrivateConstruction({
    required this.offset,
    required this.library,
    required this.className,
    required this.constructor,
    required this.key,
  });

  /// Where the construction appears, in code units of the decoded source.
  final int offset;

  /// Import URI of the library declaring the class.
  final String library;

  /// The private class being constructed.
  final String className;

  /// The constructor named, `new` when unnamed.
  final String constructor;

  /// The manifest key the release would have had to grant.
  final String key;
}

/// What a patch may do with a changed member.
enum RouteBRepresentability {
  /// Static-shaped call. Emitted as the patchable form.
  representable,

  /// Instance member. Reachable only where the call site devirtualizes.
  ///
  /// **Not a verdict.** Whether a given site devirtualizes or becomes a
  /// dispatch-table call is decided per-site by the precompiler and is not
  /// visible in the kernel, so this is an honest "cannot tell from here" rather
  /// than a quiet yes. See [RouteBCoverage.conditional].
  conditional,

  /// The release cannot reach it at all.
  unreachable,

  /// Not in the release's manifest. Unknown reachability is not reachability.
  unknown,

  /// New in the patch and not carried. A patch replaces bodies; from
  /// analysis version 16 it may also add a top-level function that only the
  /// patch calls (a helper), and every other new member lands here, with a
  /// reason naming why.
  added,

  /// A changed or new field, `const` or constructor (analysis version 14).
  ///
  /// A patch replaces method bodies. A field's initial value and a
  /// constructor come from the release, and a patch is compiled against the
  /// release's declarations, so it would read an edited `const`'s old value.
  /// Shipping the rest of the patch would leave the edit out without a word.
  declaration,
}

/// A changed member's signature, on both sides.
///
/// P4.4. `changed` is the load-bearing bit, and it is NOT the same question as
/// "did this member change" -- every patched member changed, that is the point.
/// This asks whether the SHAPE changed, because the release's compiled call
/// sites carry the release's own ArgumentsDescriptor: attaching a replacement
/// with a different arity gives those call sites a function they cannot call
/// correctly, and nothing after publication can notice.
class RouteBSignatureChange {
  /// {@macro route_b_signature_change}
  const RouteBSignatureChange({
    required this.release,
    required this.patch,
    required this.changed,
  });

  /// The signature identity in the RELEASE.
  final String release;

  /// The signature identity in the patch.
  final String patch;

  /// Whether the two differ. Reported by the analyzer rather than re-derived
  /// here: the strings are the analyzer's own normal form, and comparing them
  /// in two places would eventually mean comparing them two ways.
  final bool changed;
}

/// One member the patch cannot carry, and why.
///
/// The reason is carried verbatim from the analyzer rather than re-derived
/// here. `Foo.bar -> unsupported dispatch-table call` and
/// `Foo.bar -> target unreachable` both reject, and they are not
/// interchangeable: one points at compiler coverage, the other at retention.
class RouteBRejection {
  /// {@macro route_b_rejection}
  const RouteBRejection({
    required this.target,
    required this.category,
    required this.reason,
  });

  /// `library#selector`, the same identity the container packs by.
  final String target;

  /// Which rule rejected it.
  final RouteBRepresentability category;

  /// The analyzer's own wording.
  final String reason;
}

/// Where a changed member's new body lives in the patch's own source.
///
/// A span rather than text: the analyzer has the kernel's offsets, the producer
/// has the file, and neither needs an opinion about how a replacement library
/// is assembled.
class RouteBSourceSpan {
  /// {@macro route_b_source_span}
  const RouteBSourceSpan({
    required this.fileUri,
    required this.start,
    required this.end,
  });

  /// The file the frontend read, as a URI.
  final String fileUri;

  /// Byte offset of the declaration, annotations included.
  final int start;

  /// Byte offset just past its closing token.
  final int end;
}

/// What the release would have had to retain for a private access to bind.
///
/// The key is the analyzer's, resolved from the interface target: a private
/// member may be DECLARED on a superclass in the same library, and the release
/// manifest keys it under the class that declares it.
class RouteBPrivateTarget {
  /// {@macro route_b_private_target}
  const RouteBPrivateTarget({
    required this.library,
    required this.className,
    required this.name,
  });

  /// Import URI of the library declaring the member.
  final String library;

  /// The class declaring it.
  final String className;

  /// Its VM-shaped name: bare for a field, `get:`/`set:`-prefixed for an
  /// accessor, matching what `LibraryIndex` keys and what the manifest holds.
  final String name;
}

/// One receiver-based access the producer must rewrite.
class RouteBReceiverAccess {
  /// {@macro route_b_receiver_access}
  const RouteBReceiverAccess({
    required this.offset,
    required this.member,
    required this.kind,
    this.privateTarget,
  });

  /// Where the member's IDENTIFIER starts, in code units of the decoded
  /// source. `label` and `this.label` are the same Kernel node and report the
  /// same offset, so only the source text distinguishes them.
  final int offset;

  /// The member being read or called.
  final String member;

  /// `get` for `label`, `set` for `label = x`, `invoke` for `helper()` with or
  /// without arguments, `helperCall` for a call to a NEW instance method the
  /// patch carries (version 17), which takes the receiver as its first
  /// argument instead of being prefixed by it. The
  /// argument list is copied verbatim and never interpreted, so its shape is
  /// not part of what the lowering has to understand. The surface
  /// widens one form at a time, and the producer refuses a kind it does not
  /// know rather than assuming its lexical edit happens to suit.
  final String kind;

  /// Non-null when [member] is private, naming the capability the release must
  /// have granted. The analyzer reports it; the decision is the CLI's, because
  /// the capability manifest is a per-release artifact and the analyzer ships
  /// in the compiler cell.
  final RouteBPrivateTarget? privateTarget;
}

/// One use of a static of the member's own class that is written without a
/// qualifier, as the analyzer placed it.
@immutable
class RouteBStaticReference {
  /// {@macro route_b_static_reference}
  const RouteBStaticReference({
    required this.offset,
    required this.member,
    required this.kind,
    this.interpolated = false,
  });

  /// Where the identifier starts, in code units of the decoded source.
  final int offset;

  /// The static's name.
  final String member;

  /// `get`, `set`, `invoke`, `tearoff`, or `constant`.
  final String kind;

  /// Whether it is the `$name` form of a string interpolation.
  final bool interpolated;
}

/// What a class or extension member's body takes from its enclosing scope (the
/// document's `enclosingScope`), which a replacement library does not have.
///
/// A replacement is a top-level function. An unqualified `k` that meant the
/// class's `static k` is looked up among top-level names there, so a same-named
/// top-level wins silently. Kernel knows what each name resolved to and the
/// front end's token stream knows whether a qualifier is written; the analyzer
/// reports only the uses that need one.
@immutable
class RouteBEnclosingScope {
  /// {@macro route_b_enclosing_scope}
  const RouteBEnclosingScope({
    required this.className,
    required this.staticReferences,
    required this.usedTypeParameters,
    required this.problems,
    this.extensionInstance = false,
  });

  /// Parses one entry of `enclosingScope`.
  factory RouteBEnclosingScope.fromJson(Map<String, dynamic> json) {
    final className = json['class'];
    if (className is! String) {
      throw const FormatException('an enclosing scope names no class');
    }
    List<String> names(String field) => [
      for (final n in json[field] as List? ?? const []) n as String,
    ];
    return RouteBEnclosingScope(
      className: className,
      staticReferences: [
        for (final r in json['staticReferences'] as List? ?? const [])
          RouteBStaticReference(
            offset: (r as Map<String, dynamic>)['offset'] as int,
            member: r['member'] as String,
            kind: r['kind'] as String,
            interpolated: r['interpolated'] == true,
          ),
      ],
      usedTypeParameters: names('usedTypeParameters'),
      problems: names('problems'),
      extensionInstance: json['extensionInstance'] == true,
    );
  }

  /// The enclosing class or extension, which qualifies a static.
  final String className;

  /// Every use of one of its statics that needs a qualifier.
  final List<RouteBStaticReference> staticReferences;

  /// Class type parameters the body mentions.
  final List<String> usedTypeParameters;

  /// Reasons the member cannot be carried; non-empty means refuse.
  final List<String> problems;

  /// Whether the member is an INSTANCE member of an extension (analysis 22),
  /// which takes its receiver first and so cannot be carried without a
  /// `lowering`.
  final bool extensionInstance;
}

/// What Kernel knows about turning an instance method into a static
/// replacement that takes its receiver as argument 0.
///
/// Kernel decides MEANING — which accesses are receiver-based, what they
/// resolve to, where their identifier starts. The producer supplies SYNTAX.
/// Neither re-derives the other's job.
class RouteBLowering {
  /// {@macro route_b_lowering}
  const RouteBLowering({
    required this.receiverType,
    required this.nameOffset,
    required this.accesses,
    required this.unsupported,
    this.origin,
    this.extensionName,
    this.superInvocations = const [],
    this.signatureTypes,
    this.releaseSuperTargets,
    this.privateConstructions,
    this.releasePrivateConstructions,
  });

  /// The type the receiver parameter is written with: the class, or for an
  /// extension member its on-type (`int`, `List<String>?`).
  final String receiverType;

  /// The extension this member is an instance member of (analysis version 22),
  /// or null for a class member. The producer writes `Name(self).sibling` for a
  /// call of a sibling member and qualifies the extension's statics with it.
  final String? extensionName;

  /// Offset of the method's NAME. The producer scans forward from here for the
  /// parameter list, because an annotation like `@pragma('vm:never-inline')`
  /// has parentheses of its own.
  final int nameOffset;

  /// Every receiver access to rewrite.
  final List<RouteBReceiverAccess> accesses;

  /// Reasons this body is outside the supported surface. Non-empty means
  /// refuse by name rather than lower on a guess.
  final List<String> unsupported;

  /// The INFERRED type of each positional parameter and of the return, as
  /// source the replacement can write (analysis version 21), or null for a
  /// document that predates it.
  ///
  /// The lowered form is a top-level function, which overrides nothing, so a
  /// parameter or return type the source left out (Dart takes it from the
  /// overridden member) would become `dynamic`. The producer writes these in
  /// where the source omitted a type. A null ELEMENT is a type the replacement
  /// library cannot name; the producer refuses a target that would need it.
  final RouteBSignatureTypes? signatureTypes;

  /// Where this method lives, in SOURCE terms (analysis version 10).
  ///
  /// What a replacement compiler needs to find the method again in its own
  /// kernel. Null for a document that did not carry one.
  final RouteBOrigin? origin;

  /// Every super target the RELEASE version of this same method already
  /// direct-called (analysis version 11).
  ///
  /// The narrow-v1 admission rule: a patched super site is carried only when
  /// its target's provenance is in this set. The causal argument is that the
  /// release
  /// version of THIS compiled method direct-called the target, so AOT had to
  /// emit code for it — and a `DirectCall` to a target with no code aborts the
  /// app rather than failing to bind (`super0/s2b1e/`).
  ///
  /// SAME METHOD, never program-wide: evidence from an unrelated release method
  /// would not support that chain.
  ///
  /// THREE STATES, and they are not interchangeable:
  ///
  ///   null   the measurement was UNAVAILABLE. The analyzer could not build
  ///          a hierarchy over the release kernel — it is the
  ///          `--no-link-platform` import kernel, whose `dart:core` classes
  ///          carry no AST — so it did not look. Nothing may be concluded
  ///          about what the release called.
  ///   []     the measurement was TAKEN: the release version of this method
  ///          direct-called nothing.
  ///   [...]  the measurement was taken and these targets were observed.
  ///
  /// Collapsing null into `[]` would turn "we did not look" into the positive
  /// claim "the release called nothing". Both refuse a super patch, so the
  /// distinction is not a safety gap — it is the difference between a refusal
  /// that names a missing measurement and one that asserts a measured fact.
  final List<RouteBProvenance>? releaseSuperTargets;

  /// Constructions of a PRIVATE class in this body, or null when the analyzer
  /// did not measure them.
  ///
  /// Null means a version-11 document, which cannot say. It does NOT mean the
  /// body constructs none.
  final List<RouteBPrivateConstruction>? privateConstructions;

  /// The same measurement taken on the RELEASE's version of this same method,
  /// or null when nobody measured it.
  ///
  /// THREE STATES, and a consumer must keep them apart. Null is "unavailable" —
  /// a version-11 or version-12 document, or a version-13 one whose base could
  /// not be examined — and admits nothing. Empty is a MEASUREMENT: the release
  /// version of this method constructed none, so any construction the candidate
  /// performs is newly introduced. Populated is positive evidence, per
  /// constructor.
  ///
  /// A release-wide manifest cannot substitute for this. It contains
  /// `_Private.new` whenever ANY released method constructed it, which says
  /// nothing about whether THIS method did.
  final List<RouteBPrivateConstruction>? releasePrivateConstructions;

  /// Genuine `super.member()` sites in this body (analysis version 10).
  ///
  /// REPORTED, not refused, by the analyzer — because the analyzer's kernel is
  /// not the authority for either the shape or the target. This build cannot
  /// yet produce a direct-super replacement, so a non-empty list is refused;
  /// see `_lower` in `route_b_producer.dart`.
  final List<RouteBSuperInvocation> superInvocations;
}

/// The inferred signature of a lowered member; see
/// [RouteBLowering.signatureTypes].
@immutable
class RouteBSignatureTypes {
  /// {@macro route_b_signature_types}
  const RouteBSignatureTypes({required this.params, required this.returnType});

  /// One entry per positional parameter, in order: the type as source, or null
  /// when it cannot be written in the replacement library.
  final List<String?> params;

  /// The return type as source, or null when it cannot be written.
  final String? returnType;
}

/// A method's source-level identity (analysis version 10).
///
/// `memberKind` travels with the name because a class may hold a method, a
/// getter and a setter of one name, so name plus class is not an identity.
class RouteBOrigin {
  /// {@macro route_b_origin}
  const RouteBOrigin({
    required this.library,
    required this.className,
    required this.member,
    required this.memberKind,
  });

  /// Library URI as the release's kernel names it.
  final String library;

  /// Declaring class.
  final String className;

  /// Member name.
  final String member;

  /// `method`, `getter`, `setter`, `operator`, `factory`.
  final String memberKind;
}

/// One `super.member()` site.
///
/// Carries no declaring class and no argument count: AOT mixin deduplication
/// renames the target's owner, and TFA can rewrite `super.tag('a', 7)` to zero
/// arguments in the analyzer's own kernel. The resolved [target] IS carried, as
/// provenance only — the narrow tuple 2A.2 measured as portable.
@immutable
class RouteBSuperInvocation {
  /// {@macro route_b_super_invocation}
  const RouteBSuperInvocation({
    required this.offset,
    required this.member,
    required this.kind,
    this.target,
  });

  /// Source offset of the member name at the call site.
  final int offset;

  /// The member `super.` names.
  final String member;

  /// Always `method` at version 10; getters and setters stay `unsupported`.
  final String kind;

  /// The resolved super target, as provenance (analysis version 11).
  ///
  /// Null when nothing resolved, which is a refusal rather than an absence.
  final RouteBProvenance? target;
}

/// A member's SOURCE PROVENANCE — the only identity that survives both AOT
/// mixin deduplication and the AOT/no-AOT boundary.
///
/// Carries no enclosing class on purpose: that is exactly the part AOT renames.
@immutable
class RouteBProvenance {
  /// {@macro route_b_provenance}
  const RouteBProvenance({
    required this.fileUri,
    required this.fileOffset,
    required this.name,
    required this.kind,
  });

  /// Where the declaration was written.
  final String fileUri;

  /// Its offset in that file.
  final int fileOffset;

  /// Its name.
  final String name;

  /// `Method`, `Getter`, `Setter`, … — Kernel's `ProcedureKind.name`.
  final String kind;

  /// Value equality: this is compared, not identified.
  @override
  bool operator ==(Object other) =>
      other is RouteBProvenance &&
      other.fileUri == fileUri &&
      other.fileOffset == fileOffset &&
      other.name == name &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(fileUri, fileOffset, name, kind);

  @override
  String toString() => '$fileUri|$fileOffset|$name|$kind';
}

/// Reads a provenance tuple, or null.
RouteBProvenance? _provenance(Object? value) => switch (value) {
  final Map<String, dynamic> m => RouteBProvenance(
    fileUri: m['fileUri']! as String,
    fileOffset: m['fileOffset']! as int,
    name: m['name']! as String,
    kind: m['kind']! as String,
  ),
  _ => null,
};

/// One symbol a carried body names that the release's loader must find by
/// name (analysis version 18).
///
/// A FACT, not a verdict: whether the release kept it is decided against the
/// release's own interface and manifest, in `RouteBRetention`.
@immutable
class RouteBExternalReference {
  /// {@macro route_b_external_reference}
  const RouteBExternalReference({
    required this.kind,
    this.library = '',
    this.className,
    this.member,
    this.isPrivate = false,
    this.viaConstant = false,
    this.inlined,
    this.receiverLibrary,
    this.receiverClass,
    this.reason,
  });

  /// Parses one entry of `externalReferences`.
  ///
  /// [readInlined] is true only for a document of analysis
  /// [routeBInlinedOpsAnalysisVersion] or later: an `inlined` field on an
  /// older one is ignored, so only an analyzer that computes it can say it.
  /// [readReceiver] is the same for [receiverClass] on a `for-in`, from
  /// [routeBForInReceiverAnalysisVersion], and [readFutureReceiver] for the
  /// `_Future` receiver of an `await`, from
  /// [routeBProvableFutureAnalysisVersion].
  factory RouteBExternalReference.fromJson(
    Map<String, dynamic> json, {
    bool readInlined = false,
    bool readReceiver = false,
    bool readFutureReceiver = false,
  }) {
    final kind = json['kind'];
    if (kind is! String || !_kinds.contains(kind)) {
      throw FormatException('an external reference has the unknown kind $kind');
    }
    if (kind == 'unanalyzed') {
      return RouteBExternalReference(
        kind: kind,
        reason: json['reason'] as String? ?? 'the body could not be walked',
      );
    }
    final library = json['library'];
    if (library is! String) {
      throw const FormatException('an external reference names no library');
    }
    final receiver = _knownReceiver(
      json,
      forIn: readReceiver,
      future: readFutureReceiver,
    );
    return RouteBExternalReference(
      kind: kind,
      library: library,
      className: json['class'] as String?,
      member: json['member'] as String?,
      isPrivate: json['private'] == true,
      viaConstant: json['viaConstant'] == true,
      inlined: readInlined
          ? _knownInlined(
              library: library,
              className: json['class'],
              member: json['member'],
              inlined: json['inlined'],
            )
          : null,
      receiverLibrary: receiver?.$1,
      receiverClass: receiver?.$2,
    );
  }

  /// The receiver class a document names, or null. Two references carry one:
  /// a `for-in`'s `Iterable.get:iterator` ([forIn], any class), and an
  /// `await` of a provable `_Future` ([future], `Future.then` on exactly
  /// `dart:async` `_Future`). A receiver on any other reference, or any other
  /// receiver on `Future.then`, is not believed: it would narrow the check
  /// for a member the analyzer never narrowed.
  static (String, String)? _knownReceiver(
    Map<String, dynamic> json, {
    required bool forIn,
    required bool future,
  }) {
    final library = json['receiverLibrary'];
    final cls = json['receiverClass'];
    if (library is! String || cls is! String) return null;
    if (library.isEmpty || cls.isEmpty) return null;
    if (json['kind'] != 'instance') return null;
    if (forIn &&
        json['library'] == 'dart:core' &&
        json['class'] == 'Iterable' &&
        json['member'] == 'get:iterator') {
      return (library, cls);
    }
    if (future &&
        json['library'] == 'dart:async' &&
        json['class'] == 'Future' &&
        json['member'] == 'then' &&
        library == 'dart:async' &&
        cls == '_Future') {
      return (library, cls);
    }
    return null;
  }

  /// The opcodes the bytecode compiler can emit for an operator, by selector
  /// (`RecognizedMethods.binaryIntOps`, `binaryDoubleOps` and the unary
  /// negations in dart2bytecode, `==` excluded: `a == b` is never a call the
  /// compiler specializes). A document's `inlined` is believed only when it
  /// names an operator of `int`, `double` or `num` with opcodes that operator
  /// can have, so a buggy or edited document cannot waive the check for any
  /// other member.
  static const inlinedOpcodes = <String, Set<String>>{
    '+': {'AddInt', 'AddDouble'},
    '-': {'SubInt', 'SubDouble'},
    '*': {'MulInt', 'MulDouble'},
    '~/': {'TruncDivInt'},
    '%': {'ModInt'},
    '/': {'DivDouble'},
    '&': {'BitAndInt'},
    '|': {'BitOrInt'},
    '^': {'BitXorInt'},
    '<<': {'ShlInt'},
    '>>': {'ShrInt'},
    '>': {'CompareIntGt', 'CompareDoubleGt'},
    '<': {'CompareIntLt', 'CompareDoubleLt'},
    '>=': {'CompareIntGe', 'CompareDoubleGe'},
    '<=': {'CompareIntLe', 'CompareDoubleLe'},
    'unary-': {'NegateInt', 'NegateDouble'},
  };

  static String? _knownInlined({
    required String library,
    required Object? className,
    required Object? member,
    required Object? inlined,
  }) {
    if (inlined is! String || member is! String) return null;
    if (library != 'dart:core' ||
        !const {'int', 'double', 'num'}.contains(className)) {
      return null;
    }
    final allowed = inlinedOpcodes[member];
    if (allowed == null) return null;
    final parts = inlined.split('|');
    return parts.every(allowed.contains) ? inlined : null;
  }

  static const _kinds = {
    'class',
    'top-level',
    'static',
    'constructor',
    'instance',
    'dynamic',
    'unanalyzed',
  };

  /// `class` (named as a type), `top-level`, `static`, `constructor`,
  /// `instance`, `dynamic` (a call by name on a `dynamic` receiver; [member]
  /// is the selector), or `unanalyzed` (the analyzer could not walk the body).
  final String kind;

  /// The library URI, as the release's kernel names it.
  final String library;

  /// The declaring class, or null for a top-level member.
  final String? className;

  /// The VM's name for the member (`get:`/`set:` for an accessor, empty for an
  /// unnamed constructor), or null for a class.
  final String? member;

  /// Whether the member, or the class holding it, is private.
  final bool isPrivate;

  /// Whether a constant names it, which the release's interface retained even
  /// for an instance member of `dart:`.
  final bool viaConstant;

  /// The opcode(s), joined by `|`, the bytecode compiler emits for EVERY site
  /// of this member in the body (analysis 20 and later), so none is looked up
  /// at run time; null when any site is a call, the analysis predates the
  /// field, or the document names something that is not an operator opcode
  /// (see [inlinedOpcodes]).
  final String? inlined;

  /// The library of [receiverClass] (analysis 23 and later).
  final String? receiverLibrary;

  /// For a `for-in`'s `Iterable.get:iterator`, the class of the loop
  /// iterable's static type (analysis 23 and later): the runtime receiver is
  /// an instance of one of its subtypes. Null when the analysis predates the
  /// field or could not name one (a `dynamic` iterable, a type parameter), in
  /// which case the receiver is any `Iterable`.
  final String? receiverClass;

  /// Why the body could not be walked, for `unanalyzed`.
  final String? reason;

  /// `Class.member` or `member` or `Class`, as a developer would write it.
  String get displayName {
    final c = className;
    final m = member;
    if (m == null) return c ?? library;
    final bare = m.replaceFirst(RegExp('^(get|set):'), '');
    final name = bare.isEmpty ? (c ?? library) : bare;
    return c == null || bare.isEmpty ? name : '$c.$name';
  }
}

/// The whole-patch outcome.
enum RouteBVerdict {
  /// Every changed member can be carried.
  accept,

  /// At least one cannot, so none of them ship.
  reject,

  /// Nothing changed. A patch would install and do nothing.
  inert,
}

/// The analyzer's output, parsed.
class RouteBCoverage {
  /// {@macro route_b_coverage}
  const RouteBCoverage({
    required this.analysisVersion,
    required this.verdict,
    required this.changed,
    required this.added,
    required this.removed,
    required this.representable,
    required this.conditional,
    required this.rejections,
    required this.refusalSummary,
    this.signatures = const {},
    this.sources = const {},
    this.lowering = const {},
    this.carried = const [],
    this.callers,
    this.canCarry = false,
    this.helpers = const [],
    this.unusedHelpers = const [],
    this.externalReferences,
    this.enclosingScope,
  });

  /// Parses the analyzer's JSON document.
  ///
  /// Throws [FormatException] on anything it does not fully understand.
  factory RouteBCoverage.fromJson(String contents) {
    final Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } on FormatException catch (error) {
      throw FormatException(
        'the coverage analyzer did not emit JSON: ${error.message}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'the coverage analyzer did not emit a JSON object',
      );
    }

    final version = decoded['analysisVersion'];
    if (!knownRouteBAnalysisVersions.contains(version)) {
      throw FormatException(
        'the coverage analyzer speaks version $version, and this build of '
        'Shorebird understands '
        '${(knownRouteBAnalysisVersions.toList()..sort()).join(', ')}',
      );
    }
    final analysisVersion = version! as int;

    final map = decoded;
    List<String> strings(String key) {
      final value = map[key];
      if (value is! List) {
        throw FormatException('the analysis is missing "$key"');
      }
      return value.cast<String>();
    }

    final verdict = switch (map['verdict']) {
      'accept' => RouteBVerdict.accept,
      'reject' => RouteBVerdict.reject,
      'inert' => RouteBVerdict.inert,
      final Object? other => throw FormatException(
        'the analysis carries an unknown verdict "$other"',
      ),
    };

    final signatures = <String, RouteBSignatureChange>{};
    if (map['signatures'] case final Map<String, Object?> raw) {
      for (final entry in raw.entries) {
        if (entry.value case final Map<String, Object?> sig) {
          final release = sig['release'];
          final patch = sig['patch'];
          if (release is! String || patch is! String) continue;
          signatures[entry.key] = RouteBSignatureChange(
            release: release,
            patch: patch,
            // Absent means the analyzer did not say, which is not "unchanged".
            changed: sig['changed'] as bool? ?? release != patch,
          );
        }
      }
    }

    final rejections = <RouteBRejection>[];
    for (final entry in (map['rejections'] as List<Object?>? ?? const [])) {
      final rejection = entry! as Map<String, dynamic>;
      rejections.add(
        RouteBRejection(
          target: rejection['target']! as String,
          category: switch (rejection['category']) {
            'unreachable' => RouteBRepresentability.unreachable,
            'unknown' => RouteBRepresentability.unknown,
            'added' => RouteBRepresentability.added,
            'declaration' => RouteBRepresentability.declaration,
            final Object? other => throw FormatException(
              'the analysis carries an unknown rejection category "$other"',
            ),
          },
          reason: rejection['reason']! as String,
        ),
      );
    }

    // A reject with nothing to point at is a contract violation, not a patch
    // failure. Refusing with "something was wrong" is the failure mode the
    // whole reason-carrying design exists to avoid.
    if (verdict == RouteBVerdict.reject && rejections.isEmpty) {
      throw const FormatException(
        'the analysis rejects the patch but names no target',
      );
    }

    final sources = <String, RouteBSourceSpan>{};
    if (map['sources'] case final Map<String, dynamic> recorded) {
      for (final entry in recorded.entries) {
        final span = entry.value as Map<String, dynamic>;
        sources[entry.key] = RouteBSourceSpan(
          fileUri: span['fileUri']! as String,
          start: span['start']! as int,
          end: span['end']! as int,
        );
      }
    }

    final lowering = <String, RouteBLowering>{};
    if (map['lowering'] case final Map<String, dynamic> recorded) {
      for (final entry in recorded.entries) {
        final l = entry.value as Map<String, dynamic>;
        lowering[entry.key] = RouteBLowering(
          receiverType: l['receiverType']! as String,
          nameOffset: l['nameOffset']! as int,
          accesses: [
            for (final a in (l['accesses'] as List<Object?>? ?? const []))
              RouteBReceiverAccess(
                offset: (a! as Map<String, dynamic>)['offset']! as int,
                member: (a as Map<String, dynamic>)['member']! as String,
                kind: a['kind']! as String,
                privateTarget: switch (a['private']) {
                  final Map<String, dynamic> t => RouteBPrivateTarget(
                    library: t['library']! as String,
                    className: t['class']! as String,
                    name: t['name']! as String,
                  ),
                  _ => null,
                },
              ),
          ],
          unsupported: [
            for (final u in (l['unsupported'] as List<Object?>? ?? const []))
              u! as String,
          ],
          extensionName: switch (l['extension']) {
            final String name
                when analysisVersion >=
                    routeBExtensionReceiverAnalysisVersion =>
              name,
            null => null,
            _ => throw const FormatException(
              'a lowering carries an "extension" that this analysis version '
              'does not define',
            ),
          },
          origin: switch (l['origin']) {
            final Map<String, dynamic> o => RouteBOrigin(
              library: o['library']! as String,
              className: o['class']! as String,
              member: o['member']! as String,
              memberKind: o['memberKind']! as String,
            ),
            _ => null,
          },
          signatureTypes: switch (l['signatureTypes']) {
            final Map<String, dynamic> t when t['params'] is List<Object?> =>
              RouteBSignatureTypes(
                params: [
                  for (final v in t['params']! as List<Object?>) v as String?,
                ],
                returnType: t['returnType'] as String?,
              ),
            _ => null,
          },
          superInvocations: [
            for (final v
                in (l['superInvocations'] as List<Object?>? ?? const []))
              if (v case final Map<String, dynamic> site)
                RouteBSuperInvocation(
                  offset: site['offset']! as int,
                  member: site['member']! as String,
                  kind: site['kind']! as String,
                  target: _provenance(site['target']),
                ),
          ],
          // ABSENT is preserved as null. `?? const []` here would erase the
          // analyzer's distinction at the boundary, which is exactly where it
          // has to survive.
          releaseSuperTargets: switch (l['releaseSuperTargets']) {
            final List<Object?> raw => [
              for (final v in raw)
                if (_provenance(v) case final RouteBProvenance p) p,
            ],
            _ => null,
          },
          // ASYMMETRIC BY VERSION, and that is the whole point.
          //
          // A version-11 document does not carry this field and never could, so
          // its absence means UNMEASURED and stays null -- the consumer must
          // then fall back to the conservative source scan. A version-12
          // document always carries it, so an absent field there is a
          // malformed document rather than an empty measurement.
          //
          // Reading a missing v11 field as `[]` would assert that the body
          // constructs no private class, which nobody measured. That is the
          // same absence-versus-empty rule that `releaseSuperTargets` needed.
          privateConstructions: switch (l['privateConstructions']) {
            final List<Object?> raw => [
              for (final c in raw)
                RouteBPrivateConstruction(
                  offset: (c! as Map<String, dynamic>)['offset']! as int,
                  library: (c as Map<String, dynamic>)['library']! as String,
                  className: c['class']! as String,
                  constructor: c['constructor']! as String,
                  key: c['key']! as String,
                ),
            ],
            _ when analysisVersion >= 12 => throw FormatException(
              'the analysis speaks version $analysisVersion but a lowering '
              'carries no "privateConstructions"',
            ),
            _ => null,
          },
          // ABSENT stays null, on every version. A version-13 analyzer omits
          // it when the base could not be examined, and that is a real answer:
          // nothing was measured, so nothing may be admitted on it. Defaulting
          // to `[]` would turn "we did not look" into "the release method
          // constructed none", which is a claim, and the wrong one.
          releasePrivateConstructions:
              switch (l['releasePrivateConstructions']) {
                final List<Object?> raw => [
                  for (final c in raw)
                    RouteBPrivateConstruction(
                      offset: (c! as Map<String, dynamic>)['offset']! as int,
                      library:
                          (c as Map<String, dynamic>)['library']! as String,
                      className: c['class']! as String,
                      constructor: c['constructor']! as String,
                      key: c['key']! as String,
                    ),
                ],
                _ => null,
              },
        );
      }
    }

    Map<String, List<String>>? callers;
    if (analysisVersion >= routeBCarryAnalysisVersion) {
      final raw = map['callers'];
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('the analysis is missing "callers"');
      }
      callers = {
        for (final entry in raw.entries)
          entry.key: (entry.value as List).cast<String>(),
      };
    }

    // VERSION 18. Absent on 17 and earlier, and absent means "not measured",
    // never "references nothing": the two are kept apart by the null.
    Map<String, List<RouteBExternalReference>>? externalReferences;
    if (analysisVersion >= routeBRetentionAnalysisVersion) {
      final raw = map['externalReferences'];
      if (raw is! Map<String, dynamic>) {
        throw const FormatException(
          'the analysis is missing "externalReferences"',
        );
      }
      externalReferences = {
        for (final entry in raw.entries)
          entry.key: [
            for (final r in entry.value as List)
              RouteBExternalReference.fromJson(
                r as Map<String, dynamic>,
                readInlined: analysisVersion >= routeBInlinedOpsAnalysisVersion,
                readReceiver:
                    analysisVersion >= routeBForInReceiverAnalysisVersion,
                readFutureReceiver:
                    analysisVersion >= routeBProvableFutureAnalysisVersion,
              ),
          ],
      };
    }

    // Present when the analyzer reports class scope. Absent means "not
    // measured", never "uses nothing".
    Map<String, RouteBEnclosingScope>? enclosingScope;
    final rawScope = map['enclosingScope'];
    if (rawScope is Map<String, dynamic>) {
      enclosingScope = {
        for (final entry in rawScope.entries)
          entry.key: RouteBEnclosingScope.fromJson(
            entry.value as Map<String, dynamic>,
          ),
      };
    }

    return RouteBCoverage(
      analysisVersion: analysisVersion,
      verdict: verdict,
      canCarry: analysisVersion >= routeBCarryAnalysisVersion,
      carried: analysisVersion >= routeBCarryAnalysisVersion
          ? strings('carried')
          : const [],
      callers: callers,
      sources: sources,
      lowering: lowering,
      signatures: signatures,
      changed: strings('changed'),
      added: strings('added'),
      helpers: analysisVersion >= routeBHelpersAnalysisVersion
          ? strings('helpers')
          : const [],
      unusedHelpers: analysisVersion >= routeBHelpersAnalysisVersion
          ? strings('unusedHelpers')
          : const [],
      externalReferences: externalReferences,
      enclosingScope: enclosingScope,
      removed: strings('removed'),
      representable: strings('patchable'),
      conditional: strings('conditional'),
      rejections: rejections,
      refusalSummary: map['refusalSummary'] as String?,
    );
  }

  /// The version of the analyzer that wrote this document, one of
  /// [knownRouteBAnalysisVersions].
  final int analysisVersion;

  /// The whole-patch outcome.
  final RouteBVerdict verdict;

  /// Members whose compiled form differs from the release's.
  final List<String> changed;

  /// UNCHANGED members analyzed as if they had changed, because the release
  /// holds an inlined or folded copy of a changed member inside them. They
  /// appear in [representable] or [conditional] like any changed member, and
  /// never in [changed].
  final List<String> carried;

  /// For each analyzed member, the app members whose bodies name it in the
  /// patched kernel. Null for an analysis from before version 15.
  final Map<String, List<String>>? callers;

  /// Whether the analyzer that wrote this takes `--carry`.
  final bool canCarry;

  /// Every member only the patched kernel has. Before version 16 each is a
  /// rejection; from 16 the ones in [helpers] and [unusedHelpers] are not.
  final List<String> added;

  /// New top-level functions and getters the patch carries as source, inside
  /// every replacement library that needs them (version 16). A subset of
  /// [added]. Each has a `sources` span and a `callers` entry.
  final List<String> helpers;

  /// New top-level functions nothing in the patch reaches (version 16). Not
  /// shipped and not a rejection.
  final List<String> unusedHelpers;

  /// The helpers [key] reaches: named by its body, or by a helper that is, per
  /// [callers]. They ship inside [key]'s replacement library, so what they name
  /// is part of what that replacement asks the release to have kept.
  Set<String> helpersNeededBy(String key) {
    final needed = <String>{};
    if (helpers.isEmpty) return needed;
    var grew = true;
    while (grew) {
      grew = false;
      for (final helper in helpers) {
        if (needed.contains(helper)) continue;
        final of = callers?[helper] ?? const <String>[];
        if (of.contains(key) || of.any(needed.contains)) {
          needed.add(helper);
          grew = true;
        }
      }
    }
    return needed;
  }

  /// The [callers] of [key] that the RELEASE has, which leaves out [helpers]:
  /// a helper is new, so the release never runs a copy of anything inside it.
  List<String>? releaseCallersOf(String key) => callers?[key]
      ?.where((c) => !helpers.contains(c) && !unusedHelpers.contains(c))
      .toList();

  /// The external symbols each carried member's body names, keyed by
  /// `library#selector` (analysis version 18). Null for an earlier analysis,
  /// which did not measure them.
  final Map<String, List<RouteBExternalReference>>? externalReferences;

  /// What each carried class member's body takes from its class scope, keyed by
  /// `library#selector`. Null when the analyzer did not report it.
  final Map<String, RouteBEnclosingScope>? enclosingScope;

  /// Members the patch drops. Reported, never fatal: the release keeps them and
  /// nothing calls them from the patch's own code.
  final List<String> removed;

  /// Changed members that are static-shaped, and so genuinely patchable.
  final List<String> representable;

  /// Changed instance members, which the kernel cannot decide.
  ///
  /// **These ship.** That is the reference tooling's behaviour, preserved
  /// deliberately rather than tightened here: deciding them needs per-call-site
  /// data from the release snapshot, which no kernel carries. Tightening it to
  /// a refusal without that data would reject every instance-member patch,
  /// including the ones that work today.
  final List<String> conditional;

  /// Every member that cannot be carried, with the analyzer's own reason.
  final List<RouteBRejection> rejections;

  /// The analyzer's aggregate refusal line, if it refused.
  final String? refusalSummary;

  /// Where each changed member's new body lives, by `library#selector`.
  final Map<String, RouteBSourceSpan> sources;

  /// Implicit-`this` lowering facts, for changed INSTANCE members and, from
  /// analysis version 17, for each instance helper (keyed `library#Class.m`).
  final Map<String, RouteBLowering> lowering;

  /// Signature identities for changed members, keyed by `library#selector`.
  ///
  /// Empty for a release analyzed by a cell that predates P4.4, which the
  /// producer treats as "not established" rather than as "unchanged".
  final Map<String, RouteBSignatureChange> signatures;

  /// The refusal, as the user will read it.
  ///
  /// Names every rejected target and its reason. A count would be worse than
  /// useless here: "1 changed member is not reachable" tells you a patch failed
  /// and gives you nowhere to go.
  String get refusalMessage {
    // A field or constructor is in neither `changed` nor `added`, which list
    // procedures only, so it is counted from its rejection.
    final declarations = rejections
        .where((r) => r.category == RouteBRepresentability.declaration)
        .length;
    // Helpers are in `added` but are not rejections; count only the new
    // members that are.
    final refusedAdded = (added.length - helpers.length - unusedHelpers.length)
        .clamp(0, added.length);
    final buffer = StringBuffer()
      ..writeln(
        'This patch cannot be built: ${rejections.length} of '
        '${changed.length + carried.length + refusedAdded + declarations} '
        '${carried.isEmpty ? 'changed ' : ''}members cannot be carried by '
        'a Route B patch.',
      )
      ..writeln();
    for (final rejection in rejections) {
      buffer.writeln('  ${rejection.target}');
      if (carried.contains(rejection.target)) {
        buffer.writeln(
          '      (unchanged, but the release holds a copy of a changed member '
          'inside it, so the patch must replace it too)',
        );
      }
      buffer.writeln('      ${rejection.reason}');
    }
    buffer
      ..writeln()
      ..write(
        'The whole patch is refused, not the part that failed. Shipping the '
        'rest would leave your app running some functions from the patch and '
        'some from the release. Nothing was uploaded.',
      );
    return buffer.toString();
  }
}

/// The `--include` prefixes the analyzer is run with for an app whose package
/// is [packageName]: the app's own libraries, whole, and nothing else.
///
/// This is the breadth the release used for its census and its dynamic
/// interface (`route_b_release_kernels.dart`), and a patch's analysis must use
/// the same one, or the analyzer reads the release's own framework members as
/// changed. Empty for a null or empty name, which is the analyzer's default
/// (every non-`dart:` library is the app) and the only safe answer when the
/// release's package cannot be named.
List<String> routeBAppIncludePrefixes(String? packageName) =>
    packageName == null || packageName.isEmpty
    ? const []
    : ['package:$packageName/'];

/// Runs the coverage analyzer out of a resolved compiler cell.
///
/// `compiler` is the cell belonging to the RELEASE's engine, so the analyzer
/// reading these dills is version-matched to the frontend that wrote them.
class RouteBCoverageAnalyzer {
  /// {@macro route_b_coverage_analyzer}
  const RouteBCoverageAnalyzer();

  /// Analyze the change between [baseDill] and [patchedDill].
  ///
  /// [carry] names unchanged members to analyze as if they had changed. Only
  /// an analyzer of [routeBCarryAnalysisVersion] or later takes it; pass it
  /// only when an earlier analysis said [RouteBCoverage.canCarry].
  RouteBCoverage analyze({
    required RouteBCompiler compiler,
    required File baseDill,
    required File patchedDill,
    List<String> includePrefixes = const [],
    Set<String> carry = const {},
  }) {
    final result = Process.runSync(compiler.runtime.path, [
      compiler.analyzer.path,
      '--base-dill',
      baseDill.path,
      '--patched-dill',
      patchedDill.path,
      for (final prefix in includePrefixes) ...['--include', prefix],
      for (final key in carry.toList()..sort()) ...['--carry', key],
    ]);

    if (result.exitCode != 0) {
      throw RouteBCompilerException(RouteBCompilerProblem.invalid, '''
The Route B coverage analyzer failed (exit ${result.exitCode}):

${result.stderr}

Treat this as corruption or a bad cache, not as a problem with the release.
Nothing was uploaded.''');
    }

    return RouteBCoverage.fromJson(result.stdout as String);
  }
}
