# AFTER-RUN BLOCKED — engine rebuild fails on SDK hash, 2026-08-19

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
