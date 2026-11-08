# D-SUPER-2C.1 · CELL-BINDING-V2 CDN — END-TO-END CERTIFIED

    H2 = 64ff9f592ae319eea04db6092b71319d4778b873

No H2 member changed, no new release, release 139 untouched.

## 1. Descriptor published, exact bytes

    source  selfhost/engine/route_b/super0/s2c/h2_address/cell_manifest.v2
    dest    download.shorebird.dev/shorebird/cell-manifests/<H2>.v2
    size    2,074 bytes
    digest  sha256(...)[0:40] = 64ff9f59…b873   SELF-AUTHENTICATES

No rendering: the 16 `%H` strings are part of the authenticated preimage and
were preserved verbatim.

The descriptor is NOT a member of the cell it addresses — `cell-manifests`
appears 0 times in `cell_manifest.v2`. A descriptor inside its own manifest
would make the address depend on itself.

## 2. `cell-manifests/` is local-only

New `@cell_manifest` matcher and handler in the Caddyfile, placed after
`@overlay_hit` (which serves present files) and before every fallback. NOT
gated on `{stock_engine_hash}`: a descriptor is meaningful before its cell is
mapped, and no upstream has ever held a self-hosted cell descriptor, so a
fallback could only serve something that is not the requested preimage.

    present    HTTP 200, X-Overlay: hit, exact committed bytes
    absent     HTTP 404, body "no such route-b cell descriptor (local-only
               namespace)", no X-Overlay, no Location

## 3. The real fetcher, three states

`route_b_compiler_cache.dart` gained `_fetchCellManifest`:

    200            -> the descriptor, for the resolver to authenticate
    404            -> null, genuine absence, selects v1
    anything else  -> THROW

Transport failure, 5xx, unexpected redirect and truncation are NOT absence.
Collapsing them would reproduce the absent-vs-invalid defect one layer down.
The descriptor is never promoted to a persistent cache: it is written to a temp
file only because the resolver takes a `File`.

## 4. END-TO-END through the real CDN, from an empty compiler cache

Driven through the PRODUCTION `RouteBCompilerResolver`, with an
instrumented client recording every request:

    REQUESTS, in order
      1  /download.shorebird.dev/shorebird/cell-manifests/<H2>.v2
      2  /download.shorebird.dev/shorebird/<H2>/route-b-compiler-darwin-arm64.zip

    RESULT                    ACCEPTED
    bundle archive sha256     9d4ace27d6d6b77c0bad6d0cbc318f4b4a4b74c59f3462407d688843ee779c59
    producer lineage          a5a8be5854c529268378ce16762a16d6e31763e9
    eight members             8 of 8 present and hash-verified
    dart2bytecode + flutter   PASS
    dual-kernel capability    true

Descriptor-before-compiler ordering is therefore observed on the wire, not only
in-process.

## 5. Negatives, on the real network

    served MALFORMED descriptor
      RESULT REFUSED — "the cell descriptor is not route-b-cell-v2
                        (first line: address_schema something-else)"
      REQUESTS: 1 — the descriptor only.
      The compiler endpoint received ZERO requests.

    nonexistent descriptor
      HTTP 404, local body, no X-Overlay, no Location, no fallback artifact

## 6. LEGACY CONTROL — v1 still governs historical cells

    descriptor for H         HTTP 404  (none published)
    fetcher                  returns null -> v1 rule
    RESULT                   ACCEPTED, capability true

So adding the descriptor fetcher did not make v2 mandatory for historical
cells. And the causal negative from the host matrix still holds: H2 requested
with a bundle recording H and NO descriptor refuses under v1 equality.

## Tests

    30/30   binding (10) + resolver (11) + cache (9), analyzer clean

The cache suite needed a default `httpClient.get` stub returning 404 and a
`Uri` fallback registration. Those tests are all v1-era, so a genuine absence is
the correct stub — left unstubbed, a mock returns null and fails with a type
error that says nothing about which rule was under test.

## CLI revision used

    6f97de7e7bd97355de517fb63a9c2f9b6a0f2243   parent 50e472a6 (release 139's)
    flutter.version 8427e3da (F2 -> H2), banked at
    mml555/shorebird refs/heads/route-b-2c-cli-cellbind, fresh-fetch verified

Release 139's CLI identity is untouched; this is the revision that was tested
and the one a subsequent release must use.

## State

    H2                    ACTIVE, 16/16, AUDIT CLEAN
    H2 tooling            PATCH-RESOLVABLE
    release 139           RETAINED, non-patchable negative specimen
