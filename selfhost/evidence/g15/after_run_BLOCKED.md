# AFTER-RUN BLOCKED — engine builds, but the ARTIFACT SET cannot be made coherent

*** SUPERSEDED 2026-08-19, SAME DAY — THE ENGINE BUILD IS FIXED ***
===================================================================
**The "Invalid SDK hash" build failure below is SOLVED, and the engine now
builds. The after-run is still blocked, but for a different and better-understood
reason. Original text kept below because its elimination steps remain valid.**

## ROOT CAUSE OF THE BUILD FAILURE — found, and cheap

Generated `version.cc` files in `out/ios_release/*/gen/.../dart/runtime/` were
from **2026-08-10** and hard-coded SDK hash **`6b58bb3a72`**, the old Dart base
revision. The Dart SDK's git HEAD moved to `9e8c898a4d2a3b4d…` on **2026-08-18
16:48** — the commit that moved the Dart work off a detached HEAD onto a branch.
New dills therefore record `9e8c898a4d` while the stale generated file kept the
tool at `6b58bb3a72`.

That is why the Aug 17 build worked and today's did not: **nothing about the
toolchain was broken; a generated file was stale.**

The decisive clue was that the freshly-built `gen_snapshot` was **byte-identical**
to the Aug 17 one (`b8be0471…`) — so the tool was not the variable and the dill
had to be. That comparison came free from preserving both binaries.

Deleting the three `version.cc` files and rebuilding: **`ninja exit=0`**, new
engine arm64 `LC_UUID 4C4C447D-5555-3144-A165-51D432516584`, and the wiring is in
the shipped bytes:

    __patch_boot_lifecycle__      1
    ambiguous_boot_retry          1
    recovered_after_ambiguity     1
    retired_after_ambiguity       1

All five gates passed: coherent build, updater revision `ae1a4849` tied
mechanically (`RecoveredAfterAmbiguity` present at that commit, absent at its
parent), wiring in the binary, fixture digest identical to the freeze, baseline
untouched.

## THE REAL BLOCKER — a coherent set is FOUR artifacts, not one

Swapping the engine alone reproduces the same mismatch one layer up. The SDK hash
must agree across:

| artifact | supplies | swapped? |
|---|---|---|
| `Flutter.xcframework` | the engine + updater | yes |
| `gen_snapshot` / `analyze_snapshot` | AOT snapshotting | yes |
| `flutter_patched_sdk_product` | the platform dill the app compiles against | yes |
| **`dart-sdk`** | the FRONTEND that reads that dill | **no — still `6b58bb3a72`** |

With the first three at `9e8c898a4d`, the app build fails in the frontend:

    Crash when compiling package:killswitch_probe/main.dart:
    Unexpected Kernel SDK Version 9e8c898a4d (expected 6b58bb3a72)
      BinaryBuilder._readAndVerifySdkHash

**So only two coherent end-states exist:** everything at `9e8c898a4d`, which needs
a HOST build to produce a matching `dart-sdk`; or everything back at
`6b58bb3a72`, which has no wiring.

## WHAT I DID WRONG, AND UNDID

I hand-swapped files inside `~/.shorebird`'s artifact cache. That is off-pipeline:
this repo already has `build_host_zips.sh` and `publish_ios_overlay.sh` for
exactly this, and `build_host_zips.sh`'s own header describes this hazard —
publishing a `flutter_patched_sdk_product` that disagrees with `sky_engine.zip`.

The hand-swap left `~/.shorebird` **mixed and unable to build iOS at all**.
**Restored** from backups taken before each swap, and verified: engine
`4C4C44C0…`, product SDK `6b58bb3a72`, zero wiring strings, and a real patch
build reaching "Verifying patch can be applied to release" with no hash errors.

I also reverted a premature `compatibility.yaml` stamp of
`updater_revision: ae1a4849`. **Provenance must describe what actually ships**, and
no engine carrying that revision is in service.

## THE CORRECT NEXT STEP

Use the documented pipeline rather than cache surgery:

1. `build_host_zips.sh` — host toolchain from the SAME tree, giving a `dart-sdk`
   at `9e8c898a4d`;
2. `publish_ios_overlay.sh` — publish the full set under one engine hash, so the
   CLI resolves a coherent set by construction;
3. only then stamp `compatibility.yaml` and cut release 103.

