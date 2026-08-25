// cspell:words CALLSITES callsite targetable
//
// route_b_release_probe -- P4.1's instrument. Answers ONE question about a
// release, for one target at a time:
//
//     Did a supported invocation site of this target survive compilation?
//
// It does NOT answer whether runtime control flow reaches that site. A dead
// branch has a surviving call site and is never executed, and this probe reports
// it GREEN. See P41_RELEASE_PROBE_SPEC.md; that distinction is the whole reason
// the instrument exists rather than being inferred from a patch's outcome.
//
// WHY THIS LIVES IN THE CELL. It encodes gen_snapshot's v8 snapshot-profile
// schema and the VM's object-pool call form. Both are properties of the
// COMPILER that produced the release, so a probe from another lineage would
// misread the profile the same way a mismatched kernel reader misreads a dill.
// The producer never parses profile JSON; it asks the matching cell.
//
// The measured fact this rests on (evidence/p41_measurement_note.md): a
// patchable static call loads the callee's entry point out of the CALLER's
// object pool, so `target Function <- ObjectPool <- caller Code` IS a surviving
// call site. A folded target still has a Function node but no such pool.
import 'dart:convert';
import 'dart:io';

/// Bumped when the classification or the evidence shape changes. Recorded in the
/// output and checked against the release binding, so a profile produced under
/// one revision cannot be silently consumed under another.
const probeRevision = 1;

/// The profile schema this probe was written against. There is no version field
/// in the profile itself, so the shape is asserted STRUCTURALLY: if gen_snapshot
/// changes the layout, this fails closed as PROFILE_INVALID rather than reading
/// the wrong columns. Indexing the wrong array is not hypothetical -- the first
/// decode of this format read `type` out of `strings` instead of
/// `meta.node_types`, and every count it produced had to be voided.
const _nodeFields = ['type', 'name', 'id', 'self_size', 'edge_count'];
const _edgeFields = ['type', 'name_or_index', 'to_node'];
const _requiredNodeTypes = ['Function', 'Class', 'Library', 'Code', 'ObjectPool'];

/// Internal result model (spec §3). Deliberately finer than the product
/// vocabulary: the producer collapses four of these to UNKNOWN, but collapsing
/// them HERE would turn a broken instrument into a confident verdict about code.
enum ProbeResult {
  targetNotFound('TARGET_NOT_FOUND'),
  targetAmbiguous('TARGET_AMBIGUOUS'),
  profileInvalid('PROFILE_INVALID'),
  artifactBindingMismatch('ARTIFACT_BINDING_MISMATCH'),
  zeroQualifyingCallsites('ZERO_QUALIFYING_CALLSITES'),
  oneOrMoreQualifyingCallsites('ONE_OR_MORE_QUALIFYING_CALLSITES');

  const ProbeResult(this.wire);
  final String wire;
}

class Evidence {
  int targetFunctionNodes = 0;
  int callerOwnedPools = 0;
  int tearoffPools = 0;
  int selfOwnedPools = 0;
  int unownedPools = 0;
  int otherReferrers = 0;
  final callers = <String>[];

  Map<String, Object?> toJson() => {
    'target_function_nodes': targetFunctionNodes,
    // The ONLY input to the policy fact. Everything below is recorded so a
    // change in the incidental counts is visible instead of silent.
    'caller_owned_pools': callerOwnedPools,
    'tearoff_pools': tearoffPools,
    'self_owned_pools': selfOwnedPools,
    'unowned_pools': unownedPools,
    'other_referrers': otherReferrers,
    'callers': callers,
  };
}

/// A target's logical identity (spec §4). The STRING is how this profile is
/// looked up today; the identity is the triple. Names are usable because Route
/// B's dynamic interface keeps targetable members bindable by name even under
/// obfuscation -- measured, and the reason lookup is allowed to use them.
class TargetId {
  TargetId(this.library, this.className, this.member);

