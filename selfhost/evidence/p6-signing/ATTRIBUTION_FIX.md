# The launch-attribution fix — implemented, pinned, not yet on hardware

Closes the mechanism half of Arm C box 12. The device half is one rejection
launch plus one recovery launch on a new cell, and is NOT done.

## What was wrong, at source level

`ARM_C_EXECUTION_IDENTITY.md` proved the *behaviour*: the rejected patch never
executed (outcome P1), but it stayed credited, and the resulting cleanup deleted
the fallback. The remaining question was why launch start ran BEFORE validation,
1 ms apart, when `ConfigureShorebird` calls `ValidateNextBootPatch()` and nothing
obviously precedes it. It is now answered by reading the engine rather than
inferring:

    ConfigureShorebird()                        shorebird.cc:~648
      -> SetBaseSnapshot(settings)              iOS only
           -> DartSnapshot::IsolateSnapshotFromSettings()
                -> ResolveIsolateData()         dart_snapshot.cc:160
                     -> Updater::ReportLaunchStart()   <-- HERE
      -> ValidateNextBootPatch()                shorebird.cc:~650  <-- one line later

So the iOS base-snapshot preload dragged launch attribution ahead of validation.
Nothing in the lifecycle code was "wrong" in isolation; the ordering was an
emergent property of two unrelated call sites, which is why it survived review.

## The fix

One operation, in one updater state transition:

    UpdaterState::prepare_next_boot()
      1. validate_next_boot_patch()      -- rejection is a NORMAL outcome, logged
      2. next_boot_patch()               -- read the pointer only AFTER step 1
      3. set_running_patch(selected)     -- in-memory session identity
      4. record_boot_start_for_patch(selected.number)   -- the only disk write
      5. return selected

Invariant, frozen:

> `currently_booting_patch` == the patch number belonging to the returned active
> path. Not "normally equal."

Exposed as ONE C symbol, `shorebird_prepare_next_boot_patch()`, consumed by
`Updater::PrepareNextBootPatch()`. The engine's three-call sequence is gone, and
the two accessors were REMOVED from the C++ interface rather than left unused —
while they exist a future caller can reassemble the broken ordering.

**Retention is unchanged and needs no exception.** With correct attribution a
successful boot promotes the patch that actually booted, so `cleanup_older_than`
cannot reach it. The earlier reading that cleanup was too eager was wrong:
`record_boot_success` did exactly what its contract says, having been told the
wrong patch succeeded.

## The unit matrix, as precommitted

Run in the updater tree that actually ships (`third_party/updater`), and mirrored
in `vendor/updater`.

| row | returns | credits |
|---|---|---|
| `next=P2, last=P1`, P2 valid | P2 | P2 |
| `next=P2, last=P1`, P2 unverifiable under the release key | **P1** | **P1** |
| `next=P1, no last`, P1 unverifiable | **base / None** | **None** |
| `next=P1, last=P1`, P1 valid | P1 | P1 |
| P3 installed + promoted AFTER prepare returned P1 | — | **still P1** |

The load-bearing regression, in full: P1 known-good / P2 invalid / prepare → P1 /
boot success → `last_booted_patch` stays 1, P1 still `Installed`, **P1's artifact
file still on disk**, P2 remains `Bad{ValidationFailed}`.

The concurrency row is the reason attribution is bound to the RETURNED patch
rather than to a later re-read of the pointer: `update()` and the update thread
may move `next_boot_patch` at any time, so moving `report_launch_start` a few
lines later would not have been sufficient.

## Mutation results — the tests are not vacuous

Restoring the old *attribute-before-validate* ordering:

    prepare_returns_the_candidate_when_it_validates ................. ok
    prepare_attribution_survives_a_later_pointer_change ............. ok
    prepare_falls_back_and_attributes_the_fallback_not_the_candidate  FAILED
    prepare_returns_base_when_the_only_candidate_is_rejected ........ FAILED
    prepare_success_after_fallback_keeps_the_fallback_installed ..... FAILED

Two rows still pass. That asymmetry IS the defect's survival mechanism: the two
facts agreed whenever nothing was rejected, so every happy-path test was green.

Dropping the C++ once-per-process cache fails 5 of the 14 `UpdaterTest` cases.

## A second vacuity found while doing this

`updater_unittests.cc` was compiled only by `shorebird_unittests`, which **does
not link** on the host build (`Shorebird_ReadLinkHeader` is defined only in
Shorebird's private Dart fork). All 14 of its tests had therefore never
executed — the same trap `0008` documented for the arming tests. They now build
in `shorebird_arming_unittests` and run.

    shorebird_arming_unittests : 21 tests, 21 passed
    updater (engine copy)      : 300 tests, 300 passed
    updater (vendor copy)      : 267 tests, 267 passed

## Provenance

    updater consumed revision  f729f958e9be  ->  af6e842ccf87
    engine commit              2c7b8c3ea5    ->  619fdad176
    patches                    selfhost/engine/route_b/0014-atomic-prepare-next-boot.patch
                               selfhost/engine/route_b/0014-updater-atomic-prepare-next-boot.patch

## NOT done, and why it is not a detail

* **No new iOS cell yet.** The bytes on the device are still cell `ca7d2c0d…`,
  built from updater `f729f958e9be`. Nothing above has run on hardware.
* **Signing stays UNCERTIFIED.** Box 12 requires the last-known-good patch to
  continue on a real rejection launch.
* **A revision bump collides with measurement mode** — see
  `MEASUREMENT_MODE.md`. `af6e842ccf87` is not in
  `Repository.eligibleUpdaterRevisions`, and step 5 of that document is "stop
  changing lifecycle behaviour". Raised rather than resolved here.
* **The three unexplained crashes** from the Arm C reproduction are still
  unexplained and are not folded into this fix.
