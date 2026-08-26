<!-- cspell:words privatestate airgap xcframework precommitted -->

# P6_DEVICE_EPOCH

    P6_DEVICE_EPOCH = cell 8e65981251dc945356d532120e424836da10245c

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
