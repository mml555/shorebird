import 'package:mocktail/mocktail.dart';
import 'package:platform/platform.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/config/shorebird_yaml.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/runtime_endpoint.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/src/base/process.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group(RuntimeEndpoint, () {
    const selfHostedApi = 'http://localhost:18080';
    const deviceReachable = 'http://10.0.0.7:18080';

    late Platform platform;
    late ShorebirdEnv shorebirdEnv;
    late ShorebirdLogger logger;
    late RuntimeEndpoint runtimeEndpoint;

    R runWithOverrides<R>(R Function() body) => runScoped(
      body,
      values: {
        loggerRef.overrideWith(() => logger),
        platformRef.overrideWith(() => platform),
        shorebirdEnvRef.overrideWith(() => shorebirdEnv),
        runtimeEndpointRef.overrideWith(() => runtimeEndpoint),
      },
    );

    /// Sets the environment and the bundled `shorebird.yaml`'s `base_url`.
    void configure({
      String? hostedUrl,
      String? expectedRuntimeUrl,
      String? baseUrl,
    }) {
      final env = <String, String>{};
      if (hostedUrl != null) env[hostedUrlEnvVar] = hostedUrl;
      if (expectedRuntimeUrl != null) {
        env[runtimeBaseUrlEnvVar] = expectedRuntimeUrl;
      }
      when(() => platform.environment).thenReturn(env);
      when(
        shorebirdEnv.getShorebirdYaml,
      ).thenReturn(ShorebirdYaml(appId: 'test-app-id', baseUrl: baseUrl));
    }

    setUp(() {
      platform = MockPlatform();
      shorebirdEnv = MockShorebirdEnv();
      logger = MockShorebirdLogger();
      runtimeEndpoint = RuntimeEndpoint();
    });

    group('upstream workflow', () {
      // The control the fix must not break. Absence of base_url legitimately
      // means "use Shorebird's own service"; an upstream user has no
      // SHOREBIRD_HOSTED_URL and must be entirely unaffected.
      test('absent base_url remains valid and does not refuse', () {
        configure();

        expect(runWithOverrides(() => runtimeEndpoint.check()), isEmpty);
        expect(
          () => runWithOverrides(runtimeEndpoint.assertShippable),
          returnsNormally,
        );
      });

      test('an explicit upstream base_url is not refused', () {
        configure(baseUrl: 'https://$upstreamRuntimeHost');

        expect(runWithOverrides(() => runtimeEndpoint.check()), isEmpty);
      });
    });

    group('self-hosted workflow', () {
      // The Super Fixture failure, exactly: the CLI published against a
      // self-hosted control plane, the app shipped with app_id only, and the
      // device silently asked api.shorebird.dev for a patch it could never be
      // offered.
      test('REFUSES app_id only, with no base_url', () {
        configure(hostedUrl: selfHostedApi);

        final problems = runWithOverrides(() => runtimeEndpoint.check());
        expect(problems, hasLength(1));
        expect(problems.single.problem, RuntimeEndpointProblem.absent);

        expect(
          () => runWithOverrides(runtimeEndpoint.assertShippable),
          throwsA(
            isA<ProcessExit>().having((e) => e.exitCode, 'exitCode', 78),
          ),
        );
      });

      test('REFUSES a base_url that names upstream Shorebird', () {
        configure(
          hostedUrl: selfHostedApi,
          baseUrl: 'https://$upstreamRuntimeHost',
        );

        final problems = runWithOverrides(() => runtimeEndpoint.check());
        expect(problems.single.problem, RuntimeEndpointProblem.upstream);
      });

      test('REFUSES a base_url inconsistent with the configured endpoint', () {
        configure(
          hostedUrl: selfHostedApi,
          expectedRuntimeUrl: deviceReachable,
          baseUrl: 'http://192.168.1.5:18080',
        );

        final problems = runWithOverrides(() => runtimeEndpoint.check());
        expect(problems.single.problem, RuntimeEndpointProblem.inconsistent);
      });

      // The runtime endpoint is NOT derived from the control-plane URL: an
      // operator reaching the API on localhost still ships a device-reachable
      // address, and those disagreeing is normal rather than an error.
      test('accepts a runtime endpoint that differs from the API URL', () {
        configure(
          hostedUrl: selfHostedApi,
          expectedRuntimeUrl: deviceReachable,
          baseUrl: deviceReachable,
        );

        expect(runWithOverrides(() => runtimeEndpoint.check()), isEmpty);
      });

      test('accepts a base_url when no expected endpoint is configured', () {
        configure(hostedUrl: selfHostedApi, baseUrl: deviceReachable);

        expect(runWithOverrides(() => runtimeEndpoint.check()), isEmpty);
      });

      test('a trailing slash is not a difference worth refusing over', () {
        configure(
          hostedUrl: selfHostedApi,
          expectedRuntimeUrl: deviceReachable,
          baseUrl: '$deviceReachable/',
        );

        expect(runWithOverrides(() => runtimeEndpoint.check()), isEmpty);
      });

      // Closes the hole where self-hosted intent is declared ONLY by naming the
      // runtime endpoint: without this, the gate would not engage at all.
      test('REFUSES when only the runtime endpoint declares self-hosting', () {
        configure(expectedRuntimeUrl: deviceReachable);

        final problems = runWithOverrides(() => runtimeEndpoint.check());
        expect(problems.single.problem, RuntimeEndpointProblem.absent);
      });
    });

    test('problem codes are stable', () {
      expect(
        RuntimeEndpointProblem.values.map((p) => p.code),
        equals([
          'RUNTIME_ENDPOINT_ABSENT',
          'RUNTIME_ENDPOINT_UPSTREAM',
          'RUNTIME_ENDPOINT_INCONSISTENT',
        ]),
      );
    });
  });
}
