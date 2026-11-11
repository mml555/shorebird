import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:platform/testing.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_origin.dart';
import 'package:shorebird_cli/src/http_client/http_client.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/src/base/process.dart';
import 'package:shorebird_cli/src/toolchain_coherence.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';
import 'package:test/test.dart';

import 'fakes.dart';
import 'helpers.dart';
import 'mocks.dart';

void main() {
  useTempWorkingDirectory();
  group(ToolchainCoherence, () {
    const cell = '4792f0eca461f3761001a1adbe131b4b115e3684';
    const priorCell = 'ca7d2c0d43bf975db2c42cc0aa6351d527443abf';
    const stock = '69f9831c360d9152862ec3897c67fb09ae843f3b';

    const iosModes = ['ios', 'ios-profile', 'ios-release'];

    late Directory flutterDir;
    late Directory publishedIos;
    late ToolchainCoherence coherence;

    /// Engine bytes belonging to [revision] for [mode].
    ///
    /// Per-mode AND per-revision, so a comparator that mixed up modes, or one
    /// that compared a mode against itself, could not pass.
    String engineBytes(String revision, String mode) =>
        'FLUTTER-ENGINE revision=$revision mode=$mode';

    /// Writes a zip at [zipPath] containing [content] at the ios-arm64 engine
    /// path, which is where the production comparator reads from.
    void writePublishedEngineZip(String zipPath, String content) {
      final stage = Directory.systemTemp.createTempSync('stage');
      File(
          p.join(
            stage.path,
            'Flutter.xcframework',
            'ios-arm64',
            'Flutter.framework',
            'Flutter',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
      Directory(p.dirname(zipPath)).createSync(recursive: true);
      final result = Process.runSync('zip', [
        '-q',
        '-r',
        zipPath,
        '.',
      ], workingDirectory: stage.path);
      expect(result.exitCode, 0, reason: 'zip failed: ${result.stderr}');
      stage.deleteSync(recursive: true);
    }

    /// Builds a checkout whose stamps, gen_snapshots and engine bytes are what
    /// the arguments say. Defaults are the COHERENT case, so each test states
    /// only its own defect.
    void makeCheckout({
      String engineStamp = cell,
      String? dartSdkStamp = cell,
      bool patchableGenSnapshot = true,
      String cachedEngineRevision = cell,
      String publishedEngineRevision = cell,
      bool cacheIosEngines = true,
      bool publishIosEngines = true,
      Set<String> omitPublishedModes = const {},
    }) {
      final cache = Directory(p.join(flutterDir.path, 'bin', 'cache'))
        ..createSync(recursive: true);
      File(
        p.join(cache.path, 'engine.stamp'),
      ).writeAsStringSync('$engineStamp\n');
      if (dartSdkStamp != null) {
        File(
          p.join(cache.path, 'engine-dart-sdk.stamp'),
        ).writeAsStringSync('$dartSdkStamp\n');
      }
      for (final mode in iosModes) {
        final dir = Directory(p.join(cache.path, 'artifacts', 'engine', mode))
          ..createSync(recursive: true);
        // A stand-in binary: what the check looks for is the flag NAME as a
        // delimited token, exactly as the VM stores it.
        final body = patchableGenSnapshot
            ? 'xx patchable_static_calls yy'
            : 'xx some_other_flag yy';
        File(p.join(dir.path, 'gen_snapshot_arm64')).writeAsStringSync(body);

        if (cacheIosEngines) {
          File(
              p.join(
                dir.path,
                'Flutter.xcframework',
                'ios-arm64',
                'Flutter.framework',
                'Flutter',
              ),
            )
            ..createSync(recursive: true)
            ..writeAsStringSync(engineBytes(cachedEngineRevision, mode));
        }

        if (publishIosEngines && !omitPublishedModes.contains(mode)) {
          writePublishedEngineZip(
            p.join(publishedIos.path, mode, 'artifacts.zip'),
            engineBytes(publishedEngineRevision, mode),
          );
        }
      }
    }

    List<ToolchainCoherenceProblem> checkFor(
      ReleasePlatform platform, {
      bool withPublishedIos = true,
    }) => coherence.check(
      flutterDirectory: flutterDir,
      engineRevision: cell,
      platform: platform,
      publishedIosEngineDir: withPublishedIos ? publishedIos : null,
    );

    setUp(() {
      flutterDir = Directory.systemTemp.createTempSync('coherence');
      publishedIos = Directory.systemTemp.createTempSync('published');
      coherence = const ToolchainCoherence();
    });

    tearDown(() {
      if (flutterDir.existsSync()) flutterDir.deleteSync(recursive: true);
      if (publishedIos.existsSync()) publishedIos.deleteSync(recursive: true);
    });

    test('reports nothing when the toolchain is coherent', () {
      makeCheckout();
      expect(checkFor(ReleasePlatform.ios), isEmpty);
    });

    test('catches a stale HOST DART SDK, the defect this exists for', () {
      // engine.version and the engine artifacts agree; only the kernel producer
      // is behind. This is precisely the state that produced an app.dill which
      // aborted the mandatory snapshot-profile writer while gen_snapshot was
      // byte-identical to a known-good one.
      makeCheckout(dartSdkStamp: stock);
      final problems = checkFor(ReleasePlatform.ios);
      expect(problems, hasLength(1));
      expect(problems.single.code, ToolchainIncoherence.hostDartSdkStale);
      // The identities must be in the message; 'stale' alone is not actionable.
      expect(problems.single.detail, contains(stock));
      expect(problems.single.detail, contains(cell));
    });

    test('catches stale engine artifacts', () {
      makeCheckout(engineStamp: stock);
      expect(
        checkFor(ReleasePlatform.ios).map((e) => e.code),
        contains(ToolchainIncoherence.engineArtifactsStale),
      );
    });

    test('a MISSING stamp is undeterminable, not coherent', () {
      // Not established is not the same as unchanged.
      makeCheckout(dartSdkStamp: null);
      final problems = checkFor(ReleasePlatform.ios);
      expect(problems, hasLength(1));
      expect(problems.single.code, ToolchainIncoherence.undeterminable);
    });

    test('catches a stock gen_snapshot', () {
      makeCheckout(patchableGenSnapshot: false);
      final problems = checkFor(ReleasePlatform.ios);
      expect(problems, hasLength(3)); // one per iOS mode
      expect(problems.map((e) => e.code).toSet(), {
        ToolchainIncoherence.genSnapshotNotPatchable,
      });
    });

    test('does not match the flag name inside a longer identifier', () {
      // Guards the token check itself: a binary mentioning
      // patchable_static_calls_v2 does not advertise this flag.
      makeCheckout();
      for (final mode in iosModes) {
        File(
          p.join(
            flutterDir.path,
            'bin',
            'cache',
            'artifacts',
            'engine',
            mode,
            'gen_snapshot_arm64',
          ),
        ).writeAsStringSync(' patchable_static_calls_v2 ');
      }
      expect(checkFor(ReleasePlatform.ios).map((e) => e.code).toSet(), {
        ToolchainIncoherence.genSnapshotNotPatchable,
      });
    });

    // ------------------------------------------------------------------
    // THE FALSE-GREEN. Measured on 2026-08-27 activating cell 4792f0ec: the
    // producer gate would have authorized a release built against the PREVIOUS
    // cell's runtime, because every check it had compared stamps or a
    // capability flag, and neither can tell one Route B cell from another.
    // ------------------------------------------------------------------
    group('cached engine identity', () {
      test(
        'REFUSES the exact state that passed: stamps current, engines stale',
        () {
          // Reproduces it precisely:
          //   engine.version / engine.stamp / engine-dart-sdk.stamp  4792f0ec
          //   cached iOS engines                                     ca7d2c0d's
          //   gen_snapshot patchable_static_calls                    present
          makeCheckout(cachedEngineRevision: priorCell);

          final problems = checkFor(ReleasePlatform.ios);

          expect(
            problems.map((e) => e.code).toSet(),
            {ToolchainIncoherence.engineArtifactsStale},
            reason:
                'no stamp or capability problem exists in this state — the '
                'byte comparison is the only thing that can catch it',
          );
          // ALL THREE modes named, not just the release one: a partially
          // refreshed cache is as incoherent as a wholly stale one.
          expect(problems, hasLength(3));
          for (final mode in iosModes) {
            // 'ios' is a prefix of the other two mode names, so match the
            // exact phrase rather than the bare mode.
            final forMode = problems.where(
              (e) => e.detail.contains('cached $mode engine'),
            );
            expect(forMode, hasLength(1), reason: 'expected one for $mode');
            // Both digests present, so the failure is actionable.
            expect(forMode.single.detail, contains(cell));
          }
        },
      );

      test('PASSES once the real engines are in the cache', () {
        // The other half of the pair. Same everything, engines substituted.
        makeCheckout();
        expect(checkFor(ReleasePlatform.ios), isEmpty);
      });

      test('a per-mode mismatch is caught, not averaged away', () {
        // Only ios-profile is stale. A comparator that checked one mode and
        // generalised, or that stopped at the first match, would miss this.
        makeCheckout();
        File(
          p.join(
            flutterDir.path,
            'bin',
            'cache',
            'artifacts',
            'engine',
            'ios-profile',
            'Flutter.xcframework',
            'ios-arm64',
            'Flutter.framework',
            'Flutter',
          ),
        ).writeAsStringSync(engineBytes(priorCell, 'ios-profile'));

        final problems = checkFor(ReleasePlatform.ios);
        expect(problems, hasLength(1));
        expect(
          problems.single.code,
          ToolchainIncoherence.engineArtifactsStale,
        );
        expect(problems.single.detail, contains('ios-profile'));
      });

      test('a MISSING cached engine is UNDETERMINABLE, never green', () {
        // The producer gate deliberately differs from the diagnostic script
        // here. At producer time an absent engine means the identity was not
        // established, and absence is not a match.
        makeCheckout(cacheIosEngines: false);
        final problems = checkFor(ReleasePlatform.ios);
        expect(problems, hasLength(3));
        expect(problems.map((e) => e.code).toSet(), {
          ToolchainIncoherence.undeterminable,
        });
      });

      test('an UNSET published source is UNDETERMINABLE and refuses', () {
        // Stamps alone must not be allowed to stand in for identity — that is
        // exactly the substitution that produced the false green.
        makeCheckout();
        final problems = checkFor(
          ReleasePlatform.ios,
          withPublishedIos: false,
        );
        expect(problems, hasLength(1));
        expect(problems.single.code, ToolchainIncoherence.undeterminable);
        expect(
          problems.single.detail,
          contains(publishedIosEngineDirEnvVar),
        );
      });

      test('a published root that does not exist is UNDETERMINABLE', () {
        makeCheckout();
        publishedIos.deleteSync(recursive: true);
        final problems = checkFor(ReleasePlatform.ios);
        expect(problems, hasLength(1));
        expect(problems.single.code, ToolchainIncoherence.undeterminable);
      });

      test('a published zip missing for ONE mode is UNDETERMINABLE', () {
        makeCheckout(omitPublishedModes: const {'ios-release'});
        final problems = checkFor(ReleasePlatform.ios);
        expect(problems, hasLength(1));
        expect(problems.single.code, ToolchainIncoherence.undeterminable);
        expect(problems.single.detail, contains('ios-release'));
      });

      test('an unreadable published zip is UNDETERMINABLE', () {
        makeCheckout();
        // A file that is not a zip at all: the comparator must refuse rather
        // than treat an unreadable source as agreement.
        File(
          p.join(publishedIos.path, 'ios-release', 'artifacts.zip'),
        ).writeAsStringSync('not a zip');
        final problems = checkFor(ReleasePlatform.ios);
        expect(problems, hasLength(1));
        expect(problems.single.code, ToolchainIncoherence.undeterminable);
      });

      test('android is unaffected by any of it', () {
        // The causal pair for engine identity, mirroring the gen_snapshot one:
        // the SAME stale iOS engines, the only difference being the platform.
        makeCheckout(cachedEngineRevision: priorCell);
        expect(checkFor(ReleasePlatform.android), isEmpty);
        expect(
          checkFor(ReleasePlatform.ios).map((e) => e.code).toSet(),
          {ToolchainIncoherence.engineArtifactsStale},
        );
      });

      test('android does not need a published iOS source at all', () {
        makeCheckout();
        expect(
          checkFor(ReleasePlatform.android, withPublishedIos: false),
          isEmpty,
        );
      });
    });

    group('platform scoping', () {
      // The invariant is: a producer may only build a platform when the
      // components THAT PLATFORM uses are coherent with the engine it claims.
      // Not: every platform in the checkout must be qualified before any may
      // build. The engine cell is an iOS Route B specialization activated by
      // overwriting engine.version for the whole checkout, so the unscoped
      // version blocked Android entirely -- no cell carries Android artifacts.

      test('android: matching stamps PASS', () {
        makeCheckout();
        expect(checkFor(ReleasePlatform.android), isEmpty);
      });

      test('android: stale engine-dart-sdk.stamp REFUSES', () {
        // The universal checks stay universal: today's mixed-toolchain defect
        // is impossible on Android as well as iOS.
        makeCheckout(dartSdkStamp: stock);
        expect(
          checkFor(ReleasePlatform.android).map((e) => e.code),
          contains(ToolchainIncoherence.hostDartSdkStale),
        );
      });

      test('android: stale engine.stamp REFUSES', () {
        makeCheckout(engineStamp: stock);
        expect(
          checkFor(ReleasePlatform.android).map((e) => e.code),
          contains(ToolchainIncoherence.engineArtifactsStale),
        );
      });

      test('android: a MISSING stamp is UNDETERMINABLE and refuses', () {
        makeCheckout(dartSdkStamp: null);
        expect(
          checkFor(ReleasePlatform.android).map((e) => e.code),
          contains(ToolchainIncoherence.undeterminable),
        );
      });

      // ---- the causal pair for the scope change ----
      // Same checkout, same non-Route-B iOS compiler. The ONLY difference
      // is the platform being produced. This is what shows the protection was
      // scoped, not deleted.
      test('android: a non-Route-B iOS gen_snapshot is IRRELEVANT', () {
        makeCheckout(patchableGenSnapshot: false);
        expect(checkFor(ReleasePlatform.android), isEmpty);
      });

      test('ios: that SAME non-Route-B gen_snapshot REFUSES', () {
        makeCheckout(patchableGenSnapshot: false);
        expect(checkFor(ReleasePlatform.ios).map((e) => e.code).toSet(), {
          ToolchainIncoherence.genSnapshotNotPatchable,
        });
      });

      test('ios: the exact Route B token PASSES', () {
        makeCheckout();
        expect(checkFor(ReleasePlatform.ios), isEmpty);
      });

      test('android says explicitly what was NOT evaluated', () {
        // Silence would make a green Android line read as a claim about the iOS
        // half. It must not — and that now covers engine identity too, which is
        // the check whose silence would have been most costly.
        expect(
          coherence.describe(
            platform: ReleasePlatform.android,
            engineRevision: cell,
          ),
          allOf(
            contains('platform=android'),
            contains('iOS Route B capability: NOT EVALUATED'),
            contains('iOS engine identity: NOT EVALUATED'),
          ),
        );
        expect(
          coherence.describe(
            platform: ReleasePlatform.ios,
            engineRevision: cell,
          ),
          allOf(
            isNot(contains('NOT EVALUATED')),
            contains('iOS engine identity: VERIFIED'),
          ),
        );
      });
    });

    group('assertToolchainCoherent', () {
      late ShorebirdEnv shorebirdEnv;
      late ShorebirdLogger logger;
      late TestNativePlatform platform;
      late http.Client httpClient;
      late Directory shorebirdRoot;

      const mirror = 'https://mirror.test';

      R runWithOverrides<R>(R Function() body) => runScoped(
        body,
        values: {
          httpClientRef.overrideWith(() => httpClient),
          loggerRef.overrideWith(() => logger),
          platformRef.overrideWith(() => platform),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          toolchainCoherenceRef.overrideWith(() => coherence),
        },
      );

      Future<void> assertIos() => runWithOverrides(
        () => coherence.assertCoherent(releasePlatform: ReleasePlatform.ios),
      );

      String publishedUrl(String mode) =>
          '$mirror/flutter_infra_release/flutter/$cell/$mode/artifacts.zip';

      Directory keptDir() => Directory(
        p.join(shorebirdRoot.path, 'bin', 'cache', 'published_ios_engines'),
      );

      /// The record kept for [cell] fetched from [mirror].
      File keptDigests() {
        final baseKey = sha256
            .convert(utf8.encode(mirror))
            .toString()
            .substring(0, 16);
        return File(p.join(keptDir().path, '$cell-$baseKey.json'));
      }

      String digestOf(String revision, String mode) =>
          sha256.convert(utf8.encode(engineBytes(revision, mode))).toString();

      /// Serves the zips [makeCheckout] wrote under `publishedIos` at the
      /// mirror's URLs, the way the Flutter tool would fetch them.
      void serveMirror({
        int statusCode = HttpStatus.ok,
        String? failingMode,
        String? brokenStreamMode,
      }) {
        when(() => httpClient.send(any())).thenAnswer((invocation) async {
          final request = invocation.positionalArguments.first as http.Request;
          final mode = iosEngineModes.firstWhere(
            (m) => request.url.toString() == publishedUrl(m),
          );
          final zip = File(p.join(publishedIos.path, mode, 'artifacts.zip'));
          if (mode == brokenStreamMode) {
            return http.StreamedResponse(
              Stream<List<int>>.error(const SocketException('reset')),
              HttpStatus.ok,
            );
          }
          final status = (failingMode == null || mode == failingMode)
              ? statusCode
              : HttpStatus.ok;
          return http.StreamedResponse(
            Stream.value(
              status == HttpStatus.ok ? zip.readAsBytesSync() : <int>[],
            ),
            status,
          );
        });
      }

      setUpAll(() {
        registerFallbackValue(FakeBaseRequest());
      });

      setUp(() {
        shorebirdEnv = MockShorebirdEnv();
        logger = MockShorebirdLogger();
        httpClient = MockHttpClient();
        shorebirdRoot = Directory.systemTemp.createTempSync('shorebird_root');
        platform = TestNativePlatform(
          environment: {publishedIosEngineDirEnvVar: publishedIos.path},
        );
        when(() => shorebirdEnv.flutterDirectory).thenReturn(flutterDir);
        when(() => shorebirdEnv.shorebirdEngineRevision).thenReturn(cell);
        when(() => shorebirdEnv.shorebirdRoot).thenReturn(shorebirdRoot);
        when(() => logger.progress(any())).thenReturn(MockProgress());
      });

      tearDown(() {
        if (shorebirdRoot.existsSync()) {
          shorebirdRoot.deleteSync(recursive: true);
        }
      });

      test('returns normally when coherent', () async {
        makeCheckout();
        await expectLater(assertIos(), completes);
        verifyNever(() => httpClient.send(any()));
      });

      test(
        'REFUSES before publication when engine-dart-sdk.stamp is incoherent',
        () async {
          // The mutation control for the producer gate: this is the state that
          // shipped a release which could not be patched, and it must now stop
          // the build instead of being discovered afterwards.
          makeCheckout(dartSdkStamp: stock);
          await expectLater(assertIos(), throwsA(isA<ProcessExit>()));
          verify(
            () => logger.err(
              any(that: contains('not coherent with its engine revision')),
            ),
          ).called(1);
        },
      );

      test('refuses when a gen_snapshot is stock', () async {
        makeCheckout(patchableGenSnapshot: false);
        await expectLater(assertIos(), throwsA(isA<ProcessExit>()));
      });

      // THE PRODUCER-LEVEL REGRESSION. `release ios` and `patch ios` both route
      // through here, so this is the assertion that a stale-cache release is
      // refused rather than published.
      test('REFUSES the stale-engine state at the producer boundary', () async {
        makeCheckout(cachedEngineRevision: priorCell);
        await expectLater(assertIos(), throwsA(isA<ProcessExit>()));
        // One per stale mode: the producer names each, rather than collapsing
        // three stale engines into a single line.
        verify(
          () => logger.err(
            any(that: contains(ToolchainIncoherence.engineArtifactsStale.wire)),
          ),
        ).called(3);
      });

      test('an ANDROID build still passes with no published source', () async {
        platform = platform.copyWith(environment: {});
        makeCheckout();
        await expectLater(
          runWithOverrides(
            () => coherence.assertCoherent(
              releasePlatform: ReleasePlatform.android,
            ),
          ),
          completes,
        );
        verifyNever(() => httpClient.send(any()));
      });

      group('with $publishedIosEngineDirEnvVar unset', () {
        setUp(() {
          platform = platform.copyWith(
            environment: {ArtifactOrigin.flutterStorageKey: mirror},
          );
        });

        test(
          'fetches the published engines from the mirror and passes',
          () async {
            makeCheckout();
            serveMirror();
            await expectLater(assertIos(), completes);
            for (final mode in iosEngineModes) {
              verify(
                () => httpClient.send(
                  any(
                    that: isA<http.Request>().having(
                      (r) => r.url.toString(),
                      'url',
                      publishedUrl(mode),
                    ),
                  ),
                ),
              ).called(1);
            }
            expect(keptDigests().existsSync(), isTrue);
          },
        );

        test(
          'keeps the digests, so the next build downloads nothing',
          () async {
            makeCheckout();
            serveMirror();
            await assertIos();
            clearInteractions(httpClient);
            await expectLater(assertIos(), completes);
            verifyNever(() => httpClient.send(any()));
          },
        );

        test('REFUSES a stale cache against the fetched engines', () async {
          makeCheckout(cachedEngineRevision: priorCell);
          serveMirror();
          await expectLater(assertIos(), throwsA(isA<ProcessExit>()));
          verify(
            () => logger.err(
              any(
                that: contains(ToolchainIncoherence.engineArtifactsStale.wire),
              ),
            ),
          ).called(3);
        });

        test('a published zip the mirror lacks is UNDETERMINABLE', () async {
          makeCheckout();
          serveMirror(statusCode: HttpStatus.notFound);
          await expectLater(assertIos(), throwsA(isA<ProcessExit>()));
          verify(
            () => logger.err(
              any(
                that: allOf(
                  contains(ToolchainIncoherence.undeterminable.wire),
                  contains(publishedIosEngineDirEnvVar),
                  contains('${publishedUrl('ios')} answered 404'),
                ),
              ),
            ),
          ).called(1);
          expect(keptDigests().existsSync(), isFalse);
        });

        test('an unreachable mirror is UNDETERMINABLE', () async {
          makeCheckout();
          when(
            () => httpClient.send(any()),
          ).thenThrow(const SocketException('no route'));
          await expectLater(assertIos(), throwsA(isA<ProcessExit>()));
          verify(
            () => logger.err(any(that: contains('no route'))),
          ).called(1);
        });

        test('a record kept from ANOTHER origin is not used', () async {
          // The same revision can be different bytes on upstream and on a
          // mirror. A record from one must not judge a cache from the other:
          // here it names the prior cell's engines, and using it would refuse
          // a coherent cache (or, reversed, approve a stale one).
          makeCheckout();
          serveMirror();
          final other = File(p.join(keptDir().path, '$cell-other.json'))
            ..createSync(recursive: true)
            ..writeAsStringSync(
              jsonEncode({
                'source': 'https://elsewhere.test',
                'digests': {
                  for (final m in iosEngineModes) m: digestOf(priorCell, m),
                },
              }),
            );
          await expectLater(assertIos(), completes);
          verify(() => httpClient.send(any())).called(3);
          expect(other.existsSync(), isTrue);
          expect(keptDigests().existsSync(), isTrue);
        });

        test('a kept record whose source differs is fetched again', () async {
          makeCheckout();
          serveMirror();
          keptDigests()
            ..createSync(recursive: true)
            ..writeAsStringSync(
              jsonEncode({
                'source': 'https://elsewhere.test',
                'digests': {
                  for (final m in iosEngineModes) m: digestOf(priorCell, m),
                },
              }),
            );
          await expectLater(assertIos(), completes);
          verify(() => httpClient.send(any())).called(3);
        });

        test(
          'a kept record with a malformed digest is fetched again',
          () async {
            makeCheckout();
            serveMirror();
            keptDigests()
              ..createSync(recursive: true)
              ..writeAsStringSync(
                jsonEncode({
                  'source': mirror,
                  'digests': {
                    for (final m in iosEngineModes) m: 'not-a-digest',
                  },
                }),
              );
            await expectLater(assertIos(), completes);
            verify(() => httpClient.send(any())).called(3);
          },
        );

        test('a failure on the LAST mode keeps nothing', () async {
          makeCheckout();
          serveMirror(
            statusCode: HttpStatus.notFound,
            failingMode: 'ios-release',
          );
          await expectLater(assertIos(), throwsA(isA<ProcessExit>()));
          verify(
            () => logger.err(
              any(
                that: contains('${publishedUrl('ios-release')} answered 404'),
              ),
            ),
          ).called(1);
          expect(keptDigests().existsSync(), isFalse);
        });

        test(
          'a stream that breaks after the headers is UNDETERMINABLE',
          () async {
            makeCheckout();
            serveMirror(brokenStreamMode: 'ios-profile');
            await expectLater(assertIos(), throwsA(isA<ProcessExit>()));
            verify(
              () => logger.err(
                any(
                  that: allOf(
                    contains(ToolchainIncoherence.undeterminable.wire),
                    contains(publishedUrl('ios-profile')),
                  ),
                ),
              ),
            ).called(1);
            expect(keptDigests().existsSync(), isFalse);
          },
        );

        test('a record that cannot be written refuses, never throws', () async {
          makeCheckout();
          serveMirror();
          // A FILE where the record directory goes.
          keptDir().parent.createSync(recursive: true);
          File(keptDir().path).writeAsStringSync('in the way');
          await expectLater(assertIos(), throwsA(isA<ProcessExit>()));
          verify(
            () => logger.err(
              any(that: contains('fetching the published iOS engines failed')),
            ),
          ).called(1);
        });

        test('an unreadable kept record is fetched again', () async {
          makeCheckout();
          serveMirror();
          keptDigests()
            ..createSync(recursive: true)
            ..writeAsStringSync('not json');
          await expectLater(assertIos(), completes);
          verify(() => httpClient.send(any())).called(3);
        });
      });
    });
  });
}
