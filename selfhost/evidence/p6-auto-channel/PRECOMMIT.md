# Automatic non-stable track via config — acceptance precommit

Closes only the seam the tracks row left open. **Tracks routing itself is already
certified and is not re-run.**

## What is under test

    real source shorebird.yaml carrying `channel: beta`
      -> the CLI accepts it                      (the fix)
      -> a normal release build
      -> the SHIPPED shorebird.yaml carries channel: beta
      -> the AUTOMATIC updater starts (no manual API call anywhere)
      -> the server sees channel=beta
      -> a beta-only patch downloads automatically
      -> the next launch executes it

One client. No cloned bundles — the tracks clones were uninstalled first, so the
`LC_UUID` collision is out of scope by construction.

## Setup

`flavored_app`, existing app `1c99c679-…`, bundle `dev.selfhost.flavoredProbe.foo`,
entry `lib/main_tracks.dart`, release **1.11.0+1**. `channel: beta` added to the
**committed source** `shorebird.yaml` — not a post-build edit to the bundled copy,
which is what the tracks arm had to resort to and precisely what this fix removes.

`auto_update` is **absent**, so automatic updating is on. That is the difference
from the manual-API lane, which sets it false.

## Observables

`main_tracks.dart` renders three rows, and the `channel` row reads the **bundled**
`shorebird.yaml` — the same file the native updater consults:

| row | expected | role |
|---|---|---|
| `channel` | `beta` | proves the shipped config carries it |
| `release` | `TRACKS-REL-1` | control — must not change |
| `track state` | `TRACK-V1` → **`TRACK-V2`** | the target |

## Deployment

    patch 1 -> beta only, rollout 100
    stable  -> no deployment row

## What must be true, and how each is evidenced

1. **the CLI accepted the key** — the release build completes at all; before the
   fix it would throw `UnrecognizedKeysException`;
2. **the shipped bundle carries it** — read from
   `App.framework/flutter_assets/shorebird.yaml` in the fetched release artifact;
3. **the automatic updater sent it** — the client's own log shows
   `channel: "beta"` with **no** manual API call in the app (`main_tracks.dart`
   imports no `shorebird_code_push`);
4. **the patch downloaded without any button** — `__patch_download__` event and a
   `/download/` request, from a launch where nothing was pressed;
5. **the next launch executed it** — `TRACK-V2` on screen, `__patch_install__`.

## The control

`channel` omitted → the automatic request uses `stable`. **Already measured for
this exact fixture** in the tracks arm: with no `channel` key, the base app's
updater sent `channel: "stable"` for release `1.9.0+1`
(`evidence/p6-tracks/updater_syslog_excerpt.txt`). Cited rather than re-run,
because a second release proving the documented default would add nothing — and
saying so is better than implying a fresh measurement.

## What does NOT count

* A check that fails on a **first** launch of a fresh process. The tracks arm
  measured the pre-main vs local-network-permission race; a failed check is a
  harness failure, never evidence.
* Installing the locally built archive after publishing a patch. It is the
  **patch** build. The release is fetched from the control plane.
* Any manual `checkForUpdate`/`update` call — that is the other lane's proof.
