// cspell:words prepass
//
// Route B (selfhost): did the RELEASE keep every external symbol the patch's
// bytecode names?
//
// WHY THIS EXISTS. A replacement body is compiled against the release's whole
// import kernel, so it compiles whatever it names. It RUNS against the
// release's AOT snapshot, which holds only what the release retained, and the
// bytecode loader resolves every library, class, field and function by name
// and ABORTS THE PROCESS when one is missing (`bytecode_reader.cc`: "Unable to
// find library", "class", "field", "function"). Seam 6 attaches before `main`,
// so that is a boot abort. Before this check the only things standing between
// such a patch and a device were an accident (a dependency API the release
// never called shows up in the analysis as a new class) and nothing at all (a
// framework or SDK symbol, which the analysis does not diff).
//
// MEASURED, not assumed (`probes/retention_loader.sh`, real snapshot and real
// loader, a dependency package standing in for Flutter): a class, constructor,
// static, static field or top-level the release never named ABORTS, even when
// release code reaches it (the AOT compiler inlines it away). An INSTANCE
// member does not abort (the loader gives an interface target a stand-in), but
// a call to one the snapshot lacks throws `NoSuchMethodError`, which is a patch
// that runs wrongly, so it is refused here too unless the release records it.
//
// WHAT COUNTS AS RETAINED is what the release's dynamic interface says, and
// only that: it is the artifact the release was built with, hash-verified in
// the release's provenance. It keeps
//
//   * a `library:` item with no class or member: every PUBLIC class and member
//     of that library (the app's own libraries, whole);
//   * a `library:`/`class:`/`member:` item: that member (the SDK members, the
//     framework and dependency members the release's own code named, the
//     private members, the granted constructors);
//   * a `class:` item with no member: the class and its public members;
//   * a `can-be-used-as-type` class: that class, findable by name.
//
// A private member additionally has the release's capability manifest to
// answer it, as everywhere else in Route B.
//
// FAIL CLOSED. A reference whose retention cannot be established is refused:
// not in the interface, no interface at all, an interface this build cannot
// read, a body the analyzer could not walk, or a member the analysis recorded
// nothing for. "Could not tell" is never "kept".
//
// The interface is a CONSERVATIVE witness: a static the release reaches but
// never names (a widget constructor a Material widget builds, say) may well be
// in the snapshot, and is refused anyway because nothing at patch time says so.
// The refusal is worded for that: the release's own code never used it.
//
// WHAT IT DOES NOT COVER, said once so nobody reads more into a pass:
//
//   * an instance member of a `dart:` class (`s.substring(1)`) is NOT decidable
//     from anything a patch has: it binds by selector, the generator leaves it
//     out of the interface on purpose, and the AOT kernel the CLI would have to
//     read is not parsed here. One the release never called throws
//     `NoSuchMethodError` on a device. So it is refused unless it is on
//     [routeBDeviceProvenSdkInstanceMembers], a short list of members measured
//     to work. A patch outside the list can always be made to work by cutting a
//     release whose own code calls the member; the refusal says so;
//   * a reference the compiler adds that no source token names (string
//     interpolation, `for`, `async`), and `dart:_` libraries, which no
//     interface can hold and no patch spells;
//   * an extension GETTER or SETTER (`record.wait`, `Ext|get#x`): refused
//     always, by name. The interface never lists a `#` member (the generator
//     skips them), so a release cannot be shown to have kept one, and one it
//     lacks aborts the process at load. The analyzer must report it first (it
//     did not before the fix in this tree), so a cell built before that fix
//     still lets it through; an extension METHOD (`Ext|m`) is reported and
//     answered like any other top-level member;
//   * the declared type of a local variable. Measured: a never-used class as
//     the type of an unassigned local loads (`local_type_only`); an
//     assignment or cast to it is a type node and is collected.
import 'dart:io';

import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:yaml/yaml.dart';