  /// `package:foo/bar.dart#Class.member`, or `package:foo/bar.dart#topLevel`.
  /// Accessors must be passed in VM form: `get:x` / `set:x`.
  factory TargetId.parse(String spec) {
    final hash = spec.indexOf('#');
    if (hash <= 0 || hash == spec.length - 1) {
      throw FormatException('target must be "<library uri>#<selector>"', spec);
    }
    final library = spec.substring(0, hash);
    final selector = spec.substring(hash + 1);
    // A dot separates class from member, but `get:`/`set:` prefixes contain no
    // dot and a top-level selector has none either.
    final dot = selector.lastIndexOf('.');
    if (dot <= 0) return TargetId(library, null, selector);
    return TargetId(
      library,
      selector.substring(0, dot),
      selector.substring(dot + 1),
    );
  }

  final String library;
  final String? className;
  final String member;

  /// Top-level members are owned by the VM's `::` pseudo-class.
  String get owningClassName => className ?? '::';

  @override
  String toString() =>
      '$library#${className == null ? member : '$className.$member'}';
}

/// A decoded profile. Nothing here is clever; the value is that every structural
/// assumption is checked once, in one place, and a violation is PROFILE_INVALID.
class Profile {
  Profile._(this._types, this._names, this._out, this._in);

  final List<String> _types;
  final List<String> _names;
  final List<List<ProfileEdge>> _out;
  final List<List<ProfileEdge>> _in;

  int get nodeCount => _types.length;

  static (Profile?, String?) decode(Object? json) {
    if (json is! Map) return (null, 'top level is not an object');
    final snapshot = json['snapshot'];
    if (snapshot is! Map) return (null, 'no snapshot object');
    final meta = snapshot['meta'];
    if (meta is! Map) return (null, 'no snapshot.meta');

    final nodeFields = (meta['node_fields'] as List?)?.cast<String>();
    final edgeFields = (meta['edge_fields'] as List?)?.cast<String>();
    if (nodeFields == null || !_sameList(nodeFields, _nodeFields)) {
      return (null, 'node_fields is $nodeFields, expected $_nodeFields');
    }
    if (edgeFields == null || !_sameList(edgeFields, _edgeFields)) {
      return (null, 'edge_fields is $edgeFields, expected $_edgeFields');
    }
    // node_types/edge_types are lists-of-lists; the first entry is the name
    // table. Reading the type out of `strings` instead of here is the decode bug
    // that voided a whole measurement, so it is asserted rather than assumed.
    final nodeTypes = _firstNameTable(meta['node_types']);
    final edgeTypes = _firstNameTable(meta['edge_types']);
    if (nodeTypes == null) return (null, 'meta.node_types is not a name table');
    if (edgeTypes == null) return (null, 'meta.edge_types is not a name table');
    for (final t in _requiredNodeTypes) {
      if (!nodeTypes.contains(t)) return (null, 'node type "$t" is absent');
    }

    final strings = (json['strings'] as List?)?.cast<String>();
    final nodes = (json['nodes'] as List?)?.cast<num>();
    final edges = (json['edges'] as List?)?.cast<num>();
    if (strings == null) return (null, 'no strings array');
    if (nodes == null) return (null, 'no nodes array');
    if (edges == null) return (null, 'no edges array');

    final nf = nodeFields.length, ef = edgeFields.length;
    if (nodes.length % nf != 0) return (null, 'nodes array is ragged');
    if (edges.length % ef != 0) return (null, 'edges array is ragged');

    final n = nodes.length ~/ nf;
    final declaredNodes = snapshot['node_count'];
    if (declaredNodes is num && declaredNodes.toInt() != n) {
      return (null, 'node_count is $declaredNodes but the array holds $n');
    }
    final declaredEdges = snapshot['edge_count'];
    if (declaredEdges is num && declaredEdges.toInt() != edges.length ~/ ef) {
      return (null, 'edge_count disagrees with the edges array');
    }

    final types = List<String>.filled(n, '');
    final names = List<String>.filled(n, '');
    final counts = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = nodes[i * nf].toInt();
      final nm = nodes[i * nf + 1].toInt();
      if (t < 0 || t >= nodeTypes.length) return (null, 'node $i type $t');
      if (nm < 0 || nm >= strings.length) return (null, 'node $i name $nm');
      types[i] = nodeTypes[t];
      names[i] = strings[nm];
      counts[i] = nodes[i * nf + 4].toInt();
    }

