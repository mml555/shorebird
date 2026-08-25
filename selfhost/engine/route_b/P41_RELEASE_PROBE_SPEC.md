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

## 9. Known unmeasured items

- Release-shape equivalence (`--strip` / assembly output) — control in §10.
- Profile cost on a realistic app — sizing measurement, not mechanism research.
  The toy's 1.6 MB / 24,833 nodes is not a product-cost figure.

## 10. Regression controls this spec requires

1. The three-specimen partition, as a permanent control, including `deadBranch`
   classifying GREEN.
2. Release-shape equivalence: the same three targets classified identically under
   the release's actual configuration — iOS emits `--snapshot_kind=app-aot-assembly`
   and strips afterwards, Android emits `--elf --strip`.
3. The full mutation table in §7.
4. End-to-end through the **actual producer**, not only the standalone probe.
