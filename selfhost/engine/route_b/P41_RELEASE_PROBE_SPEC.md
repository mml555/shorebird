# P4.1 — release probe contract

Status: **FROZEN** as of 2026-08-25. Derived entirely from the measurements in
`evidence/p41_measurement_note.md` (three specimens, one release, unobfuscated
and obfuscated). Nothing here is an extrapolation; where a thing is unmeasured
this document says so.

The claim the whole instrument is allowed to make:

> **A green result means a supported invocation site survived compilation. It
> does not mean runtime control flow will reach it.**

`deadBranch` is the permanent control that keeps that sentence honest: it has a
surviving call site and is never executed, and it must classify GREEN. Any change
that renames its result to something implying reachability is a defect.

---

## 1. The measured fact the instrument rests on

For a Route B-targetable `Function`, a surviving patchable-static invocation is
represented by the target `Function` appearing in an `ObjectPool` owned by caller
`Code`. A folded target remains identifiable as a `Function` but has no
qualifying caller-owned pool reference.

The mechanism, not a coincidence: a patchable static call loads the callee's
`entry_point_` out of the CALLER's object pool (`ldur lr,[r0,#7]; blr lr`). The
pool entry IS the call site.

Permanent control table:

```text
foldOpaque  -> qualifying caller-owned reference exists
foldConst   -> target exists, zero qualifying caller-owned references
deadBranch  -> qualifying caller-owned reference exists
```

That encodes **survival**, not reachability.

## 2. Qualifying referrers, defined narrowly

Not all pools count. Every referrer of the target `Function` node is classified:

| category | counts as surviving invocation |
|---|---|
| pool owned by `Code` for a different Dart function (the caller), where the pool entry is the patchable `Function` reference | **yes** |
| the target's own tear-off machinery | no |
| pool owned by the target's own `Code` | no |
| `ObjectPool` with no recoverable `Code` owner | no — **recorded separately** |
| non-pool reference | no |
| malformed / unknown edge | cannot establish → `UNKNOWN` |

The instrument emits the raw categories as evidence:

```text
target_function_nodes: 1
caller_owned_pools:    1
tearoff_pools:         1
self_owned_pools:      0
unowned_pools:         1
other_referrers:       0
```

The policy fact is derived from `caller_owned_pools` **alone**. This exists so
that today's incidental "3 pools" cannot become tomorrow's accidental contract:
the measured 3 decomposes into 1 caller-owned + 1 tear-off + 1 unowned, and only
the first is load-bearing.

## 3. Internal result model, frozen before the product vocabulary

The instrument keeps more precision than the producer needs:

```text
TARGET_NOT_FOUND
TARGET_AMBIGUOUS
PROFILE_INVALID
ARTIFACT_BINDING_MISMATCH
ZERO_QUALIFYING_CALLSITES
ONE_OR_MORE_QUALIFYING_CALLSITES
```

Product mapping:

| instrument result | product result | publication |
|---|---|---|
| `ONE_OR_MORE_QUALIFYING_CALLSITES` | `SURVIVING_CALLSITE` | continue |
| `ZERO_QUALIFYING_CALLSITES` | `NO_SURVIVING_CALLSITE` | refuse |
| not found / ambiguous / invalid / binding mismatch | `UNKNOWN` | refuse |

Three distinctions the user-facing wording must preserve:

- **Function found + zero qualifying caller refs** is *authoritative absence*.
- **Function not found** is *not* absence.
- **Profile could not be trusted** is *not* absence.

All three refuse publication. They are not the same message, and collapsing them
would turn a broken instrument into a confident verdict about the code.

## 4. Identity

The conceptual identity of a target is:

```text
library URI + owning class (if any) + member + signature identity where required
```

Names are the *current profile lookup mechanism*, not the contract.

Recorded dependency, measured in `evidence/p41_measurement_note.md`:

> Route B's dynamic interface causes targetable member names to remain bindable
> under obfuscation. The probe relies on that property and fails closed if a
> target identity can no longer be uniquely recovered.

Evidence for it: under `--obfuscate`, 3,371 of 5,095 names were renamed, and the
split was exactly interface membership — `print`/`now`/`millisecondsSinceEpoch`
preserved, `exponent`/`implementation`/`xIndex` → `UL`/`TH`/`mp`. Every Route B
target is interface-named by construction, so lookup holds for exactly the
members Route B can patch. If that ever changes, the failure mode is
`TARGET_NOT_FOUND` → `UNKNOWN` → refuse, never a false green.

## 5. Binding to the exact release — non-negotiable

The profile sidecar carries:

```text
profile_format_revision
probe_revision
cell_id
release artifact SHA-256
release kernel/interface digest where relevant
```

The producer verifies the binding before consuming any result.

A valid profile describing artifact A must be unusable for artifact B even when
the bundle version matches, the source revision matches, the filenames match, and
the targets happen to have the same names. This is P4.4's exact-artifact
principle applied to P4.1.

## 6. Ownership

