# D-SUPER-2C.1 · H2-ACTIVATION — AUDIT CLEAN

    H2       = 64ff9f592ae319eea04db6092b71319d4778b873
    fallback = 69f9831c360d9152862ec3897c67fb09ae843f3b

## Pre-mutation bank

    Caddyfile                 508e76db959316485c4e37f5a1160bb4a17ce9988315c44878ff87983fcad97e
    experimental_hashes.map   6b52fc927874dcb8a8bcdc4cb442a2557f3e43f269049b5fb32434d7f6152d98
    cdn-cache        f73f82278101 / fa127f1f052e / 18:13:47.934835084Z
    artifact-proxy   e35efc5947c0 / 0719c42487a8 / 18:13:47.923907459Z

## 1. H2-specific protection

Added to `@must_be_local_pkgs` only:

    …|a5a8be58…|64ff9f59…)/(sky_engine|flutter_gpu)\.zip
    |a5a8be58…/(ios|ios-profile)/artifacts\.zip
    |64ff9f59…/(ios|ios-profile)/artifacts\.zip

H's entries untouched. The global `[0-9a-f]{40}` matcher was NOT broadened — H2
appears in it zero times.

## 2. Map

    64ff9f592ae319eea04db6092b71319d4778b873 69f9831c360d9152862ec3897c67fb09ae843f3b

Entries 44 -> 45. Introduced by a comment block naming the schema
(`route-b-cell-v2`), the five-member delta from retired H, the manifest path
that recomputes the address, and the distinction between the pinned SHOREBIRD
fallback and the upstream Flutter base `83675ed2` that `artifacts_manifest.yaml`
names. H REMAINS MAPPED — retired as a promotion target, not erased.

    map sha256 after   b952abd1e8e73d9576f70894bba14955660be97470de7d81aaad2b85d7901e1c

## 3. Activation — cdn-cache only

    cdn-cache        f73f82278101 -> bd01e42b3dab      RECREATED
                     image fa127f1f052efee271dee5d414341038101cb91943fea76ea299ea9962f53b20
                     unchanged
    artifact-proxy   e35efc5947c0 -> e35efc5947c0      UNTOUCHED
                     started 18:13:47.923907459Z -> identical

No image rebuild, no volume mutation.

## 4. Post-activation whole-cell verification — 16/16

    16/16 HTTP 200
    16/16 X-Overlay: hit
    14 compared by exact sha256 to cell_manifest.v2
     2 metadata members fetched rendered, canonicalized H2 -> %H, canonical
       digests equal to the manifest entries

Re-checked values, as served AFTER activation:

    dart-sdk           cf5551883d9f7f3f15ca712600ef6053c9dd1e7a48225d21ad6abc25db51f166
    darwin-arm64/art   59884426060bebafd950213928f2a77282363494b5a493fe85cec30adac395f3
    font-subset        3094baa9c913ceca7b8cc9701ebb3df9bcfd61ffe5c4386e1026504c5f7db1f7
    route-b compiler   9d4ace27d6d6b77c0bad6d0cbc318f4b4a4b74c59f3462407d688843ee779c59

Served-archive lineage:

    product platform dill      9e8c898a4d
    debug   platform dill      9e8c898a4d
    font-subset const_finder   3ebd1f3b9355ea419cd80d7afa3dbfa491cb998956ce1998c8896ef7a5a3380f

## 5. Mapping behaviour, beyond overlay hits

FALLBACK — `patch-windows-x64.zip`, the policy's compat-mirrored entry for this
cell, deliberately outside `@must_be_local`:

    under H2        HTTP 200, 276,334 bytes
    under pinned    HTTP 200, 276,334 bytes
    bytes identical YES
    X-Overlay       absent under H2  -> not overlay bytes
    in overlay      NO               -> unowned, as policy intends
    members         patch.exe        -> a real artifact, not an error body

So `H2 -> 69f9831c` actually resolves; the cell is not an overlay-only island.

DENIED — foreign host toolchains stay loud:

    dart-sdk-linux-x64.zip     404
    dart-sdk-darwin-x64.zip    404
    dart-sdk-windows-x64.zip   404

30-byte bodies, not stock bytes. Activation did not reopen a cross-toolchain
fallback.

## 6. Audit

    owned-built        16
    owned-mirrored     0
    compat-mirrored    1
    denied             4
    missing-required   0
    unprotected        0
    denied-present     0

    AUDIT CLEAN for 64ff9f592ae319eea04db6092b71319d4778b873 (macos-ios)

The four UNPROTECTED findings from the publication step are closed by the
per-hash protection above. Policy was not altered.

H is also still CLEAN and unaffected by the activation.

## Not done

Pins unchanged, release not retried.

    release                      DOES NOT EXIST
    provenance.engineRevision    NOT CLAIMED

Next lane is tracked H2 resolution: a new Flutter commit off `371005c9` moving
`engine.version` H -> H2, a new candidate CLI commit pointing `flutter.version`
at it, both remote-banked, then empty-cache precache, then the local canonical B
`flutter build ipa`, and only then `shorebird release ios`.
