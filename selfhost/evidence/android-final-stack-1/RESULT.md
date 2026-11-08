<!-- cspell:words uiautomator screencap keyguard bidiff localsend Lockscreen PRODUCTIONIZATION -->

# ANDROID-FINAL-STACK-1 — the Android workflow works; the FROZEN CELL cannot serve it

2026-09-03. **STOP AND REPORT**, per step 7. No language feature, no cell
minted, no architecture change, nothing fixed.

## Verdict, in one line

**Every stage of the ordinary Android developer workflow — release, patch,
self-hosted discovery, download, physical activation with an unmistakable
patched result — was proven end to end. It could NOT be proven on the frozen
cell `cd848320`, which publishes no Android engine, and that is the only thing
that failed.**

## The A/B, which is the whole finding

Identical harness, identical app, identical control plane, identical command.
The **only** variable is which Flutter revision (and therefore which engine) the
release is built against.

| run | selector | engine | result |
|---|---|---|---|
| **frozen stack** | pinned `e64eb0af…` | **`cd848320…` (the frozen cell)** | **exit 70** — `Failed to precache Flutter null` |
| control | `--flutter-version=309dd657…` | `e1eaecbc…` (stock) | **exit 0** — release published |

The frozen run's underlying error, from the CLI's own log:

    flutter precache --android
      ├─ [1/6] android-arm-profile/darwin-x64
    Failed to download https://download.shorebird.dev/flutter_infra_release/
      flutter/cd848320d605ff8af5060cabf9a8d1b35853f752/android-arm-profile/darwin-x64.zip
    Exception: 404

**Why it cannot be worked around, measured rather than assumed:**

* The pinned Flutter `e64eb0af…`'s own `bin/internal/engine.version` **is**
  `cd848320…`, so precache asks for Android artifacts *at the cell address*.
* `selfhost/cdn/overlay/…/cd848320…/` contains **zero** Android artifacts
  (`find -iname '*android*'` → nothing). It holds `darwin-arm64`, `ios`,
  `ios-profile`, `ios-release` and the SDK/patched-sdk zips. It is a macOS/iOS
  cell.
* Through the local CDN the cell **is** mapped to the Android-serving fallback
  (`experimental_hashes.map:494` → `69f9831c…`), and the profile artifact then
  resolves — but the one that matters does not:

      android-arm-profile/darwin-x64.zip    -> 200 (5,339,294 B, from the fallback)
      android-arm64-release/darwin-x64.zip  -> 404
      android-arm64-release/linux-x64.zip   -> 404

  `android-arm64-release/` is in the CDN's `@must_be_local` matcher
  (`Caddyfile:163-165`), so a miss is a **deliberate loud 404** rather than a
  silent fall back to stock bytes. That protection is correct: taking a stock
  release-mode Android engine for a Route B cell would produce an app whose
  engine is not the one the cell qualified.
* And the local CDN is not in the path unless it is configured, which this run
  did not do.

  **CORRECTED 2026-09-03 (FLUTTER-STORAGE-AUTHORITY-1).** This bullet first
  said the CLI "forces `FLUTTER_STORAGE_BASE_URL` to `download.shorebird.dev`",
  citing `CDN_INDEPENDENCE.md`. That citation was **stale and the claim was
  wrong**: the fork made that variable overridable in `05fc58f5`, the original
  self-host commit, and pointing it at a probe origin demonstrably routes
  `flutter precache`'s request there. What was true is the narrower half —
  `SHOREBIRD_FLUTTER_STORAGE_BASE_URL` does not exist (and, on inspection,
  should not: a third alias for a working standard knob would be worse).

  It changes nothing about this lane's finding. Routing was never the Android
  blocker; the blocker is that **no Android release engine exists at the cell
  address to route TO**, which the `@must_be_local` 404 above establishes
  independently of any origin configuration. See
  [`../flutter-storage-authority-1/RESULT.md`](../flutter-storage-authority-1/RESULT.md).

So the frozen stack has no Android release engine, by construction, and the
refusal is the protection working.

## What WAS proven, end to end

On the control (stock engine `e1eaecbc…`), against a throwaway self-hosted
control plane reached from the device by `adb reverse`:

**1–2 · release and identity**

    release id 1   version 1.0.0+1   flutter 309dd6573a9f (3.44.7)
    platform_statuses: {"android": "active"}
    shorebird_version: 1.6.115+selfhost.1

| arch | bytes | sha256 (16) |
|---|--:|---|
| `arm` | 3,195,468 | `4d2ddaddb26cc7e1` |
| `aarch64` | 2,884,496 | `5b2f6af729dd57ad` |
| `x86_64` | 3,015,568 | `1cb2f10a9d97405d` |
| `aab` | 46,543,401 | `35832b427d96aa19` |
| `android_supplement` | 244 | `53b0d70be5bdf1a7` |

**3 · an ordinary code patch**, produced by the normal producer — a one-line
change to a marker function, no manual bytecode, no manifest editing, no
capability injection:

    patch id 1   number 1   status ready   channel stable
      arm      5,609 B  80126b38636b9396
      aarch64  5,601 B  cf7127ab32fef7b7
      x86_64   5,606 B  06cf6628b7e22e05

Kilobyte-scale artifacts against megabyte-scale release snapshots — the Android
**bidiff** path, which needs no AOT linker and no Route B.

**4 · self-hosted discovery and download**, from the device's own requests:

    POST /api/v1/patches/check            200
    GET  /download/67620a3960e76e04…      200      <- the aarch64 patch artifact
    POST /api/v1/patches/events           204

**5 · physical activation on a real Android runtime.** Device `3f72a543`,
OnePlus **CPH2551, Android 16 (SDK 36), arm64-v8a**, wired USB.

