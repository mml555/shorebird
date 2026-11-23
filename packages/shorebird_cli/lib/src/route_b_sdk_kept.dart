// cspell:words ifaces
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shorebird_cli/src/route_b_sdk_base_classes.dart';

/// What a release's own snapshot kept, read from the v8 snapshot profile that
/// `gen_snapshot --write-v8-snapshot-profile-to` wrote at release time
/// (`route_b_snapshot_profile.json`).
///
/// An instance member of a `dart:` class is bound by selector when the patch
/// runs: the VM looks the name up in the receiver's class, then its super
/// classes, and only finds a function the precompiler left in that class's
/// function list. A function that is in the list but has only a lazy-compile
/// stub for code stops the app ("Attempt to compile function"). Both facts are
/// in the profile: a `Class` node points at an `Array` of its `Function`
/// nodes, and each `Function` points at its `Code`.
///
/// Classes are identified by their node in the profile, never by name: the
/// profile has several classes of one name in different libraries (a user
/// `_List` beside the SDK's), and a lookup that merged them could report a
/// member the SDK class does not have. Only the edges named `functions_`,
/// `super_type_` and `interfaces_` are read; the invocation-dispatcher cache,
/// method extractors and hash tables are ignored.
///
/// Measured on the iPhone 7 / cell 2fc41d3f counter release (PR #216), for the
/// seven runtime classes that could be mapped to VM classes: every device
/// RESOLVES was a resolved function with real code, and every device
/// NoSuchMethodError was a function missing from the chain. Two cases it gets
/// wrong the unsafe way: `List.sort` and `Iterable.contains` on a
/// `List.filled` list resolve here (real code) and abort on the device. So
/// this is NECESSARY, not sufficient: it is asked together with the measured
/// list, never instead of it. It also refuses a few members the device
/// resolved without a lookup (int and double operators), which is the safe
/// direction.
class RouteBSnapshotKept {
  RouteBSnapshotKept._(
    this._name,
    this._library,
    this._functions,
    this._hasCode,
    this._super,
    this._interfaces,
    this._allocated,
  );

  /// Reads a snapshot profile. Throws a [FormatException] for anything that is
  /// not one, including a table whose shape is wrong.
  factory RouteBSnapshotKept.fromProfileJson(String text) {
    try {
      return RouteBSnapshotKept._decode(text);
    } on FormatException {
      rethrow;
      // A malformed table surfaces as a TypeError or RangeError; it is the
      // same answer, "not a snapshot profile".
    } catch (error) {
      throw FormatException('the snapshot profile is malformed ($error)');
    }
  }

