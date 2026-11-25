// cspell:words prepass aeiou
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
//     from the interface: it binds by selector and the generator leaves it out
//     on purpose. One the release never kept throws `NoSuchMethodError` on a
//     device, or stops the app. So it is accepted only when BOTH hold:
//       1. it is on the device-measured list ([routeBSdkMeasuredAccepted]),
//          every probe of which resolved, on more than one runtime class; and
//       2. THIS release's own snapshot profile ([RouteBSnapshotKept]) resolves
//          it, on every VM class the measurement ran it on, to a function with
//          real code. A release whose profile is missing or does not match its
//          recorded digest refuses (`--allow-unchecked-sdk-calls` skips this
//          check, and only this check, for SDK members).
//     Or when the release's own interface names the member: the release is
//     built with a short `--sdk-members` list (`print`, `DateTime.now`, ...),
//     and a member on it is accepted with neither check, not even the failing
//     list. That is all this exception covers. The
//     generator does NOT name an instance member of `dart:core` because the
//     release's own code calls it, so a release that calls `Iterable.map`
//     does not thereby get `Iterable.map` accepted.
//     CAVEATS: the list was measured on ONE app at ONE cell, so it says what is
//     expected, not what holds for every release; the profile check is
//     necessary, not sufficient (`List.sort` and `Iterable.contains` on a
//     `List.filled` list have code and abort); and a runtime class the matrix
//     did not measure (`MappedIterable`, a user's own Iterable) is not proven
//     by the device, only by its profile entry: the profile check covers every
//     class of this release that can be a subtype of the declared type, not
//     only the measured ones. A refusal on the measured list is not unlocked by
//     any flag or by any release setting; only a device measurement added to
//     the list does that. Per-release evidence (R4) is the real fix;
//   * a call by name on a `dynamic` value, an instance tear-off, a `for-in`'s
//     `iterator`/`moveNext`/`current`: reported by the analyzer from analysis
//     version 19 and answered by the same measurement. Below 19 the CLI
//     refuses unless told not to (`--allow-unchecked-sdk-calls`);
//   * string interpolation's `toString` (called virtually from the core
//     library, see [routeBSdkMeasuredAccepted]) and `await`
//     (the async machinery calls `_Future` internals directly, not by
//     selector; only a user-defined thenable's `then` is by name), and
//     `dart:_` libraries, which no interface can hold and no patch spells;
//   * an extension or extension-type GETTER or SETTER (`record.wait`,
//     `Ext|get#x`): refused always, by name. The interface never lists a `#`
//     member (the generator skips them), so a release cannot be shown to have
//     kept one, and one it lacks aborts the process at load. An extension
//     METHOD (`Ext|m`) is reported and answered like any other top-level
//     member. Needs analysis 19 to be reported at all;
//   * the declared type of a local variable. Measured: a never-used class as
//     the type of an unassigned local loads (`local_type_only`); an
//     assignment or cast to it is a type node and is collected.
import 'dart:io';

import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_release_kernels.dart';
import 'package:shorebird_cli/src/route_b_sdk_kept.dart';
import 'package:shorebird_cli/src/route_b_sdk_measurements.dart';
import 'package:yaml/yaml.dart';

/// The release's retained set, read from its dynamic interface.
class RouteBRetention {
  /// Builds a retention set from its parts. Prefer [RouteBRetention.parse].
  const RouteBRetention({
    this.wholeLibraries = const {},
    this.members = const {},
    this.classes = const {},
    this.wholeClasses = const {},
    this.capabilities,
    this.measuredAccepted = routeBSdkMeasuredAccepted,
    this.measuredFailing = routeBSdkMeasuredFailing,
    this.measuredVmClasses = routeBSdkMeasuredVmClasses,
    this.kept,
    this.keptProblem,
    this.skipKeptCheck = false,
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
    Set<String> measuredAccepted = routeBSdkMeasuredAccepted,
    Map<String, String> measuredFailing = routeBSdkMeasuredFailing,
    Map<String, List<String>> measuredVmClasses = routeBSdkMeasuredVmClasses,
    RouteBSnapshotKept? kept,
    String? keptProblem,
    bool skipKeptCheck = false,
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
      measuredAccepted: measuredAccepted,
      measuredFailing: measuredFailing,
      measuredVmClasses: measuredVmClasses,
      kept: kept,
      keptProblem: keptProblem,
      skipKeptCheck: skipKeptCheck,
    );
  }

