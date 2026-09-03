<!-- cspell:words tenancy -->

# CONTROL-PLANE-AUDIT-2 — identity and tenancy mutations are typed audit outcomes

2026-09-03. Host-side only. No cell, no release, no device, no Route B change.
Follows [`control_plane_audit_1.md`](control_plane_audit_1.md), which built the
machinery; this converts the surface AUDIT-1 deliberately left on generic
free-text rows.

## Why this surface and not compiler work

Ownership and credentials are the control-plane state that determines **who is
allowed to mutate releases and patches**. AUDIT-1 made the patch lifecycle
auditable while the state governing access to it was recorded as strings like
`detail: "dev@example.com as developer"` — untyped, no result, no HTTP status,
no notion of a refused attempt. That was the weakest link in the trail.

## What changed

Ten operations moved from `kind: "detail"` free-text notes to typed
`kind: "request"` outcomes, one row per request:

| operation | route |
|---|---|
| `user.create` | `POST /admin/users` — **issues an API key** |
| `user.register` | `POST /api/v1/users` — the CLI's own registration; provisions a personal org on first sight |
| `org.invite` | `POST /admin/orgs/{org}/invitations` |
| `org.invite.accept` | `POST /api/v1/invitations/{token}/accept` |
| `org.invite.revoke` | `DELETE /admin/orgs/{org}/invitations/{token}` |
| `org.member.role` | `PATCH /admin/orgs/{org}/members/{user}` |
| `org.member.remove` | `DELETE /admin/orgs/{org}/members/{user}` |
| `org.domains` | `PUT /admin/orgs/{org}/domains` |
| `app.collaborator.add` | `POST /admin/apps/{app}/collaborators` |
| `app.collaborator.remove` | `DELETE /admin/apps/{app}/collaborators/{user}` |

That is the **complete** set of mutating identity/tenancy routes this server
has. There is no API-key rotation or revocation endpoint to audit — only
issue — and adding one would be scope creep, not auditing.

Two new columns (migration 12): `org_id`, and `target_kind`, which finally
makes the pre-existing free-text `target` column typeable. A row with no
`target_kind` is a legacy note whose `target` nobody can interpret.

## Three decisions worth stating

**Both sides of an access change are banked.** `role_before` / `role_after` on
memberships and collaborator grants, `domains_before` / `domains_after` on the
org email policy. `Repository.addCollaborator` **upserts**, so that route
silently *changes* an existing grant as well as creating one — a row holding
only the new role cannot distinguish a fresh `developer` from a quiet
`developer -> owner`. Two new single-query helpers (`memberRole`,
`collaboratorRole`) supply the before value.

**Query-string values are banked BEFORE authorization decides.** These arrive
already parsed, so unlike a request body there is nothing to buffer and no
denial-of-service surface in reading them early. An outsider trying to grant
themselves `owner` on someone else's app therefore appears as exactly that,
rather than as a bare 403 with no subject. (Request bodies remain unread before
authentication — the AUDIT-1 limitation stands and is unchanged.)

**Capabilities are fingerprinted, never stored.** An invitation token grants the
org role it carries, up to `owner`; an API key is a credential. Both are
recorded as 12 hex characters of SHA-256:

* `user.create` banks `api_key_issued`, so a key found in a CI config can be
  fingerprinted the same way and matched to the request that issued it;
* an invitation fingerprints identically on the issue, accept and revoke rows,
  which is what links the three without any of them holding the token.

`sb_inv_` was added to the credential-shape scrubber alongside `sb_api_`, as a
backstop on free text.

## Two things deliberately NOT converted

**`POST /login` and `GET /oauth/callback` stay unclassified.** They are PUBLIC
routes. Classifying them as mutations would let an unauthenticated caller write
an audit row per request — and "a failed login writes no audit row" is an
existing, tested guarantee (`api_test.dart:196`) that exists because that was
once a real defect. A successful consent still records `login.consent` as a
detail row. There is a test asserting a failed login still writes nothing.

**`admin.denied` stays a detail row.** Every mutating admin route now writes a
typed refused event of its own, so this looks redundant — it is not. It also
fires for denied **reads** of the operator surface, `GET /admin/audit` above
all, and a read writes no mutation event by design. Without it, someone probing
the audit log itself would leave no trace at all.

## Qualification

### Request level — `packages/code_push_server/test/audit_identity_test.dart`

```
dart test test/audit_identity_test.dart  ->  +33: All tests passed
dart test -x integration                 ->  +370: All tests passed
```

