// CELL-BINDING-V2 qualification matrix.
//
// Exercises resolveRouteBCompiler directly -- the product's own resolver, not a
// re-implementation -- with a synthetic bundle, so every arm is about the
// BINDING rule rather than about real compiler bytes.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:test/test.dart';

const _files = [
  'dartaotruntime',
  'dart2bytecode.aot',
  'vm_platform.dill',
  'route_b_analyze.aot',
  'route_b_gen_kernel.aot',
  'flutter_platform_strong.dill',
  'route_b_gen_dynamic_interface.aot',
  'route_b_release_probe.aot',
];

const _member =
    'download.shorebird.dev/shorebird/%H/route-b-compiler-darwin-arm64.zip';

/// A descriptor plus the address it authenticates to. No search is needed: the
/// address IS the digest of these bytes, which is the whole point of the
/// scheme -- the descriptor is its own preimage, not a value chosen to match.
({String text, String address}) makeManifest(String compilerSha) {
  final text =
      'address_schema route-b-cell-v2\n'
      'cell macos-ios\n'
      'fallback_engine_revision 69f9831c360d9152862ec3897c67fb09ae843f3b\n'
      '$_member $compilerSha\n';
  final addr = sha256.convert(utf8.encode(text)).toString().substring(0, 40);
  return (text: text, address: addr);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('cellbind'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Writes a fake bundle file and returns (file, digest). [recordedEngine] is
  /// what its PROVENANCE.txt claims.
  (File, String) bundle(String recordedEngine, {String salt = ''}) {
    final f = File(p.join(tmp.path, 'bundle$salt.zip'))
      ..writeAsStringSync('BUNDLE$salt$recordedEngine');
    return (f, sha256.convert(f.readAsBytesSync()).toString());
  }

  Future<void> extract(File archive, Directory dest) async {
    final recorded = archive.readAsStringSync().replaceFirst(
      RegExp(r'^BUNDLE\S*?(?=[0-9a-f]{40}|$)'),
      '',
    );
    final lines = <String>['engine revision  : $recorded'];
    for (final n in _files) {
      final body = 'body-of-$n';
      File(p.join(dest.path, n)).writeAsStringSync(body);
      lines.add('$n : ${sha256.convert(utf8.encode(body))}');
    }
    File(p.join(dest.path, 'PROVENANCE.txt')).writeAsStringSync(
      '${lines.join('\n')}\n',
    );
  }

  String probe(File r, File c) =>
      'Compiles Dart sources to Dart bytecode\n--target=flutter\n'
      '--patched-verification-dill\n';

  Future<RouteBCompiler> resolve({
    required String engineHash,
    required File theBundle,
    String? manifestText,
  }) {
    return resolveRouteBCompiler(
      engineHash: engineHash,
      fetchBundle: (_) async => theBundle,
      extractTo: extract,
      cacheRoot: Directory(p.join(tmp.path, 'cache'))..createSync(),
      probe: probe,
      fetchCellManifest: manifestText == null
          ? null
          : (_) async => File(p.join(tmp.path, 'desc.v2'))
              ..writeAsStringSync(manifestText),
    );
  }

  const legacyH = 'a5a8be5854c529268378ce16762a16d6e31763e9';

  test('v2: descriptor + addressed bundle ACCEPTS, though bundle records H',
      () async {
    final (f, digest) = bundle(legacyH);
    final m = makeManifest(digest);
    final c = await resolve(
      engineHash: m.address, theBundle: f, manifestText: m.text,
    );
    expect(c.supportsDirectSuperDualKernel, isTrue);
  });

  test('v2: mutated compiler archive REFUSES on digest', () async {
    final (f, digest) = bundle(legacyH);
    final m = makeManifest(digest);
    final (other, _) = bundle(legacyH, salt: 'X');
    await expectLater(
      resolve(engineHash: m.address, theBundle: other, manifestText: m.text),
      throwsA(predicate((e) => '$e'.contains('is not the one this cell'))),
    );
  });

  test('v2: descriptor addressing another cell REFUSES', () async {
    final (f, digest) = bundle(legacyH);
    final m = makeManifest(digest);
    await expectLater(
      resolve(engineHash: 'f' * 40, theBundle: f, manifestText: m.text),
      throwsA(predicate((e) => '$e'.contains('addresses'))),
    );
  });

  test('v2: compiler member digest changed => no longer addresses the cell',
      () async {
    final (f, digest) = bundle(legacyH);
    final m = makeManifest(digest);
    final tampered = m.text.replaceFirst(digest, 'a' * 64);
    await expectLater(
      resolve(engineHash: m.address, theBundle: f, manifestText: tampered),
      throwsA(predicate((e) => '$e'.contains('addresses'))),
    );
  });

  test('v2: wrong cell REFUSES', () async {
    final (f, digest) = bundle(legacyH);
    final text = 'address_schema route-b-cell-v2\ncell linux-android\n'
        '$_member $digest\n';
    final addr = sha256.convert(utf8.encode(text)).toString().substring(0, 40);
    await expectLater(
      resolve(engineHash: addr, theBundle: f, manifestText: text),
      throwsA(predicate((e) => '$e'.contains('not macos-ios'))),
    );
  });

  test('THE CAUSAL NEGATIVE: H2 requested, bundle says H, NO descriptor '
      '=> REFUSE (v1 rule intact)', () async {
    final (f, _) = bundle(legacyH);
    await expectLater(
      resolve(engineHash: 'b' * 40, theBundle: f),
      throwsA(predicate((e) =>
          '$e'.contains('not the engine it was published under'))),
    );
  });

  test('v1 legacy: bundle records the requested hash => ACCEPT', () async {
    final (f, _) = bundle(legacyH);
    final c = await resolve(engineHash: legacyH, theBundle: f);
    expect(c.supportsDirectSuperDualKernel, isTrue);
  });
}
