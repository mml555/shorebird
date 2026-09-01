// Route B (selfhost): the ONLY supported way to get producer tooling.
//
// A patch must be compiled by the toolchain that built the release it patches.
// Every mixed-provenance failure in this project had one shape — a tool from
// one tree meeting artifacts from another, failing with a message that named
// neither — so this deliberately offers no way to assemble a toolchain by hand:
//
//   * no PATH lookup
//   * no source-tree lookup
//   * no "use the current engine instead"
//
// One resolution, one engine cell, all three files or none. An API that let a
// caller fetch the runtime and the snapshot separately would re-open the
// failure class this exists to close, and would depend on every future caller
// remembering to keep the lookups on the same hash.
//
// The publish side validates what enters a cell (audit_route_b_compiler.sh);
// this validates what leaves it. Those are different claims: one proves what we
// published, the other proves what this machine actually received.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Why producer tooling could not be resolved.
///
/// The two mean opposite things operationally and must never collapse into one
/// error: [unavailable] means nothing was ever published for this engine, so a
/// new release will not help; [invalid] means the release is fine and the
/// TOOLING is corrupt, so cutting a new release would fix nothing.
enum RouteBCompilerProblem {
  /// No bundle exists for this engine revision.
  unavailable,

  /// A bundle exists but failed provenance or capability validation.
  invalid,
}

/// Producer tooling could not be resolved for an engine.
class RouteBCompilerException implements Exception {
  /// {@macro route_b_compiler_exception}
  RouteBCompilerException(this.problem, this.message);

  /// Which of the two operationally distinct problems occurred.
  final RouteBCompilerProblem problem;

  /// A message that says which remediation applies.
  final String message;

  @override
  String toString() => message;
}

/// A validated compiler cell. Only ever constructed after every check passes.
/// A validated Route B compiler cell.
class RouteBCompiler {
  /// Only constructed by [resolveRouteBCompiler], after every check passes.
  const RouteBCompiler({
    required this.runtime,
    required this.compilerSnapshot,
    required this.platformDill,
    required this.analyzer,
    required this.frontend,
    required this.interfaceGenerator,
    required this.releaseProbe,
    required this.flutterPlatformDill,
    required this.provenance,
    this.supportsDirectSuperDualKernel = false,
  });

  /// Whether this cell's compiler implements `routeBDirectSuperDualKernelV1`.
  ///
  /// Established by asking the compiler what it advertises, not by reading a
  /// metadata line — see the probe in [resolveRouteBCompiler]. Defaults to
  /// false so a cell that predates the capability, or a hand-constructed one in
  /// a test, is treated as not having it.
  final bool supportsDirectSuperDualKernel;

  /// `dartaotruntime`, version-locked to [compilerSnapshot].
  final File runtime;

  /// `dart2bytecode.aot`, run by [runtime].
  final File compilerSnapshot;

  /// The platform dill the release was compiled against.
  final File platformDill;

  /// The coverage analyzer, run by [runtime]. Version-matched to the frontend
  /// that emitted the release's kernel.
  final File analyzer;

  /// `gen_kernel`, run by [runtime]. The release's own frontend.
  final File frontend;

  /// The dynamic-interface generator, run by [runtime]. Decides what a release
  /// retains, and therefore what a future patch can name.
  final File interfaceGenerator;

  /// P4.1's release probe, run by [runtime]. Reads the release's snapshot
  /// profile and reports, per target, whether a supported invocation site
  /// SURVIVED compilation — never whether execution reaches it.
  ///
  /// Cell-owned because it encodes gen_snapshot's snapshot-profile schema,
  /// which carries no version field of its own. The producer never parses that
  /// JSON.
  final File releaseProbe;

  /// The Flutter platform dill a real app is compiled against.
  ///
  /// Distinct from [platformDill], which is the VM platform the host harness
  /// uses. Getting these two confused produces bytecode that binds against the
  /// wrong platform and fails on device rather than here.
  final File flutterPlatformDill;

  /// The bundle's own record, verbatim. Kept so a later failure can be
  /// attributed to a specific dart revision and set of hashes rather than to
  /// "some compiler".
  final String provenance;
}

/// Runs the runtime/snapshot pair and returns its combined output.
typedef RouteBProbe = String Function(File runtime, File compilerSnapshot);

String _defaultProbe(File runtime, File compilerSnapshot) {
  final result = Process.runSync(runtime.path, [
    compilerSnapshot.path,
    '--help',
  ]);
  return '${result.stdout}${result.stderr}';
}

