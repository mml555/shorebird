import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:test/test.dart';

/// A stand-in for the published bundle. Real zips are not needed here — the
/// resolver takes extraction as a parameter — so a directory tree keeps the
/// tests about VALIDATION rather than about archive handling.
class _Bundle {
  _Bundle(this.dir);

  factory _Bundle.build(
    Directory root, {
    required String engineHash,
    String dartRev = '6b58bb3a',
    List<String> omit = const [],
    Map<String, String> contents = const {},
    Map<String, String> hashOverrides = const {},
  }) {
    final dir = Directory(p.join(root.path, 'bundle'))
      ..createSync(recursive: true);
    final files = {
      'dartaotruntime': contents['dartaotruntime'] ?? 'RUNTIME',
      'dart2bytecode.aot': contents['dart2bytecode.aot'] ?? 'SNAPSHOT',
      'vm_platform.dill': contents['vm_platform.dill'] ?? 'PLATFORM',
      'route_b_analyze.aot': contents['route_b_analyze.aot'] ?? 'ANALYZER',
      'route_b_gen_kernel.aot':
          contents['route_b_gen_kernel.aot'] ?? 'FRONTEND',
      'flutter_platform_strong.dill':
          contents['flutter_platform_strong.dill'] ?? 'FLUTTER-PLATFORM',
    };
    final recorded = <String, String>{};
    for (final entry in files.entries) {
      if (omit.contains(entry.key)) continue;
      File(p.join(dir.path, entry.key)).writeAsStringSync(entry.value);
      recorded[entry.key] =
          hashOverrides[entry.key] ??
          sha256.convert(entry.value.codeUnits).toString();
    }
    final lines = <String>[
      'Route B bytecode compiler',
      'engine revision  : $engineHash',
      'dart revision    : $dartRev',
      for (final e in recorded.entries) '${e.key} : ${e.value}',
    ];
    File(
      p.join(dir.path, 'PROVENANCE.txt'),
    ).writeAsStringSync(lines.join('\n'));
    return _Bundle(dir);
  }

  final Directory dir;
}

