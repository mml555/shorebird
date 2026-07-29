import 'dart:math';

import 'package:code_push_server/src/config.dart';
import 'package:code_push_server/src/db.dart';
import 'package:code_push_server/src/domain.dart';
import 'package:code_push_server/src/observability.dart';

// ---------------------------------------------------------------------------
// Row types
// ---------------------------------------------------------------------------

class AppRow {
  AppRow(
    this.appId,
    this.displayName,
    this.orgId,
    this.createdAt,
    this.updatedAt,
  );
  final String appId;
  final String displayName;
  final int orgId;
  final String createdAt;
  final String updatedAt;
}

class ReleaseRow {
  ReleaseRow({
    required this.id,
    required this.appId,
    required this.version,
    required this.flutterRevision,
    required this.flutterVersion,
    required this.displayName,
    required this.lifecycle,
    required this.createdAt,
    required this.updatedAt,
    required this.platformStatuses,
    this.notes,
  });
  final int id;
  final String appId;
  final String version;
  final String? flutterRevision;
  final String? flutterVersion;
  final String? displayName;
  final ReleaseLifecycle lifecycle;
  final String createdAt;
  final String updatedAt;
  final Map<String, String> platformStatuses;

  /// Freeform operator-supplied release notes, surfaced by
  /// `shorebird releases info`. Null when never set.
  final String? notes;
}

class PatchRow {
  PatchRow(
    this.id,
    this.appId,
    this.releaseId,
    this.number,
    this.status, {
    this.notes,
  });
  final int id;
  final String appId;
  final int releaseId;
  final int number;
  final PatchStatus status;

  /// Freeform operator-supplied patch notes, surfaced by
  /// `shorebird patches info`. Null when never set.
  final String? notes;
}

class ChannelRow {
  ChannelRow(this.id, this.appId, this.name);
  final int id;
  final String appId;
  final String name;
}

class ChannelPatchRow {
  ChannelPatchRow({
    required this.id,
    required this.channelId,
    required this.patchId,
    required this.status,
    required this.rollout,
    required this.rolledBack,
  });
  final int id;
  final int channelId;
  final int patchId;
  final ChannelPatchStatus status;
  final int rollout;
  final bool rolledBack;
}

class ArtifactRow {
  ArtifactRow({
    required this.id,
    required this.token,
    required this.ownerKind,
    required this.ownerId,
    required this.arch,
    required this.platform,
    required this.hash,
    required this.size,
    required this.hashSignature,
    required this.podfileLockHash,
    required this.canSideload,
    required this.status,
    required this.storageKey,
  });
  final int id;
  final String token;
  final String ownerKind;
  final int ownerId;
  final String arch;
  final String platform;
  final String hash;
  final int size;
  final String? hashSignature;
  final String? podfileLockHash;
  final bool canSideload;
  final ArtifactStatus status;
  final String storageKey;
}

class UserRow {
  UserRow(this.id, this.email, this.displayName);
  final int id;
  final String email;
  final String? displayName;
}

class MembershipRow {
  MembershipRow(
    this.orgId,
    this.orgName,
    this.orgType,
    this.role,
    this.createdAt,
    this.updatedAt,
  );
  final int orgId;
  final String orgName;
  final String orgType;
  final String role;
  final String createdAt;
  final String updatedAt;
}

// ---------------------------------------------------------------------------
// Repository — backend-agnostic (Postgres or SQLite via [Db])
// ---------------------------------------------------------------------------

class Repository {
  Repository(this._db);

  static Future<Repository> open(Config cfg) async {
    final db = await Db.open(cfg);
    final repo = Repository(db);
    await repo._migrate();
    await repo._seed();
    // Only in self-consent mode. With an IdP broker configured, LOGIN_EMAIL is
    // documented as ignored (IDP_SETUP.md, .env.example) and setup.sh's local
    // branch leaves the placeholder `you@example.com` behind, so honoring it
    // here would grant root-org ownership — and with it `POST /admin/users`,
    // which issues an API key for any address — to whoever can present that
    // identity to the IdP.
    if (cfg.idpEnabled) {
      // Skipping the grant only helps a stack that had the IdP configured from
      // its first boot. A stack that ran in self-consent mode first already has
      // the placeholder in `org_members`, and that row outlives the config
      // change: `_auth` resolves an IdP identity through `userByEmail`, so
      // whoever can present `you@example.com` to the broker lands on a root-org
      // owner. Undo the grant we made rather than leaving it for the operator
      // to notice.
      await repo.revokeSeededRootOwner(Config.placeholderLoginEmail);
    } else {
      await repo.ensureRootOwner(cfg.loginEmail);
    }
    return repo;
  }

  final Db _db;
  final _rng = Random.secure();

  /// The underlying database, exposed for read-only analytics queries.
  Db get db => _db;

  Future<void> close() => _db.close();

  /// Readiness probe: true if the database answers a trivial query.
  Future<bool> ping() => _db.ping();

  Future<List<Map<String, Object?>>> _q(
    String sql, [
    Map<String, Object?> params = const {},
  ]) => _db.query(sql, params);

  static String _ts(Object? v) =>
      v is DateTime ? v.toUtc().toIso8601String() : v.toString();

  int _int(Object? v) => (v as num).toInt();

  /// Ordered schema migrations. Version 1 is the idempotent baseline (safe to
  /// run against an already-populated database). Add new versions below; each
  /// runs once, in its own transaction, and is recorded in `schema_migrations`.
  static List<(int, List<String>)> get _migrations => [
    (1, _v1Baseline),
    (
      2,
      [
        '''CREATE TABLE IF NOT EXISTS invitations(
              token TEXT PRIMARY KEY,
              org_id INTEGER NOT NULL REFERENCES organizations(id),
              email TEXT NOT NULL, role TEXT NOT NULL,
              created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
              expires_at TIMESTAMPTZ NOT NULL, accepted_at TIMESTAMPTZ)''',
      ],
    ),
    (3, _v3Indexes),
    (
      4,
      [
        // CSRF state for the external-IdP broker flow. Persisted (not in
        // process memory) so it survives restarts and works across replicas.
        '''CREATE TABLE IF NOT EXISTS idp_states(
              state TEXT PRIMARY KEY, continue_url TEXT NOT NULL,
              expires_at TIMESTAMPTZ NOT NULL)''',
      ],
    ),
    (
      5,
      [
        // Release/patch notes. The wire contract already carried a `notes`
        // field on both DTOs and `shorebird releases info` / `patches info`
        // already print it — there was just never anywhere to store it, so it
        // was hardcoded null on every response. Deliberately plain `ALTER
        // TABLE ADD COLUMN` with no `IF NOT EXISTS`: SQLite doesn't support
        // that clause, and a versioned migration runs exactly once anyway.
        'ALTER TABLE releases ADD COLUMN notes TEXT',
        'ALTER TABLE patches ADD COLUMN notes TEXT',
      ],
    ),
    (
      6,
      [
        // Optional per-org email-domain allowlist, stored as a comma-separated
        // list of lowercase domains. NULL/empty means unrestricted, which is
        // every org's default — so an existing deployment is unaffected.
        'ALTER TABLE organizations ADD COLUMN allowed_email_domains TEXT',
      ],
    ),
  ];