Backups, durable and hash-recorded in `build_coherence/ARTEFACTS.txt`:

    evidence_preserved/shorebird_ios_release_BEFORE   engine + snapshot tools
    evidence_preserved/shorebird_common_BEFORE        both patched SDKs
    evidence_preserved/build_coherence/              gen_snapshot pair + dill

===================================================================

The baseline is frozen and intact. The after-run cannot proceed because the iOS
engine will not build from this tree.

## THE FAILURE, precisely located

    [5/8] ACTION //flutter/lib/snapshot:generate_snapshot_bin
    FAILED: gen/flutter/lib/snapshot/vm_isolate_snapshot.bin (+3)
      clang_arm64/gen_snapshot --snapshot_kind=core …
        out/ios_release/flutter_patched_sdk/platform_strong.dill
      exitCode: 254
      Can't load Kernel binary: Invalid SDK hash.

`platform_strong.dill` SDK-hash field (bytes 8..18): **`9e8c898a4d`**.

## WHAT WAS RULED OUT — three attempts, ~5 minutes of build each

| attempt | action | result |
|---|---|---|
| 1 | plain build | dill rebuilt (21:46), `gen_snapshot` left at Aug 17 → mismatch |
| 2 | delete `gen_snapshot`, rebuild | tool rebuilt (21:50), dill still from 21:46 → same failure |
| 3 | delete **both**, rebuild in one pass | both fresh → **same failure** |

**So this is not staleness and not build ordering.** The Dart SDK sources
producing `platform_strong.dill` and those compiled into `gen_snapshot` disagree
on the SDK hash even when both are produced from one invocation.

This is the hazard already documented in this repo — `UPSTREAM_INDEPENDENCE.md`
records *"fork SDK + stock const_finder → rejected: Can't load Kernel binary:
Invalid SDK hash"*, and `TFA_ROOT_CAUSE.md` hits the same string. It is a
known-shaped problem here, not a new mystery, but its resolution is
build-infrastructure work of uncertain size and it is NOT the lifecycle lane.

Stopped rather than continuing to try variants, per the rule about not turning a
2-3 attempt failure into an open-ended dig.

## THE UPDATER DID COMPILE — the wiring is not in question

    [2/8] ACTION //flutter/shell/common/shorebird:build_rust_updater
    Compiling updater v0.1.0 (…/third_party/updater/library)
    Finished `release` profile [optimized] target(s) in 4.67s

The tree was clean on branch `route-b` at `ae1a4849`, so the C3 wiring and
lifecycle telemetry compile. The failure is downstream, in the Dart snapshot
step, and unrelated to the updater change.

## BASELINE IS SAFE — verified after the failed builds

    recorded  4e2a46f1a5099c6e5f71afb27b254df4ed9e74bd9e969fa925c02ddfe71ffa71
    preserved 4e2a46f1a5099c6e5f71afb27b254df4ed9e74bd9e969fa925c02ddfe71ffa71
    live cell 4e2a46f1a5099c6e5f71afb27b254df4ed9e74bd9e969fa925c02ddfe71ffa71

`mintstage_0013` untouched (Aug 17 00:03); release 102 ipa hash matches the
freeze. The failed builds wrote only into `out/ios_release/`, which holds no
baseline artifact. The Aug 17 `gen_snapshot` is backed up at
`/tmp/gen_snapshot.aug17.bak` (volatile — re-preserve if it matters).

## WHAT IS UNAFFECTED BY THIS BLOCK

The baseline's central result needs no new engine and stands on its own:

> **An explicit patch-blaming failure and an ambiguous process disappearance are
> observably different events on real hardware** — different reporting timing,
> different breadcrumb state, different classifying process, different wire
> message.

Only row 5 — retirement vs `ambiguous_boot_retry` → `recovered_after_ambiguity`
— awaits the wired engine.

## OPTIONS, not chosen here

1. Diagnose the SDK-hash divergence (which Dart tree feeds each side). Correct,
   uncertain size, and the repo has prior art on the same error string.
2. Build on the documented Azure build host (`ENGINE_BUILD.md` §"the build host
   we actually use") rather than this Mac.
3. Land the wiring without a device after-run, marked BUILT-not-device-proven,
   and let fleet telemetry supply the evidence once an engine ships by any route.

**Do not ship the wiring to devices before the telemetry ships with it** — that
constraint is unchanged by this block.
