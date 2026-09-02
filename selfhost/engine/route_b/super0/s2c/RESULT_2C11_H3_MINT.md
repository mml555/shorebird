# D-SUPER-2C.1 · H3-MINT — successor cell published, AUDIT CLEAN

    H3 = d4c0dbc2905286eb4537d5f9a7802693096ca1fd
    predecessor H2 = 64ff9f592ae319eea04db6092b71319d4778b873

    compiler  9d4ace27… -> 39ad75dd7342e9e26370d3dab834d3770e612b238103c85cadf03d3a61e93e74
    analyzer  799a0796… -> 18862acd…

## H3.1 — EXACT 1/16 delta

Staged from H2's PUBLISHED bytes, with one substitution: the frozen Gate 3/4
archive. `publish_route_b_compiler.sh` was NOT invoked again.

    members 16   unchanged 15   changed 1

    download.shorebird.dev/shorebird/%H/route-b-compiler-darwin-arm64.zip
      old 9d4ace27d6d6b77c0bad6d0cbc318f4b4a4b74c59f3462407d688843ee779c59
      new 39ad75dd7342e9e26370d3dab834d3770e612b238103c85cadf03d3a61e93e74

No second member differs, so nothing needed classifying.

## H3.2 — address movement, deterministic

    run 1  d4c0dbc2905286eb4537d5f9a7802693096ca1fd
    run 2  d4c0dbc2905286eb4537d5f9a7802693096ca1fd
    manifest bytes identical across runs
    H3 != H2

The manifest diff against H2's is ONE LINE — the compiler digest. So this is a
real-world sensitivity control for ADDRESS-V2: a single member moved, and the
whole-cell address moved with it, mechanically visible in the preimage.

## H3.3 — PUBLISH-V2, unmodified

    dry-run address        d4c0dbc2…  == H3
    banked manifest recomputes to H3
    artifact_policy.conf   42a70f68854e81d3beedcf94f6892f117ee52853f0d3f8c0a598cdb22b0b91da
    members recorded       16
    destinations checked absent beforehand
    transaction exit 0, 16 files across the two hash roots

Manifest-before-render == manifest-reconstructed-from-final-tree is enforced
inside the transaction; the dry-run and live runs both produced exactly H3.

## H3.4 — fetch-back, served objects only

    16/16   HTTP 200, X-Overlay: hit, digests equal to the addressed manifest
    served compiler   39ad75dd…   MATCH
    other 15 served   byte-identical to H2's members   15/15

Not inferred from the overlay filesystem.

## H3.5 — descriptor, protection, activation, audit

The descriptor is REQUIRED, not optional: without it the resolver falls to the
v1 equality rule, and the archive records producer engine `a5a8be58…`, which is
not H3 — so H3 would be unresolvable. Published byte-identical, 16 `%H`
preserved, and it self-authenticates:

    sha256(descriptor)[0:40] = d4c0dbc2905286eb4537d5f9a7802693096ca1fd = H3

    protection   H3 added to @must_be_local_pkgs for sky_engine|flutter_gpu and
                 (ios|ios-profile)/artifacts.zip. H2's entries untouched; the
                 global matcher NOT broadened.
    map          d4c0dbc2… -> 69f9831c…
    activation   cdn-cache recreated only

    expected paths      sky_engine 200, ios/artifacts 200,
                        compiler 200, descriptor 200
    protected missing   dart-sdk-linux-x64.zip 404
                        nonexistent descriptor 404

    owned-built 16   missing-required 0   denied-present 0   unprotected 0
    AUDIT CLEAN for d4c0dbc2905286eb4537d5f9a7802693096ca1fd (macos-ios)

Full CLEAN, as required for a real published cell — the scratch-audit exception
does not apply here.

## H3.6 — no consumption claimed

    releases            139 (1.0.0+1) and 140 (1.0.1+2), both flutter 8427e3da
    release 140 route_b.json engineRevision   64ff9f59…  (still H2)
    no release or patch claims H3

The compiler is NOT called "consumed". H3 merely CONTAINS it. That claim is
earned when a real release or patch path resolves H3 and executes the archive.

## Unchanged

    H2                 AUDIT CLEAN, compiler still 9d4ace27…, 16 members intact
    releases 139/140   untouched, no metadata changed
    frozen archive     39ad75dd… unchanged after the mint
    host toolchain     not rebuilt; not indicated by this defect
