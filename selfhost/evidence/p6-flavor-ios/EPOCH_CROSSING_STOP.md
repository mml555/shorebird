<!-- cspell:words privatestate airgap precommitted dartaotruntime -->

# P6 device epoch crossing — **STOPPED at step 4**, on a precommitted condition

**The flavor arm was NOT run.** Stopping here is the gate working, not a failure
of flavors. The condition that fired:

> *"the cache warm cannot be positively distinguished from stale/fallback
> artifacts"*

## What was completed

| step | result |
|---|---|
| 1 · rig CLI moved to the hardening revision | **done.** `~/.shorebird` `9125eb13` → `1288131f`, stamp cleared, CLI rebuilt. Verified in the BUILT ARTIFACT rather than from the stamp: `shorebird.snapshot` contains `BUILD_IDENTITY_EVIDENCE_ABSENT`, `TARGET_SIGNATURE_CHANGED`, `UNSUPPORTED_PARAMETER_SHAPE`, `route_b_release_probe.aot`, `route_b_snapshot_profile.json` |
| 2 · `engine.version` repointed | **done.** `93a3756…` → `9b5f040c…` |
| 3 · caches cleared | **done**, per the mint's own precondition: `artifacts`, `dart-sdk`, `downloads`, `*.stamp` |
| 4 · warm through the consumer path | **FAILED, and the failure is the finding** |

## The finding: this cell chain's artifact set is incomplete

`flutter precache --ios` 404s on `ios/artifacts.zip`, and a release-shaped build
404s earlier still, on `sky_engine.zip`:

    http://localhost:8085/flutter_infra_release/flutter/9b5f040c…/sky_engine.zip → 404

**Not a regression from this mint.** Every hash in the chain hosts exactly the
same six entries, and none of them is `sky_engine.zip`:

    2c4443ce · 93a3756 · ac5d3b63 · 9b5f040c
      dart-sdk-darwin-arm64.zip  darwin-arm64  engine_stamp.json
      flutter_patched_sdk.zip  flutter_patched_sdk_product.zip  ios-release

Twenty-three other hashes in the overlay DO host `sky_engine.zip`. **Not one of
them shares our engine**: every single one has a different
`ios-release/artifacts.zip` digest than our `216a326d81688d1a`.

So `sky_engine.zip` for this engine **has never existed anywhere**.

## Why this was invisible until now

`pkg/sky_engine` is still on disk — the clear removed `artifacts`, `dart-sdk`,
`downloads` and the stamps, not `pkg/`. The 404 happens because deleting
`flutter_sdk.stamp` makes Flutter re-verify the base SDK group and try to fetch
it.

Which means: **every release cut on this cell chain compiled with a
`pkg/sky_engine` that was fetched under a DIFFERENT engine hash and then
retained across engine switches.** The stamp made it look settled. This is the
mixed-provenance shape this fork exists to remove, and it sat underneath the
chain the whole time.

**Scope, stated carefully rather than alarmingly.** The AOT kernel for a release
is compiled against `flutter_patched_sdk_product`, which IS hosted per hash and
IS correct for this engine. `pkg/sky_engine` supplies the `sky_engine` package
for resolution and analysis. So this is **not** demonstrated to have put wrong
bytes in a shipped app, and it must not be written up as if it were. What IS
demonstrated: the toolchain's provenance was not closed, and no gate noticed.

## The mint script says it clones this, and it does not

`mint_route_b_cell.sh:25` — *"its ios-release, dart-sdk, **sky_engine** and the
rest are cloned rather than rebuilt"*. The clone copies whatever the donor has,
and no donor in this chain has it, so the sentence has been describing an
artifact that was never there.

## The remedy exists, and is not a borrow

Our own engine tree generates it:

    /Volumes/build/route-b/flutter/engine/src/out/ios_release/gen/dart-pkg/sky_engine
    /Volumes/build/route-b/flutter/engine/src/out/host_release_arm64/gen/dart-pkg/sky_engine

So the fix is to PACKAGE AND PUBLISH `sky_engine.zip` (and `flutter_gpu.zip`)
**from this engine's own build** under the cell hash — not to fetch a foreign
one, and not to write a stamp asserting the cache already holds it. Writing that
stamp is the precise thing the mint's precondition #2 forbids, and here it would
assert something known to be false.

## What was NOT done, deliberately

- **No stamp was written.** The rig is left honestly unable to build rather than
  made to look ready.
- **No foreign `sky_engine` was fetched** to paper over it.
- **The flavor arm was not started.** No flavored release, no install, no launch.

## Rig state, recorded

| item | state |
|---|---|
| rig CLI | `1288131f`, rebuilt, gates verified present in the snapshot |
| `engine.version` | `9b5f040c18a43f6c1c7fae66b7c60d5936cc8b1f` |
| Flutter cache | `artifacts`, `dart-sdk`, `downloads`, `*.stamp` **removed**; `pkg/` intact. **Cannot build until the cell's artifact set is completed** |
| `dev.selfhost.airgapProbe` | **UNTOUCHED.** Nothing was installed, launched or uninstalled; no server state was altered. `MEASUREMENT_MODE.md`'s release-108 specimen is unaffected — the only mutation was to the host toolchain |
| `flavored_probe` | `ios/`+`android/` materialised and the overlay verified (`xcodebuild -list`: nine configurations, schemes `Runner`/`Foo`/`Bar`, three bundle ids). Nothing built, nothing signed, nothing installed |
| rig custody | still claimed by this P6 arm; **not** relinquished, because the arm has not run |

## What this changes about P6

The epoch crossing is a **shared prerequisite for five device rows**, and it is
now blocked on a cell-completeness defect rather than on anything about flavors.
That is worth more than the flavor result would have been: it says the remaining
P6 device work has one blocking dependency, and names it.
