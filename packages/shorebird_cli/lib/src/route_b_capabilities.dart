// cspell:words prepass
//
// The capability set a RELEASE actually granted, and the acceptance rule that
// reads it.
//
// WHY THIS IS NOT "PRIVATE IS ALLOWED". The retention policy (P2) says what a
// release INTENDS to grant. This says what a release DID grant, per target,
// and the two diverge in ways that were measured rather than imagined:
//
//   * a private enumeration that fell back to the `--aot` prepass grants a
//     narrower set than P2 promises, and the release still succeeds -- so the
//     promise is not evidence;
//   * six `_enumToString` members cannot be granted under ANY policy, because
//     `LibraryIndex` will not key a private name belonging to another library;
//   * a member can be granted while its enclosing class is NOT, and then a
//     patch cannot attach to any method of that class at all. Not a
//     hypothetical: it is what killed P3, whose 340 member grants were
//     operationally inert for exactly this reason.
//
// So acceptance is per-target and reads the release's own manifest. A
// category-level rule would accept `_FooState._controller` because "private
// instance members are retained", on a release where that member sat in the
// skipped set or its class was never retained.
//
// The rule, mechanically:
//
//   private reference requested
//     -> member present in the emitted capability set
//     -> required enclosing class capability present
//     -> not in the release's skipped set
//     -> not in the unconditional must-refuse set
//     -> ACCEPT
//   otherwise REFUSE, naming which condition failed.
import 'dart:convert';
import 'dart:io';

/// Members no policy can grant, refused unconditionally.
///
/// `_enumToString` is CFE-synthesized enum machinery whose `Name` belongs to
/// `dart:core` rather than to the library declaring the enum, and
/// `LibraryIndex` refuses to key a private name owned by another library.
/// Every policy skips it, no patch author writes it, and counting it as a
/// coverage gap would understate every policy equally.
///
/// Matched on the member's own name, because the enum it hangs off differs
/// per app.
const routeBUnconditionalRefusals = <String>{'_enumToString'};

/// Why a private reference was refused. Each value names a distinct cause,
/// because the remedies differ: a missing member may be a retention gap, a
/// missing class capability is a policy or fallback consequence, and an
/// unconditional refusal is neither.
enum RouteBRefusal {
  /// The member is not in the release's emitted capability set.
  memberNotEmitted,

  /// The PATCH TARGET itself is a member of a private class that this release
  /// did not grant.
  ///
  /// Distinct from [memberNotEmitted], which is about a member the body
  /// REFERENCES. This is about the member being replaced, and it fails later
  /// and worse if it is not caught here: the patch publishes, downloads, and the
  /// engine refuses at ATTACH on the device with a message about attachment
  /// rather than about capability. P4.2 exists to move that failure left.
  targetNotGranted,

  /// The member was emitted, but its enclosing class carries no class
  /// capability, so a patch cannot attach to a method of that class. P3's
  /// failure mode.
  ///
  /// **NO LONGER PRODUCED as of 2026-08-25, and kept rather than deleted so a
  /// reader who saw it in an older log can find out why.** The requirement was
  /// misattributed: attach needs the TARGET member granted, not the enclosing
  /// class. Measured in
  /// `selfhost/engine/route_b/probes/p1_dead_allocatability.sh` (Cfix3 attaches
  /// with no class item; Cfix, lacking the target member's grant, fails at
  /// ATTACH -- which is P3's real cause). Since the generator stopped emitting
  /// bare private `class:` items, requiring a class grant would refuse every
  /// private reference on every release.
  enclosingClassNotRetained,

  /// The release recorded this capability as skipped -- it tried and could not.
  inSkippedSet,

  /// Cannot be granted by any policy.
  unconditional,
}

/// The capability set one release granted, as recorded by the generator
/// that granted it.
class RouteBCapabilities {
  /// Construct a capability set directly. Prefer [RouteBCapabilities.fromJson]
  /// or [RouteBCapabilities.read]; this exists for tests and for callers that
  /// already hold the parsed sets.
  const RouteBCapabilities({
    required this.policy,
    required this.topLevelCallable,
    required this.staticsCallable,
    required this.instanceCallable,
    required this.classesConstructible,
    required this.skipped,
    this.classPublicMembers = const <String>{},
    this.recordsClassPublicMembers = false,
  });

