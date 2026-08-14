# Pointing `shorebird login` at a real external IdP

The self-hosted control plane can broker `shorebird login` against any standard
OAuth 2.0 / OpenID Connect identity provider (Google, Microsoft/Entra, Okta,
Auth0, …). The CLI never talks to the IdP directly — it always talks to *your*
server, and your server bounces the browser out to the IdP and back.

When no IdP is configured the server falls back to **self-consent**: `/login`
serves a sign-in form that accepts an API key (`API_KEY`, or any per-user key
from `POST /admin/users`) and issues a session for the identity that key belongs
to — the bootstrap key signs in as `LOGIN_EMAIL`. A request can never name its
own identity. Configuring the `IDP_*` variables below turns on broker mode,
after which identity comes from the IdP's `email` claim instead.

---

## 0. Authenticating a SCRIPT or an AGENT on this rig — no browser, no upstream

**Read this before you run `shorebird login`.** On this rig that command is almost
always the wrong instinct, and the CLI's own error text will send you somewhere that
does not exist for us. This section is here because that misdirection has cost real
time more than once.

### The trap, quoted exactly

When credentials are absent or stale, `shorebird account whoami` says:

```
Failed to refresh credentials.
Try logging out with shorebird logout and logging in again.
```

and a bad `SHOREBIRD_TOKEN` says:

```
Failed to parse SHOREBIRD_TOKEN. Expected an API key (sb_api_...) or a legacy CI token.
… Create an API key at https://console.shorebird.dev instead.
```

**Both messages point at upstream Shorebird infrastructure, and neither applies
here.** There is no `console.shorebird.dev` in this deployment and there is nothing
to log in *to* — our control plane is its own identity provider. The message is
inherited upstream text and is correct only for a hosted customer. Reading it as an
instruction is what wastes the time.

### What is actually true

* The CLI authenticates from **`SHOREBIRD_TOKEN`** (`auth/auth.dart:43`), which takes
  an API key beginning `sb_api_` — or a legacy `login:ci` token, which is deprecated.
* Our server ISSUES those keys itself. `POST /admin/users?email=&name=` creates the
  user and returns `{user_id, email, api_key}` (`api.dart`, the `/admin/users` route).
* That route is gated on `_authorizeServerAdmin` — owner/admin of the **root org**.
  The bootstrap `API_KEY` authenticates as user 1, an owner of the root org, so the
  bootstrap key is sufficient and no other identity is needed to get started.
* The bootstrap key lives in the container's environment, sourced from
  `~/shorebird-rig/secrets/<container>.env`. It is a **real random value**: the
  published placeholder `sb_api_selfhost_dev` (`Config.devApiKey`) is rejected at boot
  by `validate()`, so any *running* instance necessarily has a real one.
* Ports: `cps-ios` is `:18080` and `cps-android` is `:18081` on the host; both are
  `8080` inside the container.

### The recipe

Mint a purpose-named key by running the request **inside** the container, so the
bootstrap secret is used without ever being printed or copied anywhere:

```sh
docker exec cps-ios sh -lc \
  'curl -sS -X POST \
     "http://localhost:8080/admin/users?email=<purpose>@selfhost.local&name=<purpose>" \
     -H "Authorization: Bearer $API_KEY"'
```

Then use the `api_key` it returns:

```sh
SHOREBIRD_TOKEN=sb_api_… SHOREBIRD_HOSTED_URL=http://localhost:18080 \
  shorebird account whoami
```

**Mint a NAMED key per purpose rather than reusing one.** The audit row
(`user.create`) then says who did what, and revoking one lane's key does not sign out
the rig.

### If you are an agent and the command is refused

Reading `~/shorebird-rig/secrets/*.env`, and `docker exec` against a container to use
`$API_KEY`, are both credential operations and a permission layer may block them even
though nothing is printed. **That is a harness policy, not a missing capability, and
it is a different problem from "we need to log in".** Say which of the two you hit —
otherwise the next reader re-runs this whole investigation. Ask the operator to run
the one command above and hand back only the minted `sb_api_…`, which is a purpose-
scoped key rather than the bootstrap secret.

---

## 1. The broker flow

```
shorebird login
      │  opens browser at
      ▼
GET <PUBLIC_BASE_URL>/login?continue=<CLI loopback>
      │  server persists CSRF `state` -> continue (single-use, 10 min), 302 to the IdP
      ▼
IdP authorize page  (user signs in / consents)
      │  302 back to the redirect URI with ?code=&state=
      ▼
GET <PUBLIC_BASE_URL>/oauth/callback?code=&state=
      │  server POSTs the code to the IdP token endpoint (server-to-server, TLS),
      │  reads the `email` claim out of the returned id_token,
      │  mints its own single-use auth code, 302 back to the CLI loopback
      ▼
CLI loopback receives ?code=…
      │  CLI POSTs it to
      ▼
POST <PUBLIC_BASE_URL>/token   ->  { access_token (our JWT), refresh_token, … }
```

The JWT the CLI receives is minted and signed by **our** server (RS256), not by
the IdP. The IdP is used only to prove *who the user is* (their email). That
JWT is then accepted as a bearer across the whole API, and `repo.userByEmail` /
`upsertUser` maps the `email` claim to a local user record.

### The `email` claim is required

`/oauth/callback` extracts identity from the IdP token response by:

1. taking a top-level `email` field if the token endpoint returns one, else
2. base64url-decoding the **payload** of the `id_token` JWT and reading its
   `email` claim.

