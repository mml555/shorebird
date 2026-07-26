import 'dart:io';

/// Runtime configuration, all overridable by environment variables.
class Config {
  Config({
    required this.port,
    required this.publicBaseUrl,
    required this.bootstrapApiKey,
    required this.dbHost,
    required this.dbPort,
    required this.dbName,
    required this.dbUser,
    required this.dbPassword,
    required this.s3Endpoint,
    required this.s3Port,
    required this.s3AccessKey,
    required this.s3SecretKey,
    required this.s3Bucket,
    required this.s3UseSsl,
    required this.urlSigningSecret,
    required this.jwtSecret,
    required this.jwtIssuer,
    required this.downloadUrlTtl,
    required this.rateLimitPerMinute,
    required this.rateLimitShared,
    required this.uploadMethod,
    required this.idpClientId,
    required this.idpClientSecret,
    required this.idpAuthorizeUrl,
    required this.idpTokenUrl,
    required this.idpScopes,
    required this.production,
    required this.dbBackend,
    required this.storageBackend,
    required this.dataDir,
  });

  factory Config.fromEnv() {
    final env = Platform.environment;
    final port = int.parse(env['PORT'] ?? '8080');
    final dbUri = Uri.parse(
      env['DATABASE_URL'] ?? 'postgres://cps:cps@localhost:55433/code_push',
    );
    final s3 = Uri.parse(env['S3_ENDPOINT'] ?? 'http://localhost:19000');
    // Backend selection. Defaults are the single-container, zero-dependency
    // path (embedded SQLite + local-disk artifacts). Setting DATABASE_URL /
    // S3_ENDPOINT auto-selects the scale backends, so the production compose
    // needs no extra flags.
    final dbBackend =
        env['DB_BACKEND'] ??
        (env.containsKey('DATABASE_URL') ? 'postgres' : 'sqlite');
    final storageBackend =
        env['STORAGE_BACKEND'] ??
        (env.containsKey('S3_ENDPOINT') ? 's3' : 'file');
    return Config(
      dbBackend: dbBackend,
      storageBackend: storageBackend,
      dataDir: env['DATA_DIR'] ?? './data',
      port: port,
      publicBaseUrl: env['PUBLIC_BASE_URL'] ?? 'http://localhost:$port',
      bootstrapApiKey: env['API_KEY'] ?? 'sb_api_selfhost_dev',
      dbHost: dbUri.host,
      dbPort: dbUri.hasPort ? dbUri.port : 5432,
      dbName: dbUri.pathSegments.isNotEmpty
          ? dbUri.pathSegments.first
          : 'code_push',
      dbUser: dbUri.userInfo.split(':').first,
      dbPassword: dbUri.userInfo.contains(':')
          ? dbUri.userInfo.split(':').last
          : '',
      s3Endpoint: s3.host,
      s3Port: s3.hasPort ? s3.port : (s3.scheme == 'https' ? 443 : 80),
      s3AccessKey: env['S3_ACCESS_KEY'] ?? 'cps',
      s3SecretKey: env['S3_SECRET_KEY'] ?? 'cps-secret',
      s3Bucket: env['S3_BUCKET'] ?? 'code-push-artifacts',
      s3UseSsl: s3.scheme == 'https',
      urlSigningSecret: env['URL_SIGNING_SECRET'] ?? 'dev-url-signing-secret',
      jwtSecret: env['JWT_SECRET'] ?? 'dev-jwt-signing-secret-change-me',
      jwtIssuer:
          env['SHOREBIRD_JWT_ISSUER'] ??
          env['JWT_ISSUER'] ??
          (env['PUBLIC_BASE_URL'] ?? 'http://localhost:$port'),
      downloadUrlTtl: Duration(
        seconds: int.parse(env['DOWNLOAD_URL_TTL'] ?? '300'),
      ),
      rateLimitPerMinute: int.parse(env['RATE_LIMIT_PER_MINUTE'] ?? '600'),
      rateLimitShared: env['RATE_LIMIT_BACKEND'] == 'postgres',
      uploadMethod: env['UPLOAD_METHOD'] == 'resumable'
          ? 'resumable'
          : 'multipart',
      idpClientId: env['IDP_CLIENT_ID'] ?? '',
      idpClientSecret: env['IDP_CLIENT_SECRET'] ?? '',
      idpAuthorizeUrl: env['IDP_AUTHORIZE_URL'] ?? '',
      idpTokenUrl: env['IDP_TOKEN_URL'] ?? '',
      idpScopes: env['IDP_SCOPES'] ?? 'openid email',
      production:
          (env['PRODUCTION'] ?? env['ENV']) == 'production' ||
          env['PRODUCTION'] == 'true',
    );
  }

