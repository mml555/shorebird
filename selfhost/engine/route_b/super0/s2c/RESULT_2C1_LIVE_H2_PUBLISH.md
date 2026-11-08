# D-SUPER-2C.1 · LIVE-H2-PUBLISH — H2 published, 16/16 served identity verified

    H2 = 64ff9f592ae319eea04db6092b71319d4778b873

Published from the existing staged bytes only. Nothing rebuilt, regenerated,
re-zipped or re-injected. H2 is NOT activated.

## Pre-publication gate — PASS

Against the manifest committed at `c860607f`:

    16/16 staged members agree                        OK
    artifact_policy.conf  42a70f68…91da                OK
    recomputed address    64ff9f59…b873                OK
    manifest bytes identical to the committed one      OK
    route-b-compiler      9d4ace27…9c59                OK
    live H2 destinations absent (both roots)           OK

The two metadata members were compared as their canonical `%H` bytes; the other
fourteen by exact sha256.

## Publication

`v2_transaction()` against the live overlay, exit 0, address produced exactly
`64ff9f592ae319eea04db6092b71319d4778b873`. No manual `cp`, no fallback to the
v1 mint path. 16 files across the two hash roots.

## Served identity — 16/16 verified through :8085

Every member fetched, all HTTP 200 with `X-Overlay: hit`. Fourteen compared by
exact sha256 to the manifest; `engine_stamp.json` and `artifacts_manifest.yaml`
fetched as rendered H2 files, canonicalized back to `%H`, and their canonical
digests compared to the manifest entries.

The five corrected members, as SERVED:

    dart-sdk-darwin-arm64.zip        cf5551883d9f7f3f15ca712600ef6053c9dd1e7a48225d21ad6abc25db51f166
    darwin-arm64/artifacts.zip       59884426060bebafd950213928f2a77282363494b5a493fe85cec30adac395f3
    darwin-arm64/font-subset.zip     3094baa9c913ceca7b8cc9701ebb3df9bcfd61ffe5c4386e1026504c5f7db1f7
    flutter_patched_sdk.zip          c04ea2f78e215b69c44e6efadf1d60091ddb33071b7eb7e7e674d3fdfb8b00fe
    flutter_patched_sdk_product.zip  d2460d13d6c1d49e0562446578393e1038658d99ac92a9010e43f19404e7fafc

    route-b-compiler (unchanged)     9d4ace27d6d6b77c0bad6d0cbc318f4b4a4b74c59f3462407d688843ee779c59

## Served-content lineage — the repair survived publication

Read out of the SERVED archives, not the staged ones:

    product platform dill sdkHash    9e8c898a4d
    debug   platform dill sdkHash    9e8c898a4d
    font-subset const_finder         3ebd1f3b9355ea419cd80d7afa3dbfa491cb998956ce1998c8896ef7a5a3380f
    font-subset binary               655400f0…  upstream 83675ed2, unchanged

## NOT activated — the boundary this step stops at

    H2 in experimental_hashes.map    0
    H2 in Caddyfile protection       0
    cdn-cache                        not recreated (f73f82278101, unchanged)
    Flutter / CLI pins               unchanged
    release                          not retried

    H artifacts                      intact
    H map entry                      untouched

## Audit shape — as expected for a published, unprotected cell

    owned-built        16
    missing-required   0
    denied-present     0
    compat-mirrored    1
    non-UNPROTECTED findings   0
    UNPROTECTED findings       4   sky_engine, flutter_gpu, ios, ios-profile

Those four are H2-scoped protection entries that do not exist yet. Policy was
NOT altered to make the audit clean.

## Transcription corrections, with the repo manifest as authority

The ruling froze two values that do not match the committed manifest:

    dart-sdk    ruling said cf555188…   manifest cf5551883d9f7f3f…   ruling CORRECT
                (an earlier message of mine said cf551188… — that was wrong)
    font-subset ruling said 3094baa9c913ceca7b8c1ebb3df9bcfd… (60 chars)
                manifest    3094baa9c913ceca7b8cc9701ebb3df9bcfd61ffe5c4386e1026504c5f7db1f7
                the ruling's copy is missing `c970`; the manifest value is the
                one published and verified as served

`bbd2fb10…` remains historical/superseded and is not an acceptance value.

## Next transition, not started

    H2-specific Caddy protection for sky_engine, flutter_gpu, ios, ios-profile
    -> map H2 -> 69f9831c
    -> recreate cdn-cache only
    -> post-activation 16-member serving verification
    -> AUDIT CLEAN
