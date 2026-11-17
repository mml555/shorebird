import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

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
  RouteBSnapshotKept._(this._functions, this._super);

  /// Reads a snapshot profile. Throws a [FormatException] for anything that is
  /// not one.
  factory RouteBSnapshotKept.fromProfileJson(String text) {
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
    final fType = nodeFields.indexOf('type');
    final fName = nodeFields.indexOf('name');
    final fCount = nodeFields.indexOf('edge_count');
    final eTo = edgeFields.indexOf('to_node');
    if (fType < 0 || fName < 0 || fCount < 0 || eTo < 0) {
      throw const FormatException(
        'the snapshot profile lacks type, name, edge_count or to_node',
      );
    }
    final nf = nodeFields.length;
    final ef = edgeFields.length;
    final classType = nodeTypes.indexOf('Class');
    final functionType = nodeTypes.indexOf('Function');
    final arrayType = nodeTypes.indexOf('Array');
    final codeType = nodeTypes.indexOf('Code');
    final typeType = nodeTypes.indexOf('Type');
    if (<int>[classType, functionType, arrayType, codeType, typeType].any(
      (i) => i < 0,
    )) {
      throw const FormatException(
        'the snapshot profile does not name Class, Function, Array, Code and '
        'Type nodes',
      );
    }
    final count = nodes.length ~/ nf;
    final first = List<int>.filled(count + 1, 0);
    for (var i = 0; i < count; i++) {
      first[i + 1] = first[i] + (nodes[i * nf + fCount] as int);
    }
    int typeOf(int i) => nodes[i * nf + fType] as int;
    String nameOf(int i) => strings[nodes[i * nf + fName] as int] as String;
    int target(int edge) => (edges[edge * ef + eTo] as int) ~/ nf;

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

    final functions = <String, Map<String, bool>>{};
    final supers = <String, String>{};
    for (var i = 0; i < count; i++) {
      if (typeOf(i) != classType) continue;
      final cls = _className(nameOf(i));
      var superSeen = false;
      final own = functions.putIfAbsent(cls, () => {});
      for (var e = first[i]; e < first[i + 1]; e++) {
        final t = target(e);
        final type = typeOf(t);
        if (type == arrayType) {
          for (var f = first[t]; f < first[t + 1]; f++) {
            final fn = target(f);
            if (typeOf(fn) != functionType) continue;
            final name = nameOf(fn);
            own[name] = (own[name] ?? false) || hasRealCode(fn);
          }
        } else if (type == typeType && !superSeen) {
          // A class's first Type edge is its super type, and the Type points
          // at the super class; the class's own declaration type comes after.
          for (var s = first[t]; s < first[t + 1]; s++) {
            final sc = target(s);
            if (typeOf(sc) == classType) {
              final name = _className(nameOf(sc));
              if (name != cls) {
                supers.putIfAbsent(cls, () => name);
                superSeen = true;
                break;
              }
            }
          }
        }
      }
    }
    return RouteBSnapshotKept._(functions, supers);
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
    if (actual != expectedSha256) {
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
    } on FormatException catch (error) {
      return (
        kept: null,
        problem: '$routeBSnapshotProfileName is unreadable (${error.message})',
      );
    }
  }

  /// The profile's file name in a release's artifacts.
  static const routeBSnapshotProfileName = 'route_b_snapshot_profile.json';

  final Map<String, Map<String, bool>> _functions;
  final Map<String, String> _super;

  /// Whether the snapshot has a class named [name] (private-library suffix
  /// ignored).
  bool hasClass(String name) => _functions.containsKey(name);

  /// Looks [member] up the way the VM does for a call by name on an instance
  /// of [cls]: the class, then each super class. True: a function with real
  /// code. False: a function with only a lazy-compile stub (it stops the app).
  /// Null: no function of that name on the chain (a NoSuchMethodError).
  bool? resolves(String cls, String member) {
    String? current = cls;
    for (var depth = 0; current != null && depth < 64; depth++) {
      final own = _functions[current];
      if (own != null && own.containsKey(member)) return own[member];
      current = _super[current];
    }
    return null;
  }

  /// `_OneByteString@0150898` -> `_OneByteString`.
  static String _className(String raw) => raw.replaceFirst(
    RegExp(r'@\d+$'),
    '',
  );
}