  /// Reads the interface at [file], or null when it is absent or unreadable.
  /// Null is the caller's to refuse on: it is not an empty interface.
  static RouteBRetention? read(
    File? file, {
    RouteBCapabilities? capabilities,
    RouteBSnapshotKept? kept,
    String? keptProblem,
    bool skipKeptCheck = false,
  }) {
    if (file == null || !file.existsSync()) return null;
    try {
      return RouteBRetention.parse(
        file.readAsStringSync(),
        capabilities: capabilities,
        kept: kept,
        keptProblem: keptProblem,
        skipKeptCheck: skipKeptCheck,
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

  /// The keys the device matrix resolved on every runtime class and form
  /// ([routeBSdkMeasuredAccepted] unless a test supplies its own). Measured on
  /// one Flutter release: see route_b_sdk_measurements.dart.
  final Set<String> measuredAccepted;

  /// The keys the matrix saw fail, with why ([routeBSdkMeasuredFailing]).
  final Map<String, String> measuredFailing;

  /// For each accepted key, the VM classes it was measured on
  /// ([routeBSdkMeasuredVmClasses]).
  final Map<String, List<String>> measuredVmClasses;

  /// What THIS release's own snapshot kept (its snapshot profile), or null when
  /// it could not be read; [keptProblem] then says why.
  final RouteBSnapshotKept? kept;

  /// Why [kept] is null, in plain words.
  final String? keptProblem;

  /// `--allow-unchecked-sdk-calls`: do not ask this release's snapshot. The
  /// measured list still applies.
  final bool skipKeptCheck;

  /// Why a patch whose analysis cannot report an `await` (a document below
  /// `routeBAwaitAnalysisVersion`) may still call a `then` this release never
  /// compiled, or null when it cannot.
  ///
  /// Awaiting a `Future` that is not a `_Future` calls its `then` by selector,
  /// and no source token names it, so an old analyzer cannot tell a patch that
  /// awaits one from a patch that does not. What it can be asked is whether
  /// the hazard exists at all: the same question a `.then` call is asked
  /// (`Future.then` on every `Future` subtype the release allocates). A
  /// release where it holds loses nothing by the old analyzer; one where it
  /// fails (a `TickerFuture` with no compiled `then`) cannot be shown safe.
  /// Null under [skipKeptCheck] (`--allow-unchecked-sdk-calls`). It does not
  /// use the measured list: that is a call of `then` on a `_Future`.
  String? awaitUnchecked() {
    if (skipKeptCheck) return null;
    final snapshot = kept;
    if (snapshot == null) {
      return '${keptProblem ?? 'its snapshot profile is not available'}, so '
          'whether this release kept it cannot be checked';
    }
    // `_Future` is left out: awaiting one never calls `then`, so a release
    // that never compiled `_Future.then` loses nothing here.
    return snapshot.problemFor(
      declaredLibrary: 'dart:async',
      declaredClass: 'Future',
      measured: const [],
      selector: 'then',
      excludeClasses: const {'_Future'},
    );
  }

  /// Why [reference] cannot be shown to be retained, or null when it can.
  ///
  /// [inlinedHolds] is asked for a reference the analysis marks `inlined`: true
  /// (the default, before anything is compiled) lets it through, false makes it
  /// an ordinary SDK member again. The producer passes what the compiled
  /// bytecode really does, see `RouteBProducer`.
  String? refuse(
    RouteBExternalReference reference, {
    bool Function(RouteBExternalReference)? inlinedHolds,
  }) {
    final r = reference;
    if (r.kind == 'unanalyzed') {
      return 'the analysis could not tell what it uses (${r.reason}), and a '
          'symbol that cannot be shown to be kept is not kept';
    }
    // A call by name on a `dynamic` value: no declared target to look up.
    if (r.kind == 'dynamic') return _refuseDynamic(r);
    // Bound by selector at run time, and left out of the interface on purpose;
    // see the header. Only a member measured to work is let through.
    if (r.kind == 'instance' &&
        r.library.startsWith('dart:') &&
        !r.viaConstant) {
      // Every site is an opcode the patch's compiler emits (analysis 20): no
      // member is looked up, so neither the device list nor the snapshot is
      // asked. Only the analyzer's own per-site answer lifts the check.
      if (r.inlined != null && (inlinedHolds?.call(r) ?? true)) return null;
      final why = _sdkRefusal(_sdkKey(r), receiver: _receiverOf(r));
      return why == null ? null : _describeSdkInstance(r, why);
    }
    if (_retained(r)) return null;
    // An extension `#` member is answered by the snapshot profile alone, so
    // when there is none to read (missing, another release's, unreadable)
    // say why: under --allow-unchecked-sdk-calls the profile is still read
    // for these, and a bare refusal would read as the flag not working.
    if (_isExtensionHashMember(r) && !r.isPrivate && kept == null) {
      return '${_describe(r)} (${keptProblem ?? 'its snapshot profile is not '
              'available'}, so whether this release kept it cannot be checked)';
    }
    return _describe(r);
  }

  /// A dynamic call is accepted only when the measurement resolved its
  /// selector on every runtime class and form it tried. The app classes that
  /// have a member of that name arrive as `instance` references of their own
  /// and are answered by the interface like any other app member.
  String? _refuseDynamic(RouteBExternalReference r) {
    final sel = r.member ?? '';
    final bare = sel.startsWith('get:') ? sel.substring(4) : null;
    // A dynamic `get` may be a tear-off of a method of that name.
    final keys = ['dynamic#$sel', if (bare != null) 'dynamic#tearoff:$bare'];
    final failed = keys.where(measuredFailing.containsKey).toList();
    final shown = _bareSelector(sel);
    if (failed.isNotEmpty) {
      return 'a call by name to `$shown` on a dynamic value (a dynamic call, '
          'measured: ${measuredFailing[failed.first]})';
    }
    // A tear-off key is only as safe as the call it can become.
    for (final key in keys) {
      final torn = _tearoffRefusal(key);
      if (torn != null) {
        return 'a call by name to `$shown` on a dynamic value (a dynamic '
            'call, $torn)';
      }
    }
    final accepted = keys.where(measuredAccepted.contains).toList();
    if (accepted.isNotEmpty) {
      for (final key in accepted) {
        final problem = _keptProblem(key);
        if (problem != null) {
          return 'a call by name to `$shown` on a dynamic value (a dynamic '
              'call, $problem)';
        }
      }
      return null;
    }
    return 'a call by name to `$shown` on a dynamic value (a dynamic call, '
        'never measured)';
  }

  static String _bareSelector(String sel) =>
      sel.replaceFirst(RegExp('^(get|set|tearoff):'), '');

  /// Why an instance member of a `dart:` class [key] cannot be shown to be kept
  /// by THIS release, or null when it can: the release's own interface names it
  /// (the short `--sdk-members` list; neither the allow-list, the failing list
  /// nor the snapshot is asked for it: a release that names a member kept
  /// it), or it is on the device-measured
  /// list AND this release's snapshot resolves it on every VM class it was
  /// measured on and on every class of the release that can be the declared
  /// type. An empty string is "on no list".
  ///
  /// [receiver] narrows the classes asked to the release's subtypes of that
  /// class (`library`, `class`); see [_keptProblem].
  String? _sdkRefusal(String key, {(String, String)? receiver}) {
    // First: a tear-off named by the interface is still only as safe as its
    // call, which the interface's own list does not vouch for.
    final torn = _tearoffRefusal(key);
    if (torn != null) return torn;
    if (members.contains(key) && !_snapshotCheckedWhenNamed.contains(key)) {
      return null;
    }
    final failed = measuredFailing[key];
    if (failed != null) return 'measured: $failed';
    if (!measuredAccepted.contains(key)) return '';
    return _keptProblem(key, receiver: receiver);
  }

  /// Members the release names in its interface and that are still checked
  /// against its snapshot, because naming them is not shown to keep code on
  /// every class that can be the receiver.
  ///
  /// `Future.then`, `catchError`, `whenComplete` and `timeout` are named so
  /// that a release compiles them on the `Future` subtypes it allocates
  /// (`TickerFuture` in every Material app); an `await` on one calls its
  /// `then` (#289). Those subtypes live outside `dart:`, where retention by
  /// name was never measured, so the snapshot still answers.
  static const _snapshotCheckedWhenNamed = {
    'dart:async#Future#then',
    'dart:async#Future#catchError',
    'dart:async#Future#whenComplete',
    'dart:async#Future#timeout',
  };

  static (String, String)? _receiverOf(RouteBExternalReference r) {
    final library = r.receiverLibrary;
    final cls = r.receiverClass;
    return library == null || cls == null ? null : (library, cls);
  }

  /// Why a measured tear-off [key] (`...#tearoff:name`) is refused because its
  /// call form (the same key with `#tearoff:` replaced by `#`) is not
  /// accepted, or null for any other key and for a tear-off whose call form is
  /// accepted.
  ///
  /// The device probe of a tear-off creates the closure and never calls it,
  /// yet a patch that tears a member off can call it, and a member that
  /// aborts when called (`String.endsWith`) aborts through its tear-off too.
  /// The per-release snapshot profile does not stand in for this: it asks only
  /// whether the member has code, and `List.sort` has code on a `List.filled`
  /// list and still aborts.
  String? _tearoffRefusal(String key) {
    if (!key.contains('#tearoff:') ||
        !(measuredAccepted.contains(key) || members.contains(key))) {
      return null;
    }
    final call = key.replaceFirst('#tearoff:', '#');
    if (measuredAccepted.contains(call) || members.contains(call)) {
      return null;
    }
    final why = measuredFailing[call];
    return 'it is torn off, and calling it is not accepted '
        '(`${call.substring(call.indexOf('#') + 1)}`: '
        '${why == null ? 'never measured as a call' : 'measured: $why'}); the '
        'device probe of a tear-off never calls the closure';
  }

  /// Whether this release's snapshot resolves [key] on every VM class the
  /// measurement ran it on, or why not.
  ///
  /// The classes that can be the receiver are the release's subtypes of the
  /// key's own class, or of [receiver] (`library`, `class`) when the analysis
  /// named a narrower static type for it (a `for-in` over a `List` is never an
  /// `ObserverList`). A [receiver] this snapshot holds no class for narrows
  /// nothing: the key's class is asked, as before.
  String? _keptProblem(String key, {(String, String)? receiver}) {
    if (skipKeptCheck) return null;
    final snapshot = kept;
    if (snapshot == null) {
      return '${keptProblem ?? 'its snapshot profile is not available'}, so '
          'whether this release kept it cannot be checked';
    }
    final classes = measuredVmClasses[key];
    if (classes == null || classes.isEmpty) {
      return 'no VM class was measured for it';
    }
    // `library#Class#member`, or `dynamic#selector` (any class).
    final parts = key.split('#');
    final dynamicKey = parts.length == 2 && parts.first == 'dynamic';
    final narrowed =
        !dynamicKey &&
        receiver != null &&
        snapshot.hasClassIn(receiver.$1, receiver.$2);
    return snapshot.problemFor(
      declaredLibrary: dynamicKey
          ? null
          : narrowed
          ? receiver.$1
          : parts.first,
      declaredClass: dynamicKey
          ? null
          : narrowed
          ? receiver.$2
          : parts[1],
      measured: classes,
      selector: _selectorOf(key),
    );
  }

  /// `dart:core#Iterable#tearoff:map` -> `map`; `dynamic#get:length` ->
  /// `get:length`.
  static String _selectorOf(String key) {
    final last = key.substring(key.lastIndexOf('#') + 1);
    return last.startsWith('tearoff:') ? last.substring(8) : last;
  }

  static String _sdkKey(RouteBExternalReference r) =>
      '${r.library}#${r.className}#${r.member}';

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
      if (members.contains(key)) return !_manifestSkips(key);
      // The interface cannot list one, so the release's own snapshot answers:
      // a function in it with code is one the release itself calls, which is
      // what keeps it past the precompiler (a release that never called it
      // lacks it, and that is the case that aborts at load). A
      // `vm:entry-point` pragma retains one too, and is as callable. An
      // unnamed extension's `#N` name is its position in the library, which a
      // patch cannot shift (it cannot add an extension).
      return !r.isPrivate &&
          member != null &&
          (kept?.hasTopLevelFunction(r.library, member) ?? false);
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
      if (!r.isPrivate && _isVmPredefinedCore(r)) return true;
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

  /// The `dart:core` classes the VM itself defines before any library loads
  /// (`Object`, `Null`, `bool`, `int`, `double`, `num`, `String`): named as a
  /// TYPE, they need no interface item.
  ///
  /// The loader finds a class a patch names by looking it up in its library
  /// (`Unable to find class X in Library`). The VM predefines these class ids
  /// and the precompiler's class dropping starts above them, but the library
  /// dictionary entry can still be nulled when nothing reaches the class
  /// (`DropLibraryEntries`), so the rule is not structural: every Flutter app
  /// reaches all seven (the snapshot profile of release 1.0.0+34 holds all of
  /// them in `dart:core`, though its interface lists none of `bool`, `num` or
  /// `Null`). So when the release's snapshot profile is available it must hold
  /// the class node, and the predefined rule alone answers only when there is
  /// no profile. A patch cannot name one of their members this way (that is a
  /// member reference, answered by the interface); only the bare class.
  /// `dynamic` and `Never` are not classes and arrive as no reference.
  bool _isVmPredefinedCore(RouteBExternalReference r) {
    final name = r.className;
    if (r.library != 'dart:core' ||
        r.kind != 'class' ||
        name == null ||
        !const {
          'Object',
          'Null',
          'bool',
          'int',
          'double',
          'num',
          'String',
        }.contains(name)) {
      return false;
    }
    final snapshot = kept;
    return snapshot == null || snapshot.hasClassIn('dart:core', name);
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

  /// "the dart: method `String.toUpperCase` (an SDK instance member ...)".
  String _describeSdkInstance(RouteBExternalReference r, String why) {
    final how = why.isEmpty ? '' : ', $why';
    final torn = r.member?.startsWith('tearoff:') ?? false;
    final name = torn
        ? '${r.className}.${_bareSelector(r.member!)} torn off'
        : r.displayName;
    // "`Iterable.iterator` over a `List`": the loop's receiver (analysis 23).
    final receiver = _receiverOf(r)?.$2;
    final over = receiver == null
        ? ''
        : ' over ${_article(receiver)} `$receiver`';
    return 'the ${r.library.substring(0, r.library.indexOf(':'))}: method '
        '`$name`$over (an SDK instance member$how)';
  }

  /// "an" before `Iterable` or `_Array`, "a" before `List`.
  static String _article(String name) =>
      RegExp('^_*[aeiou]', caseSensitive: false).hasMatch(name) ? 'an' : 'a';

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
  List<String> unretained(
    RouteBCoverage coverage,
    Iterable<String> keys, {
    bool Function(RouteBExternalReference)? inlinedHolds,
  }) {
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
        if (refuse(r, inlinedHolds: inlinedHolds) case final why?) {
          out.add(why);
        }
      }
    }
    return out.toList();
  }

