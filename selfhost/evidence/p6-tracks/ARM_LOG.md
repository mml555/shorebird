# P6 · tracks — arm log

Running log against the frozen `PRECOMMIT.md`.

## Setup

Release **1.10.0+1** (server id **121**) cut with
`--target lib/main_tracks.dart`, flavor `foo`, `--export-method development`.
`Route B retention: 4 named SDK members, interface 2218 bytes`.

Two clients cut from that ONE build by `scripts/make_track_clients.sh`:

| | client A | client B |
|---|---|---|
| bundle id | `dev.selfhost.flavoredProbe.foo.tka` | `…foo.tkb` |
| display name | `Tracks A` | `Tracks B` |
| bundled `channel:` | `alpha` | `beta` |
| `app_id` | `1c99c679-…` | **same** |
| release version | `1.10.0+1` | **same** |
| AOT payload | `2bda0fb0971e` | **same, and equal to the source build** |

Installed with `ios-deploy --bundle` and no `-d`.

### The invariant had to be corrected, not dropped

The builder first asserted `App.framework/App` was byte-identical and **refused**:
re-signing rewrites the Mach-O code-signature blob, so the file hash changes
while no AOT byte does. Deleting the assertion would have removed the only thing
standing between "two clients, one release" and an accidentally rebuilt
snapshot, so it was narrowed to the AOT **payload** — hashed with the signature
stripped — and the script still reports that the signed files *do* differ, so the
narrowing is visible rather than silent.

That a re-signature cannot matter is measured: nothing on the device verifies the
base binary. `check_hash` (`vendor/updater/library/src/updater.rs:327`) hashes
the **downloaded patch** against the server's hash, and the `libapp.so` hashing
sketched in the comment at `:334` was never implemented. Route B's
release-artifact binding is a **publish-time producer** check.

## Vacuity guard satisfied before Phase 0

`api.dart:2008` returns an empty response for an **unknown** channel, so a
client on a channel that never existed receives nothing regardless of any
deployment. Both tracks were therefore created and asserted first:

    channels on 1c99c679-…: alpha, beta, stable
    ASSERTION OK: alpha and beta both exist, so withholding can only be a
    deployment decision

## Phase 0 — server state

    release 1.10.0+1 -> id 121
      (no patches yet)

Read from `deployments`, not the convenience `channel` field. Nothing is
deployed on any track, so at this point neither client can be withheld *for a
track reason* — which is exactly what makes Phase 0 a control and not evidence
about tracks.

## Two harness defects fixed on the way, both in the guard itself

1. the channels reader assumed `{channels:[…]}`; `api.dart:1711` returns a
   **bare** array. The assertion crashed before it could assert.
2. the deployments reader carried escaped quotes into a single-quoted `python3
   -c` block and would not parse.

Both are worth naming because they were failures *of the checking code*, and a
guard that throws before it asserts is indistinguishable from no guard.

## Phase 0 — device half: the two clients are proven independent, but transport is DOWN

### What is established (client-side, from the device's own syslog)

Captured with `idevicesyslog` — a passive read, no debugger attached, and every
launch by hand. Each client's native updater logs the request it builds:

| | client A (`tka`) | client B (`tkb`) | base app (control) |
|---|---|---|---|
| `channel` | **`alpha`** | **`beta`** | `stable` |
| `client_id` | `06ecaea8-0dd4-…` | `23d73a05-811e-…` | `c5f049c3-f4e8-…` |
| `release_version` | `1.10.0+1` | `1.10.0+1` | `1.9.0+1` |
| `platform`/`arch` | `ios`/`aarch64` | `ios`/`aarch64` | `ios`/`aarch64` |
| `current_patch_number` | `None` | `None` | `Some(1)` |
| `app_id` | `1c99c679-…` | **same** | same |

**This is the precommit's independence requirement, met and measured:** between
A and B the only differing fields are `client_id` and `channel`. It also proves
the packaging works — the post-build edit to the bundled `shorebird.yaml`
reached the *native updater*, not merely the Dart side that renders the screen.

### What is NOT established: no check ever reached the server

Zero `POST /api/v1/patches/check` from any client. Two distinct failure shapes:

    16:40:52.341  tka  Sending patch check request … channel: "alpha"
    (no result line at all — the call was still hanging when force-quit)

    16:41:04.980  tkb  Update failed: Patch check request failed due to network
                       error.                     (~95ms after start)