  /// Indexes for the access paths that would otherwise scan. `events` is the
  /// hot one: it grows with device count x check frequency and backs every
  /// analytics query.
  static const List<String> _v3Indexes = [
    'CREATE INDEX IF NOT EXISTS events_app_ts ON events(app_id, ts)',
    'CREATE INDEX IF NOT EXISTS events_app_client ON events(app_id, client_id)',
    'CREATE INDEX IF NOT EXISTS events_app_type_ts ON events(app_id, type, ts)',
    'CREATE INDEX IF NOT EXISTS events_app_release ON events(app_id, release_version)',
    'CREATE INDEX IF NOT EXISTS artifacts_owner ON artifacts(owner_kind, owner_id)',
    'CREATE INDEX IF NOT EXISTS channel_patches_channel_status ON channel_patches(channel_id, status)',
    'CREATE INDEX IF NOT EXISTS channel_patches_patch ON channel_patches(patch_id)',
    'CREATE INDEX IF NOT EXISTS patches_release ON patches(release_id)',
    'CREATE INDEX IF NOT EXISTS patches_app ON patches(app_id)',
    'CREATE INDEX IF NOT EXISTS releases_app ON releases(app_id)',
    'CREATE INDEX IF NOT EXISTS apps_org ON apps(org_id)',
    'CREATE INDEX IF NOT EXISTS api_keys_user ON api_keys(user_id)',
    'CREATE INDEX IF NOT EXISTS org_members_user ON org_members(user_id)',
    'CREATE INDEX IF NOT EXISTS app_collaborators_user ON app_collaborators(user_id)',
    'CREATE INDEX IF NOT EXISTS rate_limits_window ON rate_limits(window_start)',
  ];

  Future<void> _migrate() async {
    await _q(
      'CREATE TABLE IF NOT EXISTS schema_migrations('
      'version INTEGER PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())',
    );
    final applied = (await _q(
      'SELECT version FROM schema_migrations',
    )).map((m) => _int(m['version'])).toSet();
    for (final (version, statements) in _migrations) {
      if (applied.contains(version)) continue;
      await _db.tx((s) async {
        for (final stmt in statements) {
          await s.query(stmt);
        }
        await s.query('INSERT INTO schema_migrations(version) VALUES (@v)', {
          'v': version,
        });
      });
      logInfo('applied schema migration', {'version': version});
    }
  }

  static const List<String> _v1Baseline = [
    '''CREATE TABLE IF NOT EXISTS users(
          id SERIAL PRIMARY KEY, email TEXT UNIQUE NOT NULL,
          display_name TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now())''',
    '''CREATE TABLE IF NOT EXISTS api_keys(
          key TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id),
          created_at TIMESTAMPTZ NOT NULL DEFAULT now())''',
    '''CREATE TABLE IF NOT EXISTS organizations(
          id SERIAL PRIMARY KEY, name TEXT NOT NULL, org_type TEXT NOT NULL,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
          updated_at TIMESTAMPTZ NOT NULL DEFAULT now())''',
    '''CREATE TABLE IF NOT EXISTS org_members(
          org_id INTEGER NOT NULL REFERENCES organizations(id),
          user_id INTEGER NOT NULL REFERENCES users(id),
          role TEXT NOT NULL, PRIMARY KEY(org_id, user_id))''',
    '''CREATE TABLE IF NOT EXISTS apps(
          app_id TEXT PRIMARY KEY, display_name TEXT NOT NULL,
          org_id INTEGER NOT NULL REFERENCES organizations(id),
          created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
          updated_at TIMESTAMPTZ NOT NULL DEFAULT now())''',
    '''CREATE TABLE IF NOT EXISTS app_collaborators(
          app_id TEXT NOT NULL REFERENCES apps(app_id),
          user_id INTEGER NOT NULL REFERENCES users(id),
          role TEXT NOT NULL, PRIMARY KEY(app_id, user_id))''',
    '''CREATE TABLE IF NOT EXISTS releases(
          id SERIAL PRIMARY KEY, app_id TEXT NOT NULL, version TEXT NOT NULL,
          flutter_revision TEXT, flutter_version TEXT, display_name TEXT,
          lifecycle TEXT NOT NULL,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
          updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
          UNIQUE(app_id, version))''',
    '''CREATE TABLE IF NOT EXISTS release_platform_status(
          release_id INTEGER NOT NULL REFERENCES releases(id),
          platform TEXT NOT NULL, status TEXT NOT NULL,
          PRIMARY KEY(release_id, platform))''',
    '''CREATE TABLE IF NOT EXISTS patches(
          id SERIAL PRIMARY KEY, app_id TEXT NOT NULL,
          release_id INTEGER NOT NULL REFERENCES releases(id),
          number INTEGER NOT NULL, status TEXT NOT NULL,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
          UNIQUE(release_id, number))''',
    '''CREATE TABLE IF NOT EXISTS channels(
          id SERIAL PRIMARY KEY, app_id TEXT NOT NULL, name TEXT NOT NULL,
          UNIQUE(app_id, name))''',
    '''CREATE TABLE IF NOT EXISTS channel_patches(
          id SERIAL PRIMARY KEY, channel_id INTEGER NOT NULL REFERENCES channels(id),
          patch_id INTEGER NOT NULL REFERENCES patches(id),
          status TEXT NOT NULL, rollout INTEGER NOT NULL DEFAULT 100,
          rolled_back BOOLEAN NOT NULL DEFAULT false,
          promoted_at TIMESTAMPTZ NOT NULL DEFAULT now(), withdrawn_at TIMESTAMPTZ)''',
    '''CREATE TABLE IF NOT EXISTS artifacts(
          id SERIAL PRIMARY KEY, token TEXT UNIQUE NOT NULL,
          owner_kind TEXT NOT NULL, owner_id INTEGER NOT NULL,
          arch TEXT NOT NULL, platform TEXT NOT NULL, hash TEXT NOT NULL,
          size INTEGER NOT NULL, hash_signature TEXT, podfile_lock_hash TEXT,
          can_sideload BOOLEAN NOT NULL DEFAULT false, status TEXT NOT NULL,
          storage_key TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now())''',
    '''CREATE TABLE IF NOT EXISTS events(
          id SERIAL PRIMARY KEY, dedupe_key TEXT UNIQUE, raw TEXT NOT NULL,
          app_id TEXT, client_id TEXT, type TEXT, patch_number INTEGER,
          platform TEXT, arch TEXT, release_version TEXT, ts BIGINT,
          received_at TIMESTAMPTZ NOT NULL DEFAULT now())''',
    '''CREATE TABLE IF NOT EXISTS audit_log(
          id SERIAL PRIMARY KEY, actor TEXT, action TEXT NOT NULL,
          target TEXT, detail TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now())''',
    '''CREATE TABLE IF NOT EXISTS auth_codes(
          code TEXT PRIMARY KEY, email TEXT NOT NULL, expires_at TIMESTAMPTZ NOT NULL)''',
    '''CREATE TABLE IF NOT EXISTS refresh_tokens(
          token TEXT PRIMARY KEY, email TEXT NOT NULL,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now())''',
    // Server-wide singleton settings (e.g. the persisted OAuth signing key),
    // so a restart / a second node reuses the same values.
    '''CREATE TABLE IF NOT EXISTS settings(
          key TEXT PRIMARY KEY, value TEXT NOT NULL,
          updated_at TIMESTAMPTZ NOT NULL DEFAULT now())''',
    // Fixed-window rate-limit counters shared across nodes.
    '''CREATE TABLE IF NOT EXISTS rate_limits(
          bucket TEXT NOT NULL, window_start BIGINT NOT NULL, count INTEGER NOT NULL,
          PRIMARY KEY(bucket, window_start))''',
  ];