  factory RouteBSnapshotKept._decode(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw FormatException(
        'the snapshot profile is not JSON: ${error.message}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('the snapshot profile is not an object');
    }
    final snapshot = decoded['snapshot'];
    final meta = snapshot is Map ? snapshot['meta'] : null;
    final nodes = decoded['nodes'];
    final edges = decoded['edges'];
    final strings = decoded['strings'];
    if (meta is! Map ||
        nodes is! List ||
        edges is! List ||
        strings is! List ||
        meta['node_fields'] is! List ||
        meta['edge_fields'] is! List ||
        meta['edge_types'] is! List ||
        (meta['edge_types'] as List).isEmpty ||
        (meta['edge_types'] as List).first is! List ||
        meta['node_types'] is! List ||
        (meta['node_types'] as List).isEmpty ||
        (meta['node_types'] as List).first is! List) {
      throw const FormatException(
        'the snapshot profile has no node and edge tables',
      );
    }
    final nodeFields = (meta['node_fields'] as List).cast<String>();
    final edgeFields = (meta['edge_fields'] as List).cast<String>();
    final nodeTypes = ((meta['node_types'] as List).first as List)
        .cast<String>();
    final edgeTypes = ((meta['edge_types'] as List).first as List)
        .cast<String>();
    final fType = nodeFields.indexOf('type');
    final fName = nodeFields.indexOf('name');
    final fCount = nodeFields.indexOf('edge_count');
    final eType = edgeFields.indexOf('type');
    final eName = edgeFields.indexOf('name_or_index');
    final eTo = edgeFields.indexOf('to_node');
    final propertyEdge = edgeTypes.indexOf('property');
    if (fType < 0 ||
        fName < 0 ||
        fCount < 0 ||
        eType < 0 ||
        eName < 0 ||
        eTo < 0 ||
        propertyEdge < 0) {
      throw const FormatException(
        'the snapshot profile lacks type, name, edge_count, name_or_index, '
        'to_node or property edges',
      );
    }
    final nf = nodeFields.length;
    final ef = edgeFields.length;
    final classType = nodeTypes.indexOf('Class');
    final functionType = nodeTypes.indexOf('Function');
    final arrayType = nodeTypes.indexOf('Array');
    final codeType = nodeTypes.indexOf('Code');
    final typeType = nodeTypes.indexOf('Type');
    final libraryType = nodeTypes.indexOf('Library');
    if (<int>[
      classType,
      functionType,
      arrayType,
      codeType,
      typeType,
      libraryType,
    ].any((i) => i < 0)) {
      throw const FormatException(
        'the snapshot profile does not name Class, Function, Array, Code, '
        'Type and Library nodes',
      );
    }
    if (nodes.length % nf != 0 || edges.length % ef != 0) {
      throw const FormatException(
        'the snapshot profile node or edge table is not a whole number of '
        'rows',
      );
    }
    final count = nodes.length ~/ nf;
    final edgeCount = edges.length ~/ ef;
    // Validate every cell the walk below will read.
    final first = List<int>.filled(count + 1, 0);
    for (var i = 0; i < count; i++) {
      final type = nodes[i * nf + fType];
      final name = nodes[i * nf + fName];
      final n = nodes[i * nf + fCount];
      if (type is! int ||
          type < 0 ||
          type >= nodeTypes.length ||
          name is! int ||
          name < 0 ||
          name >= strings.length ||
          strings[name] is! String ||
          n is! int ||
          n < 0) {
        throw FormatException('the snapshot profile node $i is malformed');
      }
      first[i + 1] = first[i] + n;
    }
    if (first[count] != edgeCount) {
      throw const FormatException(
        'the snapshot profile node edge counts do not add up to its edges',
      );
    }
    for (var e = 0; e < edgeCount; e++) {
      final to = edges[e * ef + eTo];
      final type = edges[e * ef + eType];
      final name = edges[e * ef + eName];
      if (to is! int ||
          to < 0 ||
          to % nf != 0 ||
          to ~/ nf >= count ||
          type is! int ||
          name is! int ||
          name < 0 ||
          (type == propertyEdge && name >= strings.length)) {
        throw FormatException('the snapshot profile edge $e is malformed');
      }
    }
    int typeOf(int i) => nodes[i * nf + fType] as int;
    String nameOf(int i) => strings[nodes[i * nf + fName] as int] as String;
    int target(int edge) => (edges[edge * ef + eTo] as int) ~/ nf;
    String? propertyOf(int edge) => edges[edge * ef + eType] == propertyEdge
        ? strings[edges[edge * ef + eName] as int] as String
        : null;

    // Function node -> does it have code that is not a lazy-compile stub.
    final realCode = <int, bool>{};
    bool hasRealCode(int function) => realCode.putIfAbsent(function, () {
      for (var e = first[function]; e < first[function + 1]; e++) {
        final t = target(e);
        if (typeOf(t) == codeType && !nameOf(t).startsWith('[Stub]')) {
          return true;
        }
      }
      return false;
    });

    // The class a Type node names: its first edge to a Class.
    int? classOfType(int type) {
      if (typeOf(type) != typeType) return null;
      for (var e = first[type]; e < first[type + 1]; e++) {
        final t = target(e);
        if (typeOf(t) == classType) return t;
      }
      return null;
    }

    final names = <int, String>{};
    final libraries = <int, String>{};
    final functions = <int, Map<String, bool>>{};
    final hasCode = <int, bool>{};
    final supers = <int, int>{};
    final interfaces = <int, List<int>>{};
    for (var c = 0; c < count; c++) {
      if (typeOf(c) != classType) continue;
      names[c] = _className(nameOf(c));
      libraries[c] = '';
      final own = functions[c] = {};
      var code = false;
      final ifaces = interfaces[c] = [];
      for (var e = first[c]; e < first[c + 1]; e++) {
        final property = propertyOf(e);
        final t = target(e);
        switch (property) {
          case 'library_':
            if (typeOf(t) == libraryType) libraries[c] = nameOf(t);
          case 'functions_':
            if (typeOf(t) != arrayType) break;
            for (var f = first[t]; f < first[t + 1]; f++) {
              final fn = target(f);
              if (typeOf(fn) != functionType) continue;
              final real = hasRealCode(fn);
              code = code || real;
              // Entries of one name must all have code.
              own[nameOf(fn)] = (own[nameOf(fn)] ?? true) && real;
            }
          case 'super_type_':
            final sc = classOfType(t);
            if (sc != null && sc != c) supers[c] = sc;
          case 'interfaces_' || 'mixin_':
            if (typeOf(t) == arrayType) {
              for (var f = first[t]; f < first[t + 1]; f++) {
                final ic = classOfType(target(f));
                if (ic != null && ic != c) ifaces.add(ic);
              }
            } else {
              final ic = classOfType(t);
              if (ic != null && ic != c) ifaces.add(ic);
            }
        }
      }
      hasCode[c] = code;
    }
    // Classes this release is SEEN to make instances of: the owner of an
    // allocation stub (`[Stub] Allocate <class>`, what compiled code calls to
    // allocate one; the generic stubs such as `AllocateObjectSlow` have no
    // space after `Allocate` and no class owner), or the class of an object
    // stored in the snapshot (any node with a `<class>` edge; in practice
    // only `Instance` nodes have one, so a const `Array`, `Map`, `Set`,
    // closure, double or typed-data object is not counted, and all of those
    // classes are leaves). An abstract class has neither; the VM's fixed-id
    // classes may have neither too (see [routeBVmFixedIdClasses]).
    if (!nodeTypes.contains('Instance')) {
      throw const FormatException(
        'the snapshot profile has no Instance nodes, so the classes the '
        'release allocates cannot be read',
      );
    }
    final allocated = <int>{};
    var stubs = 0;
    for (var i = 0; i < count; i++) {
      final stub =
          typeOf(i) == codeType && nameOf(i).startsWith('[Stub] Allocate ');
      for (var e = first[i]; e < first[i + 1]; e++) {
        final t = target(e);
        if (typeOf(t) != classType) continue;
        final property = propertyOf(e);
        if (stub && property == 'owner_') {
          allocated.add(t);
          stubs++;
        } else if (property == '<class>') {
          allocated.add(t);
        }
      }
    }
    // Without them every base class would read as never allocated, and the
    // check would quietly skip concrete base classes (#249).
    if (stubs == 0) {
      throw const FormatException(
        'the snapshot profile has no allocation stub owned by a class '
        '(`[Stub] Allocate` with an `owner_` edge), so the classes the '
        'release allocates cannot be read',
      );
    }
    return RouteBSnapshotKept._(
      names,
      libraries,
      functions,
      hasCode,
      supers,
      interfaces,
      allocated,
    );
  }