    final out = List.generate(n, (_) => <ProfileEdge>[], growable: false);
    final incoming = List.generate(n, (_) => <ProfileEdge>[], growable: false);
    // Edges are laid out per node in node order. Consuming the array EXACTLY is
    // the check: a leftover or a short read means the layout is not what this
    // probe was written against.
    var pos = 0;
    for (var i = 0; i < n; i++) {
      for (var k = 0; k < counts[i]; k++) {
        if (pos + ef > edges.length) return (null, 'edges array ends early');
        final et = edges[pos].toInt();
        final nameOrIndex = edges[pos + 1].toInt();
        final to = edges[pos + 2].toInt();
        pos += ef;
        if (et < 0 || et >= edgeTypes.length) return (null, 'edge type $et');
        // `to_node` is a BYTE OFFSET into the flat nodes array, not an index.
        if (to % nf != 0) return (null, 'to_node $to is not a node boundary');
        final dst = to ~/ nf;
        if (dst < 0 || dst >= n) return (null, 'to_node $to out of range');
        // For `property` edges name_or_index indexes `strings`; for `element`
        // edges it is a pool/array index and must NOT be read as a string.
        final kind = edgeTypes[et];
        final label = kind == 'property' &&
                nameOrIndex >= 0 &&
                nameOrIndex < strings.length
            ? strings[nameOrIndex]
            : null;
        final e = ProfileEdge(i, dst, kind, label);
        out[i].add(e);
        incoming[dst].add(e);
      }
    }
    if (pos != edges.length) {
      return (null, 'edges array has ${edges.length - pos} bytes left over');
    }
    return (Profile._(types, names, out, incoming), null);
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<String>? _firstNameTable(Object? v) {
    if (v is! List || v.isEmpty) return null;
    final first = v.first;
    if (first is! List) return null;
    return first.map((e) => '$e').toList();
  }

  String typeOf(int i) => _types[i];
  String nameOf(int i) => _names[i];

  int? property(int node, String name) {
    for (final e in _out[node]) {
      if (e.kind == 'property' && e.label == name) return e.dst;
    }
    return null;
  }

  Iterable<ProfileEdge> referrersOf(int node) => _in[node];

  Iterable<int> nodesOfType(String type) {
    return Iterable<int>.generate(_types.length)
        .where((i) => _types[i] == type);
  }
}

class ProfileEdge {
  ProfileEdge(this.src, this.dst, this.kind, this.label);
  final int src;
  final int dst;
  final String kind;
  final String? label;
}

/// One target's verdict.
class Verdict {
  Verdict(this.target, this.result, this.evidence, [this.detail]);
  final String target;
  final ProbeResult result;
  final Evidence evidence;
  final String? detail;

  Map<String, Object?> toJson() => {
    'target': target,
    'result': result.wire,
    if (detail != null) 'detail': detail,
    'evidence': evidence.toJson(),
  };
}

/// Resolves [id] to a single Function node and classifies its referrers.
Verdict classify(Profile p, TargetId id) {
  final ev = Evidence();

  // Identity: library URI -> owning class -> member. A bare selector is NOT the
  // identity; two libraries may each hold a `build`.
  final matches = <int>[];
  for (final fn in p.nodesOfType('Function')) {
    if (!_nameMatches(p.nameOf(fn), id.member)) continue;
    final owner = p.property(fn, 'owner_');
    if (owner == null) continue;
    if (p.nameOf(owner) != id.owningClassName) continue;
    final lib = _libraryOf(p, owner);
    if (lib == null || p.nameOf(lib) != id.library) continue;
    matches.add(fn);
  }
  ev.targetFunctionNodes = matches.length;
  if (matches.isEmpty) {
    return Verdict(
      '$id',
      ProbeResult.targetNotFound,
      ev,
      'no Function node with this identity -- absence of EVIDENCE, not '
          'evidence that no call site survived',
    );
  }
  if (matches.length > 1) {
    return Verdict(
      '$id',
      ProbeResult.targetAmbiguous,
      ev,
      '${matches.length} Function nodes share this identity; refusing to pick '
          'one',
    );
  }

  final fn = matches.single;
  for (final e in p.referrersOf(fn)) {
    if (p.typeOf(e.src) != 'ObjectPool') {
      ev.otherReferrers++;
      continue;
    }
    final owners = <String>[];
    for (final pe in p.referrersOf(e.src)) {
      if (p.typeOf(pe.src) == 'Code') owners.add(p.nameOf(pe.src));
    }
    if (owners.isEmpty) {
      // Recorded, never counted. Ambiguous evidence must not be able to pass a
      // gate; that is one of the mutations the gate tests.
      ev.unownedPools++;
    } else if (owners.any((o) => o.contains('[tear-off]'))) {
      ev.tearoffPools++;
    } else if (owners.any((o) => _isSelfCode(o, p.nameOf(fn)))) {
      ev.selfOwnedPools++;
    } else {
      ev.callerOwnedPools++;
      ev.callers.addAll(owners);
    }
  }

  return Verdict(
    '$id',
    ev.callerOwnedPools >= 1
        ? ProbeResult.oneOrMoreQualifyingCallsites
        : ProbeResult.zeroQualifyingCallsites,
    ev,
  );
}

