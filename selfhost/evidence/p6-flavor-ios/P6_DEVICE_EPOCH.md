<!-- cspell:words privatestate airgap xcframework precommitted flavoredprobe Shidduch -->

# P6_DEVICE_EPOCH

    P6_DEVICE_EPOCH       = cell 8e65981251dc945356d532120e424836da10245c
    P6_DEVICE_EPOCH_READY = true
    fixture_app_id        = 1c99c679-8650-ba82-3899-681349a59416  (flavoredprobe-p6)
    release_number        = 113  (version 1.1.0+1)
    flavor                = foo  (reaches the compiler as Foo — see below)

Every later P6 device row inherits this line rather than clearing and re-warming
independently — five repetitions would quietly become five slightly different
environments.

## Why this cell exists

`3b2471e8` closed `sky_engine`/`flutter_gpu` and was still incomplete: a
clean-cache release 404'd on `ios/artifacts.zip`, because `flutter_cache.dart`'s
`_iosBinaryDirs` requires **all three** iOS engine groups before an iOS build
proceeds — including a release build — and this tree had only `out/ios_release`.

So `ios_debug` and `ios_profile` were **built from the same pinned tree**, and
this cell addresses their digests. `3b2471e8` stays immutable as the record of
the intermediate discovery.

## The addressed manifest

    dart2bytecode.aot                 8dfb3b6682d591a3
    dartaotruntime                    075ccbb2858f299d
    flutter_gpu_sha256                c15aa66a540b59e2
    flutter_platform_strong.dill      099b03133aea3927
    ios_debug_artifacts_sha256        b5abe13dfab58709   <- new
    ios_profile_artifacts_sha256      4d88c4912ab68ba6   <- new
    route_b_analyze.aot               14538a6731604442
    route_b_gen_dynamic_interface.aot c226800242a85028
    route_b_gen_kernel.aot            81e1d8f4dc72bf2b
    route_b_release_probe.aot         ee144635d144a080
    sky_engine_sha256                 615a2da723c4064f
    vm_platform.dill                  015ef32c6cb988d8

## The gate that authorised this, in order

| step | result |
|---|---|
| build process finished | `ALL DONE`, **2** ninja invocations, both `exit=0` |
| debug qualified independently | PASS — same `engine_version` `2c7b8c3ea5925 3d3`, `dart_version` `9e8c898a4d2a3b4d`, `skia_version` `e9ed4fc9f1544c58` as the release; `dart_dynamic_modules=true`; `shorebird_use_interpreter=false`; device slice `567acd54c9a725a5`; binary newer than its own `args.gn` |
| profile qualified independently | PASS — same three revisions; device slice `7cde65d962742568`; host tools `gen_snapshot 1d5599eef478b94a`, `analyze_snapshot 8526b9a2aaff4b0e` |
| deterministic packaging | PASS — each archive packaged twice, byte-identical |
| **consumer-derived completeness** | **COMPLETE 9/9** |
| consumer-path delivery | `643a0eea0b95b81c` delivered == published, and ≠ donor `800b1d92291f83c7`, so not fallback bytes |
| compiler cell audit | AUDIT CLEAN on all eight members |
| **release from a TRULY empty cache** | **PASS** — `artifacts`, `dart-sdk`, `downloads` **and `pkg/`** removed, no stamp written. All three iOS groups fetched from this cell: `[1/3] ios`, `[2/3] ios-profile`, `[3/3] ios-release`. `Built build/ios/iphoneos/Runner.app (23.9MB)` |
| `isRouteBEngine` | **TRUE**, established positively on the CONSUMED bytes: `InterpretCall` present in `49182b375aeb858b`, which is byte-identical to what the cell serves |

## The mutation arms — these are not manifest decorations

| withdrawn | consumer failed at | verdict |
|---|---|---|
| `ios/artifacts.zip` | `[1/3] ios` → 404 | its own step |
| `ios-profile/artifacts.zip` | `[2/3] ios-profile` → 404 | its own step |
| `sky_engine.zip` (on `3b2471e8`) | `Flutter SDK → [1/5] sky_engine` → 404 | its own step |

Each fails at the artifact withdrawn and nowhere else, so each is load-bearing.

## Release runtime unchanged

`ios-release/artifacts.zip` is **`216a326d81688d1a`**, byte-identical to every
cell back to `2c4443ce`. Building two additional modes did not touch the proven
release runtime — which is the point: they are build-tool dependencies, not new
code in the release.

**P0 determination: NO RELEASE-RUNTIME DELTA.** Recorded in
`APPSTORE_COMPLIANCE.md` §7e.

## One defect the gate caught, and it was mine

Profile initially **REFUSED** — `no gen_snapshot_arm64`. Ninja had exited zero
for both modes and the log said `ALL DONE`; the gate refused anyway. The cause
was my packager looking in the out root and `clang_x64/` when these tools live in
`universal/`, which is where `publish_ios_overlay.sh` has always read them from.

Worth recording for two reasons. The refusal was **right** even though the cause
was a harness bug: an archive missing its AOT tool is not the artifact set the
consumer gets for the other modes. And the first debug archive — produced before
the path was fixed — silently omitted both host tools and was `48bae91f7cd22d2a`;
after the fix it is `b5abe13dfab58709`. Nothing was published in between, so the
wrong bytes never acquired an address.

