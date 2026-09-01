# D-SUPER-2C.1 · ADDRESS-V2 — route-b-cell-v2 QUALIFIED

    55 PASS / 0 FAIL       selfhost/engine/route_b/qualify_cell_address_v2.sh

No engine build, no host rebuild, no mint, no publication, no map mutation.

## What v2 is

    address_schema route-b-cell-v2
    cell macos-ios
    fallback_engine_revision 69f9831c360d9152862ec3897c67fb09ae843f3b
    <canonical %H path> <sha256 of the exact staged bytes>
    ...                                                     sorted

    address = first 40 hex of sha256(canonical manifest bytes)

The schema marker is the first line, so a v2 cell cannot collide with a v1
address even if every remaining digest coincided. v1 addresses are NOT
recomputed or reinterpreted: they stay immutable and keep meaning whatever their
old manifest covered.

## Membership derives from artifact_policy.conf — 16 members

    every path applicable to macos-ios (cell = macos-ios or both)
      with requirement = required
      and provenance in {owned-built, owned-mirrored}
    PLUS route-b-compiler-darwin-arm64.zip

The compiler is `optional` in the generic policy only because non-Route-B hashes
exist; for this tool it is mandatory and its own archive digest participates.

A hand-written list is exactly how v1 fell behind, so there is no second list.
If the policy gains another required, locally-owned artifact tomorrow, a v2 mint
cannot succeed without addressing it — proven by control E, not asserted.

## Self-referential metadata, without a fixed point

Staged trees mirror the overlay with a LITERAL `%H` directory, so the bytes
hashed are the bytes published. Metadata is staged as a `%H` template, hashed as
such, rendered to the real hash for publication, then canonicalized back and
required to re-digest identically.

The canonicalizer knows the permitted hash-bearing fields and refuses anything
else:

    engine_stamp.json        only as the "git_revision" value
    artifacts_manifest.yaml  comment lines only -- flutter_engine_revision is
                             the UPSTREAM Flutter base and must never be the
                             cell hash, so a hit on a data line is a defect
    everything else          no permitted field; any occurrence refuses

## Controls

    membership   all five STOP artifacts + compiler present         6 PASS
    A legacy     schema marker changes the address vs a v1-shaped
                 digest over the identical member set               PASS
    B determinism  manifest bytes and address identical twice       2 PASS
    C sensitivity  EVERY one of the 16 members moves the address    16 PASS
    D refusal      EVERY missing member refuses the mint            16 PASS
    E policy       a synthetic required line joins membership, and
                   generation refuses until its file exists         2 PASS
    F compiler     absent compiler refuses despite policy=optional  PASS
    G canonical    permitted fields accepted, all others refused    5 PASS
    H CONTRAST     v1 is blind to 4 of the 5; v2 addresses all 5    6 PASS

Control H is the one that stops this from being self-congratulatory: if v2's
sensitivity test would also pass under v1, it would prove nothing about the
defect that forced the schema. It re-measures v1's own membership from the
product and requires exactly the measured gap — blind to `dart-sdk-*.zip`,
`darwin-arm64/artifacts.zip`, `flutter_patched_sdk.zip` and `font-subset.zip`,
sighted (indirectly) on the platform dill.

The harness sources `mint_route_b_cell.sh` with `MINT_CELL_LIB_ONLY` so it
exercises THE PRODUCT'S generator, never a copy.

### A defect found in the harness itself

Sourcing the product imports its `set -euo pipefail` into the harness shell.
Under `-e` the first non-zero status — a `grep -c` legitimately counting zero —
ended the run mid-control, printing control H's header and then nothing. It did
not go green-but-wrong, but it silently dropped a control. A test must own its
failure policy, so the harness now restores `set +e` explicitly and the counting
greps are `|| true`.

## Tool structure — v1 cannot publish

    --address-schema v2   default, and the only value that may publish
    --address-schema v1   forensic ONLY; refuses without --dry-run
    anything else         refused

Verified:

    --address-schema v1            -> ERROR: forensic only …
    --address-schema v9            -> ERROR: must be v1 or v2

## Consequence for H2

Under v2 the repaired host lineage NECESSARILY moves the address, even though
the compiler bundle stays byte-identical at `9d4ace27…`, sky_engine/flutter_gpu
and all three iOS modes are cloned unchanged from H, and
`flutter_platform_strong.dill` is already the correct `9e8c898a4d`. That was the
precise thing v1 could not express.

## Not done, deliberately

v2 is qualified as an ADDRESS SCHEME. It is not yet wired into the mint's
publish flow, and no cell has been minted with it. H remains RETIRED and its
bytes untouched.