  Future<void> _seed() async {
    final org = await _q('SELECT id FROM organizations WHERE id = 1');
    if (org.isEmpty) {
      // A default personal org (id 1) + a default owner user, so the bootstrap
      // API key maps to a real membership. Multi-tenant users are added later.
      await _q(
        "INSERT INTO organizations(id, name, org_type) VALUES (1, 'self-host', 'personal')",
      );
      if (_db.dialect == Dialect.postgres) {
        await _q("SELECT setval('organizations_id_seq', 1, true)");
      }
    }
    final user = await _q('SELECT id FROM users WHERE id = 1');
    if (user.isEmpty) {
      await _q(
        "INSERT INTO users(id, email, display_name) VALUES (1, 'owner@self-host.local', 'Owner')",
      );
      if (_db.dialect == Dialect.postgres) {
        await _q("SELECT setval('users_id_seq', 1, true)");
      }
      await _q(
        "INSERT INTO org_members(org_id, user_id, role) VALUES (1, 1, 'owner') ON CONFLICT DO NOTHING",
      );
    }
  }

  /// Makes [email] — the `LOGIN_EMAIL` the bootstrap key authenticates as — an
  /// owner of the root org (id 1).
  ///
  /// `_seed` hardcodes `owner@self-host.local` as user 1, but `setup.sh` writes
  /// a `LOGIN_EMAIL` of its own. Without this, signing in through `/login` with
  /// the bootstrap key produces a *different* user in a personal org, who is
  /// then refused by the operator-only routes (`POST /admin/users`) that the
  /// login page itself points at. Idempotent, and safe to run against an
  /// existing database.
  /// Runs on every boot, so it must grant exactly once per address and then
  /// never again — otherwise it silently undoes a deliberate demotion, or
  /// re-admits an operator who was removed from the org (offboarding), simply
  /// because `LOGIN_EMAIL` still names them. A marker in `settings` records
  /// that this address has had its grant, so membership after that belongs
  /// entirely to the API.
  Future<void> ensureRootOwner(String email) async {
    if (email.isEmpty) return;
    final marker = 'root_owner_seeded:$email';
    if (await getSetting(marker) != null) return;
    final user = await userByEmail(email) ?? await upsertUser(email, null);
    await _q(
      "INSERT INTO org_members(org_id, user_id, role) VALUES (1, @u, 'owner') "
      'ON CONFLICT(org_id, user_id) DO NOTHING',
      {'u': user.id},
    );
    await _q(
      "INSERT INTO settings(key, value) VALUES (@k, 'true') "
      'ON CONFLICT(key) DO NOTHING',
      {'k': marker},
    );
  }

  /// Undoes an [ensureRootOwner] grant for [email], for the enable-the-IdP-later
  /// path where a placeholder address must not keep root-org ownership.
  ///
  /// Gated on the same `settings` marker [ensureRootOwner] writes, so it only
  /// removes membership *this code* granted. An address deliberately made an
  /// owner through the API has no marker and is left alone — otherwise every
  /// boot would silently offboard a legitimate operator who happens to share
  /// the address. User 1 is never touched: it is the identity the bootstrap
  /// `API_KEY` maps to, so dropping its membership would lock out the key.
  Future<void> revokeSeededRootOwner(String email) async {
    if (email.isEmpty) return;
    final marker = 'root_owner_seeded:$email';
    if (await getSetting(marker) == null) return;
    final user = await userByEmail(email);
    if (user != null && user.id != 1) {
      await _q('DELETE FROM org_members WHERE org_id = 1 AND user_id = @u', {
        'u': user.id,
      });
    }
    await _q('DELETE FROM settings WHERE key = @k', {'k': marker});
  }

  String _uuid() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    String hex(int a, int c) =>
        b.sublist(a, c).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  String newToken() => List<int>.generate(
    16,
    (_) => _rng.nextInt(256),
  ).map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  // ---- Auth / users ----

  /// Resolves an API key to its user id. The bootstrap key maps to user 1.
  Future<int?> userIdForApiKey(String key) async {
    final r = await _q('SELECT user_id FROM api_keys WHERE key = @k', {
      'k': key,
    });
    if (r.isEmpty) return null;
    return _int(r.first['user_id']);
  }

  Future<UserRow?> userById(int id) async {
    final r = await _q('SELECT * FROM users WHERE id = @id', {'id': id});
    if (r.isEmpty) return null;
    final m = r.first;
    return UserRow(
      _int(m['id']),
      m['email'] as String,
      m['display_name'] as String?,
    );
  }

  Future<UserRow> upsertUser(String email, String? displayName) async {
    final r = await _q(
      'INSERT INTO users(email, display_name) VALUES (@e, @d) '
      'ON CONFLICT(email) DO UPDATE SET display_name = COALESCE(EXCLUDED.display_name, users.display_name) '
      'RETURNING id, email, display_name',
      {'e': email, 'd': displayName},
    );
    final m = r.first;
    final user = UserRow(
      _int(m['id']),
      m['email'] as String,
      m['display_name'] as String?,
    );
    // On first sight, give the user a personal org + owner membership.
    final existing = await _q('SELECT 1 FROM org_members WHERE user_id = @u', {
      'u': user.id,
    });
    if (existing.isEmpty) {
      final org = await _q(
        "INSERT INTO organizations(name, org_type) VALUES (@n, 'personal') RETURNING id",
        {'n': email},
      );
      await _q(
        "INSERT INTO org_members(org_id, user_id, role) VALUES (@o, @u, 'owner')",
        {'o': org.first['id'], 'u': user.id},
      );
    }
    return user;
  }

  Future<String> createApiKey(int userId) async {
    final key = 'sb_api_${newToken()}${newToken()}';
    await _q('INSERT INTO api_keys(key, user_id) VALUES (@k, @u)', {
      'k': key,
      'u': userId,
    });
    return key;
  }

  Future<UserRow?> userByEmail(String email) async {
    final r = await _q('SELECT * FROM users WHERE email = @e', {'e': email});
    if (r.isEmpty) return null;
    final m = r.first;
    return UserRow(
      _int(m['id']),
      m['email'] as String,
      m['display_name'] as String?,
    );
  }

  /// True if [userId] can access [appId] via org membership or collaboration.
  Future<bool> userCanAccessApp(int userId, String appId) async {
    final r = await _q(
      'SELECT 1 FROM apps a JOIN org_members m ON m.org_id = a.org_id '
      'WHERE a.app_id = @a AND m.user_id = @u '
      'UNION SELECT 1 FROM app_collaborators c WHERE c.app_id = @a AND c.user_id = @u',
      {'a': appId, 'u': userId},
    );
    return r.isNotEmpty;
  }

  /// True if [userId] may administer [appId] — i.e. manage its collaborators.
  /// That means an owner/admin of the owning org, or a collaborator who was
  /// themselves granted an owner/admin role. A plain `developer` collaborator
  /// can ship patches but cannot change who else has access.
  Future<bool> userIsAppAdmin(int userId, String appId) async {
    final r = await _q(
      'SELECT 1 FROM apps a JOIN org_members m ON m.org_id = a.org_id '
      "WHERE a.app_id = @a AND m.user_id = @u AND m.role IN ('owner','admin') "
      'UNION SELECT 1 FROM app_collaborators c '
      "WHERE c.app_id = @a AND c.user_id = @u AND c.role IN ('owner','admin')",
      {'a': appId, 'u': userId},
    );
    return r.isNotEmpty;
  }

