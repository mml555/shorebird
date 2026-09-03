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