/// A library-private member is mangled `_foo@12345` in the profile. Scoping is
/// already by library, and the mangling id is per-library, so matching the base
/// name inside one library cannot collide.
bool _nameMatches(String profileName, String member) {
  if (profileName == member) return true;
  final at = profileName.indexOf('@');
  return at > 0 && profileName.substring(0, at) == member;
}

int? _libraryOf(Profile p, int owner) {
  final direct = p.property(owner, 'library_');
  if (direct != null && p.typeOf(direct) == 'Library') return direct;
  // A PatchClass wraps the class it patches; follow it rather than reporting the
  // target as absent.
  for (final name in const ['patched_class_', 'origin_class_', 'wrapped_class_']) {
    final wrapped = p.property(owner, name);
    if (wrapped != null) {
      final lib = p.property(wrapped, 'library_');
      if (lib != null && p.typeOf(lib) == 'Library') return lib;
    }
  }
  return null;
}

bool _isSelfCode(String codeName, String functionName) {
  final bare = codeName.replaceAll('[Optimized] ', '').replaceAll('[Unoptimized] ', '');
  return bare == functionName;
}

const _usage = '''
route_b_release_probe -- did a supported invocation site of a target survive
compilation?

  route_b_release_probe --profile <profile.json> --binding <binding.json>
                        --artifact-sha256 <hex> --target <lib#selector> ...

  --profile          the release's v8 snapshot profile, from gen_snapshot
                     --write-v8-snapshot-profile-to
  --binding          the sidecar's binding metadata, written by the release
  --artifact-sha256  the digest of the artifact the producer is about to patch
  --cell-id          the cell the producer resolved, if it should be checked
  --target           <library uri>#<selector>, repeatable. Accessors in VM form
                     (get:x / set:x). A dot separates class from member.
  --targets-file     one target per line, as an alternative to --target

Emits one JSON object on stdout. A verdict is an answer, so producing one exits
0 even when the answer refuses publication; exit 2 means the probe could not
run at all.

This reports SURVIVAL, not reachability. A never-executed call site is a
surviving call site.
''';

