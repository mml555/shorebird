<!-- cspell:words flavoredprobe canonicalised precommitted nostart -->

# P6 · obfuscation — **PASS**

> An obfuscated iOS Route B release accepted and physically executed a
> same-configuration patch targeting a method on a private class; the replacement
> executed through the retained interface identity while unrelated Dart names
> were demonstrably obfuscated.

Release **119** (`1.7.0+1`, flavor `foo`, `P6_DEFINE=ALPHA73`, `--obfuscate`,
development-signed) on cell **`ca7d2c0d43bf975db2c42cc0aa6351d527443abf`**, app
`flavoredprobe-p6`, patch **81**.

## Pre-publication evidence — obfuscation actually happened

| requirement | result |
|---|---|
| `RouteBBuildConfig` records obfuscation | `obfuscate: True`, `splitDebugInfoPath: /tmp/p6_obf_symbols` |
| real obfuscation output exists | `obfuscation_map.json` in the release supplement |
| a meaningful set of unrelated names renamed | **16,255 of 17,988** — e.g. `devicePixelRatio → lcb`, `_bottomLeft@164070249 → _Mec@164070249`, `_updateFragmentShader → _Tvc` |
| the targetable identity stays recoverable | `_FooState`, `target`, `_field` all **PRESERVED** in the same map |
| P4.1 finds a surviving call site for the exact target | `_FooState.target → ONE_OR_MORE_QUALIFYING_CALLSITES`, caller `[Optimized] _readObf` |
| release and patch agree under G4.1 | the patch published; a mismatch is refused by P5 before any build |

**The control that distinguishes "the workflow works" from "the flag was
ignored":** unrelated names are renamed *in the same map* that preserves the
interface-retained target. That is the mechanism the P4.1 host arm measured —
a name the dynamic interface retains must stay bindable at run time, so the
obfuscator preserves exactly the members Route B can patch — now confirmed on a
real obfuscated release.

## Device

| line | before | after |
|---|---|---|
| **obf state** | `OBF-V1` | **`OBF-V2-FLD`** |
| release | `FLAVORED-FIXTURE-V1` | unchanged |
| flavor state | `V1/Foo` | unchanged |
| asset | `BAKED-INTO-RELEASE` | unchanged |

`OBF-V2-FLD` carries two facts: the replacement executed, and it read `_field`
**through the receiver** — so the capability path is exercised too, since the
release had to have granted `_FooState#_field` for that reference to be carried.

Corroborated: `patches/1/dlc.vmcode.routeb` installed on the device, `state.json`
at `1.7.0+1`, and a `POST /api/v1/patches/check` in the server log.

## What was NOT observed, stated rather than glossed

**No device screenshot of `OBF-V1` for release 119.** The tap that produced the
capture already had the patch applied, so the baseline was never photographed on
this release.

The baseline is instead established from the release artifact **the server
holds**: App binary `b2b6e8752d0032b9` — byte-identical to the digest recorded in
`route_b_profile_binding.json` — contains `OBF-V1` and does **not** contain
`OBF-V2`. That is strong evidence about what the release renders, and it is
host-side rather than a device observation. Recorded as such.

Also: the `define state: V2/ALPHA73` row on screen is **this release's own baked
value**, not a patch effect — `defineState` was left at `V2` in source after the
defines arm. It is not an observable for this arm and must not be read as a second
patch result.

## Two product defects this arm found, both before any device reading

**1 · P4.1 refused every member of a private class.** The profile mangles private
CLASS names as well as members (`_FooState@306106223`), and the probe compared the
class name exactly while already tolerating the suffix on the member. Every such
target resolved to `TARGET_NOT_FOUND`.

It failed **closed**, so nothing wrong could ship — but it would have refused the
shape P1 proved on device, meaning the P4.1 gate added earlier the same day
silently narrowed an already-certified capability. That is the more important
half. Fixed; the gate grew a private-class specimen and a mutation showing the
exact comparison is what refused *and* that top-level targets still resolve, so
the mutation is narrow rather than breaking resolution wholesale. 29/29.

**2 · Obfuscated patches died on an unregistered scope ref.**

    Bad state: read(ScopedRef<GenSnapshotProbe>) was called in a scope which
    does not contain a corresponding value for the provided ref

right after *"Applying obfuscation map to patch build."* `shorebird_scope.dart`'s
own comment had already named this failure mode — *"unit tests cannot catch
[it], because they inject every ref they use"* — and `genSnapshotProbeRef` was
simply absent. Fixed in one line; the guard against the class is a test that
DERIVES which refs are reachable through a top-level `read` getter and requires
each to be satisfied, mutation-checked by removing the registration.

## A consequence of the cell model, worth stating plainly

Fixing the probe required a **new cell**, because the probe is cell-owned.
Release 118 — cut minutes earlier against `8e659812` — is **permanently judged by
the buggy probe it shipped with**, and no fix can reach it.

That is the versioning model working as designed: a patch is judged by the
instrument that shipped with its release's toolchain. But it means **an
instrument bug is only fixed for releases cut afterwards**, and that belongs in
`P41_RELEASE_PROBE_SPEC.md` as a property rather than being rediscovered.

## Negatives stayed off-device, as precommitted

No obfuscated-release/plain-patch pair, no wrong `split-debug-info`, no mangled
identity was sent to the phone. P5 owns configuration mismatch; the host profile
study owns obfuscation identity behaviour.
