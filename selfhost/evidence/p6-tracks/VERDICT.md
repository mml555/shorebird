# P6 · tracks — CERTIFIED (server-side routing), with one product gap named

## The certified claim

> **Tracks CERTIFIED:** two independent clients on the same release requested
> different channels. With patch 1 deployed only to alpha, the alpha client
> received and executed it while the beta client was explicitly withheld.
> Promoting the unchanged patch to beta caused that same beta client to receive
> and execute it, establishing channel deployment as the causal variable.

App `flavoredprobe-p6`, release **1.10.0+1** (id 121), **one** patch,
rollout **100** everywhere, no progressive rollout anywhere in this arm.

## The three phases

| phase | server (`deployments`) | client A / `alpha` | client B / `beta` |
|---|---|---|---|
| 0 control | no patches | check → `patch_available: false`, `TRACK-V1` | check → `patch_available: false`, `TRACK-V1` |
| 1 isolation | alpha LIVE 100; **beta absent** | `true` (patch 1) → download+install → **`TRACK-V2`** | `false` ×2, **zero events**, `TRACK-V1` |
| 2 causal | alpha LIVE 100 **and** beta LIVE 100 | still `TRACK-V2` | `true` (patch 1) → download+install → **`TRACK-V2`** |

## Why the negative is causal rather than an absence

Phase 1's withholding is backed by more than a screen: B demonstrably **asked**
(its updater logged the request; the server answered 200), the request carried
**`channel: "beta"`**, the response was
`PatchCheckResponse { patch_available: false, patch: None }`, and the `events`
table held **no row of any type** for B's `client_id`.

Phase 2 is what makes it causal. The **same** `client_id` `8ce6ece3`, requesting
the **same** channel, for the **same** patch 1, on the same binary and server,
flipped from `false` to `true` across a change to **one deployment row** — no
rebuild, no reinstall:

| alternative explanation for Phase 1 | excluded because |
|---|---|
| transport | the same client reached the same server and downloaded |
| signing | the same signed bundle installed and ran the patch |
| stale release | `release_version 1.10.0+1` throughout |
| bad patch artifact | the same patch 1 artifact applied on B |
| broken updater | the same updater downloaded and installed |
| wrong app id | `app_id` unchanged, and it now matches |
| B incapable of updating | B just updated |

## Assertions made on `deployments`, and why that mattered here

Not a stylistic choice — it changed the answer. After Phase 2 the convenience
`channel` field reads **`'beta'` alone**, because it returns only the newest live
deployment. Asserting on it would have reported the patch as having **moved off
alpha**, inverting the multi-track claim. `deployments` showed
`alpha status=active rolled_back=False` and `beta status=active rolled_back=False`
simultaneously, and client A staying on `TRACK-V2` confirmed it on the device.
Promotion is additive, as `set_track_command.dart` documents.

## The product gap this arm cannot certify around

**There is no supported config path onto a non-stable track.** The native updater
reads `channel:` from the bundled `shorebird.yaml`
(`vendor/updater/library/src/yaml.rs:60`), but the CLI's generated parser has
`allowedKeys` of exactly `app_id`, `flavors`, `base_url`, `auto_update`,
`patch_verification` with `disallowUnrecognizedKeys: true`
(`shorebird_yaml.g.dart:16-23`). A user who writes `channel: beta` — the
documented way to select a track — gets an `UnrecognizedKeysException`.

So this row certifies **server-side routing and updater behaviour**. It does
**not** certify "a user configures a track the supported way", because that path
does not currently work. Recorded as a defect, not worked around silently.

## Deviations, stated rather than glossed

**The two clients are not byte-identical bundles.** A Route B patch binds to one
release artifact, and iOS will not install one bundle id twice, so both clients
were cut from ONE build (`scripts/make_track_clients.sh`) and differ in bundle
id, display name, bundled `channel:`, and executable UUID. Held fixed and
verified: `app_id`, `release_version`, platform, arch, supported patch kinds,
Phase-0 patch state, and the **AOT payload** (hash-compared with the code
signature stripped, and asserted equal to the source build).

**Renders captured:** B at `TRACK-V2` (`03_phase2_beta_v2.png`) and the two
installs (`02_two_installs_home.png`). B's Phase-1 `TRACK-V1` and A's readings
are from by-hand observation plus the updater logs and `events` table — two
attempted screenshots caught the home screen and an unrelated Safari page and
were renamed or deleted rather than filed under names they did not earn.

**No debugger anywhere.** Installed with `ios-deploy --bundle` and no `-d`/`-L`;
every launch a by-hand tap; diagnosis via `idevicesyslog`, a passive reader.

## Two findings worth keeping beyond this row

**1 · Copies of one build collide on `LC_UUID`, and iOS attributes local-network
permission by executable UUID.** With a colliding set installed, iOS logged
`Got local network blocked notification: … bundle_id: (null)` and refused
connections in ~0.2ms with no round trip — for **every** app sharing the UUID,
including the untouched base app that had patched successfully an hour earlier
and broke purely as collateral damage. Zero checks reached the server before
`scripts/set_macho_uuid.py` gave each bundle its own UUID; they landed
immediately afterwards. Safari reaching the server from the phone is what
separated "the phone cannot route" from "these apps cannot".

**2 · The updater checks pre-main while iOS resolves local-network permission
asynchronously.** The first request in a fresh process can therefore lose that
race, and the updater abandons the update for that launch. Every successful check
in this arm came from a **second** launch. This is the mechanism behind the
tap → force-quit → tap-again ritual every device arm on this rig has needed —
previously folklore, now a recorded property.