| moment | marker | screenshot |
|---|---|---|
| first launch of the installed release | `ANDROID-FINAL-V1-RELEASE` | [`1_first_launch.png`](1_first_launch.png) |
| after download, **before** restart | `ANDROID-FINAL-V1-RELEASE` | [`2_after_download_still_v1.png`](2_after_download_still_v1.png) |
| after restart | **`ANDROID-FINAL-V2-PATCHED`** | [`3_after_restart_v2.png`](3_after_restart_v2.png) |

Read two independent ways: mechanically out of the accessibility tree
(`uiautomator dump`) **and** visually from the screenshots. The middle row is
the load-bearing one — it separates **staged** from **executed**, so the change
cannot be attributed to the download alone.

The marker sits in a `@pragma('vm:never-inline')` function behind a
`DateTime.now()` guard, borrowed from the signing fixture. A bare constant
would be folded and the patch would be invisible to the analyzer — a mistake
that cost two release cycles earlier in this programme.

Device-reported events, and no failure of any kind:

    __patch_download__  __patch_install__   patch_number 1
    installs 3   install_failures 0   update_failures 0

(Counts are cumulative over three device runs, two of which were the
keyguard-blocked attempts below.)

**6 · current hydration/coherence behaviour was exercised, not inherited.** That
is what produced the finding: hydration is where the frozen stack stops. On the
control it printed `Done Running flutter precache` and proceeded. Nothing here
rests on historical Android evidence.

**A by-product worth noting:** the whole lifecycle is legible from one
`GET /admin/audit?release_id=1` call — `release.create` → five
`release.artifact.create`/`artifact.upload` pairs → `release.ready` →
`release.update(active)` → `patch.create` → three patch artifacts →
`patch.promote`, every row `success` with its status. That is
CONTROL-PLANE-AUDIT-1/2 doing real work on traffic it was not written against.

## Four harness faults, all mine, each caught before it could mislead

Recorded because three of them produced a *plausible* wrong answer:

1. **`--release-version` on a full Android release** exits 64 before any build;
   the flag is aar/ios-framework only, and the version comes from
   `pubspec.yaml`.
2. **The wrong fixture.** `selfhost/fixtures/android_signing_app` exists to
   probe a NON-DEBUG signing identity and its gradle refuses without a keystore
   at an uncommitted path. Replaced with what `flutter create` gives an ordinary
   developer, carrying the same marker discipline.
3. **Skipped an init step.** A fresh app lacks the INTERNET permission and a
   validator correctly refused. Fixed by running the product's own
   `shorebird doctor --fix` rather than hand-editing the manifest.
4. **The two that actually mattered.** `adb exec-out screencap -p` streams
   through stdout, and this device prints `[Warning] Multiple displays…` first —
   so every captured `.png` was not a PNG, and two *different* screens produced
   **byte-identical** files because both were just the warning text. Then, with
   valid captures, a **secured keyguard** left the app running and invisible: the
   updater still completed check → download → `__patch_install__` while the
   marker read `<none>` three times. Mechanism evidence looked perfect and the
   observable was simply absent.

   Both are now refused rather than tolerated: screenshots go via
   `screencap` to a file plus `adb pull` (never a channel that can also carry
   text) and are asserted to be PNGs, and the device stage **exits 2** if
   `mDreamingLockscreen` is not `false`.

## What this does and does not license

**Does:** the Android release → patch → discovery → download → physical
activation path is sound on today's CLI, producer and self-hosted control plane.
The Android mechanism needs no Route B and no linker.

**Does not:** it says nothing about Android on the frozen cell, because that
combination cannot be built. Any claim that "the frozen stack supports Android"
is unsupported by evidence and is contradicted by the A/B above.

## The correction this lane forces on a record I wrote earlier today

`SUPPORTED_STATE.yaml`'s new `product_surfaces` block (added hours ago, in the
ADD-TO-APP-1 wording pass) said:

    android: SUPPORTED — see ANDROID rows in WORKFLOW_CERTIFICATION.md

That was an over-claim and this lane disproves it for the frozen cell. The
re-certification against the final stack (`WORKFLOW_CERTIFICATION.md` §
"ROUTE-B-PRODUCTIONIZATION-1") is **entirely iOS** — rows 1 and 7 re-certified
by 6F/6G, everything else carried forward. Corrected in the same commit as this
document.

## If Android on the frozen stack is ever wanted

One decision, not a task: **publish Android engine artifacts for the cell** (at
minimum `android-arm64-release`, which `@must_be_local` requires be genuinely
ours), which means building and qualifying an Android Route B engine and
re-addressing the cell. That is cell/architecture work and was not started.

Note what it is *not*: the Android patch mechanism itself needs nothing new. It
is bidiff, it works, and this lane proved it.

## Provenance

| thing | value |
|---|---|
| repo revision | `6363ad1a` (clean) |
| CLI | `/Volumes/build/route-b/shorebird-candidate/bin/shorebird`, `1.6.115+selfhost.1` |
| frozen selector / cell | `e64eb0af52e1c43c3b21a39556d789538d0df9b3` / `cd848320d605ff8af5060cabf9a8d1b35853f752` |
| control selector / engine | `309dd6573a9fe716410489284cd325a34b950375` / `e1eaecbcac6d` (Flutter 3.44.7) |
| device | `3f72a543` OnePlus CPH2551, Android 16 (SDK 36), arm64-v8a, wired USB |
| control plane | throwaway sqlite/file instance on a free port, `adb reverse`; `cps-ios`/`cps-android` untouched |
| scripts | `selfhost/scripts/android1_{release,patch,device}.sh` |
