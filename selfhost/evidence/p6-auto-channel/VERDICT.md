# Automatic non-stable track via config — CLOSED

> The `channel:` key in a project's `shorebird.yaml` is accepted by the CLI,
> reaches the shipped bundle, and is used by the **automatic** updater: a
> beta-only patch downloaded with no user action and executed on the next launch.
> There is now a supported configuration path onto a non-stable track.

`flavored_app`, app `1c99c679-…`, release **1.13.0+1** (id 126), one patch, one
client, `auto_update` absent so automatic updating is on.

    patch 1 -> beta LIVE rollout 100
    stable  -> ABSENT (no deployment row)

## The chain, each link evidenced

| link | evidence |
|---|---|
| source `shorebird.yaml` carries `channel: beta` | committed fixture config, not a post-build edit |
| the CLI accepts it | the release build completed; before the fix it threw `ParsedYamlException: Unrecognized keys: [channel]` |
| the shipped bundle carries it | `App.framework/flutter_assets/shorebird.yaml` in the **fetched release artifact**: `app_id`, `base_url`, `channel: beta` |
| the app makes no manual API call | `main_tracks.dart` imports no `shorebird_code_push` (0 occurrences) |
| the automatic updater sent it | client log: `channel=beta release=1.13.0+1` |
| the patch downloaded with no user action | `__patch_download__ 1` for client `c5f049c3`, from launches where nothing was pressed — the fixture has no buttons |
| the next launch executed it | `__patch_install__ 1`, `ROUTEB: applied 1/1 targets`, and on screen `channel: beta` / `release: TRACKS-REL-1` / **`track state: TRACK-V2`** |

Render: `01_auto_beta_v2.png`.

## The control

`channel` omitted → the automatic request uses `stable`. Already measured for
this same fixture in the tracks arm: with no `channel` key its updater sent
`channel: "stable"` for release `1.9.0+1`
(`evidence/p6-tracks/updater_syslog_excerpt.txt`). Cited, not re-run — a second
release proving the documented default would add nothing, and saying so is better
than implying a fresh measurement.

## The fix spanned TWO repos, and the first half alone was worse than nothing

**`shorebird_cli`** — `ShorebirdYaml` gained `channel`, and the generated parser's
`allowedKeys` with it. Named `channel` rather than `track` because the updater,
protocol and server all speak `channel`.

**`flutter_tools`** (the pinned Flutter fork) — `compileShorebirdYaml` rebuilds
the bundled `shorebird.yaml` on every build: flavor-resolved `app_id`, then
`copyIfSet` for `base_url`, `auto_update`, `patch_verification` only. `channel`
was dropped. So after the CLI fix alone the key was **accepted and silently
inert** — strictly worse than the original rejection, which at least told the
user. Captured as `selfhost/flutter/0001-shorebird-yaml-carry-channel.patch`.

**Found only by inspecting the shipped artifact.** The release completed cleanly
with `channel: beta` in the source, and nothing in the CLI output hinted the key
had been dropped. Release 1.11.0+1 was published in that state.

## Two releases burned, and what each bought

| release | outcome |
|---|---|
| 1.11.0+1 | CLI accepted the key; **shipped bundle lacked it** — exposed the `flutter_tools` half |
| 1.12.0+1 | `flutter_tools` patched, bundle **still** lacked it — exposed that `flutter_tools` runs from a snapshot keyed on SDK revision, not source content, so source edits are inert until `flutter_tools.snapshot`/`.stamp` are deleted |
| 1.13.0+1 | the certified run |

Both are left published as the record. The snapshot-invalidation step is now a
required line in `selfhost/flutter/README.md`, because a future reader applying
that patch would otherwise repeat 1.12.0+1 exactly.

## A defect fixed on the way: `init` was discarding config

Proving `channel` survives the CLI's own rewrite paths turned up
`_addShorebirdYamlToProject` rebuilding `shorebird.yaml` from a hardcoded
template. `init` adding newly detected flavors to an **existing** project
therefore discarded every key the template omits — `base_url`, a real
`auto_update`, and `channel`. **For a self-hosted app, adding a flavor repointed
it at the default control plane.** It now edits the user's own text in place with
`YamlEditor`, preserving comments and formatting, and returns the model parsed
from what was actually written. Pinned by a test and mutation-checked.

## Scope

This closes the **configuration** seam only. Track routing itself was already
certified (`evidence/p6-tracks/VERDICT.md`) and was **not** re-run. Progressive
rollout stays out of scope and untouched.

---

# Re-demonstrated from the owned pin, on a coherent toolchain

The original certification above ran on release 1.13.0+1, built from a checkout
carrying a **local** `flutter_tools` edit. This section closes the remaining
arrow: the same behaviour from a Flutter revision we own, bootstrapped from our
own bytes, with no local patch anywhere.

## The chain, end to end

    owned Flutter commit  a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61
      on refs/heads/selfhost/3.44.8 in the durable mirror (verified by ls-remote)
        -> clean bootstrap: SHOREBIRD_FLUTTER_GIT_URL=file://…/mirrors/flutter.git
           FLUTTER_STORAGE_BASE_URL=http://localhost:8085
           no git apply, no manual source copy, no stale flutter_tools snapshot
        -> coherent cell activation (engine + host dart-sdk + both tool snapshots)
           verify_toolchain_coherence.sh: 0 failures
        -> two consecutive clean releases 1.16.0+1 and 1.17.0+1
           no cache surgery between them, both shipping channel: beta
        -> patch 1 published to BETA ONLY (stable: ABSENT)
        -> device, no buttons pressed, by-hand taps only:

    00:53:21  automatic check   channel=beta   release_version=1.17.0+1
              __patch_download__ 1
              __patch_install__  1
    00:53:40  Shorebird updater: active patch is a Route B container
              ROUTEB: applied 1/1 targets, entering main

    rendered:  channel: beta / release: TRACKS-REL-1 / track state: TRACK-V2

Render: `02_coherent_pin_auto_beta.png`. Release artifact fetched from the control
plane, not the local build. Installed with `ios-deploy --bundle` and no `-d`/`-L`;
every launch a by-hand tap; observation via passive `idevicescreenshot` and
`idevicesyslog`.

## What this closes

**Pinned-toolchain reproducibility is no longer a claim about a workstation.** The
`channel:` support the automatic updater depends on lives in a commit on a ref we
own and mirror, and a checkout created from those bytes alone produces a release
that a device patches on the non-stable track it was configured for.

The `selfhost/flutter/0001-…patch` file is provenance only; the supported revision
contains it.
