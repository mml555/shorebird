import 'package:code_push_server/src/config.dart';
import 'package:test/test.dart';

/// Builds a Config with all-real (non-dev-default) values, overridable per test.
Config _cfg({
  bool production = true,
  String bootstrapApiKey = 'sb_api_realkey_0123456789abcdef',
  String dbPassword = 'a-real-db-password',
  String s3SecretKey = 'a-real-s3-secret',
  String urlSigningSecret = 'a-real-url-signing-secret',
  String jwtSecret = 'a-real-jwt-secret',
  String publicBaseUrl = 'https://cps.example.com',
}) {
  return Config(
    port: 8080,
    publicBaseUrl: publicBaseUrl,
    bootstrapApiKey: bootstrapApiKey,
    dbHost: 'postgres',
    dbPort: 5432,
    dbName: 'code_push',
    dbUser: 'cps',
    dbPassword: dbPassword,
    s3Endpoint: 'minio',
    s3Port: 9000,
    s3AccessKey: 'cps',
    s3SecretKey: s3SecretKey,
    s3Bucket: 'code-push-artifacts',
    s3UseSsl: false,
    urlSigningSecret: urlSigningSecret,
    jwtSecret: jwtSecret,
    jwtIssuer: publicBaseUrl,
    downloadUrlTtl: const Duration(seconds: 300),
    rateLimitPerMinute: 600,
    rateLimitShared: false,
    uploadMethod: 'multipart',
    idpClientId: '',
    idpClientSecret: '',
    idpAuthorizeUrl: '',
    idpTokenUrl: '',
    idpScopes: 'openid email',
    production: production,
    dbBackend: 'postgres',
    storageBackend: 's3',
    dataDir: './data',
  );
}

void main() {
  group('Config.validate()', () {
    test('non-production never complains (dev defaults allowed)', () {
      final c = _cfg(
        production: false,
        jwtSecret: 'dev-jwt-signing-secret-change-me',
        urlSigningSecret: 'dev-url-signing-secret',
        bootstrapApiKey: 'sb_api_selfhost_dev',
        dbPassword: 'cps',
        s3SecretKey: 'cps-secret',
        publicBaseUrl: 'http://10.0.0.7:8080',
      );
      expect(c.validate(), isEmpty);
    });

    test('production with all real secrets passes', () {
      expect(_cfg().validate(), isEmpty);
    });

    test('production catches each dev-default secret by name', () {
      expect(
        _cfg(jwtSecret: 'dev-jwt-signing-secret-change-me').validate(),
        contains('JWT_SECRET'),
      );
      expect(
        _cfg(urlSigningSecret: 'dev-url-signing-secret').validate(),
        contains('URL_SIGNING_SECRET'),
      );
      expect(
        _cfg(bootstrapApiKey: 'sb_api_selfhost_dev').validate(),
        contains('API_KEY'),
      );
      expect(
        _cfg(s3SecretKey: 'cps-secret').validate(),
        contains('S3_SECRET_KEY'),
      );
    });

    test('production catches empty and default db password', () {
      expect(
        _cfg(dbPassword: '').validate(),
        contains('DATABASE_URL password'),
      );
      expect(
        _cfg(dbPassword: 'cps').validate(),
        contains('DATABASE_URL password'),
      );
    });

    test('production requires https public base url (localhost exempt)', () {
      expect(
        _cfg(publicBaseUrl: 'http://cps.example.com').validate(),
        contains('PUBLIC_BASE_URL should be https in production'),
      );
      // localhost over http is allowed (local TLS-terminated testing).
      expect(_cfg(publicBaseUrl: 'http://localhost:8080').validate(), isEmpty);
    });

    test(
      'a fully dev-default production config reports every problem at once',
      () {
        final c = _cfg(
          jwtSecret: 'dev-jwt-signing-secret-change-me',
          urlSigningSecret: 'dev-url-signing-secret',
          bootstrapApiKey: 'sb_api_selfhost_dev',
          dbPassword: 'cps',
          s3SecretKey: 'cps-secret',
          publicBaseUrl: 'http://cps.example.com',
        );
        expect(c.validate(), hasLength(6));
      },
    );
  });
}