/// Locates the published bundle for [engineHash], downloading it if needed.
/// Returns null when nothing is published for that engine.
typedef RouteBBundleFetcher = Future<File?> Function(String engineHash);

/// Locates the published `route-b-cell-v2` descriptor for [engineHash].
/// Returns null when the cell publishes none, which selects the v1 rule.
typedef RouteBCellManifestFetcher = Future<File?> Function(String engineHash);

/// The manifest member that must carry the compiler bundle's digest.
const _compilerMember =
    'download.shorebird.dev/shorebird/%H/'
    'route-b-compiler-darwin-arm64.zip';

/// A `route-b-cell-v2` descriptor: the preimage of a cell address.
///
/// WHY THIS EXISTS. Until v2, one field carried two identities: the bundle's
/// `PROVENANCE.txt` recorded an engine revision AND was required to
/// equal the address it was published under. Those coincided while an address
/// meant "the engine", and stopped coinciding the moment an address meant "this
/// whole set of 16 artifacts". A cell can legitimately republish a
/// byte-identical compiler under a new whole-cell address -- and writing that
/// new address into the bundle cannot work, because its own digest is an
/// addressed member, so each rewrite moves the address again. It never
/// converges.
///
/// So the two identities are separated. The bundle's internal field is evidence
/// about WHAT the bundle is (its producer lineage). The descriptor is evidence
/// about WHICH CELL that exact bundle belongs to. Binding is by digest, which
/// is strictly stronger than the equality it replaces: a bundle from another
/// cell fails the member-digest check, a descriptor from another cell fails to
/// hash to the requested address, and editing either changes a digest.
class RouteBCellManifest {
  RouteBCellManifest._({
    required this.address,
    required this.cell,
    required this.compilerSha256,
  });

  /// The cell address this descriptor is the preimage of.
  final String address;

  /// The build cell the descriptor is for, e.g. `macos-ios`.
  final String cell;

  /// The digest of the compiler bundle this cell addresses.
  final String compilerSha256;

  /// Parses and SELF-AUTHENTICATES: the descriptor's own digest must be the
  /// address being requested. Returns null when this is not a v2 descriptor at
  /// all, so the caller can fall back to the v1 rule; throws when it IS a v2
  /// descriptor and is wrong.
  static RouteBCellManifest? parse({
    required List<int> bytes,
    required String engineHash,
  }) {
    final text = utf8.decode(bytes, allowMalformed: true);
    if (!text.startsWith('address_schema route-b-cell-v2')) return null;

    final digest = sha256.convert(bytes).toString().substring(0, 40);
    if (digest != engineHash) {
      throw _invalid(
        engineHash,
        'the cell descriptor addresses $digest, not the cell it was '
        'requested for',
      );
    }

    String? cell;
    String? compiler;
    var compilerCount = 0;
    for (final line in const LineSplitter().convert(text)) {
      final parts = line.split(' ');
      if (parts.length != 2) continue;
      if (parts[0] == 'cell') cell = parts[1];
      if (parts[0] == _compilerMember) {
        compilerCount++;
        compiler = parts[1];
      }
    }
    if (cell == null) {
      throw _invalid(engineHash, 'the cell descriptor names no cell');
    }
    if (compilerCount != 1 || compiler == null) {
      throw _invalid(
        engineHash,
        'the cell descriptor lists the compiler bundle $compilerCount times, '
        'expected exactly once',
      );
    }
    return RouteBCellManifest._(
      address: digest,
      cell: cell,
      compilerSha256: compiler,
    );
  }
}

const _requiredFiles = [
  'dartaotruntime',
  'dart2bytecode.aot',
  'vm_platform.dill',
  // The coverage analyzer is part of the cell, not a CLI asset. It reads the
  // RELEASE's kernel, and the kernel binary format is versioned, so a reader
  // from another lineage would refuse the dill or misread it. Required, so a
  // cell published before the analyzer existed fails loudly here rather than
  // at the moment a patch needs it.
  'route_b_analyze.aot',
  // The release's own frontend, so the --no-aot kernel dart2bytecode needs is
  // produced by the same lineage as the AOT kernel flutter emitted, rather than
  // by whatever gen_kernel the release machine happened to have.
  'route_b_gen_kernel.aot',
  // The FLUTTER platform, not the VM one. `vm_platform.dill` is what the host
  // harness compiles --target vm toys against; a real app is --target flutter,
  // and binding it against the VM platform fails at load time, on device.
  'flutter_platform_strong.dill',
  // Retention is declared at release time, and must come from the same lineage
  // as the compiler that will resolve those names later.
  'route_b_gen_dynamic_interface.aot',
  // P4.1's release probe. Required for the same reason the analyzer is: a cell
  // published before it existed must fail HERE, naming the cell, rather than at
  // the moment a patch needs a refusal gate and silently has none. A gate that
  // is absent is indistinguishable from a gate that passed.
  'route_b_release_probe.aot',
];

