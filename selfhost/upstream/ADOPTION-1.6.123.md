# Upstream adoption survey — 1.6.115 → 1.6.123

Surveyed 2026-09-25. Our pin: `1.6.115+selfhost.1`. Upstream `origin/main`:
`bf9698c0d`, release 1.6.123. **42 commits** since our merge-base
`81b6c2550` (2026-07-28), spanning 4 releases (1.6.116 → 1.6.123).

No code changed by this survey.

## Summary

Most of the 42 are Flutter pins and release prep. Three CLI features call
**six server endpoints we do not implement**, and one of them needs a change
to our state machine that we deliberately closed. Nine fixes are CLI-only and
carry no server surface.

---

## 1. Server-facing — needs endpoints

Exact contracts, read from upstream `code_push_client.dart`.

| # | Endpoint | Request | Response | Our server |
|---|---|---|---|---|
| 1 | `POST /api/v1/apps/{appId}/releases/{releaseId}/patches/{patchId}/rollback` | empty body | 200 = changed, **304 = already rolled back** | **implemented** — rolls back on every active channel; see below |
| 2 | `POST .../patches/{patchId}/rollforward` | empty body | 200 = changed, 304 = already active | **intentionally unsupported** — 501, see §3 |
| 3 | `GET /api/v1/plan` | — | `{"level": "free"\|"pro"\|"business"\|"enterprise"}`, nullable | absent |
| 4 | `PATCH /api/v1/apps/{appId}` | `{"name": "<displayName>"}` | 2xx | **implemented**, §5 |
| 5 | `POST /api/v1/organizations/{organizationId}/apps` | `{"app_id": "<appId>"}` | 2xx | **implemented** — this is a **transfer** of an existing app, see §5 |
| 6 | `DELETE /api/v1/apps/{appId}/channels/{channelId}` | — | 2xx | **implemented** (soft delete), §5 |

### The good news on rollback

Our server **already carries the entire rollback data model**. This is not a
schema gap:

```
repository.dart:1574  rolledBackPatchNumbers(channelId, releaseId)
api.dart:2293         'rolled_back_patch_numbers': rolledBack     <- patch-check already emits it
api.dart:1893         'is_rolled_back': await repo.patchRolledBack(p.id)
repository.dart:1558  withdraw(channelId, patchId, {required bool rollback})
```

Upstream's documented device behaviour — *"devices on the affected
release_version that next call the patch-check endpoint will receive the patch
number in `rolled_back_patch_numbers`"* — is **already what our server does**.

