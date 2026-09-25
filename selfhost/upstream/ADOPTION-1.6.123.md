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
| 4 | `PATCH /api/v1/apps/{appId}` | `{"name": "<displayName>"}` | 2xx | absent |
| 5 | `POST /api/v1/organizations/{organizationId}/apps` | `{"app_id": "<appId>"}` | 2xx | absent |
| 6 | `DELETE /api/v1/apps/{appId}/channels/{channelId}` | — | 2xx | absent |

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

## Recommended order

1. ~~Endpoint #1 `rollback`~~ — done.
2. Endpoints #4/#5/#6 app and channel management — additive, no state-machine
   change. Define the authorization rule once, then apply it to all three.
3. ~~Decide §3~~ — ruled (c); rollforward refused with 501.
4. Skip #3 `GET /plan` and both `stripe_api` commits.
5. §2 CLI fixes behind a governed pin promotion.