  Future<bool> userInOrg(int userId, int orgId) async {
    final r = await _q(
      'SELECT 1 FROM org_members WHERE user_id = @u AND org_id = @o',
      {'u': userId, 'o': orgId},
    );
    return r.isNotEmpty;
  }

  /// True if [userId] is an owner/admin of [orgId] (may invite others).
  Future<bool> userIsOrgAdmin(int userId, int orgId) async {
    final r = await _q(
      "SELECT 1 FROM org_members WHERE user_id = @u AND org_id = @o "
      "AND role IN ('owner','admin')",
      {'u': userId, 'o': orgId},
    );
    return r.isNotEmpty;
  }

  Future<String> createInvitation(int orgId, String email, String role) async {
    final token = 'sb_inv_${newToken()}';
    await _q(
      "INSERT INTO invitations(token, org_id, email, role, expires_at) "
      "VALUES (@t,@o,@e,@r, now() + interval '7 days')",
      {'t': token, 'o': orgId, 'e': email, 'r': role},
    );
    return token;
  }

  /// The invitation for [token], with an `expired` flag computed **in SQL**.
  ///
  /// The comparison has to happen here, not in Dart. `expires_at` is
  /// `TIMESTAMPTZ`, which the SQLite translation rewrites to `TEXT`, so the
  /// caller gets a `DateTime` on Postgres and a `String` on SQLite — the
  /// default backend. A `value is DateTime` guard therefore silently never
  /// fired on single-container deployments and the 7-day expiry set by
  /// [createInvitation] was not enforced at all. Both backends compare
  /// correctly here: [_tsFmt] keeps the SQLite text form lexicographically
  /// chronological, which is the same reason `consumeAuthCode` and
  /// `consumeIdpState` filter in SQL.
  Future<Map<String, dynamic>?> invitation(String token) async {
    final r = await _q(
      'SELECT *, (expires_at <= now()) AS expired FROM invitations '
      'WHERE token = @t',
      {'t': token},
    );
    return r.isEmpty ? null : r.first;
  }

  /// Accepts an invitation for [userId] (whose email must match the invite):
  /// records acceptance and adds org membership, transactionally.
  Future<void> acceptInvitation(
    String token,
    int userId,
    int orgId,
    String role,
  ) => _db.tx((s) async {
    await s.query(
      'UPDATE invitations SET accepted_at = now() WHERE token = @t',
      {'t': token},
    );
    await s.query(
      "INSERT INTO org_members(org_id, user_id, role) VALUES (@o,@u,@r) "
      "ON CONFLICT(org_id, user_id) DO UPDATE SET role = EXCLUDED.role",
      {'o': orgId, 'u': userId, 'r': role},
    );
  });

  Future<void> addCollaborator(String appId, int userId, String role) => _q(
    'INSERT INTO app_collaborators(app_id, user_id, role) VALUES (@a,@u,@r) '
    'ON CONFLICT(app_id, user_id) DO UPDATE SET role = EXCLUDED.role',
    {'a': appId, 'u': userId, 'r': role},
  );

  // ---- Team management (read + mutate) ----

  /// Members of [orgId]: `{user_id, email, display_name, role}` per row.
  Future<List<Map<String, Object?>>> orgMembers(int orgId) async {
    final r = await _q(
      'SELECT u.id AS user_id, u.email, u.display_name, m.role '
      'FROM org_members m JOIN users u ON u.id = m.user_id '
      'WHERE m.org_id = @o ORDER BY u.email',
      {'o': orgId},
    );
    return r
        .map(
          (m) => {
            'user_id': _int(m['user_id']),
            'email': m['email'],
            'display_name': m['display_name'],
            'role': m['role'],
          },
        )
        .toList();
  }

  Future<void> setMemberRole(int orgId, int userId, String role) => _q(
    'UPDATE org_members SET role = @r WHERE org_id = @o AND user_id = @u',
    {'r': role, 'o': orgId, 'u': userId},
  );

  Future<void> removeMember(int orgId, int userId) => _q(
    'DELETE FROM org_members WHERE org_id = @o AND user_id = @u',
    {'o': orgId, 'u': userId},
  );

  /// Count of members with an owner/admin role — used to refuse removing the
  /// last owner (which would orphan the org).
  Future<int> orgAdminCount(int orgId) async {
    final r = await _q(
      "SELECT COUNT(*) AS c FROM org_members WHERE org_id = @o AND role IN ('owner','admin')",
      {'o': orgId},
    );
    return _int(r.first['c']);
  }

  /// The org's email-domain allowlist, lowercased. Empty means unrestricted.
  Future<List<String>> orgAllowedDomains(int orgId) async {
    final r = await _q(
      'SELECT allowed_email_domains AS d FROM organizations WHERE id = @o',
      {'o': orgId},
    );
    if (r.isEmpty) return const [];
    return parseDomainList(r.first['d'] as String?);
  }

  /// Replaces the org's allowlist. An empty [domains] clears it (unrestricted).
  Future<void> setOrgAllowedDomains(int orgId, List<String> domains) => _q(
    'UPDATE organizations SET allowed_email_domains = @d, updated_at = now() '
    'WHERE id = @o',
    {'d': domains.isEmpty ? null : domains.join(','), 'o': orgId},
  );

  /// The org that owns [appId], or null if there is no such app. Needed to
  /// resolve an app-scoped request back to the org whose policy governs it.
  Future<int?> appOrgId(String appId) async {
    final r = await _q('SELECT org_id FROM apps WHERE app_id = @a', {
      'a': appId,
    });
    return r.isEmpty ? null : _int(r.first['org_id']);
  }

  /// Pending (unaccepted) invitations for [orgId].
  Future<List<Map<String, Object?>>> orgInvitations(int orgId) async {
    final r = await _q(
      'SELECT token, email, role, created_at, expires_at FROM invitations '
      'WHERE org_id = @o AND accepted_at IS NULL ORDER BY created_at DESC',
      {'o': orgId},
    );
    return r
        .map(
          (m) => {
            'token': m['token'],
            'email': m['email'],
            'role': m['role'],
            'created_at': _ts(m['created_at']),
            'expires_at': _ts(m['expires_at']),
          },
        )
        .toList();
  }

  Future<void> revokeInvitation(int orgId, String token) => _q(
    'DELETE FROM invitations WHERE org_id = @o AND token = @t',
    {'o': orgId, 't': token},
  );

  /// Collaborators on [appId]: `{user_id, email, display_name, role}` per row.
  Future<List<Map<String, Object?>>> appCollaborators(String appId) async {
    final r = await _q(
      'SELECT u.id AS user_id, u.email, u.display_name, c.role '
      'FROM app_collaborators c JOIN users u ON u.id = c.user_id '
      'WHERE c.app_id = @a ORDER BY u.email',
      {'a': appId},
    );
    return r
        .map(
          (m) => {
            'user_id': _int(m['user_id']),
            'email': m['email'],
            'display_name': m['display_name'],
            'role': m['role'],
          },
        )
        .toList();
  }

  Future<void> removeCollaborator(String appId, int userId) => _q(
    'DELETE FROM app_collaborators WHERE app_id = @a AND user_id = @u',
    {'a': appId, 'u': userId},
  );

