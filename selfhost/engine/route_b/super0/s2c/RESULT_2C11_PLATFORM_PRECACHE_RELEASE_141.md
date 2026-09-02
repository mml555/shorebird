# D-SUPER-2C.1 · PLATFORM-PRECACHE + RELEASE 141

    THE CLAIM, EARNED

    From an unprepared cache, the normal pinned Shorebird workflow selected
    F3/H3, obtained the required iOS engine artifacts ITSELF, passed coherence,
    executed the qualified Route B compiler 39ad75dd, and created release 141.

## The defect, and why two changes were needed

`installRevision` was not the whole story. Two independent faults:

    1. HYDRATION      installRevision early-returned on directory existence, so
                      a bootstrap-created checkout never precached; and its
                      precacheArgs always included --android, which a macos-ios
                      cell cannot serve (overlay-owned path -> loud 404).

    2. ORDER          assertCoherent ran BEFORE installRevision, so it judged
                      the ambient revision before the target's artifacts existed.
                      Fixing hydration alone did NOT fix the release: case 1
                      still refused, with no precache line in the log at all,
                      because coherence never let it get that far.

Fault 2 was only visible after fixing fault 1. The contract the ruling stated —
select, hydrate, establish identity, then gate — is now the actual order.

## What changed

    shorebird_flutter.dart
      precacheArgsFor(ReleasePlatform?)   target-specific: --ios / --android /
                                          --macos / --windows / --linux, with the
                                          historical pair kept for null
      installRevision(..., releasePlatform)
                                          hydration is UNCONDITIONAL and
                                          idempotent; directory existence is
                                          evidence a checkout exists, not that
                                          the target engine exists
      _precache                           runs the TARGET revision's own binary
                                          via shorebirdEnv.copyWith(...)
                                          .flutterBinaryFile — the pinned binary
                                          resolves its own engine.version and
                                          requested the wrong engine's artifacts

    release_command.dart                  coherence moved AFTER selection and
                                          hydration, and scoped to the TARGET
                                          revision
    patch_command.dart                    hydrates once per DISTINCT target
                                          platform

`@must_be_local` was NOT weakened and H3 serves no Android artifacts.

## Two bugs I introduced and fixed while doing it

    Stack overflow   the env override closure resolved `shorebirdEnv` from the
                     scope being defined, so copyWith recursed into itself.
                     Captured the target env BEFORE entering the scope.
    Malformed tests  a regex rewrite nested `releasePlatform:` inside
                     `any(named: 'revision', …)`. Repaired.

## Acceptance

### Case 1 — pinned fresh path, EXIT=0

F3 checkout DELETED, H3 compiler cache cleared, no `--flutter-version`, no
manual precache:

    Updating Flutter...              bootstrap obtained F3
    Running flutter precache... Done PRODUCT hydrated the iOS engine
    (no coherence refusal)           identity established, not UNKNOWN
    Downloading Route B compiler for engine d4c0dbc2... Done
    Release Version: 1.0.2+3
    Creating release... Done         EXIT=0

### Case 2 — explicit fresh override, no Android

`--flutter-version <F3>` with the checkout removed: precache ran, and
`android-arm` appears **0 times** in the log. It then refused only on the
duplicate version, which is correct now that 141 holds 1.0.2+3.

### Case 3 — negative control

H3's `ios-release/artifacts.zip` moved aside (served 404 as a protected path):

    Running flutter precache...  FAILED
    EXIT=70, no release created

Absence was NOT converted into success by the existing checkout or the Dart
stamp. Artifact restored; H3 audits CLEAN.

### Android regression

Unit-verified: `precachesAndroid for an Android release` asserts
`['precache', '--android']` and `isNot(contains('--ios'))`. NOT verified
end-to-end — this rig has no Android cell for this engine, and I am not claiming
one.

## GATE C — execution, not download

The observables that cannot exist without the compiler having run:

    "Could not check the two release kernels"   0 occurrences
    "coverage analyzer failed"                   0
    "narrower contract"                          0
    "will not be patchable"                      0

    release_import.dill   PRESENT locally
                          PRESENT in route_b.json's artifact map
                          PRESENT in the UPLOADED supplement
                          uploaded bytes == local bytes
                          93012195e3f2893ab5d84a774fe8b16ed98791405f53766ce820ac9715a72742

That artifact is produced only when the analyzer executes and BOTH release-time
agreement predicates return true. Release 140 withheld it precisely because the
v11 analyzer exited 255. Its presence is therefore downstream evidence of
successful execution, tied to the exact archive:

    consumed compiler   39ad75dd7342e9e26370d3dab834d3770e612b238103c85cadf03d3a61e93e74

## FROZEN release 141

    release ID              141
    version                 1.0.2+3
    flutterRevision         ab29aee0598b5a0d63cdfca1ddbe153ab8a5265e   (F3)
    engineRevision          d4c0dbc2905286eb4537d5f9a7802693096ca1fd   (H3)
    patchableCallSites      8462
    releaseArtifactSha256   8280c1257dca7a2d18c9e73bbdb3168ca66cd7aaed7d68c0fde2a36d4abb0bc8
    compatibilityRevision   1
    artifacts               7, including release_import.dill
    route_b.json            b89501e3b17e40bad6e75e5fc20586158168271c4cb9d383ba54a3e26575cb7b
    supplement zip          553acf27b6e1e046d7e1da0631e4da03d9ea8aaed325e0c21c18ea27600b8de7
    canonical B source      9e73ba40ad81ce60a3c07b9e526b25bbb50eeeb9a9e8873b09027d62125bf33c

CLI that produced it: `5cdae1e4f134c98fdf7520e00430ee168115ce72`, pin F3, banked
at `route-b-2c-cli-precache` and verified from a fresh bare fetch.

## Preservation

    releases 139/140   unchanged; 140 still records H2 and still has NO
                       release_import.dill — the negative specimen is intact
    F2, H2             unchanged, H2 AUDIT CLEAN
    F3, H3             unchanged, H3 AUDIT CLEAN
    39ad75dd           unchanged
    H3 serving policy  unbroadened

## Tests

    shorebird_flutter        50/50   (contract tests rewritten deliberately:
                                      "does nothing if already installed" encoded
                                      the defect and now asserts skip-clone-but-
                                      still-hydrate)
    release + patch commands 126/126
    analyzer clean