If neither is present the login fails with `?error=no_email`. Therefore your
`IDP_SCOPES` **must** include a scope that yields the email claim (`openid
email` — the default — is sufficient for both Google and Microsoft).

> Security note: the broker **decode-only** parses the `id_token` — it does not
> verify the id_token's signature. This is safe here because the token is
> fetched directly from the IdP's token endpoint over TLS in a server-to-server
> call (not passed through the browser), so its provenance is already
> established by the transport. A hardened deployment could additionally fetch
> the IdP's JWKS and verify the id_token signature + `iss`/`aud`/`exp` before
> trusting the `email` claim; that is not implemented today.

---

## 2. Environment variables the server reads

All are read in `lib/src/config.dart`. Broker mode activates only when
`IDP_CLIENT_ID`, `IDP_AUTHORIZE_URL`, and `IDP_TOKEN_URL` are all non-empty
(`Config.idpEnabled`).

| Variable | Purpose | Default |
|---|---|---|
| `IDP_CLIENT_ID` | OAuth client id issued by the IdP | `""` (broker off) |
| `IDP_CLIENT_SECRET` | OAuth client secret | `""` |
| `IDP_AUTHORIZE_URL` | IdP authorization endpoint | `""` |
| `IDP_TOKEN_URL` | IdP token endpoint | `""` |
| `IDP_SCOPES` | Space-separated scopes | `openid email` |

The **redirect / callback URI** you register at the IdP is always:

```
<PUBLIC_BASE_URL>/oauth/callback
```

e.g. `https://code-push.example.com/oauth/callback`. It must match exactly
(scheme, host, path, no trailing slash) — the server sends this same string in
both the authorize redirect and the token exchange.

---

## 3. Google

### Create the OAuth client

1. Google Cloud Console → **APIs & Services → Credentials**.
2. **Create Credentials → OAuth client ID**.
3. Application type: **Web application**.
4. Under **Authorized redirect URIs** add exactly:
   `https://code-push.example.com/oauth/callback`
   (substitute your `PUBLIC_BASE_URL`).
5. Save. Copy the **Client ID** and **Client secret**.
6. Configure the **OAuth consent screen** (external or internal). Ensure the
   `email` scope is allowed; `openid email` are non-sensitive so no
   verification is required.

### Env vars

```bash
IDP_CLIENT_ID=<your-google-client-id>.apps.googleusercontent.com
IDP_CLIENT_SECRET=CHANGE_ME_google_client_secret
IDP_AUTHORIZE_URL=https://accounts.google.com/o/oauth2/v2/auth
IDP_TOKEN_URL=https://oauth2.googleapis.com/token
IDP_SCOPES=openid email
```

Google returns an `id_token` in the token response; its payload carries the
`email` claim, which the broker reads.

---

## 4. Microsoft / Entra ID (Azure AD)

### Create the app registration

1. Azure Portal → **Microsoft Entra ID → App registrations → New
   registration**.
2. Give it a name and pick the supported account types (single-tenant, or
   multi-tenant if you want any Entra org to sign in).
3. **Redirect URI**: platform **Web**, value exactly:
   `https://code-push.example.com/oauth/callback`
4. Register. Copy the **Application (client) ID** and your **Directory (tenant)
   ID**.
5. **Certificates & secrets → New client secret**. Copy the secret **value**
   (not the id).

### Env vars

Replace `{tenant}` with your tenant ID (or `common` for the multi-tenant
endpoint, `organizations` for any work/school account):

```bash
IDP_CLIENT_ID=<application-client-id>
IDP_CLIENT_SECRET=CHANGE_ME_entra_client_secret
IDP_AUTHORIZE_URL=https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize
IDP_TOKEN_URL=https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
IDP_SCOPES=openid email
```

Entra's v2.0 endpoint returns an `id_token` whose payload includes `email` when
the `email` scope is requested (for some account types the email may surface as
`preferred_username` — if you find logins failing with `no_email`, ensure the
account has a real email and the `email` optional claim is enabled on the app
registration's **Token configuration**).

---

## 5. Pointing the CLI at your server

Set these before `shorebird login` so the CLI treats your server as both the
API host and the auth service:

```bash
export SHOREBIRD_HOSTED_URL=https://code-push.example.com
export AUTH_SERVICE_URL=https://code-push.example.com
export SHOREBIRD_JWT_ISSUER=https://code-push.example.com   # must equal the server's iss

shorebird login
```

`SHOREBIRD_JWT_ISSUER` must equal the server's `SHOREBIRD_JWT_ISSUER` (the `iss`
claim it stamps into JWTs, and the `jwt_issuer` it returns from `/users/me`) or
the CLI will reject the minted token.

With broker mode enabled, `shorebird login` now opens the **IdP's** sign-in page
(Google / Microsoft) instead of self-consenting. After the user authenticates,
the browser returns to the CLI loopback and the CLI exchanges the code at
`/token` for the session JWT.

---

## 6. Verifying

- `GET https://code-push.example.com/login?continue=http://localhost:1234`
  should 302 to the IdP authorize URL (not straight back to `continue`).
- After a successful `shorebird login`, `shorebird apps list` (or any
  authenticated command) should work, and `GET /api/v1/users/me` should return
  the IdP email.
- Failures come back to the CLI loopback as `?error=…`
  (`no_email`, `missing_code`, `Invalid state`, or the IdP's own error code).
</content>
</invoke>