void main() {
  group('resolveRouteBCompiler', () {
    late Directory tmp;
    late Directory cacheRoot;
    const engineHash = '591a9f8d';

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('rbc');
      cacheRoot = Directory(p.join(tmp.path, 'cache'))..createSync();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<RouteBCompiler> resolve({
      _Bundle? bundle,
      String probeOutput =
          'Compiles Dart sources to Dart bytecode.\n--target ... flutter ...',
    }) {
      return resolveRouteBCompiler(
        engineHash: engineHash,
        fetchBundle: (_) async => bundle == null
            ? null
            : (File(p.join(tmp.path, 'bundle.zip'))..writeAsStringSync('zip')),
        extractTo: (archive, destination) async {
          for (final f in bundle!.dir.listSync().whereType<File>()) {
            File(
              p.join(destination.path, p.basename(f.path)),
            ).writeAsBytesSync(f.readAsBytesSync());
          }
        },
        cacheRoot: cacheRoot,
        probe: (_, _) => probeOutput,
      );
    }

    test('resolves a clean cell and returns all three files', () async {
      final compiler = await resolve(
        bundle: _Bundle.build(tmp, engineHash: engineHash),
      );

      expect(compiler.runtime.existsSync(), isTrue);
      expect(compiler.compilerSnapshot.existsSync(), isTrue);
      expect(compiler.platformDill.existsSync(), isTrue);
      expect(compiler.provenance, contains('engine revision  : $engineHash'));
      // Promoted into the cache under the engine hash, not left in staging.
      expect(
        p.basename(compiler.runtime.parent.path),
        equals(engineHash),
      );
    });

    test('reports UNAVAILABLE when nothing is published', () async {
      await expectLater(
        resolve(),
        throwsA(
          isA<RouteBCompilerException>()
              .having(
                (e) => e.problem,
                'problem',
                RouteBCompilerProblem.unavailable,
              )
              .having(
                (e) => e.message,
                'message',
                contains('has not been published'),
              ),
        ),
      );
    });

    test('reports INVALID when a recorded hash does not match', () async {
      // The exact shape the published-side tamper test produced: bytes that
      // still run, but are not the bytes we published.
      await expectLater(
        resolve(
          bundle: _Bundle.build(
            tmp,
            engineHash: engineHash,
            contents: {'dart2bytecode.aot': 'SNAPSHOT-tampered'},
            hashOverrides: {
              'dart2bytecode.aot': sha256
                  .convert('SNAPSHOT'.codeUnits)
                  .toString(),
            },
          ),
        ),
        throwsA(
          isA<RouteBCompilerException>()
              .having(
                (e) => e.problem,
                'problem',
                RouteBCompilerProblem.invalid,
              )
              .having(
                (e) => e.message,
                'message',
                contains('does not match its recorded hash'),
              ),
        ),
      );
    });

    test('reports INVALID when hashes pass but the probe fails', () async {
      // The other half of the pair the audit proved matters: bytes that are
      // exactly what we published, which nonetheless do not form a working
      // compiler.
      await expectLater(
        resolve(
          bundle: _Bundle.build(tmp, engineHash: engineHash),
          probeOutput: 'command not found',
        ),
        throwsA(
          isA<RouteBCompilerException>()
              .having(
                (e) => e.problem,
                'problem',
                RouteBCompilerProblem.invalid,
              )
              .having(
                (e) => e.message,
                'message',
                contains('do not run as dart2bytecode'),
              ),
        ),
      );
    });

    test('reports INVALID when --target flutter is unsupported', () async {
      await expectLater(
        resolve(
          bundle: _Bundle.build(tmp, engineHash: engineHash),
          probeOutput: 'Compiles Dart sources to Dart bytecode.\n--target vm',
        ),
        throwsA(
          isA<RouteBCompilerException>().having(
            (e) => e.message,
            'message',
            contains('does not support --target flutter'),
          ),
        ),
      );
    });

    test('reports INVALID when the platform dill is missing', () async {
      await expectLater(
        resolve(
          bundle: _Bundle.build(
            tmp,
            engineHash: engineHash,
            omit: ['vm_platform.dill'],
          ),
        ),
        throwsA(
          isA<RouteBCompilerException>().having(
            (e) => e.message,
            'message',
            contains('missing vm_platform.dill'),
          ),
        ),
      );
    });

    test('reports INVALID when the coverage analyzer is missing', () async {
      // A cell published before the analyzer existed is INVALID, not
      // unavailable: something IS published for this engine, and the
      // remediation is to republish the cell rather than to cut a release.
      await expectLater(
        resolve(
          bundle: _Bundle.build(
            tmp,
            engineHash: engineHash,
            omit: ['route_b_analyze.aot'],
          ),
        ),
        throwsA(
          isA<RouteBCompilerException>()
              .having(
                (e) => e.problem,
                'problem',
                RouteBCompilerProblem.invalid,
              )
              .having(
                (e) => e.message,
                'message',
                contains('missing route_b_analyze.aot'),
              ),
        ),
      );
    });

    test('reports INVALID when the bundle belongs to another engine', () async {
      // A bundle copied between hashes passes every other check.
      await expectLater(
        resolve(bundle: _Bundle.build(tmp, engineHash: 'someotherengine')),
        throwsA(
          isA<RouteBCompilerException>().having(
            (e) => e.message,
            'message',
            contains('records engine someotherengine'),
          ),
        ),
      );
    });

    test('never promotes a failed extraction into the cache', () async {
      // The cache must not become a way to skip validation on the next run.
      await expectLater(
        resolve(
          bundle: _Bundle.build(tmp, engineHash: engineHash),
          probeOutput: 'nope',
        ),
        throwsA(isA<RouteBCompilerException>()),
      );
      expect(
        Directory(p.join(cacheRoot.path, engineHash)).existsSync(),
        isFalse,
      );
    });

    test('replaces a previously cached cell rather than trusting it', () async {
      final stale = Directory(p.join(cacheRoot.path, engineHash))
        ..createSync(recursive: true);
      File(p.join(stale.path, 'dart2bytecode.aot')).writeAsStringSync('STALE');

      final compiler = await resolve(
        bundle: _Bundle.build(tmp, engineHash: engineHash),
      );

      expect(compiler.compilerSnapshot.readAsStringSync(), equals('SNAPSHOT'));
    });
  });
}