  Future<List<MembershipRow>> memberships(int userId) async {
    final r = await _q(
      'SELECT o.* , m.role FROM org_members m JOIN organizations o ON o.id = m.org_id '
      'WHERE m.user_id = @u ORDER BY o.id',
      {'u': userId},
    );
    return r.map((m) {
      return MembershipRow(
        _int(m['id']),
        m['name'] as String,
        m['org_type'] as String,
        m['role'] as String,
        _ts(m['created_at']),
        _ts(m['updated_at']),
      );
    }).toList();
  }

  // ---- Apps ----

  Future<AppRow> createApp(String displayName, int orgId) async {
    final appId = _uuid();
    final r = await _q(
      'INSERT INTO apps(app_id, display_name, org_id) VALUES (@a, @d, @o) '
      'RETURNING app_id, display_name, org_id, created_at, updated_at',
      {'a': appId, 'd': displayName, 'o': orgId},
    );
    final m = r.first;
    return AppRow(
      m['app_id'] as String,
      m['display_name'] as String,
      _int(m['org_id']),
      _ts(m['created_at']),
      _ts(m['updated_at']),
    );
  }

  /// Apps visible to [orgIds] (org ownership); if [orgIds] is null, all apps.
  Future<List<AppRow>> apps({List<int>? orgIds}) async {
    final List<Map<String, Object?>> r;
    if (orgIds == null) {
      r = await _q('SELECT * FROM apps ORDER BY created_at');
    } else if (orgIds.isEmpty) {
      return [];
    } else {
      final placeholders = <String>[];
      final params = <String, Object?>{};
      for (var i = 0; i < orgIds.length; i++) {
        placeholders.add('@o$i');
        params['o$i'] = orgIds[i];
      }
      r = await _q(
        'SELECT * FROM apps WHERE org_id IN (${placeholders.join(',')}) ORDER BY created_at',
        params,
      );
    }
    return r.map((m) {
      return AppRow(
        m['app_id'] as String,
        m['display_name'] as String,
        _int(m['org_id']),
        _ts(m['created_at']),
        _ts(m['updated_at']),
      );
    }).toList();
  }

  // ---- Releases ----

  Future<ReleaseRow> createRelease({
    required String appId,
    required String version,
    String? flutterRevision,
    String? flutterVersion,
    String? displayName,
    String? notes,
  }) async {
    final r = await _q(
      'INSERT INTO releases(app_id, version, flutter_revision, flutter_version, '
      'display_name, lifecycle, notes) VALUES (@a,@v,@fr,@fv,@dn,@l,@n) RETURNING id',
      {
        'a': appId,
        'v': version,
        'fr': flutterRevision,
        'fv': flutterVersion,
        'dn': displayName,
        'l': ReleaseLifecycle.draft.name,
        'n': notes,
      },
    );
    return (await release(_int(r.first['id'])))!;
  }

  Future<ReleaseRow?> release(int id) async {
    final r = await _q('SELECT * FROM releases WHERE id = @id', {'id': id});
    if (r.isEmpty) return null;
    return _releaseFrom(r.first);
  }

  Future<ReleaseRow?> releaseByVersion(String appId, String version) async {
    final r = await _q(
      'SELECT * FROM releases WHERE app_id = @a AND version = @v',
      {'a': appId, 'v': version},
    );
    if (r.isEmpty) return null;
    return _releaseFrom(r.first);
  }

  Future<List<ReleaseRow>> releases(String appId) async {
    final r = await _q('SELECT * FROM releases WHERE app_id = @a ORDER BY id', {
      'a': appId,
    });
    return Future.wait(r.map(_releaseFrom));
  }

  Future<ReleaseRow> _releaseFrom(Map<String, Object?> m) async {
    final id = _int(m['id']);
    final ps = <String, String>{};
    final statuses = await _q(
      'SELECT platform, status FROM release_platform_status WHERE release_id = @id',
      {'id': id},
    );
    for (final s in statuses) {
      ps[s['platform'] as String] = s['status'] as String;
    }
    return ReleaseRow(
      id: id,
      appId: m['app_id'] as String,
      version: m['version'] as String,
      flutterRevision: m['flutter_revision'] as String?,
      flutterVersion: m['flutter_version'] as String?,
      displayName: m['display_name'] as String?,
      lifecycle: ReleaseLifecycle.parse(m['lifecycle'] as String),
      createdAt: _ts(m['created_at']),
      updatedAt: _ts(m['updated_at']),
      platformStatuses: ps,
      notes: m['notes'] as String?,
    );
  }

  /// Sets (or, with a null [notes], clears) the release's notes.
  Future<void> setReleaseNotes(int releaseId, String? notes) => _q(
    'UPDATE releases SET notes = @n, updated_at = now() WHERE id = @id',
    {'n': notes, 'id': releaseId},
  );

  Future<void> setReleaseLifecycle(int releaseId, ReleaseLifecycle lifecycle) =>
      _q(
        'UPDATE releases SET lifecycle = @l, updated_at = now() WHERE id = @id',
        {'l': lifecycle.name, 'id': releaseId},
      );

  Future<void> setReleasePlatformStatus(
    int releaseId,
    String platform,
    String status,
  ) async {
    await _q(
      'INSERT INTO release_platform_status(release_id, platform, status) VALUES (@r,@p,@s) '
      'ON CONFLICT(release_id, platform) DO UPDATE SET status = EXCLUDED.status',
      {'r': releaseId, 'p': platform, 's': status},
    );
    await _q('UPDATE releases SET updated_at = now() WHERE id = @id', {
      'id': releaseId,
    });
  }

  // ---- Patches ----

  Future<PatchRow> createPatch(
    String appId,
    int releaseId, {
    String? notes,
  }) async {
    final maxR = await _q(
      'SELECT COALESCE(MAX(number),0) AS n FROM patches WHERE release_id = @r',
      {'r': releaseId},
    );
    final number = _int(maxR.first['n']) + 1;
    final r = await _q(
      'INSERT INTO patches(app_id, release_id, number, status, notes) '
      'VALUES (@a,@r,@n,@s,@no) RETURNING id',
      {
        'a': appId,
        'r': releaseId,
        'n': number,
        's': PatchStatus.draft.name,
        'no': notes,
      },
    );
    return (await patch(_int(r.first['id'])))!;
  }

  Future<PatchRow?> patch(int id) async {
    final r = await _q('SELECT * FROM patches WHERE id = @id', {'id': id});
    if (r.isEmpty) return null;
    return _patchFrom(r.first);
  }

  Future<void> setPatchStatus(int patchId, PatchStatus status) => _q(
    'UPDATE patches SET status = @s WHERE id = @id',
    {'s': status.name, 'id': patchId},
  );

  /// Sets (or, with a null [notes], clears) the patch's notes.
  Future<void> setPatchNotes(int patchId, String? notes) => _q(
    'UPDATE patches SET notes = @n WHERE id = @id',
    {'n': notes, 'id': patchId},
  );

  Future<List<PatchRow>> patchesForRelease(int releaseId) async {
    final r = await _q(
      'SELECT * FROM patches WHERE release_id = @r ORDER BY number',
      {'r': releaseId},
    );
    return r.map(_patchFrom).toList();
  }

  PatchRow _patchFrom(Map<String, Object?> m) => PatchRow(
    _int(m['id']),
    m['app_id'] as String,
    _int(m['release_id']),
    _int(m['number']),
    PatchStatus.parse(m['status'] as String),
    notes: m['notes'] as String?,
  );

