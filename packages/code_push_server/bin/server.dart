// code_push_server — self-hosted Shorebird control plane.
//
// Single-container by default (embedded SQLite + local-disk artifacts); an
// opt-in Postgres + S3/MinIO scale profile is auto-selected by DATABASE_URL /
// S3_ENDPOINT. Short-lived signed download URLs, partial rollouts, audit log +
// rate limiting, multi-tenancy, OAuth login, event-derived analytics,
// health/readiness, and graceful shutdown. Wire-compatible with the pinned
// Shorebird CLI + native updater.
import 'dart:async';
import 'dart:io';

import 'package:code_push_server/src/api.dart';
import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/oauth.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main() async {
  final config = Config.fromEnv();

  final problems = config.validate();
  if (problems.isNotEmpty) {
    stderr.writeln(
      'FATAL: PRODUCTION mode but insecure config: ${problems.join(', ')}',
    );
    stderr.writeln(
      'Set real secrets (openssl rand -hex 32) before booting in production.',
    );
    exit(78); // EX_CONFIG
  }

  final repo = await Repository.open(config);
  final store = await ArtifactStore.open(config);

  // Persist the OAuth signing key so issued JWTs survive restarts and are
  // valid across multiple server nodes (previously ephemeral per boot).
  final signingKeyJson = await repo.getOrCreateSetting(
    'oauth_signing_key',
    () => OAuthService.keyToJson(OAuthService.generateKey()),
  );
  final api = Api(repo, store, config, signingKeyJson: signingKeyJson);

  final server = await shelf_io.serve(
    api.handler,
    InternetAddress.anyIPv4,
    config.port,
  );
  // Close idle keep-alive connections so slow/abandoned clients can't tie up
  // sockets indefinitely (mild slow-loris mitigation).
  server.idleTimeout = const Duration(seconds: 60);
  stdout.writeln(
    'code_push_server listening on ${server.port}'
    '${config.production ? ' [PRODUCTION]' : ''}',
  );
  stdout.writeln('  public base url : ${config.publicBaseUrl}');
  if (config.dbBackend == 'sqlite') {
    stdout.writeln(
      '  database        : sqlite (${config.dataDir}/code_push.db)',
    );
  } else {
    stdout.writeln(
      '  database        : postgres ${config.dbHost}:${config.dbPort}/${config.dbName}',
    );
  }
  if (config.storageBackend == 's3') {
    stdout.writeln(
      '  artifacts       : s3 ${config.s3Endpoint}:${config.s3Port}/${config.s3Bucket}',
    );
  } else {
    stdout.writeln('  artifacts       : files (${config.dataDir}/artifacts)');
  }
  stdout.writeln('  jwt issuer      : ${config.jwtIssuer}');

  // Periodic housekeeping: drop expired, never-consumed OAuth auth codes.
  final purgeTimer = Timer.periodic(
    const Duration(hours: 1),
    (_) => repo.purgeExpiredAuthCodes(),
  );

  // Graceful shutdown: stop accepting connections, drain, close the pool.
  var shuttingDown = false;
  Future<void> shutdown(ProcessSignal sig) async {
    if (shuttingDown) return;
    shuttingDown = true;
    stdout.writeln('received $sig, shutting down...');
    purgeTimer.cancel();
    await server.close();
    await repo.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(shutdown);
  }
}