  /// Parse a manifest emitted by `gen_dynamic_interface.dart --manifest`.
  ///
  /// A malformed or absent manifest is NOT an empty capability set: an empty
  /// set would silently refuse every private reference and look like a policy
  /// decision. It throws, so the caller decides whether to refuse loudly or
  /// fall back.
  factory RouteBCapabilities.fromJson(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    List<String> list(String key) =>
        ((json[key] as List<dynamic>?) ?? const <dynamic>[])
            .map((e) => e as String)
            .toList();
    return RouteBCapabilities(
      policy: json['policy'] as String? ?? 'unknown',
      topLevelCallable: list('privateTopLevelCallable').toSet(),
      staticsCallable: list('privateStaticsCallable').toSet(),
      instanceCallable: list('privateInstanceCallable').toSet(),
      classesConstructible: list('privateClassesConstructible').toSet(),
      skipped: list('refused').toSet(),
      classPublicMembers: list('privateClassPublicMembers').toSet(),
      // WHETHER THE KEY EXISTS AT ALL, not whether it is non-empty. A release
      // cut before 2026-08-25 granted a private class's public members through
      // a bare `class:` item and recorded no such list, so an absent key means
      // "this release cannot answer per-member" and an empty one means "it
      // answered, and granted none". Collapsing them would refuse every target
      // on a private class for every older release.
      recordsClassPublicMembers: json.containsKey('privateClassPublicMembers'),
    );
  }

  /// Read a release's manifest from its supplement.
  static RouteBCapabilities? read(File manifest) {
    if (!manifest.existsSync()) return null;
    try {
      return RouteBCapabilities.fromJson(manifest.readAsStringSync());
    } on Exception {
      return null;
    }
  }

  /// The retention policy the release recorded, for diagnostics.
  final String policy;

  /// `uri#member` entries.
  final Set<String> topLevelCallable;

  /// `uri#Class#member` entries that are static.
  final Set<String> staticsCallable;

  /// `uri#Class#member` entries that are instance members.
  final Set<String> instanceCallable;

  /// `uri#Class` entries whose class capability was granted.
  final Set<String> classesConstructible;

  /// `uri#Class#member` entries for the PUBLIC members of private classes.
  ///
  /// These are what a patch TARGETS: a target is almost always a public method
  /// of a private `State` class. Before 2026-08-25 they arrived implicitly
  /// inside a bare `class:` item, together with construction; now they are
  /// named one by one, which is what makes a per-target check possible.
  final Set<String> classPublicMembers;

  /// Whether the manifest carried a `privateClassPublicMembers` key.
  ///
  /// False for a release cut by the older generator, which granted those
  /// members through a class item and recorded no list. It is not refused —
  /// it genuinely granted them — it simply cannot be asked per member.
  final bool recordsClassPublicMembers;

  /// The exact capabilities this release could not grant, verbatim from
  /// the manifest.
  ///
  /// Entries carry a trailing parenthesised reason, so matching is by prefix.
  final Set<String> skipped;

  /// Whether this release granted a private INSTANCE member, and everything
  /// that implies.
  ///
  /// [library] and [className] identify the enclosing class; [member] is the
  /// VM-shaped name (bare for a method or field, `get:`/`set:`-prefixed for
  /// an accessor).
  ///
  /// Returns null when accepted, or the reason it is refused.
  RouteBRefusal? refuseInstanceMember({
    required String library,
    required String className,
    required String member,
  }) {
    if (_isUnconditional(member)) return RouteBRefusal.unconditional;

    final key = '$library#$className#$member';
    if (skipped.any((s) => s.startsWith(key))) {
      return RouteBRefusal.inSkippedSet;
    }
    if (!instanceCallable.contains(key) && !staticsCallable.contains(key)) {
      return RouteBRefusal.memberNotEmitted;
    }

    // ~~THE CONDITION P3'S COLLAPSE PROVED IS LOAD-BEARING.~~ **RE-DIAGNOSED
    // 2026-08-25, and the requirement was misattributed.** P3's member grants
    // were inert, but not because a private class needs a class-level
    // capability: they were inert because P3 never granted the TARGET member,
    // which in P3's own fixture was a PUBLIC method of a private class. Attach
    // needs the target member granted; it does not need the class.
    //
    // Measured: `probes/p1_dead_allocatability.sh` arm Cfix3 attaches to
    // `_Kept.show` and reads `self._hidden` with NO bare class item anywhere in
    // the interface -- only member grants. Cfix (the same grant set minus the
    // target member's grant) fails at ATTACH, which is P3's failure reproduced
    // with its real cause isolated.
    //
    // This matters beyond bookkeeping: `classesConstructible` no longer means
    // "the class is retained". It means "these constructors were explicitly
    // granted", and it is EMPTY on a release that grants none -- so keeping
    // this check would refuse every private member reference on every release.
    if (className.startsWith('_')) {
      final classKey = '$library#$className';
      if (skipped.any((s) => s.startsWith(classKey))) {
        return RouteBRefusal.inSkippedSet;
      }
    }
    return null;
  }