## Rig state, as the epoch baseline

| item | state |
|---|---|
| rig CLI | `1288131f`, rebuilt; gate markers verified present in `shorebird.snapshot` |
| `engine.version` | `8e65981251dc945356d532120e424836da10245c` |
| cache | populated **from this cell alone**, from empty, without a stamp |
| `isRouteBEngine` | TRUE, on the consumed bytes |
| `dev.selfhost.airgapProbe` | **UNTOUCHED** — nothing installed, launched or uninstalled; `MEASUREMENT_MODE.md`'s release-108 specimen unaffected |
| custody | held by the P6 flavor arm |

## What is still owed before the flavor arm

A **clean release through the CLI** — not `flutter build` — confirming the
P4/P5-era shape: snapshot profile, profile/artifact binding, contract revision,
release target, and `RouteBBuildConfig`. Only then the ten precommitted flavor
requirements.


---

# Epoch READY — the clean CLI release passed

`epoch established` was not `epoch release-ready`, and the distinction earned its
keep: the first release **failed** the gate on two fields.

## The dedicated app

`flavoredprobe-p6` / `1c99c679-8650-ba82-3899-681349a59416`, registered fresh on
`cps-ios`. Nothing was reused: `airgapProbe`'s release-108 state, its patch
history and its lifecycle evidence are all untouched, and every server row for
this work attributes cleanly to P6. The registration is fixture setup, not a
claim.

## Release 113 (1.1.0+1), verified FROM THE SERVER

The supplement was downloaded back through the control plane — not read from the
local build tree — so what is checked is what survived the CLI → server
boundary. All fourteen fields:

| evidence | result |
|---|---|
| current cell | `8e65981251dc9453` = the epoch |
| Route B positively selected | 6,253 patchable sites, 1792/MiB |
| snapshot profile | present, 7,330,503 bytes |
| profile/artifact binding | present |
| contract revision | 1 |
| release target | `'lib/main.dart'` |
| `RouteBBuildConfig` | non-null, fingerprint `7f7064b52cbb1a9a` |
| flavor | recorded `Foo` == **shipped** `Foo` |
| profile digest | == sha256 of the profile as delivered |
| binding digest | == sha256 of the binding as delivered |
| binding artifact digest | == sha256 of the **actual** App binary |
| `route_b.json` artifact digest | == the same App binary |
| binding cell | == release cell |
| binding probe revision | 1 |

**The vacuity protection did its job.** Between release 112 and 113 the App
binary digest moved `38c00c9e…` → `084d77b0…` and the binding digest moved
`2563bab2…` → `7db2c221…`. A stale sidecar from the previous release could not
have satisfied these checks, which is the whole reason they compare independently
computed digests rather than asserting a field exists.

## The two failures on release 112, and what they were

**1 · `releaseTarget: null` — a real defect, fixed.** P5 recorded the raw
`--target` flag, so the field was null for every release that did not pass one —
almost all of them. Provenance that is absent in the common case is not
provenance. It now records the effective target, `lib/main.dart`. Not read from
`Generated.xcconfig` despite that file carrying `FLUTTER_TARGET`: see below.

**2 · `FLUTTER_APP_FLAVOR: 'Foo'` — NOT a defect. My check was wrong.** I
expected the CLI argument's spelling, `foo`. The flavor that reaches the compiler
is the Xcode **scheme** name, which is why `_resolveAppleFlavor` maps it, and
`flutter_injected_defines.dart:77` records why reading it from the xcconfig
instead "would reintroduce the exact casing divergence `f06fa056` closed".

Settled by the shipped program rather than by argument: the built AOT contains
**`V1/Foo`**. So the release's record matches what shipped, which is the invariant
that matters. The check now compares the recorded flavor against the **shipped
program**, which is a stronger assertion than comparing it to a CLI argument.

**A related finding worth keeping.** `ios/Flutter/Generated.xcconfig` was
observed holding `FLUTTER_APP_FLAVOR=foo` while this release's own program had
`Foo` — it was left over from an earlier plain `flutter build`. So that file is
not a trustworthy record of *this* build at an arbitrary moment, which is exactly
why the new `releaseTarget` does not read from it.

## What blocks the flavor DEVICE arm — and it is not flavors

`shorebird release ios` first failed at IPA export:

    error: exportArchive No Accounts
    error: exportArchive No profiles for 'dev.selfhost.flavoredProbe.foo' were found

The team `SK85S6YZP9` is configured in the project, and signing identities exist,
but the only provisioning profile on this machine covers an unrelated app
(`SK85S6YZP9.com.ShidduchCard`). A non-interactive `xcodebuild` cannot mint one.

`--no-codesign` was used, which is sufficient for the release-shape gate — it
produces the xcarchive, the App binary and every sidecar, all of which the gate
verified. **It is not sufficient for the device arm**, whose requirement 9 is a
physical render of `FLAVORPROBE-V4`.

So the flavor arm now has one open prerequisite: a development-signed install of
`dev.selfhost.flavoredProbe.foo`. That is a signing question, not a Route B one,
and it is recorded here rather than worked around.

## Baseline frozen

Release **113** is the V3 baseline. It will not be rebuilt for the flavor arm —
the point of this gate is that this clean CLI release *is* the baseline.