Future<int> main(List<String> args) async {
  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    stdout.write(_usage);
    return 0;
  }

  String? profilePath, bindingPath, artifactSha, cellId, targetsFile;
  final targets = <String>[];
  for (var i = 0; i < args.length; i++) {
    String value() {
      if (i + 1 >= args.length) {
        stderr.writeln('${args[i]} needs a value');
        exit(2);
      }
      return args[++i];
    }

    switch (args[i]) {
      case '--profile':
        profilePath = value();
      case '--binding':
        bindingPath = value();
      case '--artifact-sha256':
        artifactSha = value();
      case '--cell-id':
        cellId = value();
      case '--target':
        targets.add(value());
      case '--targets-file':
        targetsFile = value();
      default:
        stderr.writeln('unknown argument: ${args[i]}');
        return 2;
    }
  }
  if (targetsFile != null) {
    targets.addAll(
      File(targetsFile)
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#')),
    );
  }
  if (profilePath == null) {
    stderr.writeln('--profile is required');
    return 2;
  }
  if (targets.isEmpty) {
    stderr.writeln('at least one --target is required');
    return 2;
  }

  final out = <String, Object?>{'probe_revision': probeRevision};

  // BINDING FIRST. A profile that describes a different artifact is not weak
  // evidence about this one; it is evidence about something else. Every target
  // is refused before the profile is even read.
  final binding = _checkBinding(bindingPath, artifactSha, cellId);
  out['binding'] = binding.toJson();
  if (!binding.ok) {
    out['targets'] = [
      for (final t in targets)
        Verdict(
          t,
          ProbeResult.artifactBindingMismatch,
          Evidence(),
          binding.detail,
        ).toJson(),
    ];
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(out));
    return 0;
  }

  final file = File(profilePath);
  if (!file.existsSync()) {
    out['profile'] = {'status': 'INVALID', 'detail': 'no file at $profilePath'};
    out['targets'] = [
      for (final t in targets)
        Verdict(t, ProbeResult.profileInvalid, Evidence(), 'no profile file')
            .toJson(),
    ];
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(out));
    return 0;
  }

  Object? json;
  try {
    json = jsonDecode(file.readAsStringSync());
  } on FormatException catch (e) {
    json = null;
    out['profile'] = {'status': 'INVALID', 'detail': 'not JSON: ${e.message}'};
  }
  final (profile, problem) =
      json == null ? (null, 'not JSON') : Profile.decode(json);
  if (profile == null) {
    out['profile'] ??= {'status': 'INVALID', 'detail': problem};
    out['targets'] = [
      for (final t in targets)
        Verdict(t, ProbeResult.profileInvalid, Evidence(), problem).toJson(),
    ];
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(out));
    return 0;
  }
  out['profile'] = {'status': 'OK', 'nodes': profile.nodeCount};

  final verdicts = <Map<String, Object?>>[];
  for (final spec in targets) {
    try {
      verdicts.add(classify(profile, TargetId.parse(spec)).toJson());
    } on FormatException catch (e) {
      stderr.writeln('bad target "$spec": ${e.message}');
      return 2;
    }
  }
  out['targets'] = verdicts;
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(out));
  return 0;
}

class _Binding {
  _Binding(this.ok, this.detail, this.fields);
  final bool ok;
  final String? detail;
  final Map<String, Object?> fields;

  Map<String, Object?> toJson() => {
    'status': ok ? 'OK' : 'MISMATCH',
    if (detail != null) 'detail': detail,
    ...fields,
  };
}

_Binding _checkBinding(String? path, String? artifactSha, String? cellId) {
  if (path == null) {
    return _Binding(false, 'no --binding was supplied', const {});
  }
  final f = File(path);
  if (!f.existsSync()) {
    return _Binding(false, 'no binding file at $path', const {});
  }
  Map<String, Object?> b;
  try {
    b = (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
  } catch (_) {
    return _Binding(false, 'binding file is not a JSON object', const {});
  }
  final fields = <String, Object?>{
    for (final k in const [
      'profile_format_revision',
      'probe_revision',
      'cell_id',
      'release_artifact_sha256',
      'release_kernel_sha256',
      'dynamic_interface_sha256',
    ])
      if (b.containsKey(k)) k: b[k],
  };

  final declaredProbe = b['probe_revision'];
  if (declaredProbe is! int) {
    return _Binding(false, 'binding has no integer probe_revision', fields);
  }
  if (declaredProbe != probeRevision) {
    return _Binding(
      false,
      'binding was written for probe revision $declaredProbe, this probe is '
          '$probeRevision',
      fields,
    );
  }
  final declaredArtifact = b['release_artifact_sha256'];
  if (declaredArtifact is! String || declaredArtifact.length != 64) {
    return _Binding(
      false,
      'binding has no release_artifact_sha256',
      fields,
    );
  }
  if (artifactSha == null) {
    return _Binding(
      false,
      'no --artifact-sha256 to compare the binding against',
      fields,
    );
  }
  if (declaredArtifact.toLowerCase() != artifactSha.toLowerCase()) {
    // Deliberately says nothing about the targets. Same version, same source
    // revision, same filenames and even the same target names do not make a
    // profile of artifact A into evidence about artifact B.
    return _Binding(
      false,
      'the profile describes artifact $declaredArtifact but the producer is '
          'patching $artifactSha',
      fields,
    );
  }
  if (cellId != null && b['cell_id'] != null && b['cell_id'] != cellId) {
    return _Binding(
      false,
      'the profile was produced by cell ${b['cell_id']}, the producer resolved '
          '$cellId',
      fields,
    );
  }
  return _Binding(true, null, fields);
}