  /// Per-channel deployment state for [patchId]: `{channel, status, rollout,
  /// rolled_back}` per row (newest promotion first). Empty = not promoted.
  Future<List<Map<String, Object?>>> patchDeployments(int patchId) async {
    final r = await _q(
      'SELECT c.name AS channel, cp.status, cp.rollout, cp.rolled_back '
      'FROM channel_patches cp JOIN channels c ON c.id = cp.channel_id '
      'WHERE cp.patch_id = @p ORDER BY cp.promoted_at DESC',
      {'p': patchId},
    );
    return r
        .map(
          (m) => {
            'channel': m['channel'],
            'status': m['status'],
            'rollout': _int(m['rollout']),
            'rolled_back': asDbBool(m['rolled_back']),
          },
        )
        .toList();
  }

  /// True if [patchId] has ever been promoted to a channel (active or since
  /// withdrawn). A promoted patch's artifact set is frozen: accepting a new
  /// arch afterwards would flip the patch back to `uploading` and silently
  /// unserve it mid-rollout.
  Future<bool> patchIsPromoted(int patchId) async {
    final r = await _q(
      'SELECT 1 FROM channel_patches WHERE patch_id = @p LIMIT 1',
      {'p': patchId},
    );
    return r.isNotEmpty;
  }

  /// True if [patchId] has been rolled back on any channel.
  Future<bool> patchRolledBack(int patchId) async {
    final r = await _q(
      'SELECT 1 FROM channel_patches WHERE patch_id = @p AND rolled_back = true LIMIT 1',
      {'p': patchId},
    );
    return r.isNotEmpty;
  }

  Future<int?> latestPatchNumberForApp(String appId) async {
    final r = await _q(
      'SELECT MAX(number) AS n FROM patches WHERE app_id = @a',
      {'a': appId},
    );
    final n = r.first['n'];
    return n == null ? null : _int(n);
  }

  // ---- Channels ----

  Future<ChannelRow> createChannel(String appId, String name) async {
    final r = await _q(
      'INSERT INTO channels(app_id, name) VALUES (@a,@n) RETURNING id',
      {'a': appId, 'n': name},
    );
    return ChannelRow(_int(r.first['id']), appId, name);
  }

  Future<ChannelRow?> channel(String appId, String name) async {
    final r = await _q(
      'SELECT * FROM channels WHERE app_id = @a AND name = @n',
      {'a': appId, 'n': name},
    );
    if (r.isEmpty) return null;
    final m = r.first;
    return ChannelRow(
      _int(m['id']),
      m['app_id'] as String,
      m['name'] as String,
    );
  }

  Future<ChannelRow?> channelById(int id) async {
    final r = await _q('SELECT * FROM channels WHERE id = @id', {'id': id});
    if (r.isEmpty) return null;
    final m = r.first;
    return ChannelRow(
      _int(m['id']),
      m['app_id'] as String,
      m['name'] as String,
    );
  }

  Future<List<ChannelRow>> channels(String appId) async {
    final r = await _q('SELECT * FROM channels WHERE app_id = @a ORDER BY id', {
      'a': appId,
    });
    return r.map((m) {
      return ChannelRow(
        _int(m['id']),
        m['app_id'] as String,
        m['name'] as String,
      );
    }).toList();
  }

  // ---- ChannelPatches ----

  /// Promote [patchId] to [channelId] transactionally: supersede other active
  /// patches on the channel (stop serving them — not a rollback) and activate
  /// this one.
  ///
  /// Supersession is scoped **per platform**. The Shorebird CLI creates one
  /// patch per platform — `--platforms=android,ios` publishes TWO patches — so
  /// withdrawing every other active patch made the last-promoted platform evict
  /// the other, and those devices silently fell back to no patch. A channel
  /// therefore holds at most one active patch *per platform*, not one overall.
  ///
  /// A patch is superseded only when the incoming one **fully covers** it —
  /// every platform it carries is also carried by [patchId]. Withdrawing on any
  /// overlap re-created the same bug in the opposite direction: nothing stops a
  /// patch carrying artifacts for several platforms (`_createPatchArtifact`
  /// takes `platform` per artifact), and promoting an android-only patch over
  /// an active android+ios one would withdraw the whole `channel_patches` row,
  /// unserving the iOS devices. Leaving a partially-covered patch active is
  /// safe because [activeChannelPatch] resolves per platform and takes the
  /// highest patch number: android gets the newcomer, iOS keeps the incumbent.
  Future<void> promote(
    int channelId,
    int patchId, {
    int rollout = 100,
  }) => _db.tx((s) async {
    await s.query(
      'UPDATE channel_patches SET status = @w, withdrawn_at = now() '
      'WHERE channel_id = @c AND status = @a AND patch_id <> @p '
      // Supersede a patch only if it has no platform outside the incoming
      // patch's set. Kept as a top-level IN (…) — correlated only between the
      // artifact aliases, never against channel_patches — so it runs unchanged
      // on both Postgres and the SQLite translation layer.
      //
      // A patch with no artifacts has an empty platform set and so supersedes
      // nothing; that is the intended reading (it can serve no device), and
      // promote is only reachable for a `ready` patch, which by definition has
      // verified artifacts.
      'AND patch_id IN ('
      '  SELECT DISTINCT a.owner_id FROM artifacts a'
      "  WHERE a.owner_kind = 'patch' AND NOT EXISTS ("
      '    SELECT 1 FROM artifacts a3'
      "    WHERE a3.owner_kind = 'patch' AND a3.owner_id = a.owner_id"
      '      AND a3.platform NOT IN ('
      '        SELECT a2.platform FROM artifacts a2'
      "        WHERE a2.owner_kind = 'patch' AND a2.owner_id = @p"
      '      )'
      '  )'
      ')',
      {
        'w': ChannelPatchStatus.withdrawn.name,
        'a': ChannelPatchStatus.active.name,
        'c': channelId,
        'p': patchId,
      },
    );
    await s.query(
      'INSERT INTO channel_patches(channel_id, patch_id, status, rollout, rolled_back) '
      'VALUES (@c,@p,@s,@r,false)',
      {
        'c': channelId,
        'p': patchId,
        's': ChannelPatchStatus.active.name,
        'r': rollout,
      },
    );
  });

  /// Newest active patch on [channelId]. When [platform] is given, only
  /// considers patches that actually carry an artifact for it.
  ///
  /// The platform filter matters because a channel can hold one active patch
  /// per platform (see [promote]); picking the globally-newest active patch
  /// would hand an Android device an iOS-only patch and serve it nothing.
  Future<ChannelPatchRow?> activeChannelPatch(
    int channelId, {
    String? platform,
  }) async {
    final r = await _q(
      'SELECT cp.* FROM channel_patches cp JOIN patches p ON p.id = cp.patch_id '
      'WHERE cp.channel_id = @c AND cp.status = @s '
      '${platform == null ? '' : 'AND EXISTS ('
                '  SELECT 1 FROM artifacts a'
                "  WHERE a.owner_kind = 'patch' AND a.owner_id = cp.patch_id"
                '    AND a.platform = @plat'
                ') '}'
      'ORDER BY p.number DESC LIMIT 1',
      {
        'c': channelId,
        's': ChannelPatchStatus.active.name,
        if (platform != null) 'plat': platform,
      },
    );
    if (r.isEmpty) return null;
    return _cpFrom(r.first);
  }