/// Resolve producer tooling for [engineHash], or throw.
///
/// [extractTo] receives the bundle and a destination and is expected to unpack
/// it; injected so this stays testable without an archive dependency.
Future<RouteBCompiler> resolveRouteBCompiler({
  required String engineHash,
  required RouteBBundleFetcher fetchBundle,
  required Future<void> Function(File archive, Directory destination) extractTo,
  required Directory cacheRoot,
  RouteBProbe probe = _defaultProbe,
  RouteBCellManifestFetcher? fetchCellManifest,
}) async {
  // The v2 descriptor, if this cell publishes one. Fetched BEFORE the bundle so
  // a descriptor that fails to authenticate refuses without downloading tooling
  // it would then have to discard.
  RouteBCellManifest? manifest;
  if (fetchCellManifest != null) {
    final descriptor = await fetchCellManifest(engineHash);
    if (descriptor != null && descriptor.existsSync()) {
      manifest = RouteBCellManifest.parse(
        bytes: descriptor.readAsBytesSync(),
        engineHash: engineHash,
      );
    }
  }

  final bundle = await fetchBundle(engineHash);
  if (bundle == null || !bundle.existsSync()) {
    throw RouteBCompilerException(
      RouteBCompilerProblem.unavailable,
      '''
Route B producer tooling has not been published for engine $engineHash.

Patches for this release cannot be built until it is. This is not a problem with
the release or with your Dart changes.''',
    );
  }

  // Extract to a STAGING directory and promote only after validation. A
  // half-written or invalid extraction must never become the cache: the next
  // run would find it, skip validation, and compile against it.
  final staging = Directory(
    p.join(cacheRoot.path, '.$engineHash.staging'),
  );
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync(recursive: true);

  try {
    await extractTo(bundle, staging);
  } on Exception catch (error) {
    throw RouteBCompilerException(
      RouteBCompilerProblem.invalid,
      'Route B producer tooling for engine $engineHash could not be '
      'extracted: $error',
    );
  }

  final provenanceFile = File(p.join(staging.path, 'PROVENANCE.txt'));
  if (!provenanceFile.existsSync()) {
    throw _invalid(engineHash, 'the bundle carries no PROVENANCE.txt');
  }
  final provenance = provenanceFile.readAsStringSync();

  for (final name in _requiredFiles) {
    if (!File(p.join(staging.path, name)).existsSync()) {
      // A partial bundle is exactly what shipping one artifact is meant to
      // prevent, so say so rather than failing later on a missing path.
      throw _invalid(engineHash, 'the bundle is missing $name');
    }
  }

  // Hashes BEFORE the probe. The published-side audit proved these are not
  // interchangeable: a snapshot with bytes appended still ran and still
  // advertised its flags, and only the hash caught it.
  for (final name in _requiredFiles) {
    final file = File(p.join(staging.path, name));
    final recorded = _recordedHash(provenance, name);
    if (recorded == null) {
      throw _invalid(
        engineHash,
        '$name has no recorded hash in PROVENANCE.txt',
      );
    }
    final actual = sha256.convert(file.readAsBytesSync()).toString();
    if (actual != recorded) {
      throw _invalid(
        engineHash,
        '$name does not match its recorded hash '
        '(recorded ${recorded.substring(0, 16)}…, '
        'got ${actual.substring(0, 16)}…)',
      );
    }
  }

  // The bundle must be bound to the cell it is being resolved for. A bundle
  // copied between cells passes every other check, so this is the gate that
  // stops mixed provenance -- and it has two forms.
  //
  // Deliberately not restricted to hex: a bundle whose provenance is mangled
  // should report what it actually contains, not "<none>", which reads as a
  // missing field rather than a wrong one.
  final recordedEngine = RegExp(
    r'^engine revision\s*:\s*(\S+)',
    multiLine: true,
  ).firstMatch(provenance)?.group(1);

  if (manifest == null) {
    // v1: the address MEANT the engine, so the bundle's own field is the
    // binding. Unchanged, and it still governs every historical cell.
    if (recordedEngine != engineHash) {
      throw _invalid(
        engineHash,
        'the bundle records engine ${recordedEngine ?? '<none>'}, '
        'not the engine it was published under',
      );
    }
  } else {
    // v2: the address means the WHOLE CELL, so the binding is by digest. The
    // descriptor already proved it hashes to engineHash; now the archive we
    // actually received must be the member that descriptor addresses.
    //
    // `recordedEngine` is NOT compared to engineHash here. Under v2 it records
    // the producer lineage, which for a cell that republishes an unchanged
    // bundle is legitimately an earlier address. It is still required to be
    // PRESENT, so a bundle with no provenance at all cannot pass.
    if (recordedEngine == null) {
      throw _invalid(engineHash, 'the bundle records no engine revision');
    }
    if (manifest.cell != 'macos-ios') {
      throw _invalid(
        engineHash,
        'the cell descriptor is for cell ${manifest.cell}, not macos-ios',
      );
    }
    final bundleDigest = sha256.convert(bundle.readAsBytesSync()).toString();
    if (bundleDigest != manifest.compilerSha256) {
      throw _invalid(
        engineHash,
        'the compiler bundle digest ${bundleDigest.substring(0, 16)}… is not '
        'the one this cell addresses '
        '(${manifest.compilerSha256.substring(0, 16)}…)',
      );
    }
  }

  final runtime = File(p.join(staging.path, 'dartaotruntime'));
  final compilerSnapshot = File(p.join(staging.path, 'dart2bytecode.aot'));
  if (!Platform.isWindows) {
    // Zip round-trips lose the executable bit on some paths.
    Process.runSync('chmod', ['+x', runtime.path]);
  }

  // ...and only now, does it actually work?
  final output = probe(runtime, compilerSnapshot);
  if (!output.contains('Compiles Dart sources to Dart bytecode')) {
    throw _invalid(
      engineHash,
      'the runtime and compiler do not run as dart2bytecode',
    );
  }
  if (!output.contains('flutter')) {
    throw _invalid(
      engineHash,
      'the compiler does not support --target flutter, which Route B patches '
      'are compiled with',
    );
  }

  // routeBDirectSuperDualKernelV1, ASKED OF THE BINARY.
  //
  // Not read from a metadata line: a hand-written capability string is true of
  // whatever somebody typed, and this whole programme has been bitten by stamps
  // that describe a cache rather than its bytes. The compiler is asked what it
  // advertises, exactly as `--target flutter` is asked above.
  //
  // Advertising the option is necessary and not sufficient — it proves the CLI
  // surface, not the dual-kernel BEHAVIOUR. Behaviour is established once, at
  // cell qualification, by `qualify_dual_kernel_cell.sh`, which runs the
  // moved-site probe and its wrong-verifier negative before a cell may be
  // published. What ties the two together is the per-artifact SHA-256 check
  // above: a cell advertising this option contains exactly the dart2bytecode
  // that passed that probe.
  final supportsDirectSuperDualKernel = output.contains(
    'patched-verification-dill',
  );

  // Atomic promotion: rename onto the final path only once everything passed.
  final cell = Directory(p.join(cacheRoot.path, engineHash));
  if (cell.existsSync()) cell.deleteSync(recursive: true);
  staging.renameSync(cell.path);

  return RouteBCompiler(
    runtime: File(p.join(cell.path, 'dartaotruntime')),
    compilerSnapshot: File(p.join(cell.path, 'dart2bytecode.aot')),
    platformDill: File(p.join(cell.path, 'vm_platform.dill')),
    analyzer: File(p.join(cell.path, 'route_b_analyze.aot')),
    frontend: File(p.join(cell.path, 'route_b_gen_kernel.aot')),
    interfaceGenerator: File(
      p.join(cell.path, 'route_b_gen_dynamic_interface.aot'),
    ),
    releaseProbe: File(p.join(cell.path, 'route_b_release_probe.aot')),
    flutterPlatformDill: File(
      p.join(cell.path, 'flutter_platform_strong.dill'),
    ),
    provenance: provenance,
    supportsDirectSuperDualKernel: supportsDirectSuperDualKernel,
  );
}

String? _recordedHash(String provenance, String name) {
  final match = RegExp(
    '^${RegExp.escape(name)}\\s*:\\s*([0-9a-f]{64})',
    multiLine: true,
  ).firstMatch(provenance);
  return match?.group(1);
}

RouteBCompilerException _invalid(String engineHash, String detail) {
  return RouteBCompilerException(
    RouteBCompilerProblem.invalid,
    '''
Route B producer tooling for engine $engineHash failed validation: $detail.

Treat this as corruption or a bad cache, not as a problem with the release —
cutting a new release would not fix it. Nothing was uploaded.''',
  );
}