  /// Reads the profile at [file]. [expectedSha256] is the digest the release's
  /// provenance recorded for it; a file that does not hash to it is not the
  /// release's profile.
  ///
  /// Returns the profile, or a plain-words problem. Never both.
  static ({RouteBSnapshotKept? kept, String? problem}) read(
    File? file, {
    required String? expectedSha256,
  }) {
    if (file == null || !file.existsSync()) {
      return (
        kept: null,
        problem: 'this release uploaded no $routeBSnapshotProfileName',
      );
    }
    final bytes = file.readAsBytesSync();
    if (expectedSha256 == null) {
      return (
        kept: null,
        problem:
            'this release recorded no digest for $routeBSnapshotProfileName, '
            "so it cannot be shown to be the release's own",
      );
    }
    final actual = sha256.convert(bytes).toString();
    if (actual.toLowerCase() != expectedSha256.toLowerCase()) {
      return (
        kept: null,
        problem:
            '$routeBSnapshotProfileName does not match the digest the release '
            'recorded for it',
      );
    }
    try {
      return (
        kept: RouteBSnapshotKept.fromProfileJson(utf8.decode(bytes)),
        problem: null,
      );
      // Anything a hashing-but-malformed file throws is "unreadable".
      // ignore: avoid_catches_without_on_clauses
    } catch (error) {
      final why = error is FormatException ? error.message : '$error';
      return (
        kept: null,
        problem: '$routeBSnapshotProfileName is unreadable ($why)',
      );
    }
  }

