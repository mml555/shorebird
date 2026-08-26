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