  /// Whether this release granted the PATCH TARGET itself.
  ///
  /// [library], [className] and [member] identify the target being replaced;
  /// [member] is VM-shaped (bare for a method or field, `get:`/`set:`-prefixed
  /// for an accessor), matching what the generator emits.
  ///
  /// A PUBLIC class needs no grant — a `library:` item already covers its
  /// public members — so only a private enclosing class is checked. Returns
  /// null when accepted.
  RouteBRefusal? refuseTarget({
    required String library,
    required String className,
    required String member,
  }) {
    if (!className.startsWith('_')) return null;
    final key = '$library#$className#$member';
    if (skipped.any((s) => s.startsWith(key))) {
      return RouteBRefusal.inSkippedSet;
    }
    // The member may be granted as a public member of a private class, or —
    // when the target is itself private, e.g. patching `_helper` — through the
    // ordinary private-member sets.
    if (classPublicMembers.contains(key) ||
        instanceCallable.contains(key) ||
        staticsCallable.contains(key)) {
      return null;
    }
    // A RELEASE THAT CANNOT BE ASKED IS NOT A RELEASE THAT REFUSED. Before
    // 2026-08-25 the generator granted a private class's public members through
    // a bare `class:` item and recorded no per-member list, so the honest
    // evidence for such a release is the class item itself. Refusing here would
    // reject every private-class target on every older release, which is a
    // regression dressed as a safety check.
    if (!recordsClassPublicMembers &&
        classesConstructible.contains('$library#$className')) {
      return null;
    }
    return RouteBRefusal.targetNotGranted;
  }

  /// Whether this release granted a private TOP-LEVEL member.
  ///
  /// No enclosing class, so the class condition does not apply -- which is
  /// also why this shape worked under every policy including P1.
  RouteBRefusal? refuseTopLevel({
    required String library,
    required String member,
  }) {
    if (_isUnconditional(member)) return RouteBRefusal.unconditional;
    final key = '$library#$member';
    if (skipped.any((s) => s.startsWith(key))) {
      return RouteBRefusal.inSkippedSet;
    }
    if (!topLevelCallable.contains(key)) return RouteBRefusal.memberNotEmitted;
    return null;
  }

  static bool _isUnconditional(String member) {
    // Accessors arrive `get:`/`set:`-prefixed; the unconditional set is
    // keyed on the bare name so one entry covers all three spellings.
    final bare = member.startsWith('get:') || member.startsWith('set:')
        ? member.substring(4)
        : member;
    return routeBUnconditionalRefusals.contains(bare);
  }
}

/// A refusal, phrased for the developer who wrote the patch.
///
/// Each names the CAUSE rather than the symptom, because the remedies are
/// different and the wrong guess is expensive: a retention gap is fixed by
/// re-releasing, a missing class capability by a policy change, and an
/// unconditional refusal by neither.
String describeRouteBRefusal(RouteBRefusal refusal, String target) =>
    switch (refusal) {
      RouteBRefusal.memberNotEmitted =>
        'references the private member `$target`, which this release did '
            'not retain. A patch can only name a private member the release '
            'was built to keep.',
      RouteBRefusal.enclosingClassNotRetained =>
        'references the private member `$target`, whose private enclosing '
            'class this release did not retain — so a patch cannot attach to '
            'that class at all, even though the member itself was retained.',
      RouteBRefusal.inSkippedSet =>
        'references the private member `$target`, which this release '
            'recorded as skipped: it could not be expressed in the retention '
            'interface.',
      RouteBRefusal.unconditional =>
        'references `$target`, which is compiler-generated and cannot be '
            'retained by any release — it is private to `dart:core` rather '
            'than to the library that declares it.',
      // NAMES THE TARGET, NOT A REFERENCE. Without this the same release fails
      // on the device at ATTACH, with a message about attachment, after a
      // successful publish and download.
      RouteBRefusal.targetNotGranted =>
        'replaces `$target`, a member of a private class that this release did '
            'not grant. The release names each member of a private class '
            'individually, and this one is not among them — so the patch would '
            'publish, download, and then fail to attach on the device.',
    };