| # | acceptance | how it is measured |
|---|---|---|
| 1 | successful identity mutation → exactly one typed event | eight tests, one per operation family: `user.create` (target, credential fingerprint, `account_existed`, `api_key_issued` == the fingerprint of the key actually returned, and the key absent from the serialized row); a second key for an existing account flagged as such with a *different* fingerprint; a collaborator grant then re-grant showing `role_before: null -> developer` then `developer -> admin`; an org role change showing `developer -> admin`; the domain policy showing `'' -> self-host.local -> ''`; an invitation correlated across issue / accept / revoke by one fingerprint; member and collaborator removals naming the person and the role lost |
| 2 | refused unauthorized mutation → typed refused event | a tenant cannot issue credentials (and no `api_key_issued` claims one was); a `developer` collaborator cannot grant access — and the row keeps `target: outsider@example.com`, `role_after: owner`, which is the fact worth seeing; a non-member is refused on all four org routes and the sweep asserts nothing in that org's history reads as success; an unknown credential is attributed by fingerprint with `actor_id: null` |
| 3 | failed/conflicting mutation → not success | demoting the last owner (409, both roles banked, membership verified unchanged); removing the last owner (409); a domain policy that would lock out every admin (409, policy verified unchanged); an out-of-domain invitation (403, subject intact, **no** invitation fingerprint, `orgInvitations` verified empty); accepting an invitation twice (success then refused, same fingerprint on both); plus a four-request sweep asserting every row is non-success with a 4xx/5xx status |
| 4 | request ID correlates response ↔ row | `X-Request-Id` from the response resolves through `GET /admin/audit?request_id=`; a denied audit-log **read** is traceable via its `admin.denied` detail row carrying the same request id |
| 5 | secret canary appears zero times | two canaries — an API-key-shaped one and an **invitation-token**-shaped one — presented as the bearer, in a header, in the query string, in a `name`, and as a path token, across five routes. Searched over the captured log sink plus every serialized row: **0 occurrences** each, and 0 for the real issued key, the real invitation token, and the bootstrap key. Non-vacuous: the same capture is asserted to contain `user.create`, `org.invite`, the subject address, and both tokens' fingerprints |
| 6 | read-only admin calls create no mutation events | eight reads across the whole admin + org read surface leave the ceiling untouched; a failed `POST /login` still writes nothing; the classifier is unit-tested against 12 non-mutating routes including all four public auth routes |
| 7 | generic `detail` is no longer the only evidence | a coverage test drives **all ten** operations and asserts each has a typed request row with a non-null `result` and `http_status` — so a future route added without a classifier entry fails here. A second test asserts the old rows were *replaced*, not supplemented: zero `kind: "detail"` rows exist under `user.create` or `org.invite`, so nothing is double-counted |
| 8 | `/admin/audit` answers a concrete question | `?app_id=X&operation=app.collaborator.add,app.collaborator.remove` returns exactly `[add:success, remove:success, add:refused]` with noise from a second app excluded, naming both actors, both subjects, and the `owner` role the refused attempt wanted. Also `?target_kind=user&target=<email>` across both surfaces, and an unknown `target_kind` as a **400** rather than a silently empty answer |

### End to end — `selfhost/scripts/audit_qualification.sh`

Extended with step 9, over the real wire against a throwaway server with the
real JSON log sink. **23 passed, 0 failed** (18 from AUDIT-1, 5 new).

```
9. issue a key for teammate@example.com
     user.create typed success, target_kind=user, target=the address
     api_key_issued == sha256(returned key)[:12], recomputed independently
   grant then remove app access; then an unauthorized attempt by the teammate
   ?app_id=…&operation=app.collaborator.add,app.collaborator.remove
     -> [add:success, remove:success, add:refused]
   no credential (canary, operator key, newly issued key) in the output
   two admin reads leave the ceiling unchanged
```

The refused row from that run, verbatim from the endpoint:

```json
{ "operation": "app.collaborator.add", "kind": "request",
  "actor": "teammate@example.com", "actor_id": 3,
  "actor_credential": "api_key:957543f4aad4",
  "app_id": "bce861ce-82d5-4cdb-f3b2-4b794c0b9c35",
  "target_kind": "user", "target": "outsider@example.com",
  "result": "refused", "http_status": 403,
  "detail": "{\"role_after\":\"owner\"}" }
```

Who, with which credential, on which app, for whom, what they wanted, and that
it did not happen — from one row.

## One harness defect this lane hit

`POST /api/v1/apps` defaults to the **root** org, which a freshly provisioned
user is not a member of. Six tests failed with `type 'Null' is not a subtype of
type 'String'` because the helper read `id` off a 403 body. Not a product
defect — the 403 is correct — but a reminder that a test helper which ignores a
status code fails later and in a confusing place. The helper now looks up the
caller's own organization first.

## Provenance

| thing | value |
|---|---|
| parent lane | `ce45478f` (CONTROL-PLANE-AUDIT-1) |
| migration | 12 |
| suite | 370 pass (`dart test -x integration`), 33 new |
| live run | 23 pass / 0 fail |
| new endpoint filters | `org_id`, `target_kind`, `target` |
