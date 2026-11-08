# D-SUPER-2C.0b · Step 6 — publish the qualified cell under H

    H = a5a8be5854c529268378ce16762a16d6e31763e9

## VERDICT — PASS. The served cell IS the qualified cell, byte for byte.

## Published the qualified bytes, did not regenerate them

`publish_route_b_compiler.sh` was NOT re-run. Re-running it would have re-zipped
from `out/`, and a zip embeds mtimes, so the archive would differ even with
identical members. The step 5 staged artifact was copied verbatim instead:

    staged  sha256 9d4ace27d6d6b77c0bad6d0cbc318f4b4a4b74c59f3462407d688843ee779c59
            size   19,253,416
    on disk sha256 9d4ace27d6d6b77c0bad6d0cbc318f4b4a4b74c59f3462407d688843ee779c59
    cmp     byte-identical

Pre-publication re-hash of the staged eight against the step 5 manifest: 8/8 OK.
The destination was checked for a pre-existing file first and would have refused.

## Fetch-back through the serving path

The ruling's path `/shorebird/H/...` returns 404 — correctly. The published URL
template is `{storageBaseUrl}/{bucket}/shorebird/{engineRevision}/...` and the
Caddyfile matcher is `[^/]+/shorebird/[0-9a-f]{40}/...`, so the bucket segment is
part of the address:

    GET http://localhost:8085/download.shorebird.dev/shorebird/<H>/route-b-compiler-darwin-arm64.zip

    HTTP            200
    size            19,253,416
    sha256          9d4ace27d6d6b77c0bad6d0cbc318f4b4a4b74c59f3462407d688843ee779c59
    Content-Type    application/zip
    Etag            "dl3m8ta0d1j8bgo14"
    X-Overlay       hit
    X-Engine-Hash   a5a8be5854c529268378ce16762a16d6e31763e9

Extracted into a FRESH directory from the SERVED zip. All eight constituents
verified against the qualified manifest:

    dart2bytecode.aot                  81b9a5fc…c9fce   OK
    dartaotruntime                     075ccbb2…9292    OK
    vm_platform.dill                   015ef32c…c75d2   OK
    route_b_analyze.aot                799a0796…37236   OK
    route_b_gen_kernel.aot             81e1d8f4…49e36   OK
    route_b_gen_dynamic_interface.aot  c2268002…f2155   OK
    route_b_release_probe.aot          37dffac8…9e72d   OK
    flutter_platform_strong.dill       099b0313…d61c    OK

8/8 exact. Byte equality establishes that the published cell is the cell already
qualified in step 5, so the qualification matrix was not re-run.

## Served-cell capability check

Run against the binary extracted from the SERVED archive, using the product's
own probe (`--help` containing `patched-verification-dill`):

    --patched-verification-dill    present
    routeBDirectSuperDualKernelV1  available

This is the guard against publishing a correct-looking archive path carrying the
wrong compiler.

## Preservation controls — all four hold

    1  H absent from experimental_hashes.map           PASS — map untouched
    2  4792f0ec compiler cell unchanged                200, 19,201,077 bytes,
                                                       sha256 0696da54…3164,
                                                       mtime Aug 27 16:46:44
    3  H engine artifact from step 4 unchanged         sha256 0f83e38f…1f0f,
                                                       EXACTLY the step 4 value
    4  font-subset for H still unresolved              404 — still step 7 work

Honest scope note on control 2: no sha256 for the certified CELL zip had been
banked before today, so `0696da54…` is banked here for the first time. The
"unchanged" claim rests on the mtime of Aug 27 16:46:44, which predates every
action in this lane — not on a prior hash comparison.

## Dart tree RESTORED and banked

The step 5 open shared-state note is now closed. With the served cell verified
byte-identical, the local Dart mutation stopped being load-bearing, and the
published cell is the immutable authority. Leaving a patched DEPS checkout would
only create ambiguity about later accidental rebuilds.

    git checkout -- pkg/dart2bytecode/lib/bytecode_generator.dart \
                    pkg/dart2bytecode/lib/dart2bytecode.dart

    bytecode_generator.dart  e5afe18a6d40cd0bfe4e021181eee2d996a34ea86662e0dc70877c765e5754da
    dart2bytecode.dart       35a5d8abab9bd35a9c5a1f1c62e41c3b5809dc6ee5e8f2fa99fc5aa26c0f57d3

Both equal the baseline banked in step 5. `pkg/dart2bytecode/` is clean and
`_shorebirdDirectSuper` occurs 0 times in the source. 0017 remains reproducible
from `apply_0017.py` against that baseline.

## Still blocked

    map entry           BLOCKED — step 8, after step 7
    step 7 font-subset  REQUIRED, unresolved
    candidate release   BLOCKED — after the resolution preflight
