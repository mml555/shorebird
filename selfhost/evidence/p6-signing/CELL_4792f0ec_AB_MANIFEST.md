# Cell `4792f0ec` — a runtime-only cell, member by member

    old cell  ca7d2c0d43bf975db2c42cc0aa6351d527443abf
    new cell  4792f0eca461f3761001a1adbe131b4b115e3684

The address MUST differ, and does. Runtime bytes changed, so an identical address
would have been a hard failure — and that is not hypothetical: the mint script
records a measured case where an embedder-only change left every host member
byte-identical and reproduced the donor's address exactly. That is why the three
iOS zip digests now participate in the address.

## The A/B

| member | old cell | new cell | expected | result |
|---|---|---|---|---|
| `ios/artifacts.zip` | `b5abe13dfab58709` | `c78ac905d0a2ad0c` | DIFFERENT | **DIFFERENT** |
| `ios-profile/artifacts.zip` | `4d88c4912ab68ba6` | `4af310e0a721b3f9` | DIFFERENT | **DIFFERENT** |
| `ios-release/artifacts.zip` | `216a326d81688d1a` | `c5e3908cb0f59e67` | DIFFERENT | **DIFFERENT** |
| `dartaotruntime` | `075ccbb2858f299d` | `075ccbb2858f299d` | SAME | SAME |
| `dart2bytecode.aot` | `8dfb3b6682d591a3` | `8dfb3b6682d591a3` | SAME | SAME |
| `vm_platform.dill` | `015ef32c6cb988d8` | `015ef32c6cb988d8` | SAME | SAME |
| `route_b_analyze.aot` | `14538a6731604442` | `14538a6731604442` | SAME | SAME |
| `route_b_gen_kernel.aot` | `81e1d8f4dc72bf2b` | `81e1d8f4dc72bf2b` | SAME | SAME |
| `route_b_gen_dynamic_interface.aot` | `c226800242a85028` | `c226800242a85028` | SAME | SAME |
| `route_b_release_probe.aot` | `37dffac8de643591` | `37dffac8de643591` | SAME | SAME |
| `flutter_platform_strong.dill` | `099b03133aea3927` | `099b03133aea3927` | SAME | SAME |
| `sky_engine.zip` | `615a2da723c4064f` | `615a2da723c4064f` | SAME | SAME |
| `flutter_gpu.zip` | `c15aa66a540b59e2` | `c15aa66a540b59e2` | SAME | SAME |

Exactly three members moved, and all three are the iOS engine. The host producer
toolchain is untouched, which is what makes this a runtime-only cell rather than
a toolchain change wearing a new address.

Cloning `sky_engine.zip` and `flutter_gpu.zip` was legitimate because they were
**measured** byte-identical first, not assumed. Cloning any of the three engine
mode zips would not have been, and none was cloned — each was packaged from its
own freshly built `out/ios_*` directory and installed by digest.

Old-cell digests were measured from the published bytes at mint time, not copied
from an earlier record.

## The four source identities

Kept separate on purpose, so no one can later read the documentation commit as
part of the built runtime.

    evidence_revision       3b6a5ab83bd5d36fd022731b67c918be348c57f8   (docs/checkpoint)
    control_plane_revision  58b4998007f1736b654e00e9034116f38b459be4   (patch files + CLI/server)
    engine_revision         619fdad176ff457331b50230b9511e7230a6ed93   (C++ integration)
    updater_revision        af6e842ccf87a083d1598b1e7c9e0868c5731931   (on-device runtime)

`619fdad176ff4573` is the `engine_version` the qualification gate read out of all
three mode builds independently, and `af6e842ccf87` is the revision the shipped
engine bytes stamp. Address, bytes and source therefore agree by measurement
rather than by assertion.

Remotes, all verified with `git ls-remote`:

    mml555/shorebird                 experimental
    mml555/shorebird-flutter         route-b
    mml555/shorebird-updater-mirror  route-b        (created this lane; see RUNTIME_SOURCE_BANKED.md)

## Verification chain, all run against this cell

| gate | result |
|---|---|
| `qualify_ios_modes_gate.sh` | ELIGIBLE TO MINT — both modes REPRODUCIBLE across two packagings |
| `verify_cell_delivery.sh` | DELIVERY VERIFIED — delivered digest matches published **and differs from the donor's**, so fallback bytes are excluded by name |
| `verify_cell_completeness.sh` | COMPLETE — 9/9 required for an iOS release from an empty cache |
| `audit_route_b_compiler.sh` | AUDIT CLEAN — reconstructible; published `ios-release` matches `ios_artifacts_sha256` |

## The fetched-back engine, not the staging zip

Retrieved over the consumer path, `HTTP 200`, 14,700,732 bytes:

    fetched   c5e3908cb0f59e679b4aacb02639277e18ebb657ea808d61eb1ce6123d297394
    published c5e3908cb0f59e679b4aacb02639277e18ebb657ea808d61eb1ce6123d297394  MATCH
    donor     216a326d81688d1ab32b3b277f2da1115310a0a511e3ae8e5ef3daa759131144  differs

Engine binary inside it, `sha256 62bd2395005cc315…`:

    PRESENT  af6e842ccf87                   (1)
    PRESENT  Preparing next boot            (1)
    PRESENT  Next boot candidate rejected   (1)
    PRESENT  Prepared boot of               (2)
    ABSENT   f729f958e9be                        <- the old consumed revision is gone

All three modes carry the new revision, checked per mode rather than inferred
from the release build:

    ios-release  62bd2395005cc315   ios (debug)  745e178c447789ce   ios-profile  de68eefd42df7bbb

## What these strings do NOT prove

They prove the new runtime is present and linked. They do **not** prove the
engine CALLS it: `report_launch_start` still exists in the Rust library, so a
binary that took the old path would carry both. Only the device gate settles
that, which is why `BOX12_DEVICE_GATE_PRECOMMIT.md` requires
`Preparing next boot.` present **and** `Reporting launch start.` absent in the
syslog. Call-path absence, not symbol absence.
