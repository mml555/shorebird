import 'package:mason_logger/mason_logger.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/src/base/process.dart';

/// A reference to a [RuntimeEndpoint] instance.
final runtimeEndpointRef = create(RuntimeEndpoint.new);

/// The [RuntimeEndpoint] instance available in the current zone.
RuntimeEndpoint get runtimeEndpoint => read(runtimeEndpointRef);

/// The environment variable naming the CLI's control-plane address.
const hostedUrlEnvVar = 'SHOREBIRD_HOSTED_URL';

/// The environment variable naming the endpoint the SHIPPED APP must reach.
///
/// Separate from [hostedUrlEnvVar] on purpose. The address an operator uses for
/// control-plane API calls and the address a device can reach are not
/// necessarily the same host — `localhost:18080` works for the former and is
/// the phone itself for the latter — so the runtime endpoint is its own
/// configuration value rather than something derived from the API URL.
const runtimeBaseUrlEnvVar = 'SHOREBIRD_RUNTIME_BASE_URL';

/// The host the on-device updater falls back to when the bundled
/// `shorebird.yaml` carries no `base_url`.
const upstreamRuntimeHost = 'api.shorebird.dev';

/// One reason a release's runtime endpoint is not shippable, with a stable
/// code. The code is the contract; the prose may change.
enum RuntimeEndpointProblem {
  /// `shorebird.yaml` carries no `base_url`, so the shipped app would fall back
  /// to upstream Shorebird.
  absent('RUNTIME_ENDPOINT_ABSENT'),

  /// `base_url` names upstream Shorebird while the workflow is self-hosted.
  upstream('RUNTIME_ENDPOINT_UPSTREAM'),

  /// `base_url` disagrees with the configured runtime endpoint.
  inconsistent('RUNTIME_ENDPOINT_INCONSISTENT');

  const RuntimeEndpointProblem(this.code);

  /// The stable code callers may branch on.
  final String code;
}

/// One problem found with a release's runtime endpoint.
class RuntimeEndpointIssue {
  /// Creates a [RuntimeEndpointIssue].
  const RuntimeEndpointIssue(this.problem, this.detail);

  /// Which problem this is.
  final RuntimeEndpointProblem problem;

  /// Human-readable specifics.
  final String detail;

  @override
  String toString() => '[${problem.code}] $detail';
}

/// Verifies that a self-hosted release ships an app that talks to the
/// self-hosted control plane rather than to upstream Shorebird.
///
/// WHY THIS EXISTS. The updater's `base_url` is optional, and absence
/// legitimately means "use Shorebird's own service" — that is the upstream
/// contract and this gate does not touch it. The defect is narrower: a workflow
/// operating against a SELF-HOSTED control plane could publish a release whose
/// runtime silently pointed at `api.shorebird.dev`. The app then asks upstream
/// for patches to an app that exists only on the fork's control plane, is
/// offered nothing, and reports no error — the failure is invisible on both
/// sides. That is what this makes impossible.
///
/// Detection deliberately does NOT ask "does `shorebird.yaml` have a
/// `base_url`", because that is the value under examination. It asks whether
/// the OPERATOR declared a non-upstream deployment, via [hostedUrlEnvVar] or
/// [runtimeBaseUrlEnvVar].
class RuntimeEndpoint {
  /// Every reason this release's runtime endpoint is not shippable.
  ///
  /// Empty for an upstream workflow, always: absence of configuration is the
  /// upstream default and stays valid.
  List<RuntimeEndpointIssue> check() {
    final controlPlane = platform.environment[hostedUrlEnvVar];
    final expected = platform.environment[runtimeBaseUrlEnvVar];

    // No self-hosted intent declared -> upstream. Nothing to enforce.
    if (controlPlane == null && expected == null) return const [];

    final runtime = shorebirdEnv.getShorebirdYaml()?.baseUrl;

    if (runtime == null) {
      return [
        RuntimeEndpointIssue(
          RuntimeEndpointProblem.absent,
          'shorebird.yaml carries no base_url, so the shipped app would ask '
          'https://$upstreamRuntimeHost for patches, not this deployment '
          '(${expected ?? controlPlane}).',
        ),
      ];
    }

    if (Uri.tryParse(runtime)?.host == upstreamRuntimeHost) {
      return [
        RuntimeEndpointIssue(
          RuntimeEndpointProblem.upstream,
          'shorebird.yaml base_url is $runtime, which is upstream Shorebird, '
          'but this workflow targets a self-hosted control plane.',
        ),
      ];
    }

    if (expected != null && _normalize(runtime) != _normalize(expected)) {
      return [
        RuntimeEndpointIssue(
          RuntimeEndpointProblem.inconsistent,
          'shorebird.yaml base_url is $runtime but $runtimeBaseUrlEnvVar is '
          '$expected. The shipped app would talk to the wrong endpoint.',
        ),
      ];
    }

    return const [];
  }

  /// Refuses the build unless the runtime endpoint is shippable.
  ///
  /// Called BEFORE building, because the point is not to discover after the
  /// fact that a published release cannot reach its own control plane.
  void assertShippable() {
    final problems = check();
    if (problems.isEmpty) return;

    logger
      ..err('This release would not reach its own control plane.')
      ..err('');
    for (final problem in problems) {
      logger.err('  - $problem');
    }
    logger
      ..err('')
      ..err(
        'Refusing to build. An app whose base_url is missing or wrong asks '
        'upstream Shorebird for patches it does not have, is offered nothing, '
        'and reports no error — so the failure is silent on the device and '
        'invisible on the server.',
      )
      ..err(
        'Set base_url in shorebird.yaml to the endpoint the DEVICE can reach. '
        'That is not necessarily the address you use for CLI calls: '
        'localhost is the phone itself on a physical device.',
      );
    throw ProcessExit(ExitCode.config.code);
  }

  /// Trailing slashes are not a difference worth refusing over.
  String _normalize(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
