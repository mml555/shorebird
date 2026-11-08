# The producer gate had the same false-green — closed

`verify_toolchain_coherence.sh` was fixed when the stale cache was found. The
**Dart** gate that actually stops a build was not, and it would have
green-lighted the identical state. Closed here, CLI-only: no cell was reminted.

## What was missing

`ToolchainCoherence.check` proved iOS with:

    engine.stamp            == engine.version
    engine-dart-sdk.stamp   == engine.version
    gen_snapshot            contains patchable_static_calls
    dartaotruntime          byte-compared (optional, when the zip was named)

Not one of those can distinguish this cell's engine from its predecessor's. The
first two read stamp *contents*; `patchable_static_calls` is carried by **every**
Route B cell, so it separates Route B from stock and nothing finer. So
`assertCoherent()` would have authorized `release ios` against the previous
runtime — which is exactly the state measured on 2026-08-27.

## What it does now

For an iOS producer, each of `ios`, `ios-profile`, `ios-release`:

    cached  = <flutter>/bin/cache/artifacts/engine/<mode>/
                Flutter.xcframework/ios-arm64/Flutter.framework/Flutter
    published = $SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR/<mode>/artifacts.zip
    require SHA256(cached) == SHA256(engine slice inside published)

Failure semantics, all refusals:

| state | code |
|---|---|
| cached != published | `ENGINE_ARTIFACTS_STALE` |
| env var unset | `COHERENCE_UNDETERMINABLE` |
| published root or a mode's zip missing | `COHERENCE_UNDETERMINABLE` |
| published zip unreadable | `COHERENCE_UNDETERMINABLE` |
| cached engine missing | `COHERENCE_UNDETERMINABLE` |

**"Not cached yet" is green in the shell verifier and a REFUSAL here**, and that
divergence is deliberate. The script is a diagnostic that may run at any time;
this runs immediately before artifacts are produced, and at that moment an absent
engine means the identity was never established. Absence is not a match.

Android is untouched and reports *iOS Route B capability: NOT EVALUATED | iOS
engine identity: NOT EVALUATED*. Silence there would let a green Android line
read as a claim about the iOS half.

`SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR` is **required for iOS**, unlike
`SHOREBIRD_PUBLISHED_DART_SDK_ZIP` which stays optional. Stamps may not stand in
for identity — that substitution is what produced the false green. It is an env
var rather than a baked path because where artifacts are published is a
deployment fact, and a local CDN overlay must not leak into the product.

## The load-bearing regression

Reproduces the measured state exactly — stamps current, engines stale, capability
present:

    engine.version / engine.stamp / engine-dart-sdk.stamp  4792f0ec
    cached iOS engines                                     ca7d2c0d's
    gen_snapshot patchable_static_calls                    present

    ios     -> REFUSE, 3 x ENGINE_ARTIFACTS_STALE, one per mode, both digests named
    android -> PASS

and its causal partner: the same checkout with the real engines substituted →
`ios` PASSES. The pair differs only in the engine bytes.

At the producer boundary, `assertCoherent(releasePlatform: ios)` throws
`ProcessExit` and logs `ENGINE_ARTIFACTS_STALE` once per stale mode. Both
`release ios` and `patch ios` route through it.

Also pinned: a **per-mode** mismatch (only `ios-profile` stale) is caught rather
than averaged away, so a partially refreshed cache cannot pass.

## Mutation results

Byte comparison removed → **10 tests fail**, including both halves of the
regression and the producer-boundary one:

    REFUSES the exact state that passed: stamps current, engines stale   FAILED
    REFUSES the stale-engine state at the producer boundary              FAILED
    a MISSING cached engine is UNDETERMINABLE, never green               FAILED
    REFUSES an iOS build when the published source is unset              FAILED

Restored → 30/30. Whole CLI suite: **2643 passed**, 2 skipped.

## Two defects the new tests found in my own work

1. **The error message never named the env var.** It was written as a Dart raw
   string, so it emitted the literal `$publishedIosEngineDirEnvVar`. A refusal
   telling the operator to set `$publishedIosEngineDirEnvVar` is useless. Caught
   only because the test asserted on the *variable's value* rather than on
   prose.
2. **A test matcher that could not fail correctly.** `detail.contains(mode)`
   matched all three problems for `mode == 'ios'`, since `ios` is a prefix of
   `ios-profile` and `ios-release`. Tightened to the exact phrase.

## End to end, on real bytes

The unit tests use synthetic zips built by `zip`. The real ones come from the
packaging pipeline, so the gate was also run against the live activated checkout:

    published = overlay/…/4792f0ec…      ios: 0 problems   android: 0 problems

    published = overlay/…/ca7d2c0d…      ios: 3 problems
      cached ios         745e178c447789ce  vs published 567acd54c9a725a5
      cached ios-profile de68eefd42df7bbb  vs published 7cde65d962742568
      cached ios-release 62bd2395005cc315  vs published 49182b375aeb858b
                                            android: 0 problems

Those six digests are exactly the pairs in `CELL_4792f0ec_AB_MANIFEST.md`. The
gate reads the real archives correctly, and refuses for the right reason when
pointed at the wrong cell.

## Required for the device tail

Every `shorebird release ios` / `shorebird patch ios` from now on needs:

    export SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR=\
      /Users/mendell/shorebird/selfhost/cdn/overlay/flutter_infra_release/flutter/4792f0eca461f3761001a1adbe131b4b115e3684

Without it the build refuses with `COHERENCE_UNDETERMINABLE`, which is the
intended behaviour, not a regression.
