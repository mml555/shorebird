import 'package:code_push_server/src/config.dart';

/// A [Config] for an embedded SQLite + filesystem backend rooted at [dataDir].
/// Shared by the backend integration tests (db_test, analytics_test).
Config sqliteConfig(
  String dataDir, {
  Set<String> trustedProxies = Config.defaultTrustedProxies,
  int? rateLimitPerMinute,
  int? rateLimitIpPerMinute,
  bool rateLimitShared = false,
  String? loginEmail,
  bool idpEnabled = false,
}) => Config(
  trustedProxies: trustedProxies,
  rateLimitIpPerMinute: rateLimitIpPerMinute,
  port: 8080,
  publicBaseUrl: 'http://localhost:8080',
  bootstrapApiKey: 'sb_api_selfhost_dev',
  dbHost: '',
  dbPort: 5432,
  dbName: 'code_push',
  dbUser: 'cps',
  dbPassword: '',
  s3Endpoint: '',
  s3Port: 9000,
  s3AccessKey: '',
  s3SecretKey: '',
  s3Bucket: 'code-push-artifacts',
  s3UseSsl: false,
  urlSigningSecret: 'x',
  jwtIssuer: 'http://localhost:8080',
  downloadUrlTtl: const Duration(seconds: 300),
  rateLimitPerMinute: rateLimitPerMinute ?? 600,
  rateLimitShared: rateLimitShared,
  uploadMethod: 'multipart',
  // All three must be non-empty for Config.idpEnabled; setting one is not
  // enough, so flip them together.
  idpClientId: idpEnabled ? 'client-id' : '',
  idpClientSecret: idpEnabled ? 'client-secret' : '',
  idpAuthorizeUrl: idpEnabled ? 'https://idp.test/authorize' : '',
  idpTokenUrl: idpEnabled ? 'https://idp.test/token' : '',
  idpScopes: 'openid email',
  production: false,
  dbBackend: 'sqlite',
  storageBackend: 'file',
  dataDir: dataDir,
  maxUploadBytes: 536870912,
  logFormat: 'text',
  dbSslMode: 'disable',
  loginEmail: loginEmail ?? 'owner@self-host.local',
);
