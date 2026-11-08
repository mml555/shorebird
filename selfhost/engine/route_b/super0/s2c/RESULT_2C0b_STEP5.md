# D-SUPER-2C.0b · Step 5 — build + qualify the v11+0017 compiler cell for H

    H = a5a8be5854c529268378ce16762a16d6e31763e9

## VERDICT — QUALIFIED for routeBDirectSuperDualKernelV1

Cell kept LOCAL. Staged to a scratch overlay, never to selfhost/cdn/overlay.
Publication is step 6.

## ACTION

The candidate tree's host artifacts did NOT already satisfy the contract:

    dart2bytecode_aot.snapshot  Aug 25   NO --patched-verification-dill (0017 absent)
    route_b_analyze.aot         Aug 31   rebuilt anyway, see below

`third_party/dart` is its own DEPS-managed repo, so 0017 is not bankable there as
a commit. Provenance is instead (baseline sha256 + `apply_0017.py`), which is
deterministic:

    bytecode_generator.dart  before  e5afe18a6d40cd0bfe4e021181eee2d996a34ea86662e0dc70877c765e5754da
                             after   8b35bc079401399bf331c8f533d2a9f2d0a40322d0088df5f7770febb3621948
    dart2bytecode.dart       before  35a5d8abab9bd35a9c5a1f1c62e41c3b5809dc6ee5e8f2fa99fc5aa26c0f57d3
                             after   e004ca73e6d5278831823d8a837d1a014f5d3b1aeb662fb0f0cbc05a600ee70b

The analyzer was REBUILT rather than accepted on its timestamp. A same-day mtime
is a stamp, not bytes; the shipped analyzer now provably derives from the v11
source in this repo.

Engine fork at `dfa2b24ac38477f3705ff0357530f33fe09474b8` (branch
`route-b-2c-candidate`), clean apart from an untracked `.gcs_entries`.

## OBSERVABLE — all three hold

    analyzer v11                            analysisVersion = 11   PASS
    advertises routeBDirectSuperDualKernelV1                       PASS
    accepts --patched-verification-dill                            PASS

The capability string is read the way the CLI reads it — `--help` output
containing `patched-verification-dill` (`route_b_compiler.dart:297`) — so the
probe and the product agree by construction rather than by convention.

v11 was NOT confirmed vacuously. A base==patched run emits `analysisVersion: 11`
but zero super data, which would have "passed" while proving nothing. Re-run on
the real moved-site pair (`release_aot.dill` vs a SYMMETRICALLY built
`patched_aot.dill` — same `--aot`, same `--dynamic-interface di.yaml`, per the
retention-asymmetry defect):

    lowering[Leaf.target].superInvocations[0]
        offset 1005, member close, kind method
        target { fileOffset 672, name close, kind Method }
    lowering[Leaf.target].releaseSuperTargets[0]
        { fileOffset 672, name close, kind Method }

Both v11 fields are populated AND agree on the provenance tuple — which is the
exact membership test the producer's admission gate applies.

## POSITIVE

    moved-site narrow-v1 specimen, release binding + patched verification kernel
    -> ACCEPTED, executed  WRAP:TICKER:APP-STATE

## NEGATIVE

    same specimen, RELEASE kernel as the verifier
    -> REFUSED

Refused for the RIGHT reason, not generically:

    no super invocation at offset 1005 in Leaf.target (patched kernel)

This is the arm that separates a qualification from a smoke test: a 0015/0016
cell reading the release body accepts arm 1 and cannot refuse arm 2 on that
ground.

## Cell contents (staged, 8 files)

    dart2bytecode.aot                  81b9a5fc7369c1e3d0fa26ac80c18da1420414c7e0966aa27cef2c86a88c9fce
    dartaotruntime                     075ccbb2858f299db06c2ef56b1b60c7ab07abdbc7ff413f33d4bb956e09f292
    vm_platform.dill                   015ef32c6cb988d8ec160e97da5ec62fb4d4798ac9e03815294c982b298c75d2
    route_b_analyze.aot                799a0796c4d20596c40d9742c662ad1644aa1c39485181591d42d51c1f537236
    route_b_gen_kernel.aot             81e1d8f4dc72bf2bb62ca3e157155568070327b4ea127e8dd6a8fe116d3e49d6
    route_b_gen_dynamic_interface.aot  c226800242a85028f85cbc8ff570a4650eb65beb78c278168711fdcc81cf2155
    route_b_release_probe.aot          37dffac8de643591aa095749e16cb97b9b6be3912c209fa7c2ed670f609e72d0
    flutter_platform_strong.dill       099b03133aea39273dcebf85ed8c5762ee22834e63d2ffba786be6ad7428d61c

## OPEN SHARED-STATE NOTE — the dart tree is left PATCHED

`third_party/dart` still carries 0017. Deliberate, not an oversight: step 6
publishes from these artifacts and a mid-lane restore risks a later rebuild
silently producing a 0017-less compiler. `build_dart2bytecode.sh` has its own
capability check, so such a regression would be caught rather than shipped.

To restore, when the lane closes:

    cd /Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart
    git checkout pkg/dart2bytecode/lib/bytecode_generator.dart \
                 pkg/dart2bytecode/lib/dart2bytecode.dart

F2 (upstream passthrough outage) did NOT touch this verdict: every arm above is
local — no passthrough fetch participates in cell qualification.
