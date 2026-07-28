import 'package:code_push_server/src/config.dart';
import 'package:test/test.dart';

/// Builds a Config with all-real (non-dev-default) values, overridable per test.
Config _cfg({
  bool production = true,
  String bootstrapApiKey = 'sb_api_realkey_0123456789abcdef',
  String dbPassword = 'a-real-db-password',
  String s3SecretKey = 'a-real-s3-secret',
  String urlSigningSecret = 'a-real-url-signing-secret',
  String publicBaseUrl = 'https://cps.example.com',
  String dbSslMode = 'disable',
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
    maxUploadBytes: 536870912,
    logFormat: 'text',
    dbSslMode: dbSslMode,
    loginEmail: 'owner@self-host.local',
  );
}

void main() {
  group('Config.validate()', () {
    test('non-production still allows dev-default infra credentials', () {
      // The Postgres/MinIO defaults are internal-network credentials and stay
      // production-gated. The two published placeholders do not — see below.
      final c = _cfg(
        production: false,
        dbPassword: 'cps',
        s3SecretKey: 'cps-secret',
        publicBaseUrl: 'http://10.0.0.7:8080',
      );
      expect(c.validate(), isEmpty);
    });

    test('the published placeholder secrets are rejected in EVERY mode', () {
      // These two literals are committed to this repository. API_KEY
      // authenticates as an owner of the root org (server admin: mint an API
      // key for any address, promote any patch to every device) and
      // URL_SIGNING_SECRET forges /download URLs. Gating them behind
      // PRODUCTION is what made `docker compose up -d` with no .env a
      // network-reachable admin bypass — nothing on that path sets PRODUCTION.
      for (final production in [true, false]) {
        expect(
          _cfg(
            production: production,
            urlSigningSecret: Config.devUrlSigningSecret,
          ).validate(),
          contains(startsWith('URL_SIGNING_SECRET is the published')),
          reason: 'production=$production',
        );
        expect(
          _cfg(
            production: production,
            bootstrapApiKey: Config.devApiKey,
          ).validate(),
          contains(startsWith('API_KEY is the published')),
          reason: 'production=$production',
        );
      }
    });

    test('an empty API key is rejected in every mode', () {
      // An empty key matches a blank `Authorization: Bearer ` header, so it is
      // not a valid way to retire the bootstrap key in any mode.
      for (final production in [true, false]) {
        expect(
          _cfg(production: production, bootstrapApiKey: '').validate(),
          contains('API_KEY must not be empty'),
          reason: 'production=$production',
        );
      }
    });

    test('production with all real secrets passes', () {
      expect(_cfg().validate(), isEmpty);
    });

    test('production catches each dev-default secret by name', () {
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

    test('an unrecognized DB_SSL_MODE is a problem in every mode', () {
      // WAS: `switch (env['DB_SSL_MODE']) { ..., _ => 'disable' }`. A typo like
      // `verify_full` or `required` silently downgraded to plaintext, so the
      // database credentials crossed the network in the clear with no error,
      // no warning, and no way for the operator to notice.
      for (final bad in ['verify_full', 'required', 'VERIFY-FULL', '']) {
        expect(
          _cfg(production: false, dbSslMode: bad).validate(),
          contains(startsWith('DB_SSL_MODE=')),
          reason: bad,
        );
      }
    });

    test('every documented DB_SSL_MODE value is accepted', () {
      for (final ok in Config.dbSslModes) {
        expect(_cfg(dbSslMode: ok).validate(), isEmpty, reason: ok);
      }
    });

    test(
      'a fully dev-default production config reports every problem at once',
      () {
        final c = _cfg(
          urlSigningSecret: Config.devUrlSigningSecret,
          bootstrapApiKey: Config.devApiKey,
          dbPassword: 'cps',
          s3SecretKey: 'cps-secret',
          publicBaseUrl: 'http://cps.example.com',
        );
        expect(c.validate(), hasLength(5));
      },
    );
  });

  group('rate limits', () {
    test('the per-IP ceiling defaults above the per-principal limit', () {
      // The IP bucket is the one a caller can't rotate out of, but a single
      // NAT egress IP legitimately fronts many principals, so it has room.
      final c = _cfg();
      expect(c.ipRateLimitPerMinute, greaterThan(c.rateLimitPerMinute));
    });
  });
}
