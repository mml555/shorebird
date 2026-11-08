# D-SUPER-2C.1 · mint-address completeness gate — STOP

The ruling made this the next load-bearing check before minting H2:

> Verify that the address calculation actually includes the host artifacts being
> corrected. … If mint_route_b_cell.sh's current manifest does not address those
> files, STOP again.

## VERDICT — FAIL. Four of the five cannot move the address.

`mint_route_b_cell.sh` computes the address as the first 40 hex of sha256 over a
sorted manifest. The manifest's COMPLETE membership is:

    dart2bytecode.aot                  route_b_gen_kernel.aot
    dartaotruntime                     route_b_gen_dynamic_interface.aot
    vm_platform.dill                   route_b_release_probe.aot
    route_b_analyze.aot                flutter_platform_strong.dill
    ios_artifacts_sha256               sky_engine_sha256
    ios_debug_artifacts_sha256         flutter_gpu_sha256
    ios_profile_artifacts_sha256

Against the five artifacts this repair changes:

    dart-sdk-darwin-arm64.zip          NOT ADDRESSED   0 occurrences in the script
    darwin-arm64/artifacts.zip         NOT ADDRESSED   0 occurrences
    flutter_patched_sdk.zip            NOT ADDRESSED   0 occurrences
    darwin-arm64/font-subset.zip       NOT ADDRESSED   0 occurrences
    flutter_patched_sdk_product.zip    addressed INDIRECTLY

Only the last participates, and only through its payload: `FLUTTER_PLATFORM`
(`flutter_platform_strong.dill`) is a manifest member, and the mint refuses
unless the zip's contained `flutter_patched_sdk_product/platform_strong.dill` is
byte-identical to it. The ZIP itself is not hashed into the address.

## Why this is disqualifying for H2 specifically

The two artifacts whose stale Dart lineage CAUSED this failure —
`dart-sdk-darwin-arm64.zip` and `darwin-arm64/artifacts.zip`, which carry
`frontend_server_aot`, `gen_snapshot` and `const_finder` — are precisely the ones
the address cannot express.

Worse, for THIS successor every addressed input is unchanged by design:

    compiler cell (8 files)   byte-identical, 9d4ace27… stays qualified
    sky_engine / flutter_gpu  cloned unchanged from H
    ios / ios-profile / ios-release   cloned unchanged from H
    flutter_platform_strong.dill      ALREADY 9e8c898a4d in the cell under H

So a mint run after the host rebuild would compute its address from inputs that
did not move. H2 would be a nominally new address that cannot express the one
difference that distinguishes it from H — and a future host-lineage correction
would not move it either. That is exactly the falsification the ruling named of
the script's own claim, `THE ADDRESS IS THE WHOLE CELL`, and the same defect
class the script's header already records twice: `54fb8772…` addressed on one
file, and an embedder-only change reproducing `4288817249400e62` unchanged.

## One thing the mint is NOT blind to

Its platform-dill gate would already REFUSE the current H composition: the
published `flutter_patched_sdk_product.zip` carries dill `6b58bb3a72` while the
cell's `flutter_platform_strong.dill` is `9e8c898a4d`. It would die on that
mismatch rather than mint an incoherent cell. That is a refusal, not address
expressivity — it stops a bad mint, it does not make the address complete.

## Not attempted

No mint run, no host rebuild, no republish. H untouched and still RETIRED.
Nothing added to the map.

The blocker is now a tooling gap in the mint's manifest, and closing it changes
how every future cell address is computed — which is a decision, not a repair.
