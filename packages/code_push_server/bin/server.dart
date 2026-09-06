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
import 'package:code_push_server/src/observability.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main() async {
  final config = Config.fromEnv();
  // Set the process-wide log format before anything (migrations included) logs.
  configureLogging(json: config.logFormat == 'json');

  final problems = config.validate();
  if (problems.isNotEmpty) {
    stderr.writeln('FATAL: insecure config: ${problems.join(', ')}');
    if (config.production) {
      stderr.writeln(
        'Set real secrets (openssl rand -hex 32) before booting in production.',
      );
    }
    exit(78); // EX_CONFIG
  }
  // Not fatal, and deliberately quiet for the shipped compose: that talks to
  // an in-network Postgres over a private Docker network, addressed by the
  // bare service name `postgres`. A dotted host is a real network hop, and
  // reaching one with SSL off puts the credentials on the wire in the clear.
  if (config.dbBackend == 'postgres' &&
      config.dbSslMode == 'disable' &&
      config.dbHost.contains('.') &&
      !const {'127.0.0.1', '::1'}.contains(config.dbHost)) {
    logInfo('WARNING: DB_SSL_MODE=disable to a non-local database', {
      'db_host': config.dbHost,
      'hint': 'set DB_SSL_MODE=verify-full for a managed/external Postgres',
    });
  }

  // A rollback that lands an old image on a database a newer one has already
  // migrated. Surfaced as a FATAL with a distinct exit code rather than an
  // unhandled exception, so the operator is told what to do instead of reading
  // a stack trace out of a crash loop.
  final Repository repo;
  try {
    repo = await Repository.open(config);
  } on SchemaTooNewException catch (e) {
    stderr.writeln('FATAL: $e');
    exit(65); // EX_DATAERR
  }
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
  final database = config.dbBackend == 'sqlite'
      ? 'sqlite (${config.dataDir}/code_push.db)'
      : 'postgres ${config.dbHost}:${config.dbPort}/${config.dbName}';
  final artifacts = config.storageBackend == 's3'
      ? 's3 ${config.s3Endpoint}:${config.s3Port}/${config.s3Bucket}'
      : 'files (${config.dataDir}/artifacts)';
  if (jsonLogging) {
    logInfo('server listening', {
      'port': server.port,
      'production': config.production,
      'public_base_url': config.publicBaseUrl,
      'database': database,
      'artifacts': artifacts,
      'jwt_issuer': config.jwtIssuer,
    });
  } else {
    stdout.writeln(
      'code_push_server listening on ${server.port}'
      '${config.production ? ' [PRODUCTION]' : ''}',
    );
    stdout.writeln('  public base url : ${config.publicBaseUrl}');
    stdout.writeln('  database        : $database');
    stdout.writeln('  artifacts       : $artifacts');
    stdout.writeln('  jwt issuer      : ${config.jwtIssuer}');
  }

  // Periodic housekeeping. Each of these tables is written by unauthenticated
  // or abandoned traffic, so without a sweep they only ever grow.
  Future<void> housekeeping() async {
    try {
      await repo.purgeExpiredAuthCodes();
      await repo.purgeExpiredIdpStates();
      await repo.purgeOldRateWindows();
      // Opt-in, and off by default — these two hold data an operator may want
      // to keep. Unset, `events` and `audit_log` grow without bound.
      await repo.purgeOldEvents(config.eventRetentionDays);
      await repo.purgeOldAuditLog(config.auditRetentionDays);
    } on Object catch (e, st) {
      logError('housekeeping failed', e, st);
    }
  }

  // Sweep once at boot as well as on the timer: a deployment that restarts
  // more often than the interval (rolling deploys, a crash-restart loop,
  // repeated `docker compose up -d`) would otherwise never sweep at all, which
  // is exactly the unbounded growth this exists to stop.
  unawaited(housekeeping());
  final purgeTimer = Timer.periodic(
    const Duration(hours: 1),
    (_) => housekeeping(),
  );

  // Graceful shutdown: stop accepting connections, drain, close the pool.
  var shuttingDown = false;
  Future<void> shutdown(ProcessSignal sig) async {
    if (shuttingDown) return;
    shuttingDown = true;
    logInfo('shutting down', {'signal': '$sig'});
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