  /// In production mode, refuse to boot with dev-default secrets. Returns the
  /// list of problems (empty = ok); the caller aborts if non-empty.
  List<String> validate() {
    if (!production) return const [];
    final problems = <String>[];
    if (jwtSecret == 'dev-jwt-signing-secret-change-me')
      problems.add('JWT_SECRET');
    if (urlSigningSecret == 'dev-url-signing-secret')
      problems.add('URL_SIGNING_SECRET');
    if (bootstrapApiKey == 'sb_api_selfhost_dev') problems.add('API_KEY');
    // DB/object-store credential checks apply only to the backend in use.
    if (dbBackend == 'postgres' &&
        (dbPassword.isEmpty || dbPassword == 'cps')) {
      problems.add('DATABASE_URL password');
    }
    if (storageBackend == 's3' && s3SecretKey == 'cps-secret') {
      problems.add('S3_SECRET_KEY');
    }
    if (publicBaseUrl.startsWith('http://') &&
        !publicBaseUrl.contains('localhost')) {
      problems.add('PUBLIC_BASE_URL should be https in production');
    }
    return problems;
  }

  final int port;

  /// Absolute base URL embedded in artifact upload/download URLs. Must be
  /// reachable from the device (LAN IP or an `adb reverse` localhost tunnel).
  final String publicBaseUrl;

  /// A bootstrap API key accepted in addition to any user-issued keys, so the
  /// server is usable before/without seeded users. Real per-user keys live in
  /// the database (multi-tenancy).
  final String bootstrapApiKey;

  final String dbHost;
  final int dbPort;
  final String dbName;
  final String dbUser;
  final String dbPassword;

  final String s3Endpoint;
  final int s3Port;
  final String s3AccessKey;
  final String s3SecretKey;
  final String s3Bucket;
  final bool s3UseSsl;

  /// HMAC secret for short-lived signed download URLs.
  final String urlSigningSecret;

  /// HMAC secret for minting session JWTs (OAuth login).
  final String jwtSecret;

  /// The `iss` claim stamped into JWTs; must equal the CLI's
  /// `SHOREBIRD_JWT_ISSUER` and the `jwt_issuer` returned by `/users/me`.
  final String jwtIssuer;

  final Duration downloadUrlTtl;
  final int rateLimitPerMinute;

  /// When true, rate-limit counters live in Postgres (correct across restarts
  /// and multiple nodes); otherwise an in-process fixed window (dev/single-node).
  final bool rateLimitShared;

  /// Artifact upload method advertised on register: 'multipart' (single POST)
  /// or 'resumable' (GCS-style chunked PUT with Content-Range).
  final String uploadMethod;

  /// External OAuth IdP (Google/Microsoft/etc.) to broker `shorebird login`
  /// against. When [idpEnabled] is false, /login self-consents the LOGIN_EMAIL
  /// identity (single-tenant / dev).
  final String idpClientId;
  final String idpClientSecret;
  final String idpAuthorizeUrl;
  final String idpTokenUrl;
  final String idpScopes;

  bool get idpEnabled =>
      idpClientId.isNotEmpty &&
      idpAuthorizeUrl.isNotEmpty &&
      idpTokenUrl.isNotEmpty;

  final bool production;

  /// `sqlite` (embedded, single-container default) or `postgres` (scale).
  final String dbBackend;

  /// `file` (local-disk artifacts, default) or `s3` (MinIO/S3 for scale).
  final String storageBackend;

  /// Directory for the SQLite database file and filesystem artifacts (the one
  /// thing to persist/back up in single-container mode).
  final String dataDir;
}