The **base app fails the same way**, and it has local-network permission and
successfully downloaded a patch 50 minutes earlier. So this is not about the
re-signed bundles and not about per-app permission.

One race is real and worth recording regardless:

    16:31:18.306  Sending patch check request … channel: "stable"
    16:31:18.306  Update failed: … network error            (0.3ms later)
    16:31:18.440  nehelper: Local network allowed by preference for Flavored Probe

The updater fires its check **pre-main**, while iOS resolves local-network
permission asynchronously. The first connection in a process can therefore lose
the race and the updater gives up for that launch. That is the mechanism behind
the tap → force-quit → tap-again ritual every device arm on this rig has needed.
But it does not explain a *hang*, and it does not explain the base app failing
after its grant was already on record.

### Phase 0 is therefore NOT a passed control

Both clients show `TRACK-V1` and neither has a patch — but neither asked
successfully, so "neither received a patch" is currently **unfalsifiable**.
Promoting to alpha now would produce an A-gets-it result indistinguishable from
luck, so **nothing has been promoted.** Phase 0 stands open.

### A packaging consequence found on the way

All three bundles share `LC_UUID BB02BCB5-82C5-3979-8222-9356C9611EF6`, because
they are copies of one build. iOS's network attribution keys on that UUID and
resolved `tka`'s identity to the **base** bundle id (`bundle_id: (null)` in the
blocked-connection notice, then "allowed by preference for Flavored Probe"). It
did not cause this failure, but it means **per-app local-network state cannot be
made to differ between A and B** while they share one Mach-O. If a future arm
needs A and B to hold different permissions, that shared UUID is where it breaks.

## Phase 0 — PASSED, after the UUID fix

### The blocker was my own packaging, and the fix was predicted before testing

All three bundles shared `LC_UUID BB02BCB5-…` because they are copies of one
build. iOS attributes local-network permission **by executable UUID**: with a
colliding set installed it logged `Got local network blocked notification: …
bundle_id: (null)` and refused the connection in ~0.2ms — no round trip. That hit
**every** app sharing the UUID, including the untouched base app, which had
downloaded a patch successfully an hour earlier and then began failing purely as
collateral damage of my copying.

Safari on the phone reaching `http://10.0.0.7:18080/` ("code push Ok") is what
separated "the phone cannot route to the server" from "these apps cannot", and
sent the diagnosis to the right place.

Fix: `scripts/set_macho_uuid.py` rewrites the 16-byte `LC_UUID` payload in each
copy's main executable — deterministically, from a hash of its bundle id — before
signing, so the signature covers the new bytes. Nothing else in the Mach-O
changes, and `make_track_clients.sh` still asserts the AOT payload is untouched.
The prediction was written down before the taps: with distinct UUIDs each app
gets its own grant and the checks land. Zero checks reached the server before;
four did after.

### The control, as required

Both clients on the reinstalled bundles performed a **real check** and received a
**real response**:

| client | pid | channel | `client_id` | server response |
|---|---|---|---|---|
| `tka` | 38282 | **`alpha`** | `42b44b12` | `PatchCheckResponse { patch_available: false, patch: None }` |
| `tkb` | 38270 | **`beta`** | `8ce6ece3` | `PatchCheckResponse { patch_available: false, patch: None }` |

Server side, four `POST /api/v1/patches/check -> 200`. Release state:
`(no patches yet)`, read from `deployments`.

So "neither client received a patch" is now **falsifiable**: both asked, both
were answered, and nothing was deployed. Phase 0 is a control rather than an
absence.

`client_id`s differ from the pre-fix values because the reinstall reset updater
state (`No existing state file found`) — expected, and it does not weaken the
arm: independence is a property of the two clients, not of particular UUIDs.

### A second real finding, kept

The updater fires its check **pre-main** while iOS resolves local-network
permission **asynchronously**, so the first request in a fresh process can lose
that race and the updater abandons the update for that launch. Every successful
check here came from a *second* launch. That is the mechanism behind the
tap → force-quit → tap-again ritual this rig has always needed, and it is worth
recording as a property of the updater rather than rig folklore.

## Phase 1 — patch staged

`trackState()` changed `TRACK-V1` → `TRACK-V2` in both ternary branches; the
control `kTracksRelease` is untouched. `git diff` is 2 lines.
