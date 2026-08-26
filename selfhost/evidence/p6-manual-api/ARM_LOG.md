# P6 · manual updater API — arm log

Running log against the frozen `PRECOMMIT.md`.

## Setup

New app **`manualapi-p6`** (`393fb814-0c96-dfd2-fb57-871d8f147005`) on `cps-ios`,
its own iOS bundle `dev.selfhost.manualApiApp`, one device client, nothing cloned.

Release **3.1.0+1** (id 123). Verified in the shipped artifact, not the source:

    bundled shorebird.yaml -> app_id 393fb814…, base_url http://10.0.0.7:18080,
                              auto_update: false
    AOT -> MANUAL-V1 x2, MANUAL-V2 x0, markerText retained in the interface
    Info.plist -> NSAllowsLocalNetworking + NSLocalNetworkUsageDescription

Patch 1 (`MANUAL-V2`, arm64, 1.03 KB) published `--track=beta`:

    patch 1  status=ready
      beta   status=active  rolled_back=False  rollout=100  -> LIVE
      stable ABSENT (no deployment row at all)

Both channels were created **first**, because an unknown channel also returns an
empty patch-check response — without `stable` existing, step 1's `upToDate` would
have been unfalsifiable. Channels are per-app and this app was new.

### Two setup traps, both of which would have produced a false pass

**1 · `auto_update` was silently not set.** The generated `shorebird.yaml` ships
`# auto_update: false` as a **comment**, and a substring check matched it, so the
real key was never written. The fixture would have run with `auto_update`
defaulting to **true** and Phase 0 would have been meaningless. Fixed by
uncommenting the template's own line — not appending a second key, which would
leave last-wins deciding the hinge — and asserted through the updater's real
parsing rules, plus a check that exactly one uncommented line exists.

**2 · The local archive was the PATCH build.** `shorebird patch` overwrites
`build/ios/archive`, so after publishing it contained `MANUAL-V2` and zero
`MANUAL-V1`. Installing it would have put patched code straight on the device
while every reading looked perfect. Nothing downstream would have caught it: the
engine compares the container's `built-for` against the **running** release, so
even a locally rebuilt V1 would satisfy that. The release was therefore **fetched
from the server** (`tracks_admin.sh fetch-release-app`) — the only copy that is
definitionally the release — and its markers checked before install.

Installed with `ios-deploy --bundle` and no `-d`/`-L`.

## Phase 0 — manual really means manual: PASSED

Two by-hand launches, force-quit between, **no button pressed**.

| observable | reading |
|---|---|
| marker | `MANUAL-V1` |
| current patch | `none` |
| next patch | `none` |
| last check status | `idle — nothing pressed` |
| server `patches/check` | **0** |
| `events` for `3.1.0+1` | **0** |

Render: `phase0.png`.

Patch 1 was live on beta throughout, and this client is eligible for it — so the
absence is not "there was nothing to fetch". Nothing was requested and nothing
was downloaded because no code asked. `auto_update: false` is an **engine**
property with no Dart introspection, so this behavioural absence is the only
available proof, which is why the arm is built around it.

### What Phase 0 does NOT yet establish, and how it gets closed

At this point the transport has **not** been shown to work for this app: a
client that cannot reach the control plane would produce the same zero. So Phase
0 is provisional until a later step produces a **real request reaching the
server**, which retroactively establishes that this client *could* have asked and
did not.

Recorded now, before that step runs, so the caveat is not invented afterwards.

## Phase 0 is no longer provisional

`check(stable)` put a real request on the server (200), so this client
demonstrably **can** reach the control plane. Phase 0's zero requests was
therefore a genuine abstention, not an unreachable client. The caveat recorded
above is closed by measurement rather than removed.

## Phase 1 — negative track: PASSED

| press | client sent | screen | events |
|---|---|---|---|
| `Check stable` | `channel: "stable"`, `release_version: "3.1.0+1"` | — (status overwritten before capture) | 0 |
| `Update stable` | — | `update(stable) returned normally`, current `none`, next `none` | **0** |

`update` on a track with no deployment returns normally and installs nothing —
the documented no-update behaviour rather than an exception. The substantive part
is that `next patch` stayed `none` and **no event row appeared**.

Render: `phase1_update_stable.png`.

## Phase 2 — check is not update: PASSED

    check(beta) -> UpdateStatus.outdated
    current patch: none    next patch: none    marker: MANUAL-V1
    events: 0              /download/ requests: none

The client's own log shows the request carried `channel: "beta"`. So
`checkForUpdate` reports availability **without** downloading: the status flipped
to `outdated` while nothing was fetched and nothing staged.

Render: `phase2_check_beta.png`.

## Phase 3 — the load-bearing negative: PASSED

`Update stable`, pressed immediately after `check(beta)` reported `outdated`.

    19:23:53  client sent channel=beta     <- check(beta) -> outdated
    19:28:29  client sent channel=stable   <- update(stable)

    update(stable) returned normally
    current patch: none    next patch: none    marker: MANUAL-V1
    events: 0              /download/ requests: none

**Stronger than the precommit required.** It asked only that `update(stable)` must
not download beta's patch. The client log shows *why* it did not: the call issued
its request on **`channel=stable`**, its own argument. It is not that the
download was declined downstream — the eligibility question was asked about the
right track in the first place. `update(track:)` does not consume the cached
eligibility of a preceding `checkForUpdate` on a different track.

Render: `phase3_update_stable_after_check_beta.png`.

### One reading not captured, stated rather than implied

`check(stable)`'s status string was overwritten by the next press before a
screenshot was taken, so `UpdateStatus.upToDate` is **not** on record from the
render. What is on record: the client sent `channel=stable`, the server answered
200, `stable` has no deployment row, and no download followed. Re-pressing
`Check stable` was deliberately **not** done at that point, because it would have
made the updater's most recent check `stable` and weakened Phase 3's premise —
which was worth more than the screenshot.
