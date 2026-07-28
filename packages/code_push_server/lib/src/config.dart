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
    required this.jwtIssuer,
    required this.downloadUrlTtl,
    required this.rateLimitPerMinute,
    required this.rateLimitShared,
    this.rateLimitIpPerMinute,
    this.trustedProxies = defaultTrustedProxies,
    this.eventRetentionDays = 0,
    this.auditRetentionDays = 0,
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
    required this.maxUploadBytes,
    required this.logFormat,
    required this.dbSslMode,
    required this.loginEmail,
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
      // 512 MiB default; rejects larger artifact uploads with 413.
      maxUploadBytes: int.parse(env['MAX_UPLOAD_BYTES'] ?? '536870912'),
      // Request/error log format: 'text' (human-readable, default) or 'json'
      // (one structured object per line, for log aggregators).
      logFormat: env['LOG_FORMAT'] == 'json' ? 'json' : 'text',
      port: port,
      publicBaseUrl: env['PUBLIC_BASE_URL'] ?? 'http://localhost:$port',
      // Placeholders only, so an unset value produces a named config error
      // from [validate] rather than a confusing empty-string failure. Neither
      // is accepted at boot — see [devApiKey].
      bootstrapApiKey: env['API_KEY'] ?? devApiKey,
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
      urlSigningSecret: env['URL_SIGNING_SECRET'] ?? devUrlSigningSecret,
      // TLS to Postgres. `disable` (default, in-network compose) / `require`
      // (encrypt, no cert verification) / `verify-full` (encrypt + verify).
      // Use `verify-full` for a managed/external database.
      //
      // Kept verbatim rather than coerced: a `switch` with a `_ => 'disable'`
      // arm silently downgrades a typo like `verify_full` or `required` to
      // plaintext. [validate] rejects anything unrecognized instead.
      dbSslMode: env['DB_SSL_MODE'] ?? 'disable',
      // The identity `/login` self-consents as when no external IdP is
      // configured. Never taken from the request — see Api.login.
      loginEmail: env['LOGIN_EMAIL'] ?? 'owner@self-host.local',
      jwtIssuer:
          env['SHOREBIRD_JWT_ISSUER'] ??
          env['JWT_ISSUER'] ??
          (env['PUBLIC_BASE_URL'] ?? 'http://localhost:$port'),
      downloadUrlTtl: Duration(
        seconds: int.parse(env['DOWNLOAD_URL_TTL'] ?? '300'),
      ),
      rateLimitPerMinute: int.parse(env['RATE_LIMIT_PER_MINUTE'] ?? '600'),
      rateLimitIpPerMinute: int.tryParse(env['RATE_LIMIT_IP_PER_MINUTE'] ?? ''),
      trustedProxies: _parseTrustedProxies(env['TRUSTED_PROXIES']),
      eventRetentionDays: int.tryParse(env['EVENT_RETENTION_DAYS'] ?? '') ?? 0,
      auditRetentionDays: int.tryParse(env['AUDIT_RETENTION_DAYS'] ?? '') ?? 0,
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

  /// The set of values [dbSslMode] may take. Anything else is a config error
  /// rather than a silent fallback — see [validate].
  static const dbSslModes = {'disable', 'require', 'verify-full'};

  /// The placeholder [bootstrapApiKey] / [urlSigningSecret] that ship in this
  /// repository. Both are published, so neither is ever a valid runtime value —
  /// see [validate].
  static const devApiKey = 'sb_api_selfhost_dev';
  static const devUrlSigningSecret = 'dev-url-signing-secret';

  /// The `LOGIN_EMAIL` placeholder shipped in `docker-compose.yaml`,
  /// `.env.example`, and `setup.sh`'s local branch. Unlike the secrets above
  /// this is not fatal — a local stack in self-consent mode legitimately signs
  /// in as it — but it is never a real operator identity, so the root-org grant
  /// it receives must not survive into IdP mode. See `Repository.open`.
  ///
  /// Deliberately excludes `owner@self-host.local`: that is seeded as user 1,
  /// the identity the bootstrap `API_KEY` authenticates as, and revoking its
  /// membership would break the bootstrap key.
  static const placeholderLoginEmail = 'you@example.com';

  /// Refuses to boot on a misconfiguration: published placeholder secrets (in
  /// every mode), dev-default infrastructure credentials in production, and
  /// settings whose wrong value fails open. Returns the list of problems
  /// (empty = ok); the caller aborts if non-empty.
  List<String> validate() {
    final problems = <String>[];
    // Checked in every mode, not just production: an unrecognized value used
    // to fall through to `disable`, so a typo (`verify_full`, `required`,
    // `VERIFY-FULL`) sent the database credentials over the wire in the clear
    // with no error and no warning.
    if (!dbSslModes.contains(dbSslMode)) {
      problems.add(
        'DB_SSL_MODE="$dbSslMode" must be one of ${dbSslModes.join(', ')}',
      );
    }
    // Checked in every mode, NOT just production. These two literals are
    // committed to this repository, so anyone can read them:
    //
    //   * API_KEY authenticates as user 1, an owner of the root org — the
    //     identity `_authorizeServerAdmin` treats as an operator of the whole
    //     deployment. `POST /admin/users` then mints a durable key for any
    //     address, and any patch can be promoted to every device.
    //   * URL_SIGNING_SECRET forges `/download` URLs, which are public by
    //     design and gated only by that HMAC.
    //
    // Gating these behind PRODUCTION is what made `docker compose up -d` with
    // no .env a network-reachable admin bypass: nothing in the zero-config
    // path sets PRODUCTION, so the guard never ran. There is no deployment —
    // local, CI, or otherwise — where a published credential is the right
    // value, so fail closed everywhere and let setup.sh (or an explicit env
    // var) supply a real one.
    if (urlSigningSecret == devUrlSigningSecret) {
      problems.add(
        'URL_SIGNING_SECRET is the published placeholder; set it to a random '
        'value (openssl rand -hex 32) or run ./setup.sh',
      );
    }
    if (bootstrapApiKey == devApiKey) {
      problems.add(
        'API_KEY is the published placeholder; set it to a random value '
        '(sb_api_\$(openssl rand -hex 32)) or run ./setup.sh',
      );
    }
    // An empty key would otherwise match a blank `Authorization: Bearer `
    // header and authenticate the caller as the seeded owner. To retire the
    // bootstrap key, set it to a fresh random value nobody holds.
    if (bootstrapApiKey.isEmpty) problems.add('API_KEY must not be empty');
    if (!production) return problems;
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

  /// The `iss` claim stamped into JWTs; must equal the CLI's
  /// `SHOREBIRD_JWT_ISSUER` and the `jwt_issuer` returned by `/users/me`.
  final String jwtIssuer;

  final Duration downloadUrlTtl;

  /// Per-principal request cap: one window per bearer token.
  final int rateLimitPerMinute;

  /// Explicit `RATE_LIMIT_IP_PER_MINUTE`; null means derive it. Read through
  /// [ipRateLimitPerMinute].
  final int? rateLimitIpPerMinute;

  /// Per-source-IP request cap, and the ceiling that actually holds: a bearer
  /// token is client-supplied and is not validated until after the rate-limit
  /// middleware runs, so a caller can mint a fresh per-principal window on
  /// every request just by rotating it. Defaults to 10x [rateLimitPerMinute],
  /// since one NAT egress IP legitimately carries many principals.
  int get ipRateLimitPerMinute =>
      rateLimitIpPerMinute ?? rateLimitPerMinute * 10;

  /// Reverse proxies whose `X-Forwarded-For` this server believes: literal
  /// IPs, IPv4 CIDR blocks, or `*` for "any peer". Defaults to loopback only.
  ///
  /// The header is attacker-controlled, so trusting it from an arbitrary peer
  /// turns every IP-keyed limit into a no-op — a rotating XFF buys a fresh
  /// bucket per request. See [trustsProxy].
  final Set<String> trustedProxies;

  /// When true, rate-limit counters live in Postgres (correct across restarts
  /// and multiple nodes); otherwise an in-process fixed window (dev/single-node).
  final bool rateLimitShared;

  /// Days of device events to keep; `0` (the default) keeps them forever.
  ///
  /// `events` gets one row per device check-in from a public endpoint, so it is
  /// the fastest-growing table here and nothing sweeps it — but it is also what
  /// every analytics query reads, so discarding history is the operator's call,
  /// not a default. Set it if the data volume matters more than the history.
  final int eventRetentionDays;

  /// Days of audit entries to keep; `0` (the default) keeps them forever.
  final int auditRetentionDays;

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

  /// Max artifact upload size in bytes; larger uploads are rejected with 413.
  final int maxUploadBytes;

  /// Request/error log format: `text` (human-readable, default) or `json`
  /// (one structured object per line, for aggregators like Loki/ELK).
  final String logFormat;

  /// TLS mode for the Postgres connection: `disable` (default), `require`, or
  /// `verify-full`. Anything other than `disable` sends credentials encrypted.
  final String dbSslMode;

  /// The identity `/login` self-consents as when [idpEnabled] is false. This is
  /// server-side configuration only; a request can never choose its own
  /// identity.
  final String loginEmail;

  /// True when [peerIp] — the socket peer, not anything it claims to be — is a
  /// proxy listed in [trustedProxies], and its `X-Forwarded-For` may therefore
  /// be used as the client's identity.
  /// `TRUSTED_PROXIES=*`: believe `X-Forwarded-For` from any peer. Meant for a
  /// proxy whose address can't be pinned (a dynamic or IPv6 load balancer).
  ///
  /// The weakest setting, and only safe when nothing but that proxy can reach
  /// this server: any caller that can connect directly picks its own bucket by
  /// writing the header, so every IP-keyed limit becomes rotatable again.
  bool get trustsAnyProxy => trustedProxies.contains('*');

  bool trustsProxy(String? peerIp) {
    if (trustsAnyProxy) return true;
    if (peerIp == null || trustedProxies.isEmpty) return false;
    final ip = normalizeIp(peerIp);
    for (final entry in trustedProxies) {
      if (normalizeIp(entry) == ip) return true;
      if (entry.contains('/') && _inCidr(ip, entry)) return true;
    }
    return false;
  }

  /// Unwraps an IPv4-mapped IPv6 address (`::ffff:10.0.0.1`), which is how a
  /// dual-stack listener reports an IPv4 peer, so it compares equal to the
  /// plain IPv4 form an operator would write in `TRUSTED_PROXIES`.
  static String normalizeIp(String ip) =>
      ip.startsWith('::ffff:') ? ip.substring('::ffff:'.length) : ip;

  /// IPv4 CIDR containment (`172.16.0.0/12`, the Docker bridge range). An
  /// entry that doesn't parse is simply not a match — a malformed
  /// `TRUSTED_PROXIES` must never widen trust.
  static bool _inCidr(String ip, String cidr) {
    final slash = cidr.indexOf('/');
    final bits = int.tryParse(cidr.substring(slash + 1));
    if (bits == null || bits < 0 || bits > 32) return false;
    final addr = _ipv4(ip);
    final network = _ipv4(cidr.substring(0, slash));
    if (addr == null || network == null) return false;
    if (bits == 0) return true;
    final mask = (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF;
    return (addr & mask) == (network & mask);
  }

  static int? _ipv4(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return null;
    var out = 0;
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null || n < 0 || n > 255) return null;
      out = (out << 8) | n;
    }
    return out;
  }

  /// A reverse proxy on the same host is the one peer that is safe to believe
  /// without being told about it.
  static const defaultTrustedProxies = {'127.0.0.1', '::1'};

  /// `TRUSTED_PROXIES` is a comma-separated list. Unset keeps the loopback
  /// default (a proxy on the same host); set-but-empty trusts nothing.
  static Set<String> _parseTrustedProxies(String? raw) {
    if (raw == null) return defaultTrustedProxies;
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  }
}
