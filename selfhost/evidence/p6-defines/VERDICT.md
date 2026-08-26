<!-- cspell:words flavoredprobe ALPHA canonicalised precommitted nostart -->

# P6 · Dart defines — the REPLACEMENT link: **PASS**

Release **117** (`1.5.0+1`, flavor `foo`, `P6_DEFINE=ALPHA73`, development-signed)
on `P6_DEVICE_EPOCH = 8e65981251dc945356d532120e424836da10245c`, app
`flavoredprobe-p6`, patch **80**.

## The precommitted table, as observed

| observed | meaning | this run |
|---|---|---|
| **`V2/ALPHA73`** | **PASS** — replacement executed AND the define reached its compile | ✅ |
| `V2/MISSING` | replacement executed, define DROPPED | — |
| `V2/<other>` | a different define set reached the replacement | — |
| `V1/ALPHA73` | the patch did not execute | — |

Controls, all three unchanged:

    release:       FLAVORED-FIXTURE-V1
    flavor state:  V1/Foo             <- untouched by this patch
    asset:         BAKED-INTO-RELEASE

`evidence/p6-defines/01_patched_tap.png`, from a by-hand tap.

## Why `V2/ALPHA73` closes the link and a release-side value would not

The define is read **inside the replacement body**:

    const value = String.fromEnvironment('P6_DEFINE', defaultValue: 'MISSING');

The release compiled with `P6_DEFINE=ALPHA73` by construction, so a release-side
`ALPHA73` says nothing about the replacement compiler. `V2` proves the
replacement bytecode is what ran; `ALPHA73` in the same string proves the
replacement's OWN compile received the define. `defaultValue: 'MISSING'` means a
dropped define could not have been mistaken for a correct one.

This is the link `g41c`/`g41d` left open: they proved **ANALYSIS** byte-identically
and left **REPLACEMENT** unproven on a device.

## Corroborated off-screen

    device   patches/1/dlc.vmcode.routeb        the Route B container, installed
             patches/1/dlc.vmcode.routeb.trace
             state.json release_version 1.5.0+1, 0 queued events
    server   POST /api/v1/patches/check         the device reached the control plane

## Recorded on the way, and it matters more than the arm

**The precommitted body shape could not publish at all.** See
`CONSTANT_BLINDNESS.md`: with `value` const, `'V1/$value'` is a compile-time
constant, the analyzer compares printed procedure ASTs where canonicalised
constants print by reference, and a `V1`→`V2` edit produced kernels differing at
the byte level (`33ad0bd3` vs `d7e9ec16`) that the analyzer read as
`inert, changed: []`. `shorebird patch` refused, correctly, with "Nothing in this
patch differs from the release".

Fails **closed**, so a capability boundary rather than a hole. The target was
reshaped to put the marker outside the constant, preserving every substantive
property of the precommit, and the adaptation is recorded rather than made
quietly.

## Not re-proven here, by instruction

The device epoch, the signing path, the transport and the Local Network grant were
established by the flavor arm. Prerequisites here, not claims.

## The negative stayed at the host layer

`release defines A` + `patch defines B` → `BUILD_CONFIG_MISMATCH`, owned and
tested by P5. **No mismatched define was sent to the phone.**

## The trace classifier is still refusing

`classify_routeb_trace.py` reports trace format `v=5` against its `v2`
expectation. Unchanged debt, not banked either way, and the arm does not rest on
it.
