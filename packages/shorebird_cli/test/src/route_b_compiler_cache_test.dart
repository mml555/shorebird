import 'dart:ffi' show Abi;
import 'dart:io' hide Platform;

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:platform/platform.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/abi.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/http_client/http_client.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_compiler_cache.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group(RouteBCompilerResolver, () {
    const engineRevision = 'engine-abc';

    late LocalAbi abi;
    late ArtifactManager artifactManager;
    late Cache cache;
    late http.Client httpClient;
    late ShorebirdLogger logger;
    late Platform platform;
    late Progress progress;
    late ShorebirdEnv shorebirdEnv;
    late Directory shorebirdRoot;
    late RouteBCompilerResolver resolver;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          abiRef.overrideWith(() => abi),
          artifactManagerRef.overrideWith(() => artifactManager),
          cacheRef.overrideWith(() => cache),
          httpClientRef.overrideWith(() => httpClient),
          loggerRef.overrideWith(() => logger),
          platformRef.overrideWith(() => platform),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
        },
      );
    }

    setUpAll(() {

      registerFallbackValue(Uri.parse('https://fallback.test'));
      registerFallbackValue(Directory(''));
      registerFallbackValue(File(''));
      registerFallbackValue(http.Request('GET', Uri.parse('https://x')));
    });

    setUp(() {
      abi = MockAbi();
      artifactManager = MockArtifactManager();
      cache = MockCache();
      httpClient = MockHttpClient();
      logger = MockShorebirdLogger();
      platform = MockPlatform();
      progress = MockProgress();
      shorebirdEnv = MockShorebirdEnv();
      shorebirdRoot = Directory.systemTemp.createTempSync();

      when(() => abi.current).thenReturn(Abi.macosArm64);
      when(() => platform.isMacOS).thenReturn(true);
      when(() => platform.isLinux).thenReturn(false);
      when(() => platform.isWindows).thenReturn(false);
      when(() => platform.environment).thenReturn({});
      when(() => logger.progress(any())).thenReturn(progress);
      when(() => shorebirdEnv.shorebirdRoot).thenReturn(shorebirdRoot);
      when(() => cache.storageBaseUrl).thenReturn('https://storage.test');
      when(() => cache.storageBucket).thenReturn('bucket.test');
      // These cases are all about the v1 path, so the cell descriptor is
      // genuinely ABSENT. Stubbed explicitly rather than left unstubbed: an
      // unstubbed mock returns null and fails with a type error that says
      // nothing about which rule was under test.
      when(() => httpClient.get(any())).thenAnswer(
        (_) async => http.Response('', HttpStatus.notFound),
      );
      when(
        () => cache.getArtifactDirectory(any()),
      ).thenAnswer(
        (invocation) => Directory(
          p.join(
            shorebirdRoot.path,
            invocation.positionalArguments.first as String,
          ),
        ),
      );

      resolver = RouteBCompilerResolver();
    });

    /// A zip carrying whatever the resolver is meant to validate.
    List<int> bundleZip({String? engineInProvenance, String? omit}) {
      final archive = Archive();
      void add(String name, List<int> bytes) {
        if (name == omit) return;
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      const runtime = 'runtime-bytes';
      const snapshot = 'snapshot-bytes';
      const dill = 'dill-bytes';
      const analyzer = 'analyzer-bytes';
      const frontend = 'frontend-bytes';
      const interfaceGen = 'interface-generator-bytes';
      const releaseProbe = 'release-probe-bytes';
      const flutterPlatform = 'flutter-platform-bytes';
      add('dartaotruntime', runtime.codeUnits);
      add('dart2bytecode.aot', snapshot.codeUnits);
      add('vm_platform.dill', dill.codeUnits);
      add('route_b_analyze.aot', analyzer.codeUnits);
      add('route_b_gen_kernel.aot', frontend.codeUnits);
      add('route_b_gen_dynamic_interface.aot', interfaceGen.codeUnits);
      add('route_b_release_probe.aot', releaseProbe.codeUnits);
      add('flutter_platform_strong.dill', flutterPlatform.codeUnits);
      // sha256 of the three payloads above, so the resolver's hash check
      // passes on a bundle that is genuinely intact.
      String hash(String s) => sha256.convert(s.codeUnits).toString();
      add(
        'PROVENANCE.txt',
        '''
engine revision  : ${engineInProvenance ?? engineRevision}

dart2bytecode.aot : ${hash(snapshot)}
dartaotruntime    : ${hash(runtime)}
vm_platform.dill  : ${hash(dill)}
route_b_analyze.aot : ${hash(analyzer)}
route_b_gen_kernel.aot : ${hash(frontend)}
route_b_gen_dynamic_interface.aot : ${hash(interfaceGen)}
route_b_release_probe.aot : ${hash(releaseProbe)}
flutter_platform_strong.dill : ${hash(flutterPlatform)}
'''
            .codeUnits,
      );
      return ZipEncoder().encode(archive);
    }

    void stubDownload(List<int> body, {int statusCode = 200}) {
      when(() => httpClient.send(any())).thenAnswer(
        (_) async => http.StreamedResponse(Stream.value(body), statusCode),
      );
    }

    /// Real extraction: the resolver's guarantees are about bytes on disk, and
    /// a stubbed extractor would prove nothing about them.
    void stubRealExtraction() {
      when(
        () => artifactManager.extractZip(
          zipFile: any(named: 'zipFile'),
          outputDirectory: any(named: 'outputDirectory'),
        ),
      ).thenAnswer((invocation) async {
        final zip = invocation.namedArguments[#zipFile] as File;
        final out = invocation.namedArguments[#outputDirectory] as Directory;
        await extractArchiveToDisk(
          ZipDecoder().decodeBytes(zip.readAsBytesSync()),
          out.path,
        );
      });
    }

    group('bundleFileName', () {
      test('names the host that will run the compiler', () {
        // Not the target being patched: dartaotruntime and dart2bytecode.aot
        // execute on this machine.
        expect(
          runWithOverrides(() => RouteBCompilerResolver.bundleFileName),
          'route-b-compiler-darwin-arm64.zip',
        );

        when(() => abi.current).thenReturn(Abi.macosX64);
        expect(
          runWithOverrides(() => RouteBCompilerResolver.bundleFileName),
          'route-b-compiler-darwin-x64.zip',
        );

        when(() => platform.isMacOS).thenReturn(false);
        when(() => platform.isLinux).thenReturn(true);
        expect(
          runWithOverrides(() => RouteBCompilerResolver.bundleFileName),
          'route-b-compiler-linux-x64.zip',
        );

        when(() => platform.isLinux).thenReturn(false);
        expect(
          runWithOverrides(() => RouteBCompilerResolver.bundleFileName),
          'route-b-compiler-windows-x64.zip',
        );
      });
    });

    group('resolve', () {
      test('requests the cell for the engine it was given', () async {
        // Keyed on the engine passed in, never on ambient state. This URL is
        // the whole contract with publish_route_b_compiler.sh.
        stubDownload(<int>[], statusCode: 404);

        await expectLater(
          runWithOverrides(
            () => resolver.resolve(engineRevision: engineRevision),
          ),
          throwsA(isA<RouteBCompilerException>()),
        );

        final request =
            verify(() => httpClient.send(captureAny())).captured.single
                as http.Request;
        expect(
          request.url.toString(),
          'https://storage.test/bucket.test/shorebird/$engineRevision/'
          'route-b-compiler-darwin-arm64.zip',
        );
      });

      test('reports 404 as tooling unavailable', () async {
        // The one status that means something specific: nothing was ever
        // published for this engine, so a new release will not help.
        stubDownload(<int>[], statusCode: 404);

        await expectLater(
          runWithOverrides(
            () => resolver.resolve(engineRevision: engineRevision),
          ),
          throwsA(
            isA<RouteBCompilerException>().having(
              (e) => e.problem,
              'problem',
              RouteBCompilerProblem.unavailable,
            ),
          ),
        );
      });

      test('reports other statuses as a download failure', () async {
        // Says nothing about the cell. Filing it under unavailable would send
        // someone to republish tooling that may be perfectly fine.
        stubDownload(<int>[], statusCode: 500);

        await expectLater(
          runWithOverrides(
            () => resolver.resolve(engineRevision: engineRevision),
          ),
          throwsA(isA<RouteBCompilerDownloadException>()),
        );
      });

      test('reports an unreachable host as a download failure', () async {
        when(() => httpClient.send(any())).thenThrow(const SocketException(''));

        await expectLater(
          runWithOverrides(
            () => resolver.resolve(engineRevision: engineRevision),
          ),
          throwsA(isA<RouteBCompilerDownloadException>()),
        );
      });

      test('reports a bundle from another engine as invalid', () async {
        // A bundle copied between engine hashes passes every other check, and
        // that is exactly the mixed-provenance failure this closes.
        stubDownload(bundleZip(engineInProvenance: 'some-other-engine'));
        stubRealExtraction();

        await expectLater(
          runWithOverrides(
            () => resolver.resolve(engineRevision: engineRevision),
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
                  contains('some-other-engine'),
                ),
          ),
        );
      });

      test('does not leave an invalid cell in the cache', () async {
        // A half-written or invalid extraction must never become the cache:
        // the next run would find it, skip validation, and compile with it.
        stubDownload(bundleZip(engineInProvenance: 'some-other-engine'));
        stubRealExtraction();

        await expectLater(
          runWithOverrides(
            () => resolver.resolve(engineRevision: engineRevision),
          ),
          throwsA(isA<RouteBCompilerException>()),
        );

        final cellDir = Directory(
          p.join(shorebirdRoot.path, 'route-b-compiler', engineRevision),
        );
        expect(cellDir.existsSync(), isFalse);
      });

      test('re-downloads once when a cached bundle fails validation', () async {
        // A cell can be REPUBLISHED under the same engine hash — adding an
        // artifact to it is exactly what the producer growing looks like — and
        // the download is cached by hash and platform. Without this a stale
        // bundle fails validation forever with a message that reads like
        // corruption. It happened on the rig the day the interface generator
        // joined the cell, and cost two releases before it was understood.
        var served = 0;
        when(() => httpClient.send(any())).thenAnswer((_) async {
          served++;
          return http.StreamedResponse(
            // A stale cell first, then whatever is published now.
            Stream.value(
              served == 1
                  ? bundleZip(omit: 'route_b_gen_dynamic_interface.aot')
                  : bundleZip(engineInProvenance: 'some-other-engine'),
            ),
            HttpStatus.ok,
          );
        });
        stubRealExtraction();

        // Still throws: the second cell is deliberately wrong too, because a
        // capability probe cannot run against fake bytes. The claim under test
        // is that it RE-FETCHED rather than failing on the cached copy forever.
        await expectLater(
          runWithOverrides(
            () => resolver.resolve(engineRevision: engineRevision),
          ),
          throwsA(isA<RouteBCompilerException>()),
        );

        expect(served, 2, reason: 'a stale cached bundle must be re-fetched');
      });

      test('does not re-download when nothing is published', () async {
        // A 404 says the cell was never published, so re-fetching cannot help
        // and retrying would only double the wait before the same answer.
        when(() => httpClient.send(any())).thenAnswer(
          (_) async => http.StreamedResponse(Stream.value(<int>[]), 404),
        );

        await expectLater(
          runWithOverrides(
            () => resolver.resolve(engineRevision: engineRevision),
          ),
          throwsA(
            isA<RouteBCompilerException>().having(
              (e) => e.problem,
              'problem',
              RouteBCompilerProblem.unavailable,
            ),
          ),
        );

        verify(() => httpClient.send(any())).called(1);
      });
    });
  });
}
