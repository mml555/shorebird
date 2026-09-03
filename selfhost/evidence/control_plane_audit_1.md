<!-- cspell:words vacuity -->

# CONTROL-PLANE-AUDIT-1 — control-plane mutations are auditable

2026-09-03. Host-side only. **No cell was minted, no release cut, no physical
iOS run, no workflow row re-run.** The one live producer invocation is a
`shorebird patch android` that refuses before building anything.

## What was broken

Gate 6E used *"no patch-creation request in the control-plane log"* as evidence
that a producer-refused patch published nothing. That check was struck as
vacuous. The precise fault, restated now that the code has been read:

* `cps-ios` **does** emit one request line per request today
  (`POST /api/v1/apps/{id}/patches -> 200 (4ms)`, 1,343 of them in the current
  container's log). The struck check's premise, as written in
  `HANDOFF.md` trap 2 — *"emits no HTTP request logging at all"* — is **wrong
  for the current image** (`cps-assets:local-m10`, started 2026-09-01).
* The check was vacuous anyway, for reasons the request log cannot fix. That
  log is `docker logs` — a ring buffer with no retention guarantee, cleared on
  the restart that has since happened, so nothing from 6E survives to grep. And
  a request line carries no actor, no credential, no patch or release id, and no
  notion of a refused *attempt*: `-> 409` and `-> 200` are the same shape.
  Absence in it was never falsifiable.

The conclusion 6E drew was right and rests on its four independent counts. What
was missing was **infrastructure**, not a better grep.

## What was built

`audit_log` becomes a structured record of control-plane MUTATIONS
(migration 11), with a queryable read at `GET /admin/audit`. See
[`../API_REFERENCE.md`](../API_REFERENCE.md#audit-log) for the field reference
and [`../../packages/code_push_server/PRODUCTION.md`](../../packages/code_push_server/PRODUCTION.md)
§8b for the operator recipes.

Covered operations, one `kind: "request"` row each:
`app.create`, `release.create`, `release.update`, `release.artifact.create`,
`patch.create`, `patch.update`, `patch.promote`, `patch.artifact.create`,
`patch.withdraw`, `patch.rollout`, `channel.create`, `artifact.upload`.

Three properties are **structural**, not conventional — which is the difference
between an audit trail and a `print`:

| property | why it holds |
|---|---|
| a refused mutation cannot read as success | `result` is `AuditResult.fromStatus` of the response the server actually sent. No handler can assert it |
| an attempt refused *before* a handler still appears | the auditing middleware sits OUTSIDE `_auth` and `_rateLimit`; the scope is a mutable object in the request context that `_auth` fills in |
| a read cannot masquerade as a mutation | `classifyMutation` returns null for every non-mutating route, and there is no code path that writes a request-outcome row without it |

Never recorded: API keys, JWTs, authorization headers, upload tokens, request
bodies. The event is an allowlist of computed fields
(`AuditScope.toEvent`), so those are structurally absent; credential-shape
scrubbing (`auditSafeText`) is a backstop on free text, not the mechanism.
The upload route's template is stored as `{token}` because the token is a
bearer capability, not an identifier.

## Qualification

### Request-level controls — `packages/code_push_server/test/audit_test.dart`

```
dart test test/audit_test.dart   ->  +30: All tests passed
dart test -x integration         ->  +337: All tests passed
```

| # | control | how it is measured |
|---|---|---|
| 1 | successful create | exactly one `patch.create` request row, with actor, credential fingerprint, app/release/patch/number, request id, `success`/200. Plus: two API keys on one account produce two DISTINGUISHABLE `actor_credential` values, neither containing the key |
| 2 | successful promote | `patch.promote` carrying track, release id and patch number — all of which arrive in the request BODY, so this also proves handler enrichment reaches the event. `channel.create` covered separately |
| 3 | removal | `patch.withdraw` with `rollback: true` in detail, attributed to release + patch number |
| 4 | refused mutation | five shapes — 409 not-ready, 400 missing field, 404 cross-tenant release, 403 unknown credential, 403 no credential — each `refused`, plus a sweep asserting no refusal anywhere reads as success. The two 403s never reach a handler and are still attributed to app id and to the credential fingerprint |
| 5 | read-only request | ten reads plus `patches/check` and `patches/events` leave the audit ceiling unchanged. `classifyMutation` is also unit-tested against 17 non-mutating routes |
| 6 | secret redaction | a distinctive canary (`sb_api_CANARY_DO_NOT_LOG_…`) presented as the bearer, as `x-api-key`, in the query string and in `notes`; the captured log sink plus every serialized row is searched. **0 occurrences**, and the real bootstrap key 0 too. Non-vacuous: the same capture is asserted to contain `patch.create` and the app id |
| 7 | failed transaction | a repository whose `createPatch` throws after authorization → row is `error`/500 and `?result=success&operation=patch.create` is empty. Dual arm: a repository whose audit WRITE throws → request still succeeds, `code_push_audit_write_failures_total` increments, `AUDIT WRITE FAILED` and `audit_persisted=false` both appear |
| 8 | request correlation | the response's `X-Request-Id` equals the row's `request_id`, and `GET /admin/audit?request_id=` finds it. Detail rows (`release.ready`) share the request id of the `release.update` that caused them and carry `result: null` — a sub-fact is not an outcome |

### The ceiling control — `selfhost/scripts/audit_qualification.sh`

Throwaway control plane, temp dir, free port. Real `~/.shorebird/bin/shorebird`
against `selfhost/fixtures/android_signing_app` (copied, never patched in
place). **18 passed, 0 failed.**

```
1. snapshot ceiling                                   -> 2
2. real `shorebird patch android --release-version 99.99.99+99`
     producer exit=70, 2 requests of its own reached the server
     refusal reason asserted: Release not found: "99.99.99+99"
3. NEGATIVE  ?after=2&operation=patch.create           -> count 0
4. ANTI-VACUITY: one known-valid create
     ?after=2&operation=patch.create                   -> count 1, success,
       release_id, app_id, patch_number, bootstrap credential,
       request_id == the response's X-Request-Id
5. a create refused for a bad credential               -> recorded as refused
6. canary in captured output                           -> 0 occurrences
7. release-scoped acceptance query                     -> the create
   app-scoped acceptance query                         -> [refused, success]
```

Step 4 is the whole point. Step 3 on its own passes identically against a logger
that records nothing — which is exactly what happened in 6E.

**Two vacuous versions of step 2 were written and caught before this run**, both
by reading the producer log instead of trusting the exit code, and both are now
asserted against in the script:

1. The first fixture (`manual_api_app`) has no `android/app/src`, so
   `assertPreconditions` refused **before opening a socket**. The check
   "requests reached the control plane" counted the script's own setup calls and
   passed. Fixed by snapshotting the request count immediately before the
   producer run, so only the producer's own traffic counts.
2. With an android fixture, the producer reached the server and refused —
   with `FormatException: Failed to parse Release from JSON`, because the
   release had been created over raw HTTP without `flutter_revision` /
   `flutter_version`, which the CLI's `Release.fromJson` casts unguarded. A
   real refusal, at a real server, for the wrong reason. Fixed by creating a
   parseable release, and by asserting the refusal STRING.

An exit code does not distinguish "refused where I claimed" from "refused three
steps earlier". Only the reason does.

### What this control does and does not carry

It shows that a real producer refusal reaching the server sends no patch-create
request, and that the probe saying so can fail. Its refusal is at **release
resolution**, not at 6E's private-construction admission gate — reproducing that
needs the cell and a build. The general case rests on ordering:
`publishPatch` (the only caller of `POST /patches` in
`packages/shorebird_cli/lib/src/commands/patch/patch_command.dart`) is the LAST
step of `PatchCommand.createPatch`, after `patcher.createPatchArtifacts` —
where the admission gate lives. Every producer-side refusal therefore precedes
any patch-create request by construction. That is an argument about code order,
and it says so.

## A limitation, stated rather than papered over

On `patch.create` and `patch.promote` the release and patch ids arrive in the
request **body**. A request refused by authentication is never parsed —
deliberately: buffering an unauthenticated body to decorate an audit event
would be a denial-of-service surface on the one route that can reject at the
header. Such an attempt still carries its operation and its app id (both from
the path), so:

* `?release_id=N` is the **precise** query — every attempt that got far enough
  to name a release;
* `?app_id=X` is the **complete** query — it also sees pre-authentication
  refusals.

The qualification asserts both readings. Both are documented at the endpoint.

## Not covered, and deliberately

The identity/tenancy admin surface (org invitations, members, collaborators,
`POST /admin/users`) still writes the older detail-only rows through
`Repository.audit`: correlated by `request_id` now, but with `result IS NULL`
and no `http_status`. `GET /admin/audit` marks those `kind: "detail"`, so the
two classes are never confused. Extending `classifyMutation` to that surface is
the obvious next increment; this lane's scope was the patch lifecycle.

## Provenance

| thing | value |
|---|---|
| repo revision at start | `dc0cec91f584172af022ef0e46d623015f54b0f7` |
| CLI exercised | `/Users/mendell/.shorebird/bin/shorebird` (the installed one, not the repo tree's) |
| fixture | `selfhost/fixtures/android_signing_app`, copied to a temp dir |
| migration | 11 |
| suite | 337 pass (`dart test -x integration`), 30 of them new |
| live run | 18 pass / 0 fail |