  /// The profile's file name in a release's artifacts.
  static const routeBSnapshotProfileName = 'route_b_snapshot_profile.json';

  final Map<int, String> _name;
  final Map<int, String> _library;
  final Map<int, Map<String, bool>> _functions;
  final Map<int, bool> _hasCode;
  final Map<int, int> _super;
  final Map<int, List<int>> _interfaces;

  /// The classes this release is seen to allocate (an allocation stub, or a
  /// const instance in the snapshot). Never an abstract class; not every
  /// concrete one.
  final Set<int> _allocated;
  Map<int, List<int>>? _subs;

  /// The `dart:` classes named [name] (private-library suffix ignored).
  List<int> _sdkClasses(String name, [String? library]) => [
    for (final e in _name.entries)
      if (e.value == name &&
          (library == null
              ? _library[e.key]!.startsWith('dart:')
              : _library[e.key] == library))
        e.key,
  ];

  /// Whether this snapshot holds a top-level function [name] of [library] with
  /// real code: the precompiler kept it, because something the release runs
  /// calls it. An extension getter, setter or tear-off (`Stars|get#stars`) is a
  /// top-level function of its library, and the only evidence a release has
  /// kept one: no interface lists a `#` name.
  bool hasTopLevelFunction(String library, String name) {
    for (final e in _name.entries) {
      if (e.value == '::' &&
          _library[e.key] == library &&
          (_functions[e.key]?[name] ?? false)) {
        return true;
      }
    }
    return false;
  }

  /// Whether the snapshot has a class named [name] in [library].
  bool hasClassIn(String library, String name) =>
      _sdkClasses(name, library).isNotEmpty;

  /// Whether the snapshot has a `dart:` class named [name].
  bool hasClass(String name) => _sdkClasses(name).isNotEmpty;

  /// The library of each class named [name], for messages and tests.
  List<String> librariesOf(String name) => [
    for (final e in _name.entries)
      if (e.value == name) _library[e.key]!,
  ];

  /// Looks [member] up the way the VM does for a call by name on an instance
  /// of class node [cls]: the class, then each super class. True: a function
  /// with real code. False: a function with only a lazy-compile stub (it stops
  /// the app). Null: no function of that name on the chain (a
  /// NoSuchMethodError), or a chain that loops or runs past 64 classes.
  bool? _resolvesOn(int cls, String member) {
    int? current = cls;
    final seen = <int>{};
    for (var depth = 0; current != null && depth < 64; depth++) {
      if (!seen.add(current)) return null;
      final own = _functions[current];
      if (own != null && own.containsKey(member)) return own[member];
      current = _super[current];
    }
    return null;
  }

  /// [_resolvesOn] for the `dart:` classes named [cls]: every one must resolve.
  /// Null when the snapshot has no such class.
  bool? resolves(String cls, String member) {
    final classes = _sdkClasses(cls);
    if (classes.isEmpty) return null;
    bool? result = true;
    for (final c in classes) {
      final r = _resolvesOn(c, member);
      if (r == null) return null;
      if (!r) result = false;
    }
    return result;
  }

  Map<int, List<int>> get _subtypeEdges => _subs ??= () {
    final map = <int, List<int>>{};
    for (final e in _super.entries) {
      map.putIfAbsent(e.value, () => []).add(e.key);
    }
    for (final e in _interfaces.entries) {
      for (final i in e.value) {
        map.putIfAbsent(i, () => []).add(e.key);
      }
    }
    return map;
  }();