```text
cell artifact:  route_b_release_probe
                profile decoder / schema knowledge
                probe revision

release:        exact snapshot profile
                exact artifact binding

producer:       asks the matching cell probe about each changed target
                consumes the result
                enforces publication policy
```

The producer does **not** parse profile JSON. Compiler and profile semantics stay
versioned with the cell that produced them.

## 7. Mutation table — part of the gate from the start

| mutation | required failure |
|---|---|
| disable the P4.1 producer gate | folded `foldConst` proceeds toward publication |
| count a tear-off pool as a caller | a zero-real-call fixture falsely passes |
| count an unowned pool | deliberately ambiguous evidence falsely passes |
| change the artifact digest | probe refuses the binding |
| remove the target `Function` from the profile | `UNKNOWN`, not `NO_SURVIVING_CALLSITE` |
| duplicate the target `Function` identity | `UNKNOWN`, not arbitrary first-match |
| rename the `deadBranch` result to "unreachable" | tests/docs fail — a dead branch stays `SURVIVING_CALLSITE` |

The last row is not decoration. Semantic overclaim is this project's recurring
failure mode, so it gets a test like any other regression.

## 8. Decoder facts the reader must encode

Measured, not assumed:

- A node's `type` and `name` index `meta.node_types[0]` and `meta.strings`
  respectively; edge `type` indexes `meta.edge_types[0]`. Indexing `strings` for
  the type is the error that voided the first decode.
- `to_node` is a **byte offset** into the flat `nodes` array, not a node index.
- Edges are laid out per node in node order; the walk must consume the `edges`
  array exactly, and a leftover or short read is `PROFILE_INVALID`.

## 8b. Decisions taken, 2026-08-25 — not open questions

Both were flagged as product decisions and both were then made deliberately.
Recorded here so a later reader does not reopen them as oversights.

**The full profile is the reference implementation.** The measured cost is
accepted: +5.6–6.8% snapshot time, a sidecar 140–154% of the binary (28–34%
gzipped), and **zero additional device or runtime bytes** — it is
publication-time evidence that never ships. For a gate that stops known-dead
patches from reaching devices, that is the right trade. The narrowed sidecar in
`evidence/p41_profile_cost.md` stays **unbuilt**: it becomes worthwhile only if
storage or build-transfer cost turns operationally material, and narrowing the
evidence channel immediately after proving it would risk weakening the thing
just established. Do not optimise it yet.

**No release profile means no Route B patch publication.** A hard boundary, with
no legacy exemption and no retroactive synthesis of evidence from old artifacts.
This defines a clean epoch:

| release era | evidence | eligibility |
|---|---|---|
| pre-P4.1 | no bound release profile | **unsupported** for new code patches |
| P4.1-era | profile emitted and artifact-bound at release time | eligible, subject to the checks |

Those older releases keep running. They simply cannot receive new Route B code
patches under the hardened publication contract, which is better than carrying
an indefinite bypass whose only purpose is to make an unproven prerequisite look
satisfied.

## 8c. The probe is cell-owned, so an instrument bug is not retroactive

Recorded 2026-08-26, after a real one.

The probe ships in the cell, and a patch is judged by the probe that shipped with
its release's toolchain. That is the property §6's ownership split exists to
create. It has a consequence worth stating rather than rediscovering:

> **A defect in the probe is fixed only for releases cut against a later cell.**
> A release already cut is permanently judged by the instrument it shipped with,
> and no fix can reach it.

Demonstrated: the probe compared the owning CLASS name exactly, while the profile
mangles private class names (`_FooState@306106223`) exactly as it mangles private
members. Every member of a private class resolved to `TARGET_NOT_FOUND` — failing
closed, but refusing the shape P1 had already proved on device. Fixing it required
minting `ca7d2c0d…`; release 118, cut minutes earlier against `8e659812…`, cannot
be patched on such a target ever.

**This is the right trade** — the alternative is a probe whose behaviour changes
under a release after the fact, which is exactly what the exact-artifact rule
forbids. But it means a probe defect is an **epoch-scoped** defect, and the
remediation for an affected release is to cut a new one.

## 9. Known unmeasured items

- ~~Release-shape equivalence (`--strip` / assembly output)~~ — **MEASURED**,
  12/12, `probes/p41_release_shape_equivalence.sh`. Identical classification
  under `--elf`, `--elf --strip` and assembly; the elf profiles are even
  byte-identical in size.
- ~~Profile cost on a realistic app~~ — **MEASURED**,
  `evidence/p41_profile_cost.md`, and the cost is accepted (§8b).
- Still unmeasured: a genuinely large app (`flutter_gallery` needs a `pub get`
  at the root of the pinned build tree), and the profile's share of a full
  `flutter build ios`.

## 10. Regression controls this spec requires

1. The three-specimen partition, as a permanent control, including `deadBranch`
   classifying GREEN.
2. Release-shape equivalence: the same three targets classified identically under
   the release's actual configuration — iOS emits `--snapshot_kind=app-aot-assembly`
   and strips afterwards, Android emits `--elf --strip`.
3. The full mutation table in §7.
4. End-to-end through the **actual producer**, not only the standalone probe.
