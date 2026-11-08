# Epoch B canary — evidence packet. Allow-list NOT yet changed.

Discharges steps 1–6 of the precommitted activation checklist in
`MEASUREMENT_MODE.md`. **Step 7 (adding `af6e842ccf87` to
`PolicyEpoch.b.updaterRevisions`) is deliberately NOT done here** — it is a
separate, isolated commit after review.

## Step 1 · freeze, verified before touching anything

    repo            46a547ec4d4711560e3589869bad5e0e8c9c0aac, local == fork/experimental
    working tree    clean
    PolicyEpoch.b   updaterRevisions = {}
    live Epoch A    1.8.0+1 patch 1 — first_ambiguity=1 recovered=1
                    (reproduces the documented integration proof exactly)
    live Epoch B    metrics = []
    af6e842ccf87 lifecycle rows anywhere: 0

## Step 2 · the real specimen, on the certified cell

`killswitch-g15` (`014c8ed9-2dea-ec30-fe74-3a7f5e7a77e3`) — the app
`MEASUREMENT_MODE` names as the specimen, **not** `sign_probe_app`.

    release      1.9.0+1, server id 134
    cell         4792f0eca461f3761001a1adbe131b4b115e3684
    recipe       development export, API-key SHOREBIRD_TOKEN,
                 SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR at the active cell
    runtime      NO changes to updater, engine, lifecycle semantics or cell

## Steps 3–4 · proven from the PUBLISHED bytes, not the build log

Fetched back from the control plane, `HTTP 200`, 11,071,989 bytes:

    published xcarchive   5259f4728951bb9406930dc85085c98d2cbc3cf25d21f799b0fa51ea10c72f5e
    shipped engine        e3549948c53e72a26f3450179fe89f6728ead4835beb3b8bf13543b6a129f8ee

    af6e842ccf87          PRESENT
    f729f958e9be          absent
    fe51f225c686          absent
    "Preparing next boot" / "Next boot candidate rejected" / "Prepared boot of"  all present

    bundled app_id        014c8ed9-2dea-ec30-fe74-3a7f5e7a77e3
    CFBundleShortVersionString 1.9.0   CFBundleVersion 1

Byte-based deliberately: this project has already measured stamps lying about
which engine a cache holds.

## Step 5 · one controlled non-rig client

Installed the **fetched** `.app`, not the local build. Uninstalled first, so the
updater minted fresh state — `[shorebird] No existing state file found`.

    canary client   e0af82b8-0b05-4e22-a1cd-e10f98870584

All 19 prior `killswitch-g15` client ids were recorded BEFORE the install, and the
canary id is absent from that set. Demonstrated, not assumed from "we
reinstalled". The Epoch A eligible client is `283a0e4b-…`, which is in that prior
set and is not this one.

## Step 6 · real events, carrying the revision, persisted

    id=193  __patch_download__  rel=1.9.0+1  patch=1  rev=af6e842ccf87  ios/aarch64
    id=194  __patch_install__   rel=1.9.0+1  patch=1  rev=af6e842ccf87  ios/aarch64

Read back out of the database, so this is *stored*, not merely a 2xx response.
`queued_events: []` on device confirms both were sent rather than pending.

**No ambiguity was manufactured**, and the reason was verified in source rather
than assumed: `updater_revision` sits on the `PatchEvent` envelope and is sent on
**every** event type — its own doc comment says so, precisely so eligibility is not
inferred from a release-name proxy. Only the five boot-lifecycle fields are
outcome-gated.

## Renders

| process | render | how |
|---|---|---|
| acquisition | `G15 arm 2 / boot: boot-ok / route B value: OLD-kill` | operator-observed |
| execution (pid 49614) | `route B value: EPOCH-B-CANARY`, `launch hlqx8ykqhk` | **screenshot**, `launch_b_render_EPOCH-B-CANARY.png` |

Launch B syslog:

    Preparing next boot.
    No public key configured; skipping signature verification
    Prepared boot of patch 1.
    ROUTEB: activated routeBValue in package:killswitch_probe/main.dart before main
    ROUTEB: applied 1/1 targets, entering main
    Reporting successful launch.
    Launch success for patch 1: prior_ambiguous_attempts=0

Final device state: `next_boot_patch=1 last_booted_patch=1
currently_booting_patch=null boot_attempt_count=0`, patch 1 `Installed`.

## Rig exclusion is structural, not a memorised ID list

`af6e842ccf87` rows already existed before this canary — 3 of them, all from
`signprobe-p6` (`525b41fe…`, client `cd760912…`). They prove the wire mechanism
but not the specimen requirement, which is why this lane exists.

They cannot contaminate the estimator, and not because anyone remembers their
client id: every one has `outcome IS NULL`, and `bootLifecycleMetrics` filters
`outcome IS NOT NULL`. The same is true of both canary rows above.

    transport proof     download/install events carry updater_revision
    lifecycle estimator requires outcome IS NOT NULL
    => transport rows can never enter the ambiguity/recovery population

## Two rig conditions encountered, neither an Epoch B finding

**Local-network permission.** The first acquisition attempt failed with
`Update failed: Patch check request failed due to network error` **9 ms** after the
request — a refusal, not a timeout — on a freshly installed bundle with no grant
yet. The retry succeeded. Nothing certified was involved; the host reached the
control plane throughout.

**A stalled syslog capture, self-inflicted.** Cleaning up what looked like
duplicate `idevicesyslog` readers killed the live one, so the successful
acquisition launch was not recorded in syslog at all. It was recovered from device
state and server rows, which are the authoritative sources anyway. Recorded
because **a stalled capture looks exactly like "nothing happened"** — the same
trap as reading a dropped log line as a mechanism failure.

## Scope note

`killswitch_app` has no `patch_public_key`, so Launch B logged
*No public key configured; skipping signature verification*. This canary proves
the **telemetry path**, not signature verification. Signing is certified
separately, on its own fixture, in `p6-signing/`.

## Canary setup changes, banked here and NOT in the activation commit

    selfhost/fixtures/killswitch_app/pubspec.yaml   1.8.0+1 -> 1.9.0+1
    selfhost/fixtures/killswitch_app/lib/main.dart  OLD-kill -> EPOCH-B-CANARY