/// SDK instance members measured to run in a patch on a release that never
/// named them, as `library#Class#member` (the declaring class, VM member
/// names).
///
/// A BUDGET, as the SDK-member list at release time is: a member goes on only
/// with evidence. Everything here ran on an iPhone in
/// `selfhost/engine/route_b/evidence/ios_shapes_2026_11_15` (`p03` and every
/// counter in the other patches: the numeric operators and interpolation's
/// `toString`; `p07`: a `for-in` loop's iterator calls; `p16`: `List.add` and
/// `Iterable.join`; `p17`: `split`, `where`, `map`, `toList`), or is an
/// operator the same runs could not avoid (`==`).
///
/// NOT on it, on purpose: `String.toUpperCase` (`p17` ran it, but a host run of
/// the same shape on a release that never called it threw `NoSuchMethodError`,
/// so the device run does not settle it), `Stream.where`, `Future.catchError`,
/// `Duration.inMilliseconds`, `StateError.message`, `List.contains`, and every
/// `dart:ui` member. Widening it is a measurement, not a guess.
final routeBDeviceProvenSdkInstanceMembers = <String>{
  for (final cls in ['num', 'int', 'double'])
    for (final op in [
      '+',
      '-',
      '*',
      '/',
      '~/',
      '%',
      '<',
      '>',
      '<=',
      '>=',
      'unary-',
      '==',
    ])
      'dart:core#$cls#$op',
  'dart:core#Object#==',
  'dart:core#Object#toString',
  // Interpolation calls `toString` through the VM's own virtual call, so every
  // class the VM allocates itself keeps its override.
  'dart:core#int#toString',
  'dart:core#double#toString',
  'dart:core#bool#toString',
  'dart:core#String#toString',
  'dart:core#Object#get:hashCode',
  'dart:core#String#==',
  'dart:core#List#add',
  'dart:core#Iterable#join',
  'dart:core#Iterable#where',
  'dart:core#Iterable#map',
  'dart:core#Iterable#toList',
  'dart:core#Iterable#get:iterator',
  'dart:core#Iterator#moveNext',
  'dart:core#Iterator#get:current',
  'dart:core#String#split',
};

/// The release's retained set, read from its dynamic interface.
class RouteBRetention {
  /// Builds a retention set from its parts. Prefer [RouteBRetention.parse].
  const RouteBRetention({
    this.wholeLibraries = const {},
    this.members = const {},
    this.classes = const {},
    this.wholeClasses = const {},
    this.capabilities,
  });

  /// Parses the text of a `dynamic_interface.yaml`.
  ///
  /// [capabilities] is the release's manifest, which answers for a private
  /// member. Throws [FormatException] on a document it does not understand,
  /// rather than reading it as an empty interface: an empty interface refuses
  /// everything and would look like a policy decision.
  factory RouteBRetention.parse(
    String interface, {
    RouteBCapabilities? capabilities,
  }) {
    final Object? loaded;
    try {
      loaded = loadYaml(interface);
    } on YamlException catch (error) {
      throw FormatException('the dynamic interface is not YAML: $error');
    }
    if (loaded is! YamlMap) {
      throw const FormatException('the dynamic interface is not a mapping');
    }
    final document = loaded;

    final whole = <String>{};
    final members = <String>{};
    final classes = <String>{};
    final wholeClasses = <String>{};

    List<YamlMap> items(String section) {
      final raw = document[section];
      if (raw == null) return const [];
      if (raw is! YamlList) {
        throw FormatException('the dynamic interface "$section" is not a list');
      }
      return [
        for (final item in raw)
          if (item is YamlMap)
            item
          else
            throw FormatException(
              'the dynamic interface "$section" holds a non-mapping item',
            ),
      ];
    }

    for (final item in items('callable')) {
      final library = item['library'];
      if (library is! String) {
        throw const FormatException('a callable item names no library');
      }
      final cls = item['class'];
      final member = item['member'];
      if (cls == null && member == null) {
        whole.add(library);
      } else if (member == null) {
        // A bare class item keeps the class AND its public members (the
        // generator's own wording), as older generators wrote them.
        classes.add('$library#${cls as String}');
        wholeClasses.add('$library#$cls');
      } else {
        // A member item keeps its class findable too, which is what the
        // generator relies on when it adds the class to the type list.
        if (cls is String) classes.add('$library#$cls');
        members.add('$library#${cls ?? ''}#$member');
      }
    }
    for (final item in items('can-be-used-as-type')) {
      final library = item['library'];
      final cls = item['class'];
      if (library is! String) {
        throw const FormatException('a type item names no library');
      }
      for (final name in cls is YamlList ? cls : [cls]) {
        if (name is String) classes.add('$library#$name');
      }
    }
    return RouteBRetention(
      wholeLibraries: whole,
      members: members,
      classes: classes,
      wholeClasses: wholeClasses,
      capabilities: capabilities,
    );
  }