  Future<ChannelPatchRow?> activeChannelPatchForPatch(
    int channelId,
    int patchId,
  ) async {
    final r = await _q(
      'SELECT * FROM channel_patches WHERE channel_id = @c AND patch_id = @p AND status = @s LIMIT 1',
      {'c': channelId, 'p': patchId, 's': ChannelPatchStatus.active.name},
    );
    if (r.isEmpty) return null;
    return _cpFrom(r.first);
  }

  ChannelPatchRow _cpFrom(Map<String, Object?> m) => ChannelPatchRow(
    id: _int(m['id']),
    channelId: _int(m['channel_id']),
    patchId: _int(m['patch_id']),
    status: ChannelPatchStatus.parse(m['status'] as String),
    rollout: _int(m['rollout']),
    rolledBack: asDbBool(m['rolled_back']),
  );

  Future<void> setRollout(int channelId, int patchId, int rollout) => _q(
    'UPDATE channel_patches SET rollout = @r WHERE channel_id = @c AND patch_id = @p AND status = @s',
    {
      'r': rollout,
      'c': channelId,
      'p': patchId,
      's': ChannelPatchStatus.active.name,
    },
  );

  Future<void> withdraw(
    int channelId,
    int patchId, {
    required bool rollback,
  }) => _q(
    'UPDATE channel_patches SET status = @w, withdrawn_at = now(), rolled_back = @rb '
    'WHERE channel_id = @c AND patch_id = @p AND status = @a',
    {
      'w': ChannelPatchStatus.withdrawn.name,
      'rb': rollback,
      'c': channelId,
      'p': patchId,
      'a': ChannelPatchStatus.active.name,
    },
  );

  Future<List<int>> rolledBackPatchNumbers(int channelId, int releaseId) async {
    final r = await _q(
      'SELECT p.number AS n FROM channel_patches cp JOIN patches p ON p.id = cp.patch_id '
      'WHERE cp.channel_id = @c AND cp.rolled_back = true AND p.release_id = @r ORDER BY p.number',
      {'c': channelId, 'r': releaseId},
    );
    return r.map((m) => _int(m['n'])).toList();
  }

  // ---- Artifacts ----

  Future<ArtifactRow> createArtifact({
    required String ownerKind,
    required int ownerId,
    required String arch,
    required String platform,
    required String hash,
    required int size,
    String? hashSignature,
    String? podfileLockHash,
    bool canSideload = false,
  }) async {
    final token = newToken();
    final storageKey = '$ownerKind/$ownerId/$token';
    final r = await _q(
      'INSERT INTO artifacts(token, owner_kind, owner_id, arch, platform, hash, size, '
      'hash_signature, podfile_lock_hash, can_sideload, status, storage_key) '
      'VALUES (@t,@ok,@oi,@ar,@pl,@h,@sz,@hs,@ph,@cs,@st,@sk) RETURNING id',
      {
        't': token,
        'ok': ownerKind,
        'oi': ownerId,
        'ar': arch,
        'pl': platform,
        'h': hash,
        'sz': size,
        'hs': hashSignature,
        'ph': podfileLockHash,
        'cs': canSideload,
        'st': ArtifactStatus.pending.name,
        'sk': storageKey,
      },
    );
    return (await _artifactById(_int(r.first['id'])))!;
  }

  Future<ArtifactRow?> _artifactById(int id) async {
    final r = await _q('SELECT * FROM artifacts WHERE id = @id', {'id': id});
    if (r.isEmpty) return null;
    return _artifactFrom(r.first);
  }

  /// An existing non-`failed` artifact for this owner/arch/platform, if any.
  /// Used to reject duplicate registration with 409 (failed uploads are
  /// retryable and are ignored here).
  Future<ArtifactRow?> existingArtifact(
    String ownerKind,
    int ownerId,
    String arch,
    String platform,
  ) async {
    final r = await _q(
      "SELECT * FROM artifacts WHERE owner_kind = @ok AND owner_id = @oi "
      "AND arch = @ar AND platform = @pl AND status <> 'failed' LIMIT 1",
      {'ok': ownerKind, 'oi': ownerId, 'ar': arch, 'pl': platform},
    );
    if (r.isEmpty) return null;
    return _artifactFrom(r.first);
  }

  Future<ArtifactRow?> artifactByToken(String token) async {
    final r = await _q('SELECT * FROM artifacts WHERE token = @t', {
      't': token,
    });
    if (r.isEmpty) return null;
    return _artifactFrom(r.first);
  }

  ArtifactRow _artifactFrom(Map<String, Object?> m) => ArtifactRow(
    id: _int(m['id']),
    token: m['token'] as String,
    ownerKind: m['owner_kind'] as String,
    ownerId: _int(m['owner_id']),
    arch: m['arch'] as String,
    platform: m['platform'] as String,
    hash: m['hash'] as String,
    size: _int(m['size']),
    hashSignature: m['hash_signature'] as String?,
    podfileLockHash: m['podfile_lock_hash'] as String?,
    canSideload: asDbBool(m['can_sideload']),
    status: ArtifactStatus.parse(m['status'] as String),
    storageKey: m['storage_key'] as String,
  );

  Future<void> setArtifactStatus(int artifactId, ArtifactStatus status) => _q(
    'UPDATE artifacts SET status = @s WHERE id = @id',
    {'s': status.name, 'id': artifactId},
  );

  Future<List<ArtifactRow>> releaseArtifacts(
    int releaseId, {
    String? arch,
    String? platform,
  }) async {
    final where = StringBuffer("owner_kind = 'release' AND owner_id = @o");
    final args = <String, Object?>{'o': releaseId};
    if (arch != null && arch.isNotEmpty) {
      where.write(' AND arch = @ar');
      args['ar'] = arch;
    }
    if (platform != null && platform.isNotEmpty) {
      where.write(' AND platform = @pl');
      args['pl'] = platform;
    }
    final r = await _q(
      'SELECT * FROM artifacts WHERE $where ORDER BY id',
      args,
    );
    return r.map(_artifactFrom).toList();
  }

  Future<List<ArtifactRow>> patchArtifacts(int patchId) async {
    final r = await _q(
      "SELECT * FROM artifacts WHERE owner_kind = 'patch' AND owner_id = @o ORDER BY id",
      {'o': patchId},
    );
    return r.map(_artifactFrom).toList();
  }

  Future<ArtifactRow?> patchArtifact(
    int patchId,
    String arch,
    String platform,
  ) async {
    final r = await _q(
      "SELECT * FROM artifacts WHERE owner_kind = 'patch' AND owner_id = @o AND arch = @ar AND platform = @pl",
      {'o': patchId, 'ar': arch, 'pl': platform},
    );
    if (r.isEmpty) return null;
    return _artifactFrom(r.first);
  }

  // ---- Events (idempotent) ----

  Future<bool> insertEvent({
    required String raw,
    String? dedupeKey,
    String? appId,
    String? clientId,
    String? type,
    int? patchNumber,
    String? platform,
    String? arch,
    String? releaseVersion,
    int? ts,
  }) async {
    final r = await _q(
      'INSERT INTO events(dedupe_key, raw, app_id, client_id, type, patch_number, '
      'platform, arch, release_version, ts) VALUES (@dk,@raw,@a,@c,@t,@pn,@pl,@ar,@rv,@ts) '
      'ON CONFLICT(dedupe_key) DO NOTHING RETURNING id',
      {
        'dk': dedupeKey,
        'raw': raw,
        'a': appId,
        'c': clientId,
        't': type,
        'pn': patchNumber,
        'pl': platform,
        'ar': arch,
        'rv': releaseVersion,
        'ts': ts,
      },
    );
    return r.isNotEmpty;
  }

