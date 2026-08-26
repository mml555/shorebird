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
