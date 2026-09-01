# D-SUPER-2C.1 · REAL-H2-STAGE — H2 earned in scratch

    H2 = 64ff9f592ae319eea04db6092b71319d4778b873

Nothing published live. H remains RETIRED and immutable; the live overlay was
not written and H2 is not in the map — both asserted, not assumed.

## The address, independently recomputable

    selfhost/engine/route_b/super0/s2c/h2_address/
        cell_manifest.v2                    the exact addressed bytes
        cell_manifest.v2.OLD-H-BASELINE     H's own composition under v2
        address_provenance.txt

    shasum -a 256 cell_manifest.v2 | cut -c1-40  ->  64ff9f592ae319eea04db6092b71319d4778b873

    address_schema           route-b-cell-v2
    cell                     macos-ios
    fallback_engine_revision 69f9831c360d9152862ec3897c67fb09ae843f3b
    artifact_policy.conf     42a70f68854e81d3beedcf94f6892f117ee52853f0d3f8c0a598cdb22b0b91da
    members                  16

## CAUSAL CONTROL — the corrected host lineage moves the whole-cell address

    H's own 16 members under v2   f98951cdde2b79e93ce10bd21c5e138cfcab3f26
                                  == the PUBLISH-V2 baseline, reproduced exactly
    same cell, five host members replaced
                                  64ff9f592ae319eea04db6092b71319d4778b873
    H2 != baseline                YES

Reproducing the baseline exactly matters as much as the difference: it shows the
staging is faithful, so the delta is attributable to the five replacements and
nothing else.

Manifest diff — exactly 5 changed, 11 untouched:

    dart-sdk-darwin-arm64.zip        b99426af…de0b -> cf551188…f166
    darwin-arm64/artifacts.zip       8c3c38ab…873c -> 59884426…95f3
    darwin-arm64/font-subset.zip     11f7e106…d990 -> 3094baa9…b1f7
    flutter_patched_sdk.zip          213948fe…c9e9 -> c04ea2f7…00fe
    flutter_patched_sdk_product.zip  774bb4b6…cea6 -> d2460d13…fafc

Route B compiler unchanged and verified before staging:

    9d4ace27d6d6b77c0bad6d0cbc318f4b4a4b74c59f3462407d688843ee779c59

## Real-byte sensitivity on the two causal archives

    mutate 1 byte, dart-sdk-darwin-arm64.zip   -> 8a2468bd06cdd2c4…   moved
    mutate 1 byte, darwin-arm64/artifacts.zip  -> 97eee4ea66bb37b6…   moved

These are the two that carried the failing frontend/runtime boundary.

## Render / reconstruction gate

    dry-run address                    64ff9f59…b873   == H2
    banked manifest recomputes         64ff9f59…b873
    manifest before render == manifest reconstructed from the rendered tree
                                       enforced inside v2_transaction

## Pre-protection audit shape (scratch overlay)

    owned-built        16
    missing-required   0
    denied-present     0
    non-UNPROTECTED findings   0
    compat-mirrored    1

Caddy was NOT modified to make this clean.

## Lineage observables carried by the five corrected members

    product platform dill sdkHash   9e8c898a4d
    debug   platform dill sdkHash   9e8c898a4d
    const_finder                    3ebd1f3b9355ea419cd80d7afa3dbfa491cb998956ce1998c8896ef7a5a3380f
    font-subset.zip                 3094baa9c913ceca7b8cc9701ebb3df9bcfd61ffe5c4386e1026504c5f7db1f7
      const_finder inside           3ebd1f3b…380f   the candidate one
      font-subset inside            655400f0…fd66   byte-identical to upstream 83675ed2
      LICENSE inside                f982c1bf…fcac   byte-identical to upstream

## SUPERSEDED VALUE — font-subset.zip

The HOST-COHERENCE ledger banked `bbd2fb108a1b1cea…f722b1f8`. That artifact no
longer exists: the session scratchpad holding it was wiped mid-lane, and the
archive was regenerated. **`3094baa9c913ceca…5f7db1f7` is the artifact that will
be published**, and it is the one addressed by H2.

Its COMPOSITION is unchanged — same candidate const_finder, same upstream binary
and licence, all three verified above. Only the container bytes differ.

Reproducibility was measured rather than assumed: two back-to-back runs produced
byte-identical archives, so packaging is deterministic within an environment,
and the difference came from regenerating across the scratchpad loss. This is
exactly why the v2 rule is package ONCE, stage exact bytes, address them, and
publish those same bytes — the staged `darwin-arm64/artifacts.zip` likewise
carries its injected const_finder from a single `zip` run and must not be
re-injected at publish time.

Work now lives at `/Volumes/build/route-b/h2work/`, not the session scratchpad,
so a second wipe cannot cost the staged bytes.

## Not done

No live publication, no protections, no map entry. That is the next transition
and is deliberately separate, so H2's exact address inputs are banked before any
mutation.
