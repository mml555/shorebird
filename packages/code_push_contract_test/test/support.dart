import 'package:code_push_server/src/config.dart';

/// A [Config] for an embedded SQLite + filesystem backend rooted at [dataDir].
///
/// A copy of the small part of `code_push_server/test/support.dart` this test
/// needs: tests are not importable across packages, and a copy keeps the
/// server's own test helper free to change shape.
Config sqliteConfig(String dataDir, {String uploadMethod = 'multipart'}) =>
    Config(
      trustedProxies: Config.defaultTrustedProxies,
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
      rateLimitPerMinute: 600,
      rateLimitShared: false,
      uploadMethod: uploadMethod,
      idpClientId: '',
      idpClientSecret: '',
      idpAuthorizeUrl: '',
      idpTokenUrl: '',
      idpIssuer: '',
      idpScopes: 'openid email',
      production: false,
      dbBackend: 'sqlite',
      storageBackend: 'file',
      dataDir: dataDir,
      maxUploadBytes: 536870912,
      logFormat: 'text',
      dbSslMode: 'disable',
      loginEmail: 'owner@self-host.local',
      patchSigningKeySecret: 'test-patch-signing-key-secret-0123456789',
    );
