# D-SUPER-2C.1 · HOST-COHERENCE — coherent host set built and QUALIFIED

Source authority unchanged: engine `dfa2b24ac38477f3705ff0357530f33fe09474b8`,
Dart `9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c`. No iOS engine mode rebuilt. H
untouched. `out/host_release_arm64` (the DM host, whose dill is the compiler
cell's identity input) deliberately NOT rebuilt.

## Builds — every step's own exit code, not one "ALL DONE"

    gn gen host_release_arm64_nodm     exit=0
    ninja nodm archives                exit=0   (13m49s)
    gn debug                           exit=0
    ninja debug archives               exit=0   (42m12s)
    ninja const_finder (debug)         exit=0

Every archive `unzip -t`ed, because a previous nodm run left a 138 MB PARTIAL
zip with a plausible size:

    dart-sdk-darwin-arm64.zip        144,554,615   cf5551883d9f7f3f   OK
    flutter_patched_sdk_product.zip    3,975,172   d2460d13d6c1d49e   OK
    flutter_patched_sdk.zip            3,975,080   c04ea2f78e215b69   OK
    darwin-arm64/artifacts.zip        41,013,301   9e82ab524ae023e0   OK

## Required observables

    nodm  dart_dynamic_modules lines   0
    nodm  dart_version                 9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c
    debug dart_version                 9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c

    product platform dill sdkHash      9e8c898a4d   (was 6b58bb3a72)
    debug   platform dill sdkHash      9e8c898a4d

The `_nodm` VARIANT was kept, not swapped for the DM host. PARITY.md records
that the published frontend_server is dm=false while the iOS gen_snapshot is
dm=true, and that the DM host dill failed iOS AOT with "Unexpected tag 4
(Field)". The defect was STALENESS, not the dm setting.

### A stale label caught before it could bite twice

Deriving `nodm/args.gn` from the DM host's copy inherited
`dart_version = 6b58bb3a72` — the DM host's own label disagrees with its own
dill, which is the exact defect class that produced the `engine_version` STOP
earlier in this lane. The derivation now takes `dart_version` from the Dart
checkout itself. `ninja` then reported **no work to do**, which measures
something worth keeping: `dart_version` has no dependency edge into these
archives, so it is a pure label and the bytes were already correct.

Honest note on freshness: the product zip is no longer newer than its
`args.gn`, because the label was corrected after the build. It is not stale —
ninja re-evaluated the whole graph under the corrected config and found the
outputs up to date, which is a stronger statement than an mtime comparison.

## CAUSAL CONTROL — a real compile + AOT, not header agreement

Identical candidate `gen_snapshot_arm64` (from H's `ios-release/artifacts.zip`)
in BOTH arms, so the host set is the only variable.

    POSITIVE  new 9e8 host set
              app.dill sdkHash 9e8c898a4d
              gen_snapshot exit=0            no SDK-hash rejection

    NEGATIVE  retired H 6b58 host set (published bytes)
              app.dill sdkHash 6b58bb3a72
              gen_snapshot exit=254
              "Can't load Kernel binary: Invalid SDK hash."

That is the exact release failure, reproduced on demand and then eliminated by
the corrected host lineage alone.

## const_finder lineage control

    new const_finder 3ebd1f3b9355ea41 + new 9e8 Dart
        -> FormatException: Option kernel-file is mandatory
        -> LOADED, reached Dart-level argument parsing
    old const_finder df54370e87950437 + new 9e8 Dart
        -> Can't load Kernel binary: Invalid SDK hash

This supersedes the LINEAGE SCOPE of step 7 without invalidating what step 7
proved: candidate beat stock, within the 6b58 lineage.

### The positive arm was VACUOUS on first run, and is recorded as such

`const_finder` is not in `zip_archives:artifacts` — the publisher injects it
from a separate `flutter/tools/const_finder` target, which had not been built.
So the first attempt ran `dart` against a NONEXISTENT file, got "Could not find
a command named …", and my check scored that as a successful load. Fixed by
building the target and by making the positive arm require a specific
Dart-level signal, with "file not there" scored as VACUOUS rather than PASS.

## font-subset regenerated, not reused

    new font-subset.zip   bbd2fb108a1b1cea5ad0e087a65c5270f9ceb37a20e942cc53556818f722b1f8
                          2,321,327 bytes
    const_finder inside   3ebd1f3b9355ea41   the CANDIDATE one
    font-subset inside    655400f0…fd66      byte-identical to upstream 83675ed2
    LICENSE inside        f982c1bf…fcac      byte-identical to upstream
    differs from H's      YES (H's was 11f7e106…d990)

The SDK-hash check ran against the NEW Dart and passed; `DART` was set, so it
was not skipped.

## Next

Stage the 16-member v2 cell — five corrected host members, everything else exact
cloned H bytes — and compute the real H2 in scratch first. The compiler bundle
must stay `9d4ace27…`. Nothing published; H remains RETIRED and immutable.