  /// Reads the interface at [file], or null when it is absent or unreadable.
  /// Null is the caller's to refuse on: it is not an empty interface.
  static RouteBRetention? read(
    File? file, {
    RouteBCapabilities? capabilities,
  }) {
    if (file == null || !file.existsSync()) return null;
    try {
      return RouteBRetention.parse(
        file.readAsStringSync(),
        capabilities: capabilities,
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Libraries kept whole: every public class and member.
  final Set<String> wholeLibraries;

  /// `library#Class#member` (`Class` empty for a top-level member).
  final Set<String> members;

  /// `library#Class`, findable by name.
  final Set<String> classes;

  /// `library#Class` kept by a bare `class:` item: every public member too.
  final Set<String> wholeClasses;

  /// The release's capability manifest, if it published one.
  final RouteBCapabilities? capabilities;

  /// Why [reference] cannot be shown to be retained, or null when it can.
  String? refuse(RouteBExternalReference reference) {
    final r = reference;
    if (r.kind == 'unanalyzed') {
      return 'the analysis could not tell what it uses (${r.reason}), and a '
          'symbol that cannot be shown to be kept is not kept';
    }
    // Bound by selector at run time, and left out of the interface on purpose;
    // see the header. Only a member measured to work is let through.
    if (r.kind == 'instance' &&
        r.library.startsWith('dart:') &&
        !r.viaConstant) {
      return _isUnprovenSdkInstance(r) ? _describeSdkInstance(r) : null;
    }
    return _retained(r) ? null : _describe(r);
  }

  /// Whether [r] is an instance member of a `dart:` class that is neither on
  /// the device-proven list nor named by the release's interface. A constant that names it keeps it (the release's own
  /// interface item), so that case is the interface's to answer.
  bool _isUnprovenSdkInstance(RouteBExternalReference r) =>
      r.kind == 'instance' &&
      r.library.startsWith('dart:') &&
      !r.viaConstant &&
      !routeBDeviceProvenSdkInstanceMembers.contains(
        '${r.library}#${r.className}#${r.member}',
      ) &&
      // One the release's own interface lists by name (the SDK-member list
      // the release was built with, e.g. `DateTime.millisecondsSinceEpoch`)
      // is kept by that item.
      !members.contains('${r.library}#${r.className}#${r.member}');

  /// Whether [r] is an extension getter, setter or tear-off, whose `#` name no
  /// interface lists.
  static bool _isExtensionHashMember(RouteBExternalReference r) {
    final member = r.member;
    return member != null && member.contains('|') && member.contains('#');
  }

  bool _retained(RouteBExternalReference r) {
    final cls = r.className;
    final member = r.member;
    final key = '${r.library}#${cls ?? ''}#${member ?? ''}';
    // An extension member named with `#` is not in any interface, and the
    // whole-library rule must not answer for it: the generator keeps an app
    // library's PUBLIC members whole but skips these, so the library being
    // kept says nothing about them (e22, E13: both aborted at load).
    if (_isExtensionHashMember(r)) {
      return members.contains(key) && !_manifestSkips(key);
    }
    // A PRIVATE name the patch spells is its own library's, and what answers
    // for it is the capability manifest, as everywhere else in Route B. One
    // named only by a constant is kept by the interface item itself.
    if (r.isPrivate && !r.viaConstant) {
      final caps = capabilities;
      if (caps == null) return false;
      if (member == null) {
        // A private class named as a type (`is _Marker`): the interface keeps
        // it findable, or the manifest lists one of its members.
        return classes.contains('${r.library}#$cls') ||
            _manifestKeepsClass(r.library, cls!);
      }
      return switch (r.kind) {
        'top-level' =>
          caps.refuseTopLevel(library: r.library, member: member) == null,
        // Not this check's to answer: whether a patch may CONSTRUCT a private
        // class is analysis 12's evidence (the release's own version of the
        // method constructed it), which is what puts the function in the
        // snapshot. The manifest withholds every construction by design, so
        // asking it here would refuse `createState() => _HomeState()`
        // (`unchanged_release_sweep` found exactly that).
        'constructor' => true,
        _ =>
          caps.refuseInstanceMember(
                    library: r.library,
                    className: cls!,
                    member: member,
                  ) ==
                  null ||
              caps.classPublicMembers.contains(key),
      };
    }
    if (member == null) {
      // A class named as a type.
      return classes.contains('${r.library}#$cls') ||
          (!r.isPrivate && wholeLibraries.contains(r.library));
    }
    if (members.contains(key)) return !_manifestSkips(key);
    if (!r.isPrivate &&
        cls != null &&
        wholeClasses.contains('${r.library}#$cls')) {
      return true;
    }
    return !r.isPrivate && wholeLibraries.contains(r.library);
  }

  bool _manifestSkips(String key) =>
      capabilities?.skipped.any((s) => s.startsWith(key)) ?? false;

  bool _manifestKeepsClass(String library, String cls) {
    final caps = capabilities;
    if (caps == null) return false;
    final prefix = '$library#$cls#';
    return [
      ...caps.instanceCallable,
      ...caps.staticsCallable,
      ...caps.classPublicMembers,
    ].any((k) => k.startsWith(prefix));
  }

  /// `String.toUpperCase`, for the sentence about SDK instance members.
  static String _describeSdkInstance(RouteBExternalReference r) =>
      'the ${r.library.substring(0, r.library.indexOf(':'))}: method '
      '`${r.displayName}` (an SDK instance member)';

  /// "`Padding`", the way a developer would name it. The library is added only
  /// where it helps: a framework path (`package:flutter/src/widgets/...`) is
  /// not something the developer wrote.
  static String _describe(RouteBExternalReference r) {
    if (_isExtensionHashMember(r)) {
      return 'the extension member `${r.displayName}` (${r.library})';
    }
    final what = switch (r.kind) {
      'class' => 'the ${r.isPrivate ? 'private ' : ''}class',
      'constructor' => 'the ${r.isPrivate ? 'private ' : ''}constructor',
      _ => r.isPrivate ? 'the private member' : 'the symbol',
    };
    final lib = r.library;
    final where = lib.startsWith('dart:') || lib.startsWith('package:flutter/')
        ? ''
        : ' ($lib)';
    return '$what `${r.displayName}`$where';
  }

  /// The symbols among [keys]' references that the release did not keep.
  List<String> unretained(RouteBCoverage coverage, Iterable<String> keys) {
    final all = coverage.externalReferences;
    if (all == null) return const [];
    final out = <String>{};
    for (final key in keys) {
      final references = all[key];
      if (references == null) {
        // No entry is "not measured", never "uses nothing".
        out.add(
          'what `${_selector(key)}` uses (the analysis recorded nothing for '
          'it, and a symbol that cannot be shown to be kept is not kept)',
        );
        continue;
      }
      for (final r in references) {
        if (refuse(r) case final why?) out.add(why);
      }
    }
    return out.toList();
  }

  static String _selector(String key) => key.substring(key.indexOf('#') + 1);

  /// [refusal] for [key] and the helpers its replacement library carries.
  String? refusalForTarget(RouteBCoverage coverage, String key) =>
      refusal(coverage, [key, ...coverage.helpersNeededBy(key)]);

  /// Why the members [keys] cannot be built, or null when the release kept
  /// everything they use.
  ///
  /// Null also when [coverage] predates analysis version 18 and so cannot say
  /// (see [routeBRetentionAnalysisVersion]); the caller decides what that
  /// means, and today it means a warning rather than a refusal.
  String? refusal(RouteBCoverage coverage, Iterable<String> keys) {
    final all = unretained(coverage, keys);
    final sdk = all
        .where((d) => d.contains('(an SDK instance member)'))
        .toList();
    final rest = all.where((d) => !sdk.contains(d)).toList();
    return [
      ?describeRouteBUnretained(rest),
      ?describeRouteBUnprovenSdkMembers(sdk),
    ].join('. ').nullIfEmpty;
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

/// The refusal for a patch whose analysis (version 18 or later) names symbols
/// the release's interface does not keep, or null for an empty [symbols].
///
/// Written for the developer who made the patch: it names the symbol, says the
/// release did not keep it, and says what to do.
String? describeRouteBUnretained(List<String> symbols) {
  if (symbols.isEmpty) return null;
  const shown = 5;
  final named = symbols.take(shown).join(', ');
  final more = symbols.length > shown
      ? ', and ${symbols.length - shown} more'
      : '';
  return 'it uses $named$more, which the release never used in its own code. A '
      'patch can only call what the release was built to keep, and the loader '
      'stops the app at launch when a class, constructor, static or top-level '
      'it names is not there. Cut a new release whose own code uses it (a '
      'call is enough), then patch that';
}

/// The refusal for a patch that calls SDK instance members not on the
/// device-proven list, or null for an empty [symbols].
String? describeRouteBUnprovenSdkMembers(List<String> symbols) {
  if (symbols.isEmpty) return null;
  const shown = 5;
  final named = symbols.take(shown).join(', ');
  final more = symbols.length > shown
      ? ', and ${symbols.length - shown} more'
      : '';
  return 'it calls $named$more. An SDK instance method is looked up by name '
      'when it runs, and the app throws NoSuchMethodError at that call if the '
      'release never called it; nothing at patch time can tell. Cut a new '
      'release whose own code calls it (a call is enough), then patch that';
}

/// The refusal for a release whose interface is missing or unreadable, when the
/// analysis is of a version that can check against one.
const routeBNoInterfaceReason =
    'this release uploaded no readable dynamic interface, so whether it kept '
    'the symbols this patch uses cannot be established. A symbol that cannot '
    'be shown to be kept is not kept. Cut a new release with a current CLI and '
    'patch that instead';
