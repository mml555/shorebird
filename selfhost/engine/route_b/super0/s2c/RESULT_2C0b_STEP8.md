# D-SUPER-2C.0b · Step 8 — map H and activate

    H = a5a8be5854c529268378ce16762a16d6e31763e9

## VERDICT — PASS. All five acceptance parts hold; AUDIT CLEAN after activation.

## Three identities, kept separate

    candidate selfhost engine     a5a8be5854c529268378ce16762a16d6e31763e9
    map fallback (pinned SHOREBIRD engine)
                                  69f9831c360d9152862ec3897c67fb09ae843f3b
    artifacts_manifest Flutter base (UPSTREAM)
                                  83675ed27633283e7fc296c8bca22e841224c096

The map entry uses the pinned Shorebird engine, NOT the upstream Flutter base.

## Pre-mutation bank

    experimental_hashes.map sha256  7bdc97bf9ed27082f097c8da7058c6083ca7161aa76e7194bb869f09cddd932c
    cdn-cache        container 8313e4bff321  image fa127f1f052e
    artifact-proxy   container e35efc5947c0  image 0719c42487a8
    audit                            CLEAN

## Mutation — one line

    a5a8be5854c529268378ce16762a16d6e31763e9 69f9831c360d9152862ec3897c67fb09ae843f3b

Appended with a descriptive comment block, matching the file's convention
(chronological, each entry introduced by its own comment). Entries 43 -> 44.

    map sha256 after   6b52fc927874dcb8a8bcdc4cb442a2557f3e43f269049b5fb32434d7f6152d98

## Activation — cdn-cache only

    docker compose -f selfhost/cdn/docker-compose.cdn.yaml \
      up -d --no-deps --force-recreate cdn-cache

    cdn-cache       container 8313e4bff321 -> 3746c3211b4d   RECREATED
                    image     fa127f1f052e -> fa127f1f052e   SAME, not rebuilt
    artifact-proxy  container e35efc5947c0 -> e35efc5947c0   UNTOUCHED
                    started   02:01:04Z    -> 02:01:04Z      UNTOUCHED

No image rebuild, no volume change.

## PART 1 — candidate-owned bytes still win: 10/10

All 200 with `X-Overlay: hit`. Load-bearing members re-hashed against banked
values rather than status-checked:

    sky_engine.zip                     7e440994…f6e9   MATCH
    darwin-arm64/font-subset.zip       11f7e106…d990   MATCH
    route-b-compiler-darwin-arm64.zip  9d4ace27…9c59   MATCH
    patch-linux-x64.zip                fdc4e9ef…cc1d   MATCH
    flutter_gpu.zip                    9bd35eff…b787   MATCH
    artifacts_manifest.yaml            eb6969bf…2c3c   MATCH
    patch-darwin-x64.zip               0dda5145…3c20   MATCH

Also 200/hit: `ios-release/artifacts.zip`, `darwin-arm64/artifacts.zip`,
`patch-darwin-arm64.zip`.

## PART 2 — ownership is ON

    sky_engine.zip   X-Overlay: hit   X-Engine-Hash: <H>   7e440994…f6e9
    flutter_gpu.zip  X-Overlay: hit   X-Engine-Hash: <H>   9bd35eff…b787

The stronger proof is PART 4: three paths matched by `@must_be_local` but NOT
owned by H return a hard 404. That matcher's expression requires
`stock_engine_hash != ""`, so those 404s are only possible BECAUSE H is mapped —
before mapping they would have fallen through to stock. Protection is live, not
merely configured.

## PART 3 — legitimate fallback still works

FIRST ATTEMPT WAS VACUOUS AND IS RECORDED AS SUCH. `ios/artifacts.zip` returned
504 under BOTH H and the pinned hash, and the two 21-byte timeout bodies hashed
equal — a comparison that "passed" while proving nothing. The artifact is large
and the upstream fetch exceeded the gateway deadline.

Redone with the artifact policy's actual compat-mirrored entry for this cell —
`patch-windows-x64.zip`, "no Windows builder; recorded gap", deliberately
outside `@must_be_local`:

    under H        HTTP 200  276,334 B  90c2ee05…cbc2
    under pinned   HTTP 200  276,334 B  90c2ee05…cbc2   IDENTICAL
    X-Overlay under H   (absent)        -> not overlay bytes
    present in overlay under H?  NO     -> unowned, as policy intends
    members        patch.exe            -> a real artifact, not an error body

The H -> 69f9831c fallback resolves. The cell is not an overlay-only island.

## PART 4 — denied paths are loud

    dart-sdk-linux-x64.zip      HTTP 404  (30-byte body)
    linux-x64/artifacts.zip     HTTP 404
    windows-x64/artifacts.zip   HTTP 404

Loud misses, not stock bytes. No cross-toolchain mixing.

## PART 5 — post-activation audit

    missing-required: 0   unprotected: 0   denied-present: 0
    AUDIT CLEAN for a5a8be5854c529268378ce16762a16d6e31763e9 (macos-ios)

The pre-map audit proved files and policy are coherent; these serving checks
prove Caddy now enforces that coherence.

## Next

Resolution preflight — all five must agree through the isolated CLI:

    candidate Flutter revision  371005c93a7c927b34bbd727eb2c4951f0ef090d
    engine.version              H
    release provenance.engineRevision  H
    served engine               H
    served compiler cell        H
    capability                  routeBDirectSuperDualKernelV1

Candidate release and 2C.1 A/B/C remain BLOCKED until that passes.

Linux evidence clone at `/data/shorebird-engine/route-b-2c-linux/` RETAINED
through step 8, the preflight and 2C.1, then removed with the removal recorded.
