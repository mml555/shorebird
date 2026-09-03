# Gate 6C — one new v2 cell, one changed member

    new cell   cd848320d605ff8af5060cabf9a8d1b35853f752
    donor      d4c0dbc2905286eb4537d5f9a7802693096ca1fd   (H3, untouched)
    fallback   69f9831c360d9152862ec3897c67fb09ae843f3b   (stock engine)

## The delta is exactly one member

    route-b-compiler-darwin-arm64.zip
      H3   39ad75dd7342e9e26370d3dab834d3770e612b238103c85cadf03d3a61e93e74
      new  7975b27c724240e720f77d338c80fcace5296148bd78c17588cee1b089e3fb22   (gate 6A frozen)

Of the 16 addressed members: **13 are H3's exact published bytes**, copied from
the overlay rather than rebuilt. The remaining two — `engine_stamp.json` and
`artifacts_manifest.yaml` — are self-referential, so they were canonicalized back
to their `%H` templates before addressing. That they are otherwise unchanged was
PROVEN rather than assumed: rendering each staged template with H3's hash
reproduces H3's published bytes exactly.

The compiler archive was frozen BEFORE addressing (6A). `zip` stamps mtimes and
`route_b_analyze.aot` is not byte-reproducible, so re-staging at publish time
would have published different bytes than were addressed — the same trap
`stage_h2_cell.sh` records for the const_finder injection.

## Address determinism

    run 1  cd848320d605ff8af5060cabf9a8d1b35853f752
    run 2  cd848320d605ff8af5060cabf9a8d1b35853f752

19 manifest lines: 3 preamble + 16 members, no duplicates.

## Publication and verification

    PUBLISH-V2 transaction   stage -> address -> render -> verify -> publish
    served-byte fetch-back   14/16 byte-identical as served; the two
                             self-referential members canonicalize to exactly
                             the bytes the address was computed over. 16/16.
    descriptor               cell-manifests/cd848320….v2, and sha256 of the
                             SERVED descriptor is cd848320… — it self-
                             authenticates over the wire, not just on disk
    local protection         added beside H3 in both @must_be_local_pkgs
                             regexes; `caddy validate` reports Valid
                             configuration; serving config reloaded
    ancestry map             cd848320… -> 69f9831c…, with the one-member
                             delta recorded

## The audit finding, stated precisely

    FINDING: records engine dfa2b24ac384… but is published under cd848320…
    AUDIT FINDINGS: 1

**H3 produces the identical finding** (`records engine a5a8be58… but is
published under d4c0dbc2…`, AUDIT FINDINGS: 1). The compiler archive records its
PRODUCER ENGINE, never its cell address — cell membership is carried by the
descriptor — which `experimental_hashes.map` already states in H3's own note. So
this cell audits exactly as the certified one does, and the honest claim is
"identical in kind to certified H3", not "zero findings".

## H3 untouched

    H3 descriptor  d4c0dbc2905286eb4537d5f9a7802693096ca1fd (self-authenticating, unchanged)
    H3 compiler    39ad75dd… unchanged

---

# REPAIR — the protection regex regression I introduced

Caught in review, not by me. Adding the new cell with a blind
`s/<H3>/<H3>|<new>/` substitution edited INSIDE a regex and broke grouping:

    before   …|d4c0dbc2…/(ios|ios-profile)/artifacts\.zip|…
    after    …|d4c0dbc2…|cd848320…/(ios|ios-profile)/artifacts\.zip|…

The expression is end-anchored, so `d4c0dbc2…` became an alternative that can
only match a path which IS that bare hash. **H3's `ios/artifacts.zip` and
`ios-profile/artifacts.zip` stopped being protected**, while the file still
parsed and `caddy validate` still said Valid. The claim in the original row that
H3's protection was unchanged was therefore false.

The `sky_engine|flutter_gpu` arm was unaffected, because H3 already sat inside a
group there — which is exactly why one of the two edits was fine and the other
was not.

## Repaired by grouping

    (d4c0dbc2905286eb4537d5f9a7802693096ca1fd|cd848320d605ff8af5060cabf9a8d1b35853f752)/(ios|ios-profile)/artifacts\.zip

## Mechanical validation, so this cannot recur silently

`selfhost/cdn/check_protection_matchers.py` reads the matchers out of the
Caddyfile and evaluates a table of concrete paths, asserting COVERAGE rather
than syntax: 20 paths that must be protected, 4 that must not be.

Verified red-first against the broken committed file:

    against ad733f97's Caddyfile
      NOT PROTECTED (should be): …/d4c0dbc2…/ios/artifacts.zip
      NOT PROTECTED (should be): …/d4c0dbc2…/ios-profile/artifacts.zip
      MATCHER COVERAGE FAILED: 2

    against the repair
      MATCHER COVERAGE OK

It names the same two paths the review did.

## Behavioural checks, against the running server

Protected artifacts serve their published bytes (local request), both cells:

    d4c0dbc2  ios/artifacts.zip          200  bytes match published
    d4c0dbc2  ios-profile/artifacts.zip  200  bytes match published
    d4c0dbc2  sky_engine.zip             200  bytes match published
    d4c0dbc2  flutter_gpu.zip            200  bytes match published
    cd848320  ios/artifacts.zip          200  bytes match published
    cd848320  ios-profile/artifacts.zip  200  bytes match published
    cd848320  sky_engine.zip             200  bytes match published
    cd848320  flutter_gpu.zip            200  bytes match published

Owned but not published — must 404 rather than fall through, both cells:

    d4c0dbc2  android-arm64-release/artifacts.zip  404  "overlay miss on owned artifact"
    d4c0dbc2  darwin-x64/artifacts.zip             404  "overlay miss on owned artifact"
    cd848320  android-arm64-release/artifacts.zip  404  "overlay miss on owned artifact"
    cd848320  darwin-x64/artifacts.zip             404  "overlay miss on owned artifact"

And a stock unmapped hash still resolves (69f9831c sky_engine.zip -> 200), so
the 404s are ownership rather than a broken server.

Digests unchanged by the repair: both descriptors still self-authenticate, H3's
compiler is still 39ad75dd…, the new cell's is still 7975b27c….