  // ---- OAuth codes + refresh tokens (persisted, single-use) ----

  Future<void> insertAuthCode(String code, String email, DateTime expiresAt) =>
      _q('INSERT INTO auth_codes(code, email, expires_at) VALUES (@c,@e,@x)', {
        'c': code,
        'e': email,
        'x': expiresAt,
      });

  /// Atomically consumes an unexpired auth code, returning its email (or null).
  Future<String?> consumeAuthCode(String code) async {
    final r = await _q(
      'DELETE FROM auth_codes WHERE code = @c AND expires_at > now() RETURNING email',
      {'c': code},
    );
    return r.isEmpty ? null : r.first['email'] as String;
  }

  Future<void> insertRefreshToken(String token, String email) => _q(
    'INSERT INTO refresh_tokens(token, email) VALUES (@t,@e)',
    {'t': token, 'e': email},
  );

  /// Atomically consumes (rotates) a refresh token, returning its email.
  Future<String?> consumeRefreshToken(String token) async {
    final r = await _q(
      'DELETE FROM refresh_tokens WHERE token = @t RETURNING email',
      {'t': token},
    );
    return r.isEmpty ? null : r.first['email'] as String;
  }

  Future<void> revokeRefreshToken(String token) =>
      _q('DELETE FROM refresh_tokens WHERE token = @t', {'t': token});

  /// Best-effort cleanup of expired auth codes (call periodically).
  Future<void> purgeExpiredAuthCodes() =>
      _q('DELETE FROM auth_codes WHERE expires_at < now()');

  // ---- IdP broker CSRF state (persisted, single-use) ----

  Future<void> insertIdpState(
    String state,
    String continueUrl,
    DateTime expiresAt,
  ) => _q(
    'INSERT INTO idp_states(state, continue_url, expires_at) VALUES (@s,@c,@x)',
    {'s': state, 'c': continueUrl, 'x': expiresAt},
  );

  /// Atomically consumes an unexpired IdP state, returning its `continue` URL.
  Future<String?> consumeIdpState(String state) async {
    final r = await _q(
      'DELETE FROM idp_states WHERE state = @s AND expires_at > now() '
      'RETURNING continue_url',
      {'s': state},
    );
    return r.isEmpty ? null : r.first['continue_url'] as String;
  }

  /// Drops IdP states abandoned mid-login (call periodically).
  Future<void> purgeExpiredIdpStates() =>
      _q('DELETE FROM idp_states WHERE expires_at < now()');

  /// Drops rate-limit counters for windows that have closed. Without this the
  /// table grows one row per bucket per minute, forever.
  Future<void> purgeOldRateWindows({int keepMinutes = 10}) => _q(
    'DELETE FROM rate_limits WHERE window_start < @w',
    {'w': DateTime.now().millisecondsSinceEpoch ~/ 60000 - keepMinutes},
  );

  /// Drops device events older than [days]. `events` is written one row per
  /// check-in by the public `/patches/events`, storing the raw body, so it is
  /// the fastest-growing table in the schema — but it is also what every
  /// analytics query reads, so retention is opt-in (`days <= 0` keeps
  /// everything, which is the default).
  Future<void> purgeOldEvents(int days) async {
    if (days <= 0) return;
    await _q(
      "DELETE FROM events WHERE received_at < now() - interval '$days days'",
    );
  }

  /// Drops audit entries older than [days]. Opt-in for the same reason: the
  /// audit trail is often the thing an operator most wants to keep.
  Future<void> purgeOldAuditLog(int days) async {
    if (days <= 0) return;
    await _q(
      "DELETE FROM audit_log WHERE created_at < now() - interval '$days days'",
    );
  }

  // ---- Metrics (event-derived) ----

  /// Per-patch download/install counts and unique clients for an app, sourced
  /// from the append-only events table. Event types are device-verified
  /// (`__patch_download__`, `__patch_install__`).
  Future<List<Map<String, dynamic>>> patchMetrics(String appId) async {
    final r = await _q(
      '''SELECT patch_number,
           COUNT(*) FILTER (WHERE type = '__patch_download__') AS downloads,
           COUNT(*) FILTER (WHERE type = '__patch_install__')  AS installs,
           COUNT(*) FILTER (WHERE type = '__patch_install_failure__') AS install_failures,
           COUNT(*) FILTER (WHERE type = '__patch_update_failure__')  AS update_failures,
           COUNT(DISTINCT client_id) AS unique_clients
         FROM events WHERE app_id = @a AND patch_number IS NOT NULL
         GROUP BY patch_number ORDER BY patch_number''',
      {'a': appId},
    );
    return r;
  }

  Future<Map<String, dynamic>> appMetrics(String appId) async {
    final byType = <String, int>{};
    for (final m in await _q(
      'SELECT type, COUNT(*) AS c FROM events WHERE app_id = @a GROUP BY type',
      {'a': appId},
    )) {
      byType[(m['type'] as String?) ?? 'unknown'] = _int(m['c']);
    }
    final uc = await _q(
      'SELECT COUNT(DISTINCT client_id) AS c FROM events WHERE app_id = @a',
      {'a': appId},
    );
    final total = await _q(
      'SELECT COUNT(*) AS c FROM events WHERE app_id = @a',
      {'a': appId},
    );
    return {
      'total_events': _int(total.first['c']),
      'unique_clients': _int(uc.first['c']),
      'events_by_type': byType,
    };
  }

  // ---- Settings (singletons) ----

  Future<String?> getSetting(String key) async {
    final r = await _q('SELECT value FROM settings WHERE key = @k', {'k': key});
    return r.isEmpty ? null : r.first['value'] as String;
  }

  /// Load-or-create a singleton setting atomically-ish. If absent, calls
  /// [create] and persists it. (A race between nodes at first boot is harmless:
  /// the ON CONFLICT keeps the first writer's value; callers re-read.)
  Future<String> getOrCreateSetting(
    String key,
    String Function() create,
  ) async {
    final existing = await getSetting(key);
    if (existing != null) return existing;
    final value = create();
    await _q(
      'INSERT INTO settings(key, value) VALUES (@k, @v) ON CONFLICT(key) DO NOTHING',
      {'k': key, 'v': value},
    );
    return (await getSetting(
      key,
    ))!; // re-read to win any race deterministically
  }

  // ---- Rate limiting (shared, fixed-window) ----

  /// Atomically increments the counter for [bucket] in the current minute and
  /// returns the new count. Shared across nodes via the database.
  Future<int> incrementRateWindow(String bucket, int windowStart) async {
    final r = await _q(
      'INSERT INTO rate_limits(bucket, window_start, count) VALUES (@b, @w, 1) '
      'ON CONFLICT(bucket, window_start) DO UPDATE SET count = rate_limits.count + 1 '
      'RETURNING count',
      {'b': bucket, 'w': windowStart},
    );
    return _int(r.first['count']);
  }

  // ---- Audit log ----

  Future<void> audit(
    String action, {
    String? actor,
    String? target,
    String? detail,
  }) => _q(
    'INSERT INTO audit_log(actor, action, target, detail) VALUES (@ac,@an,@tg,@dt)',
    {'ac': actor, 'an': action, 'tg': target, 'dt': detail},
  );
}