So endpoint #1 is close to a route alias over `repo.withdraw(..., rollback:
true)`, plus 304-on-idempotent-repeat, which our admin route does not
currently express (it throws `conflict` instead).

Today we expose the same capability at a different shape:

```
POST /admin/apps/{appId}/patches/{patchId}/withdraw?channel=&rollback=true
```

Note it is channel-scoped by query parameter, where upstream is
release-scoped by path. Any alias has to decide how `releaseId` maps onto our
`channel` — our `channel_patches` row is keyed `(channel_id, patch_id)`.

---

## 2. CLI-only — adoptable with no server work

Nine, in rough descending usefulness:

```
3408dbfed  report when a patch is missing libapp.so        (#3826)
c74e18a8d  name the next step in iOS patcher errors        (#3926)
19fb22ed6  signing-flag mistakes are usage errors          (#3923)
c5ef7a41e  ignore asset catalog toolchain versions in diff (#3915)
008cc5a33  stop reporting layered icons as changed assets  (#3899)
6ff87e57e  point users at plugins using legacy flutter.jar (#3820)
1ef0831dd  precache and resume the requested Flutter install (#3901)
b3adb1487  keep a pubspec comment with its key on init     (#3911)
dea22a522  --flutter-version=fvm and =system               (#3932)
1685d78b5  measure download time in build traces           (#3872)
```

`1685d78b5` touches the same build-trace code as our merged PR #3868.

## Not wanted

`b6f1120cb` and `98adec243` are upstream's Stripe billing (`stripe_api`
subscription list/create/cancel, `cancel_at`). Upstream SaaS concerns; they do
not belong in a self-hosted control plane. `GET /api/v1/plan` (#3) is the same
category — it exists to display a billing tier.

---

## 3. The one real blocker — `rollforward` needs a transition we closed

Upstream's contract: *"flips `is_rolled_back` from `true` to `false` on the
same patch row, so the same patch artifact (same hash) becomes active again."*

Our state machine forbids that by design:

```dart
// domain.dart:161
const _channelPatchNext = {
  ChannelPatchStatus.active: {ChannelPatchStatus.withdrawn},
  ChannelPatchStatus.withdrawn: <ChannelPatchStatus>{},   // TERMINAL
};
```

`withdrawn` is terminal, and `requireChannelPatchTransition` enforces it. There
are also two model differences underneath:

1. **We couple rollback to withdrawal.** One `UPDATE` sets
   `status = withdrawn` **and** `rolled_back = @rb` together, guarded by
   `WHERE status = active`. Upstream treats `is_rolled_back` as an
   independently toggleable flag on an otherwise-live row.
2. **We are channel-scoped, upstream is release-scoped.**

So `rollforward` is not an endpoint we can add over the existing model. It
requires one of:

* **(a)** open `withdrawn -> active` in `_channelPatchNext`, and add a repo
  method setting `status = active, rolled_back = false`; or
* **(b)** decouple `rolled_back` from `status` so a rolled-back patch stays
  `active` with the flag set, matching upstream's shape more closely; or
* **(c)** decline `rollforward` and keep withdrawal terminal.

**This was a product decision about the control plane's safety model, not an
upstream-sync call.** Making a deliberately terminal state non-terminal is
exactly the kind of change that should not arrive as a side effect of an
upstream sync. (a) is smallest; (b) is closest to upstream and the largest
change; (c) costs nothing and leaves `shorebird patches rollforward` failing
against a self-hosted server.

### Ruling (PM, 2026-09-25): (c)

> Self-hosted rollforward: intentionally unsupported. Withdrawn patches remain
> terminal. `shorebird patches rollforward` must fail clearly against the
> self-hosted server.

Both (a) and (b) change the state-machine contract only to match a newly
exposed upstream CLI capability, and there is no product requirement that
justifies reopening that invariant. Upstream semantics are not partially
emulated. The route exists only to refuse: `501 unsupported`, with a message
saying to publish a new patch instead, and it mutates nothing, so it writes no
audit event.

### Rollback as implemented

`POST /api/v1/apps/{app}/releases/{release}/patches/{patch}/rollback` is
`repo.withdraw(rollback: true)` applied to **every channel where the patch
is active**, because upstream's route names no channel. It runs as one
`UPDATE … RETURNING`, so of two concurrent callers only one can claim the
change.

| Patch state | Response |
|---|---|
| active on ≥1 channel | 200, body lists the channels it rolled back |
| already rolled back, active nowhere | 304 |
| never promoted, or only superseded (withdrawn, not rolled back) | 409 |
| not on the release in the path, or on another app | 404 |

Auditing uses the same `patch.withdraw` operation as the `/admin` route, with
`detail.changed` telling a 304 apart from a real change.

**Known limitation:** after patch 2 is promoted over patch 1, patch 1 is
withdrawn but *not* rolled back, and `shorebird patches rollback
--patch-number 1` returns 409. That is the existing `/admin` behaviour too:
marking a withdrawn row as rolled back would change a terminal row, which
this pass does not do.

---

## 4. Pin promotion is governed separately

`selfhost/compatibility.yaml` records `cli_version: 1.6.115+selfhost.1` and
states a revision is unsupported until the compatibility suite passes **and**
the artifact service carries the bootstrap closure for the engine that pin
resolves to, proved on a sealed cold builder — governed by
`selfhost/TOOLCHAIN_PROMOTION.md`.

So 1.6.115 → 1.6.123 is a **governed promotion, not a merge**, independent of
the endpoint work above. The endpoint work can proceed without it; adopting
the CLI-only fixes in §2 cannot.

## 5. Authorization rule for app and channel management

### Correction: #5 transfers an app, it does not create one

Upstream's client calls it `transferApp`. It backs `shorebird apps transfer`,
and its docstring reads: *"Move the app with the provided [appId] into
[organizationId]. Requires permission to transfer apps in both the source and
destination organizations."* It changes which org **owns** an existing app,
and with it who can reach the app through org membership. Earlier drafts of
this survey called it "create app under organization". App creation already
exists as `POST /api/v1/apps` with `organization_id`.

### The rule

> A mutation that changes an app's identity, structure or ownership requires
> an **owner or admin role at every scope it changes**. A collaborator grant is
> scoped to one app, so it counts at app scope and never at org scope.

What each scope means, using the predicates the server already has:

| Scope | Predicate | Who passes |
|---|---|---|
| app | `userIsAppAdmin` (`_authorizeAppAdmin`) | owner/admin of the owning org, or an owner/admin collaborator on the app |
| org | `userIsOrgAdmin` | owner/admin member of that org |

Applied to the three endpoints:

| Endpoint | Scopes it changes | Requirement |
|---|---|---|
| #4 `PATCH /apps/{app}` rename | app | app admin |
| #6 `DELETE /apps/{app}/channels/{channel}` | app | app admin |
| #5 `POST /organizations/{org}/apps` transfer | source org **and** destination org | org admin of both; an app-admin collaborator is **not** enough |

Why this and not the existing `_authorizeApp`: that gate is app *access*,
which any org member or any `developer` collaborator passes, and it is what
lets them ship. These three are not shipping:

* a rename changes what every collaborator sees;
* a channel delete stops devices on that channel receiving patches;
* a transfer moves the app out from under the old org's members.

That is the same line `userIsAppAdmin` already draws for managing
collaborators.

Consequences of applying it consistently:

* **Asymmetry with channel create, on purpose.** `POST .../channels` stays at
  app access, because creating a channel changes nothing a device sees until a
  patch is promoted to it. Deleting one is destructive, so it is gated at
  admin.
* **Transfer is orgs-only.** An owner collaborator on an app cannot move it
  into their own org. Otherwise a collaborator grant could be turned into
  ownership.
* **Refusals are 403** with a message naming the role required, matching
  `_authorizeAppAdmin`. Ids that do not belong to the app in the path stay
  404 (`_ownedChannel`). Every refusal writes a `refused` audit event, like
  every other mutation.

### Rulings (PM, 2026-09-25) and what was built

1. **Transfer is built**, org admin of both orgs. It is **refused (409) while
   the app carries collaborators outside the destination's email-domain
   allowlist**, and the refusal names them. A transfer must not be a way around
   that policy. Transferring into the org that already owns the app is a 204
   no-op.
2. **Channel delete is a soft delete** (migration 13, `channels.deleted_at`).
   A hard delete fails on the `channel_patches` foreign key, and cascading
   would erase the rollback signal.
   * `channel_patches` rows are left untouched, so a rollback issued *after*
     the delete still marks the deleted channel and reaches its devices.
   * Patch-check on a deleted channel offers no patch but still returns
     `rolled_back_patch_numbers`.
   * A deleted channel is hidden from `GET .../channels`, cannot be promoted
     to or deleted again (404), and no longer counts as a patch's current
     track.
   * Creating the same name again **restores the same row**, because devices
     know a channel only by name. Whatever was active at deletion is withdrawn
     first (superseded, not rolled back), so a restored channel serves nothing
     until something is promoted to it.
   * `stable`, `beta` and `staging` are permanent and refused with 409, as
     upstream's CLI already does.
3. **Rename** takes upstream's `{"name": ...}` and sets `display_name`. It is
   app admin, and an empty name is a 400.

Audit: `app.update`, `app.transfer` (destination org, app id and
`from_org_id`/`to_org_id` noted) and `channel.delete`. Refusals record as
`refused` like every other mutation.

Verified by the unit suite and by a scratch run of the HTTP flow against a
throwaway Postgres 16 container (migration 13, `UPDATE … RETURNING`, soft
delete, restore, transfer).

---

## Recommended order

1. ~~Endpoint #1 `rollback`~~ — done.
2. ~~Endpoints #4/#5/#6 app and channel management~~ — done under the §5 rule.
3. ~~Decide §3~~ — ruled (c); rollforward refused with 501.
4. Skip #3 `GET /plan` and both `stripe_api` commits.
5. §2 CLI fixes behind a governed pin promotion.
