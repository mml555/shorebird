# 2C.0a.1–.2 — marker written, retention MEASURED. The build is blocked on tooling.

Nothing certified moved. The engine fork is back on `route-b` at `619fdad1`, its
working tree carries the certified `shorebird.cc`, and `out/ios_release` is still
the certified build (`sha1 cc150ab6…`).

## The retention probe — run BEFORE choosing an attribute

Five candidate spellings, compiled with **this tree's pinned Clang**
(`flutter/buildtools/mac-arm64/clang`, Fuchsia clang 23) against the iOS SDK,
`-O2 -flto`, linked with `-Wl,-dead_strip`, in **both** an executable and the
`-shared` mode the framework actually uses:

    static const                       stripped
    __attribute__((used))              SURVIVED
    __attribute__((used, retain))      SURVIVED
    used + __DATA,__shorebird,
      regular,no_dead_strip            SURVIVED   <-- chosen
    used + visibility("default")       SURVIVED

**The probe is not vacuous: the plain `static const` was stripped**, so it can
detect removal.

The section form was chosen over the others because it is Darwin-native, states
the intent in the source, and **adds no exported symbol** (`nm -gU` shows none) —
so the framework's export table is unchanged and nothing can come to depend on
it as an interface.

Kept as `retention_probe.cc` so the choice can be re-checked against a future
toolchain rather than trusted.

## The marker

    branch    route-b-2c-candidate
    b456dc0d  docs-only candidate declaration
    dfa2b24a  the marker            <-- one commit on top, no rewrite

    engine/src/flutter/shell/common/shorebird/shorebird.cc

    #if defined(FML_OS_IOS)
    extern "C" {
    __attribute__((used, section("__DATA,__shorebird,regular,no_dead_strip")))
    const char kShorebirdRouteB2CCandidateMarker[] =
        "shorebird-route-b-2c-candidate-v1";
    }
    #endif

iOS only, never read, never logged, never branched on. **The Rust updater is
untouched** — `af6e842ccf87` is a separately certified provenance chain and must
not participate in a routing identity.

## Certified device slice, preserved before any build

    sha1     cc150ab64dbeef57be41fd7b1bd12bda5cb7e717
    sha256   62bd2395005cc3150d504d05b7efd9d3a4f6c14fff728cde49637d9f7f4f801c
    size     19,104,440
    af6e842ccf87                          1 occurrence
    shorebird-route-b-2c-candidate        0 occurrences

Copied aside so the candidate comparison is against a preserved artifact rather
than a rebuilt one, and so the certified build can be restored.

## BLOCKED — there is no usable `ninja` on this rig

    flutter/third_party/depot_tools/ninja   a shell wrapper for ninja.py
    ninja.py -> gclient_paths -> gclient_utils -> `import pipes`
    ModuleNotFoundError: No module named 'pipes'

`pipes` was removed in Python 3.13. `ninja.py` would then fall back to a `ninja`
on PATH, and there is none: `/opt/homebrew/opt/ninja` is a dangling symlink with
no Cellar directory behind it. No vendored `third_party/ninja/ninja` exists in
this checkout.

The 2026-08-27 build in `out/ios_release` predates whatever removed it.

**This is environment repair, not qualification work**, and it is a system-level
mutation on a shared rig, so it was not performed. The fix is one command
(`brew install ninja`), or a `pipes` shim on `PYTHONPATH` **plus** a ninja binary
— the shim alone is not enough, because the fallback still needs a real binary.

## What is ready to run the moment ninja exists

    ninja -C out/ios_release            incremental; only shorebird.cc changed
    sha1(candidate device slice)        must differ from cc150ab6…
    marker present in candidate         and absent from the preserved certified
    af6e842ccf87 unchanged              updater provenance must not move

Then the candidate Flutter pins `bin/internal/engine.version` to that measured
sha1, and the cell publishes under the same value.

## Ledger, re-verified

    engine fork HEAD    619fdad176ff4573…  on `route-b`
    working tree        certified shorebird.cc (marker absent)
    out/ios_release     cc150ab64dbeef57…  unchanged
    published cell      0696da541c2b9a9d…  unchanged
    compatibility.yaml  42a970f46a234794…  unchanged
    installed CLI       207c4a7ac91f937e…  unchanged
    experimental map    7bdc97bf9ed27082…  unchanged
