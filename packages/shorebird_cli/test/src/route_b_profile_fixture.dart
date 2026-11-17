// cspell:words tearoff
import 'dart:convert';

/// One class of a synthetic profile. [fns] maps a function name to the name of
/// its code (`[Stub] ...` is a lazy-compile stub; null is no code at all).
/// [decoys] are functions in the invocation-dispatcher cache, which a lookup by
/// name must not see.
class RouteBProfileClass {
  const RouteBProfileClass(
    this.name,
    this.library, {
    this.fns = const {},
    this.parent,
    this.ifaces = const [],
    this.decoys = const {},
  });
  final String name;
  final String library;
  final Map<String, String?> fns;
  final String? parent;
  final List<String> ifaces;
  final Map<String, String?> decoys;
}

/// A minimal v8 snapshot profile in the shape `gen_snapshot` writes. A class is
/// a `Class` node with named property edges: `declaration_type_` (a Type of
/// itself, FIRST on purpose), `interfaces_`, `super_type_`, `library_`,
/// `functions_` and `invocation_dispatcher_cache_`. [classes] is keyed by a
/// unique id; a class's `parent` and `ifaces` name ids.
String routeBProfile(Map<String, RouteBProfileClass> classes) {
  const types = [
    'ArtificialRoot',
    'Array',
    'Code',
    'Function',
    'Class',
    'Type',
    'Library',
    'Other',
  ];
  const edgeTypes = ['context', 'element', 'property', 'internal'];
  final strings = <String>[];
  int str(String s) {
    final i = strings.indexOf(s);
    if (i >= 0) return i;
    strings.add(s);
    return strings.length - 1;
  }

  // (edge type, name or index, target)
  final nodes = <({int type, String name, List<(int, String, int)> to})>[];
  int add(String type, String name, [List<(int, String, int)>? to]) {
    nodes.add((type: types.indexOf(type), name: name, to: to ?? []));
    return nodes.length - 1;
  }

  (int, String, int) prop(String name, int to) => (2, name, to);
  (int, String, int) element(int i, int to) => (1, '$i', to);

  final classIndex = <String, int>{};
  for (final entry in classes.entries) {
    classIndex[entry.key] = add('Class', entry.value.name);
  }
  final libraries = <String, int>{};
  int library(String name) => libraries.putIfAbsent(
    name,
    () => add('Library', name),
  );
  int typeOf(String id) {
    final code = add('Code', '[Stub] DefaultTypeTest');
    return add('Type', 'Unnamed [Type]', [
      prop('c', classIndex[id]!),
      prop('code', code),
    ]);
  }

  int functions(Map<String, String?> fns, int owner) {
    final fnNodes = <int>[];
    for (final fn in fns.entries) {
      final edges = <(int, String, int)>[prop('owner', owner)];
      if (fn.value != null) edges.add(prop('code', add('Code', fn.value!)));
      fnNodes.add(add('Function', fn.key, edges));
    }
    return add('Array', 'Unnamed [Array]', [
      for (var k = 0; k < fnNodes.length; k++) element(k, fnNodes[k]),
    ]);
  }

  for (final entry in classes.entries) {
    final c = entry.value;
    final self = classIndex[entry.key]!;
    final to = <(int, String, int)>[
      prop('declaration_type_', typeOf(entry.key)),
    ];
    if (c.ifaces.isNotEmpty) {
      to.add(
        prop(
          'interfaces_',
          add('Array', 'Unnamed [Array]', [
            for (var k = 0; k < c.ifaces.length; k++)
              element(k, typeOf(c.ifaces[k])),
          ]),
        ),
      );
    }
    if (c.parent != null) to.add(prop('super_type_', typeOf(c.parent!)));
    to
      ..add(prop('library_', library(c.library)))
      ..add(prop('functions_', functions(c.fns, self)));
    if (c.decoys.isNotEmpty) {
      to.add(
        prop('invocation_dispatcher_cache_', functions(c.decoys, self)),
      );
    }
    nodes[self] = (type: nodes[self].type, name: nodes[self].name, to: to);
  }
  final flatNodes = <int>[];
  final flatEdges = <int>[];
  for (var i = 0; i < nodes.length; i++) {
    flatNodes.addAll([
      nodes[i].type,
      str(nodes[i].name),
      i,
      0,
      nodes[i].to.length,
    ]);
    for (final (type, name, target) in nodes[i].to) {
      flatEdges.addAll([
        type,
        if (type == 2) str(name) else int.parse(name),
        target * 5,
      ]);
    }
  }
  return jsonEncode({
    'snapshot': {
      'meta': {
        'node_fields': ['type', 'name', 'id', 'self_size', 'edge_count'],
        'node_types': [types],
        'edge_fields': ['type', 'name_or_index', 'to_node'],
        'edge_types': [edgeTypes],
      },
    },
    'nodes': flatNodes,
    'edges': flatEdges,
    'strings': strings,
  });
}

const routeBCoreLibrary = 'dart:core';

/// `String.substring` is absent, `String.split` and `trim` are on
/// `_StringBase`, `endsWith` is there with only a lazy-compile stub, and the
/// one-byte string reaches all of them (and `Object.==`) through its super
/// chain. `String` itself is an interface-only shell. A class name's
/// private-library suffix is ignored.
final routeBStringProfile = routeBProfile({
  'Object': const RouteBProfileClass(
    'Object',
    routeBCoreLibrary,
    fns: {'==': '[Optimized] ==', 'toString': '[Optimized] toString'},
  ),
  'String': const RouteBProfileClass(
    'String',
    routeBCoreLibrary,
    parent: 'Object',
  ),
  '_StringBase': const RouteBProfileClass(
    '_StringBase@0150898',
    routeBCoreLibrary,
    parent: 'Object',
    ifaces: ['String'],
    fns: {
      'split': '[Optimized] split',
      'trim': '[Optimized] trim',
      'toUpperCase': '[Optimized] toUpperCase',
      'endsWith': '[Stub] LazyCompile',
    },
  ),
  '_OneByteString': const RouteBProfileClass(
    '_OneByteString@0150898',
    routeBCoreLibrary,
    parent: '_StringBase',
    // A class of its own: constructors and the like have code.
    fns: {'_allocate': '[Optimized] _allocate'},
  ),
});
