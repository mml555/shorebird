// cspell:words prepass
//
// Route B (selfhost): did the RELEASE keep every external symbol the patch's
// bytecode names?
//
// WHY THIS EXISTS. A replacement body is compiled against the release's whole
// import kernel, so it compiles whatever it names. It RUNS against the release's
// AOT snapshot, which holds only what the release retained, and the bytecode
// loader resolves every library, class, field and function by name and ABORTS THE
// PROCESS when one is missing (`bytecode_reader.cc`: "Unable to find library",
// "class", "field", "function"). Seam 6 attaches before `main`, so that is a boot
// abort. Before this check the only things standing between such a patch and a
// device were an accident (a dependency API the release never called shows up in
// the analysis as a new class, and is refused for that) and nothing at all (a
// framework or SDK symbol, which the analysis does not diff).
//
// WHAT COUNTS AS RETAINED is what the release's dynamic interface says, and only
// that: it is the artifact the release was built with, hash-verified in the
// release's provenance. It keeps
//
//   * a `library:` item with no class or member: every PUBLIC class and member
//     of that library (the app's own libraries, whole);
//   * a `library:`/`class:`/`member:` item: that member (the SDK members, the
//     framework and dependency members the release's own code named, the
//     private members, the granted constructors);
//   * a `class:` item or a `can-be-used-as-type:` class: that class, findable by
//     name.
//
// A private member additionally has the release's capability manifest to answer
// it, as everywhere else in Route B.
//
// FAIL CLOSED. A reference whose retention cannot be established is refused:
// not in the interface, no interface at all, an interface this build cannot
// read, or a body the analyzer could not walk. "Could not tell" is never "kept".
//
// WHAT IT DOES NOT COVER, said once so nobody reads more into a pass:
//
//   * an instance member of a `dart:` class (`s.substring(1)`). It binds by
//     selector at run time, the release generator leaves it out of the interface
//     on purpose, and its failure is a `NoSuchMethodError`, not a boot abort;
//   * a reference the compiler adds that no source token names (string
//     interpolation, `for`, `async`), and `dart:_` libraries, which no interface
//     can hold and no patch spells;
//   * the declared type of a local variable, which the bytecode is not known to
//     emit.
import 'dart:io';

import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:yaml/yaml.dart';

/// The release's retained set, read from its dynamic interface.
class RouteBRetention {
  /// Builds a retention set from its parts. Prefer [RouteBRetention.parse].
  const RouteBRetention({
    this.wholeLibraries = const {},
    this.members = const {},
    this.classes = const {},
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
        classes.add('$library#${cls as String}');
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

  /// The release's capability manifest, if it published one.
  final RouteBCapabilities? capabilities;

  /// Why [reference] cannot be shown to be retained, or null when it can.
  String? refuse(RouteBExternalReference reference) {
    final r = reference;
    if (r.kind == 'unanalyzed') {
      return 'the analysis could not tell what it uses (${r.reason}), and a '
          'symbol that cannot be shown to be kept is not kept';
    }
    // Bound by selector at run time; see the header.
    if (r.kind == 'instance' &&
        r.library.startsWith('dart:') &&
        !r.viaConstant) {
      return null;
    }
    return _retained(r) ? null : _describe(r);
  }

  bool _retained(RouteBExternalReference r) {
    final cls = r.className;
    final member = r.member;
    final key = '${r.library}#${cls ?? ''}#${member ?? ''}';
    // A PRIVATE name the patch spells is its own library's, and what answers
    // for it is the capability manifest, as everywhere else in Route B. One
    // named only by a constant is kept by the interface item itself.
    if (r.isPrivate && !r.viaConstant) {
      final caps = capabilities;
      if (caps == null) return false;
      if (member == null) return _manifestKeepsClass(r.library, cls!);
      return switch (r.kind) {
        'top-level' =>
          caps.refuseTopLevel(library: r.library, member: member) == null,
        'constructor' => caps.classesConstructible.contains(
          '${r.library}#$cls.${member.isEmpty ? 'new' : member}',
        ),
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

  /// "`DateTime.now` (dart:core)", the way a developer would name it.
  static String _describe(RouteBExternalReference r) {
    final what = switch (r.kind) {
      'class' => 'the ${r.isPrivate ? 'private ' : ''}class',
      'constructor' => 'the ${r.isPrivate ? 'private ' : ''}constructor',
      _ => r.isPrivate ? 'the private member' : 'the symbol',
    };
    return '$what `${r.displayName}` (${r.library})';
  }

  /// The symbols among [keys]' references that the release did not keep.
  List<String> unretained(RouteBCoverage coverage, Iterable<String> keys) {
    final all = coverage.externalReferences;
    if (all == null) return const [];
    return {
      for (final key in keys)
        for (final r in all[key] ?? const <RouteBExternalReference>[])
          if (refuse(r) case final why?) why,
    }.toList();
  }

  /// [refusal] for [key] and the helpers its replacement library carries.
  String? refusalForTarget(RouteBCoverage coverage, String key) =>
      refusal(coverage, [key, ...coverage.helpersNeededBy(key)]);

  /// Why the members [keys] cannot be built, or null when the release kept
  /// everything they use.
  ///
  /// Null also when [coverage] predates analysis version 18 and so cannot say
  /// (see [routeBRetentionAnalysisVersion]); the caller decides what that
  /// means, and today it means a warning rather than a refusal.
  String? refusal(RouteBCoverage coverage, Iterable<String> keys) =>
      describeRouteBUnretained(unretained(coverage, keys));
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
  return 'it uses $named$more, which the release did not keep. A patch can '
      'only use code the release was built to keep; anything else cannot be '
      'found when the patch loads, and the app would stop at launch. Cut a '
      'new release that uses it, then patch that';
}

/// The refusal for a release whose interface is missing or unreadable, when the
/// analysis is of a version that can check against one.
const routeBNoInterfaceReason =
    'this release uploaded no readable dynamic interface, so whether it kept '
    'the symbols this patch uses cannot be established. A symbol that cannot '
    'be shown to be kept is not kept. Cut a new release with a current CLI and '
    'patch that instead';