  static String _selector(String key) => key.substring(key.indexOf('#') + 1);

  /// [refusal] for [key] and the helpers its replacement library carries.
  String? refusalForTarget(
    RouteBCoverage coverage,
    String key, {
    bool Function(RouteBExternalReference)? inlinedHolds,
  }) => refusal(coverage, [
    key,
    ...coverage.helpersNeededBy(key),
  ], inlinedHolds: inlinedHolds);

  /// Why the members [keys] cannot be built, or null when the release kept
  /// everything they use.
  ///
  /// Null also when [coverage] predates analysis version 18 and so cannot say
  /// (see [routeBRetentionAnalysisVersion]); the caller decides what that
  /// means, and today it means a warning rather than a refusal.
  String? refusal(
    RouteBCoverage coverage,
    Iterable<String> keys, {
    bool Function(RouteBExternalReference)? inlinedHolds,
  }) {
    final all = unretained(coverage, keys, inlinedHolds: inlinedHolds);
    final sdk = all
        .where((d) => d.contains('(an SDK instance member'))
        .toList();
    final dynamicCalls = all
        .where((d) => d.contains('(a dynamic call'))
        .toList();
    final rest = all
        .where((d) => !sdk.contains(d) && !dynamicCalls.contains(d))
        .toList();
    return [
      ?describeRouteBUnretained(rest),
      ?describeRouteBUnprovenSdkMembers(sdk),
      ?describeRouteBDynamicCalls(dynamicCalls),
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
/// device-measured list or that this release did not keep, or null for an
/// empty [symbols].
String? describeRouteBUnprovenSdkMembers(List<String> symbols) {
  if (symbols.isEmpty) return null;
  const shown = 5;
  final named = symbols.take(shown).join(', ');
  final more = symbols.length > shown
      ? ', and ${symbols.length - shown} more'
      : '';
  return 'it calls $named$more. An SDK instance method is looked up by name '
      'when it runs, and the app throws NoSuchMethodError at that call if the '
      'release never called it. Members marked "measured" failed on a device, '
      'and those on no list were never measured: no flag unlocks '
      'either, because the patcher only lets through members '
      'measured on a device. Only a refusal because the snapshot of this '
      'release does not keep the member (or its snapshot profile could not be '
      'checked) is skipped by `--allow-unchecked-sdk-calls`. To use a refused '
      'member, call something else, or have it measured on a device and added '
      'to the patcher list${_heavyMemberAdvice(symbols)}';
}

/// The opt-in advice for the heavy SDK collection methods among [symbols], or
/// an empty string when none of them is named.
///
/// A symbol reads "the dart: method `Iterable.where` (an SDK instance member
/// ...)", so the heavy keys (`dart:core#Iterable.where`) are matched by their
/// `Class.member` display name.
String _heavyMemberAdvice(List<String> symbols) {
  final heavy = <String>{
    for (final key in routeBHeavySdkMembers)
      key.substring(key.indexOf('#') + 1).replaceFirst('get:', ''),
  };
  final named = heavy
      .where(
        (name) => symbols.any(
          // Only the call form: the opt-in keeps a member for calls, and a
          // tear-off is still refused until its call form is measured.
          (s) => s.contains('`$name`'),
        ),
      )
      .toList();
  if (named.isEmpty) return '';
  final verb = named.length == 1 ? 'is' : 'are';
  return '. ${named.join(', ')} $verb kept by a release only when '
      'shorebird.yaml sets $routeBKeepCollectionMethodsKey: true, so if this '
      'release did not keep it, set that and cut a new release';
}

/// The refusal for a patch that calls members by name on a `dynamic` value
/// that cannot be shown to be kept, or null for an empty [symbols].
String? describeRouteBDynamicCalls(List<String> symbols) {
  if (symbols.isEmpty) return null;
  const shown = 5;
  final named = symbols.take(shown).join(', ');
  final more = symbols.length > shown
      ? ', and ${symbols.length - shown} more'
      : '';
  return 'it makes $named$more. A call on a `dynamic` value is looked up by '
      'name when it runs, on whatever class the value turns out to be, and the '
      'app throws NoSuchMethodError at that call if the release never made it '
      'on that class. Cut a new release whose own code makes the same call, '
      'then patch that';
}

/// The refusal for a release whose interface is missing or unreadable, when the
/// analysis is of a version that can check against one.
const routeBNoInterfaceReason =
    'this release uploaded no readable dynamic interface, so whether it kept '
    'the symbols this patch uses cannot be established. A symbol that cannot '
    'be shown to be kept is not kept. Cut a new release with a current CLI and '
    'patch that instead';
