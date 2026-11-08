# P6 · manual updater API — precommit

Frozen before the release is cut. **One** release, **one** patch, **one** device
client. Host testing is excluded by prior investigation: without the native
updater `checkForUpdate()` returns `unavailable` and `update()` is a no-op, so a
desktop run is a false green.

## Fixture

`selfhost/fixtures/manual_api_app`, now with its own iOS project. Deliberately
**not** `flavored_app`: `auto_update: false` is app-wide in `shorebird.yaml`, and
setting it on the fixture four certified rows share would contaminate them.

`shorebird_code_push` resolves **by path** from `vendor/updater/`, so this tests
the pinned updater rather than a published package. Verified present in the
vendored API: `checkForUpdate({UpdateTrack? track})`,
`update({UpdateTrack? track})`, and custom track values.

**One client only.** The tracks arm established that copies of one build share
`LC_UUID`, that iOS attributes local-network permission by executable UUID, and
that a colliding set has connections refused in ~0.2ms. Nothing is cloned here,
so that failure mode is out of scope by construction.

### The fixture cannot leak the track

Four buttons, each passing its own track explicitly; **no** "last checked track"
state anywhere in `main.dart`. If the fixture remembered a track, it could supply
the exact leak Phase 3 is designed to detect.

`initState` is read-only — `readCurrentPatch`/`readNextPatch` inspect updater
state and nothing else. No check, no update, no startup orchestration.

## Deployment state

    release: MANUAL-V1, auto_update: false
    patch 1: MANUAL-V2
      beta   -> LIVE, rollout 100
      stable -> no deployment

Rollout 100 everywhere it is deployed; no progressive rollout in this arm.
Asserted from `deployments`, never the singular `channel` field — the tracks arm
showed that field reports only the newest live deployment and would have inverted
a multi-track reading.

## The sequence, and what each step proves

| # | action | required outcome | what it establishes |
|---|---|---|---|
| 0 | launch, relaunch, press **nothing** | `MANUAL-V1`, current `none`, next `none`, **no download** while patch 1 exists on beta | `auto_update: false` really holds. It is an ENGINE property with no Dart introspection, so it is proven **behaviourally** — by the absence of a download — not by asking the API |
| 1 | **Check stable** | server request `channel=stable`; status `upToDate`; no download; next stays `none` | the negative control: the API reports honestly on a track with nothing deployed |
| 1b | **Update stable** | no patch installed; `UpdateException` or documented no-update; next stays `none` | `update` on an empty track does nothing |
| 2 | **Check beta** | server request `channel=beta`; status `outdated`; **but** current `none`, next `none`, no artifact, still `MANUAL-V1` | `checkForUpdate` checks and does **not** secretly download |
| 3 | **Update stable**, immediately after step 2 | **must not** download beta's patch; next stays `none` | **load-bearing.** The updater now knows beta has patch 1. If `update(stable)` installs it, the call consumes cached eligibility instead of honouring its argument |
| 3b | **Update beta** | server sees beta; download occurs; future completes; next `1`; current still `none` | the key API transition — `update(track:)` stages, it does not activate |
| 4 | human force-quit + relaunch | `MANUAL-V2`, current `1` | the staged patch executes on the next launch |

Step 3 is not simplified away under any circumstances.

## Evidence required per step

The screen alone is insufficient — `readCurrentPatch` is exercised by every
airgap release, so a number appearing proves nothing about these two calls. Each
step is backed by:

* the **server log** for `POST /api/v1/patches/check`, and its absence where a
  download must not happen;
* the client's own updater log (`idevicesyslog`, passive, no debugger) showing
  the request built and the `channel` it carried;
* the `events` table (`__patch_download__`, `__patch_install__`) keyed by
  `client_id`;
* `deployments` for server-side state.

## What does NOT count

* Any step passing on the screen alone.
* A launch with a debugger attached. Install via `ios-deploy -b` with no `-d`;
  every launch a by-hand tap.
* A `patch_available` reading taken from a **first** launch of a fresh process.
  The tracks arm measured that the updater checks pre-main while iOS resolves
  local-network permission asynchronously, so a first request can lose that race
  and fail with an opaque network error. A failed check is a **harness** failure
  here, never evidence about the API.
* Any conflation with the automatic-track config defect. That defect
  (`shorebird.yaml`'s `channel:` key rejected by the CLI parser) stays logged in
  the tracks row. This lane proves **application code** can select a track; it
  does **not** fix automatic clients, and closing it is a separate decision.

## Failure handling

If step 3 downloads beta's patch, that is a **real product defect** in
`update(track:)` and the row is recorded `SUPPORTED BUT UNCERTIFIED` with the
evidence — not retried into a pass. If step 0 shows an automatic download,
`auto_update: false` is not honoured and the same applies.
