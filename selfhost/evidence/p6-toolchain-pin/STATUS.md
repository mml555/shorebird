# Flutter fork / pin reproducibility — status

## Done and proven

### 1 · The change is a real commit on a ref we own

Upstream `c15ef6379403a0a55531a058bdb2c8e55bc05c98` plus **one** change —
`compileShorebirdYaml` copying `channel:` into the compiled bundle — committed as

    a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61
    refs/heads/selfhost/3.44.8        (durable mirror)

Both pins updated: `bin/internal/flutter.version` and
`selfhost/compatibility.yaml → shorebird.flutter_revision`.

### 2 · `engine_revision` measured, not inferred

`bin/internal/engine.version` at the new commit is **unchanged**: still
`69f9831c360d9152862ec3897c67fb09ae843f3b`. So `engine_revision` stands.

Separately worth recording: the *worktree's* `engine.version` is overwritten to
the active cell (`ca7d2c0d…`). That is the documented cell-activation step
(`overlay_publish.sh:260`, and `accept_android_default.sh` does it
programmatically) — a different mechanism from the patch, and deliberately NOT
baked into the Flutter commit, because that would force a new Flutter commit per
cell.

### 3 · The mirror-prune hazard was real, and the fix is verified by experiment

`remote.origin.fetch` was `+refs/*:refs/*` with `mirror = true`, so the
documented `fetch --prune origin` mapped all upstream refs over ours. Tested
against a stand-in upstream that lacked the ref:

| refspec | outcome |
|---|---|
| `+refs/*:refs/*` only | `refs/heads/selfhost/3.44.8` **DELETED** |
| `+ ^refs/heads/selfhost/*` | **SURVIVED** |

`remote.origin.mirror` is also unset, so `push origin --mirror` can no longer try
to delete upstream refs. `cdn/README.md`'s refresh procedure now ends in a
`rev-parse --verify` that fails loudly if the ref goes missing.

### 4 · Clean bootstrap from owned bytes — the load-bearing acceptance check

    SHOREBIRD_FLUTTER_GIT_URL=file://…/selfhost/cdn/mirrors/flutter.git
    FLUTTER_STORAGE_BASE_URL=http://localhost:8085

A fresh checkout appeared at `a4a3c0d1b1b0…` with **no `git apply`, no manual
source copy, and no stale `flutter_tools` snapshot** — the snapshot was built by
that bootstrap, and `copyIfSet('channel')` is present in the checkout's **own**
source, from the commit. Its only worktree modification is `engine.version` (the
cell activation).

A release cut with that toolchain from a source `shorebird.yaml` carrying
`channel: beta` produced a shipped bundle containing:

    app_id: 1c99c679-8650-ba82-3899-681349a59416
    base_url: http://10.0.0.7:18080
    channel: beta

**That is the criterion this lane was set: owned commit → clean bootstrap →
shipped config.** The local-workstation dependency is gone.

### 5 · A version-resolution regression, found and fixed

The first bootstrapped release recorded `Flutter Version: unknown (a4a3c0d1b1)`.
Cause measured, not guessed: `getVersionForRevision`
(`shorebird_flutter.dart:222`) resolves a revision by finding
`refs/remotes/origin/flutter_release/*` branches that **contain** it. Upstream
`c15ef637` is contained in `flutter_release/3.44.8`; a child commit on a new
branch is contained in none, so the version was null → `unknown`. Left alone it
would have polluted every future release record and made `getVersion()` return
null for any Flutter-version gate.

Fixed in the CLI's own idiom: `refs/heads/flutter_release/3.44.8+selfhost.1` at
the new commit. Builds now report `Flutter 3.44.8+selfhost.1 (a4a3c0d1b1)`.
`+selfhost.1` is build metadata rather than a `-prerelease`, so it has the **same
semver precedence** as `3.44.8` and mirrors the CLI's own `1.6.115+selfhost.1`.
Protected by an exact negative refspec, since the resolver requires the branch to
live under `flutter_release/`, which upstream also populates.

### 6 · The standalone patch is now provenance only

`selfhost/flutter/README.md` carries an explicit do-not-apply notice: the
supported revision already contains it.

## NOT done — the automatic-update device smoke from the new toolchain

Blocked, and honestly two separate things:

**a · Release 1.14.0+1 is not Route B patchable.** The producer refused a patch
against it: *"This release was not built with Route B patchable call sites (8
sites, 4/MiB)."* It was cut immediately after I set `engine.version` to the cell
but before that checkout had the cell's artifacts, so it was built with stock
`gen_snapshot`. The guard caught it — a patch would have installed and changed
nothing. The checkout is correct **now** (`engine.stamp = ca7d2c0d`, its
`ios-release/gen_snapshot_arm64` carries `patchable_static_calls`).

**b · An Xcode build-graph error reproduces with the new checkout.**

    Error (Xcode): Request to create artificial node for object with cid 2232

Three attempts (1.15.0+1 twice, 1.16.0+1 once). Ruled out: stale DerivedData
(removed), stale `build/`/`.dart_tool` (removed), stale `Generated.xcconfig`
(regenerated, and it correctly points at the new checkout), and CocoaPods (this
fixture has no Podfile). One attempt did archive successfully and then failed at
IPA export, so it is not purely deterministic. Not diagnosed further.

**What this does and does not put at risk.** The certified automatic-channel
runtime behaviour stands on release 1.13.0+1 and is not affected. What is missing
is only the re-demonstration from the newly pinned toolchain. Until that runs,
the pin is proven reproducible for *building and shipping the config* but not yet
for *a device round trip*.

## Releases used, and why several exist

| release | built with | outcome |
|---|---|---|
| 1.11.0+1 | old checkout, CLI fix only | bundle lacked `channel` → exposed the `flutter_tools` half |
| 1.12.0+1 | old checkout, source patched | bundle still lacked it → exposed the stale-snapshot requirement |
| 1.13.0+1 | old checkout, patched + snapshot rebuilt | **the certified automatic-channel run** |
| 1.14.0+1 | clean bootstrap | shipped `channel: beta` ✓, but **not** Route B patchable |
| 1.15/1.16 | clean bootstrap | Xcode PIF error, not published |