  /// Whether class node [c]'s super chain reaches `Object`. A pseudo-class the
  /// VM makes for a library's top-level members has no super and no instances.
  bool _reachesObject(int c) {
    int? current = c;
    final seen = <int>{};
    for (var depth = 0; current != null && depth < 64; depth++) {
      if (!seen.add(current)) return false;
      if (_name[current] == 'Object' && _library[current] == 'dart:core') {
        return true;
      }
      current = _super[current];
    }
    return false;
  }

  /// The classes that can hold an instance whose declared type is one of
  /// [roots] (the profile's class nodes for the declared type): every class
  /// whose super or interface chain reaches a root, reaches `Object`, and is
  /// either seen allocated or may be concrete ([_mayBeConcrete]) and has a
  /// function with real code ([_isInstanceClass]).
  ///
  /// The profile does not flag abstract classes. An interface (`List`) or an
  /// abstract base has no code for the members it only declares, and would
  /// refuse every member; but it has no instances. A concrete base class
  /// (`MappedIterable`, under `EfficientLengthMappedIterable`) that lacks a
  /// member its subclasses keep must be refused (#249).

  Set<int> _instanceClasses(Iterable<int> roots) {
    final subs = _subtypeEdges;
    final seen = <int>{...roots};
    final queue = [...roots];
    while (queue.isNotEmpty) {
      final c = queue.removeLast();
      for (final s in subs[c] ?? const <int>[]) {
        if (seen.add(s)) queue.add(s);
      }
    }
    return {
      for (final c in seen)
        if (_isInstanceClass(c)) c,
    };
  }

  /// A class seen allocated ([_allocated]) is one whether or not it has
  /// compiled code of its own: a class whose members are all inherited or
  /// inlined (`CastIterable`, `EfficientLengthMappedIterable`, `Tween`) has
  /// none, and its instances still take every call its declared types allow.
  /// Any other class needs own code too, which skips one kept only as a type.
  bool _isInstanceClass(int c) =>
      _reachesObject(c) &&
      (_allocated.contains(c) || (_mayBeConcrete(c) && (_hasCode[c] ?? false)));

  /// A HEURISTIC (the profile does not flag abstract classes; #253 takes it
  /// from the release kernel instead). A class may be concrete when it is:
  ///   * a leaf (no other class extends, implements or mixes it in): the VM
  ///     allocates some leaves (`_List`, `_OneByteString`) with no stub, so a
  ///     leaf is asked even with no allocation seen;
  ///   * a class the release is seen to allocate ([_allocated]);
  ///   * a `dart:` base class the VM allocates with no per-class stub (one in
  ///     [routeBVmFixedIdClasses]) that is not known abstract.
  /// Any other base class with no allocation seen has no instance: compiled
  /// code allocates an ordinary class only through its own stub (see
  /// `route_b_sdk_base_classes.dart`).
  bool _mayBeConcrete(int c) =>
      !_subtypeEdges.containsKey(c) ||
      _allocated.contains(c) ||
      isVmAllocatedSdkClass(_library[c]!, _name[c]!);

  /// Whether `dart:` class [name] of [library] is one the VM allocates with
  /// no per-class stub ([routeBVmFixedIdClasses]) and is not known abstract.
  static bool isVmAllocatedSdkClass(String library, String name) =>
      routeBVmFixedIdClasses.contains('$library#$name') &&
      !isKnownAbstractSdkClass(library, name);

  /// Whether `dart:` class [name] of [library] is known to be abstract: an
  /// anonymous mixin application (`A&B`, always abstract), or listed in
  /// [routeBSdkAbstractBases].
  static bool isKnownAbstractSdkClass(String library, String name) =>
      name.contains('&') || routeBSdkAbstractBases.contains('$library#$name');

  /// The `dart:` base classes with real code that reach `Object` and that
  /// this release is not seen to allocate, as `library<TAB>Class`, sorted: the
  /// classes `route_b_sdk_base_classes.dart` decides. Pinned for one release in
  /// `test/fixtures/route_b_sdk_kept/stubless_sdk_bases.tsv`. Only classes
  /// with code are listed: one seen allocated is asked with or without code
  /// ([_isInstanceClass]), and one not seen allocated is asked only with code,
  /// so a code-less one never needs deciding.
  List<String> get stublessSdkBases => [
    for (final c in _name.keys)
      if (_subtypeEdges.containsKey(c) &&
          !_allocated.contains(c) &&
          (_hasCode[c] ?? false) &&
          _library[c]!.startsWith('dart:') &&
          _reachesObject(c))
        '${_library[c]}\t${_name[c]}',
  ]..sort();

  /// How many base classes this release is seen to allocate that reach
  /// `Object`: the base classes [problemFor] asks because they are allocated.
  /// Zero would mean the allocation evidence was not read.
  int get allocatedBaseClassCount => _allocated
      .where((c) => _subtypeEdges.containsKey(c) && _reachesObject(c))
      .length;

  /// Why this release's snapshot cannot be shown to resolve [selector] for a
  /// call on a value of declared type [declaredClass] in [declaredLibrary]
  /// (both null for `dynamic`: any class), or null when it can.
  ///
  /// It must resolve with real code on (a) every `dart:` class the member was
  /// measured on ([measured]), and (b) every class in this snapshot that is a
  /// subtype of the declared type and can hold instances. The receiver is
  /// always one of these: the release's classes are fixed, and a patch cannot
  /// add a class (the analyzer refuses one: `analyze_coverage.dart`,
  /// `_instanceHelperReason` and the `declaration` category). A declared type
  /// with no class in the snapshot is refused.
  String? problemFor({
    required String? declaredLibrary,
    required String? declaredClass,
    required List<String> measured,
    required String selector,
  }) {
    // A class the device measured the member on, and this release's snapshot
    // does not hold at all, is skipped: the receiver cannot be one. The
    // precompiler drops a class only when nothing allocates it (it asserts
    // `!is_allocated()` and keeps the super classes of every allocated one),
    // so a class with no node has no instance. A patch can make one only by
    // allocating it, and two kinds of allocation reach it:
    //   * a constructor, factory or static of the SDK (`Iterable.generate`,
    //     `List.generate`): a reference `_retained` answers by name, and a
    //     kept function with code that allocates the class would have kept it;
    //   * a language construct with no constructor reference in the kernel
    //     (`sync*`, `async*`, a const list, map or set literal, a record, a
    //     closure): the analyzer reports no reference for it. Those classes
    //     are [_neverSkipped], and so are the classes the VM predefines, which
    //     any real profile holds, so one missing says the profile is wrong.
    // At least one measured class that is neither must be present before any
    // is skipped, so a profile that is wrong or lacks classes still refuses;
    // every candidate receiver class is checked below.
    String? firstNeverSkipped;
    String? absent;
    var presentOrdinary = 0;
    for (final name in measured) {
      final classes = _sdkClasses(name);
      if (classes.isEmpty) {
        if (_neverSkipped(name)) {
          firstNeverSkipped ??= name;
        } else {
          absent ??= name;
        }
        continue;
      }
      if (!_neverSkipped(name)) presentOrdinary++;
      for (final c in classes) {
        final why = _problemOn(c, selector);
        if (why != null) return why;
      }
    }
    if (firstNeverSkipped != null) {
      return 'this release has no class `$firstNeverSkipped`';
    }
    if (absent != null && presentOrdinary == 0) {
      return 'this release has no class `$absent`';
    }
    final Iterable<int> candidates;
    var roots = const <int>[];
    if (declaredClass == null) {
      candidates = _name.keys.where(_isInstanceClass);
    } else {
      roots = _sdkClasses(declaredClass, declaredLibrary);
      // A declared type this snapshot has no class for (or only in another
      // library) cannot be shown to resolve anything: there is nothing to
      // check, which is not the same as nothing to fear. Refuse.
      if (roots.isEmpty) {
        return 'this release has no class `$declaredClass`'
            '${declaredLibrary == null ? '' : ' in `$declaredLibrary`'}';
      }
      candidates = _instanceClasses(roots);
    }
    String? firstWhy;
    int? firstClass;
    var more = 0;
    for (final c in candidates) {
      final why = _problemOn(
        c,
        selector,
        subtypeOf: declaredClass ?? 'dynamic',
      );
      if (why == null) continue;
      if (firstWhy == null) {
        firstWhy = why;
        firstClass = c;
      } else {
        more++;
      }
    }
    if (firstWhy == null) return null;
    final refusal = more == 0 ? firstWhy : '$firstWhy, and $more more';
    if (declaredClass == null || roots.contains(firstClass)) return refusal;
    final advice = _subtypeAdvice(
      declaredClass,
      _name[firstClass]!,
      selector,
    );
    return '$refusal. $advice';
  }

  /// Why a member the declared type has is refused for one of its subtypes,
  /// and what the patch can do instead.
  static String _subtypeAdvice(
    String declared,
    String subtype,
    String selector,
  ) {
    final advice = StringBuffer(
      'A `$declared` value can be a `$subtype` at runtime, and this release '
      'compiled no `$selector` for `$subtype` because nothing in it calls '
      '`$selector` on one; a release built with the code that calls it '
      'keeps it',
    );
    // `await` is no way out: awaiting a `_Future` (what `async` code and the
    // SDK return) goes through `_Future._thenAwait`, but awaiting any other
    // `Future` calls its `then` (`_SuspendState._awaitUserDefinedFuture` in
    // `sdk/lib/_internal/vm/lib/async_patch.dart`), and the analysis cannot
    // tell the two apart from the static type `Future`, so it is checked as a
    // call of `then` (analysis 24).
    if (declared == 'Future' && selector == 'then') {
      advice.write(
        '. An `await` on a `Future` is checked the same way, since awaiting '
        'a `$subtype` calls its `then`',
      );
    }
    return advice.toString();
  }

  /// Classes whose absence from a profile is never read as "no instance".
  ///
  /// The VM predefines these class ids and allocates them from native code, so
  /// every real profile holds them. The rest are allocated by the compiler for
  /// a language construct, with no constructor reference a patch's analysis
  /// reports (class names from the VM's `lib/` sources): `sync*`
  /// (`_SyncStarIterable`, `_SyncStarIterator`), `async*`
  /// (`_AsyncStarStreamController`), const literals (`_ImmutableList`,
  /// `_ConstMap`, `_ConstSet`), records (`_Record`, and its per-shape
  /// subclasses `_Record_N...`) and closures (`_Closure`).
  static bool _neverSkipped(String name) =>
      name.startsWith('_Record') || _neverSkippedNames.contains(name);

  static const _neverSkippedNames = {
    // Predefined by the VM.
    'Object', 'Null', 'bool', '_Smi', '_Mint', '_Double', '_List', '_Array',
    '_GrowableList', '_OneByteString', '_TwoByteString',
    // Allocated by the compiler for a language construct.
    '_SyncStarIterable', '_SyncStarIterator', '_AsyncStarStreamController',
    '_ImmutableList', '_ConstMap', '_ConstSet', '_Closure',
  };

  String? _problemOn(int cls, String selector, {String? subtypeOf}) {
    final r = _resolvesOn(cls, selector);
    if (r ?? false) return null;
    final name = _name[cls]!;
    final library = _library[cls]!;
    // A class found only because it can be the declared type is named with its
    // library: it may be the app's own.
    final where = subtypeOf == null
        ? ''
        : ' (${library.isEmpty ? 'a class' : 'in `$library`'} that can be a '
              '`$subtypeOf` here)';
    return r == false
        ? 'this release has `$name.$selector` without compiled code$where'
        : 'this release has no `$selector` on `$name`$where';
  }

  /// `_OneByteString@0150898` -> `_OneByteString`.
  static String _className(String raw) =>
      raw.replaceFirst(RegExp(r'@\d+$'), '');
}
