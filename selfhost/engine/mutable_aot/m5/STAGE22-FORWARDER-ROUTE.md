# STAGE22 — the dispatch form is the dynamic invocation forwarder

Fork `93d06e2187c`, built and stamped by `m2/build_maot.sh`.

## 1. What the three sites actually are

STAGE21 §5 inferred that the setter, operator and callable sites "do not route
through" the switchable-call path, because they recorded zero observed states.
**That inference was wrong.** Disassembling the emitted code settles it — both
`site` functions end in the identical sequence:

```
add  x16, x27, #0x1, lsl #12    ; x27 = PP, the object pool
add  x16, x16, #<off>
ldp  x30, x5, [x16]             ; LR = entry point, x5 = switchable-call data
blr  x30
```

That is the canonical ARM64 AOT switchable call. All five subjects use it.

They recorded nothing because a dynamic call to a member **with a typed
parameter** resolves to that member's DYNAMIC INVOCATION FORWARDER, not the
member. The registry is keyed on the member, so the forwarder was unrecognised
and nothing was attributed. Naming the unattributed targets showed it directly:

```
MISS_UNTRACKED ..._Alpha_dyn_set_v     state=instance-dispatch/ICData-observed
MISS_UNTRACKED ..._Beta_dyn_set_v      state=instance-dispatch/ICData-observed
```

A no-argument getter needs no forwarder, which is exactly why it was the one
subject that worked. Setter `(int x)`, `operator +(int x)` and `call(int x)`
all have a parameter; those are precisely the three rows that reported zero.

## 2. Where the forwarder goes

`Alpha_dyn_set_v`, disassembled, ends:

```
ldr  x0, [x27, #0xe8]     ; pool -> the dispatch CELL
ldur x0, [x0, #0x17]      ; x0 = cell[kCellImplFunction]
ldur x30, [x0, #0x7]      ; x30 = implFunction.entry_point_
blr  x30
```

That is verbatim the #67 cell-indirection sequence from
`flow_graph_compiler_arm64.cc`, and it is the setter's single
`indirect_call_sites_emitted=1` (the getter reports 0). The forwarder stores no
implementation identity — it re-reads the cell on every call.

## 3. The frozen cache, read back at every stage

With the inspector taught to resolve forwarders, all four warmed subjects
report and every field is identical across baseline / V2 / V3:

| row | via | site pc | state | cached fn | CurrentCode==tramp |
|---|---|---|---|---|---|
| getter | `declaration` | SAME | MegamorphicCache | `get:v` | **YES** |
| setter | `dyn-invocation-forwarder` | SAME | MegamorphicCache | `dyn:set:v` | **NO** |
| operator | `dyn-invocation-forwarder` | SAME | MegamorphicCache | `dyn:+` | **NO** |
| callable | `dyn-invocation-forwarder` | SAME | MegamorphicCache | `dyn:call` | **NO** |

`entry_cid`, `owner`, `cached_fn_addr` and `trampoline_entry` are SAME across
all three stages for every row. No relink, no re-miss, no state transition.

## 4. Classification

`dynamic/MegamorphicCache via dyn-invocation-forwarder` = **SLOT_PRESERVING**,
on this evidence: the cached object is the forwarder and its address does not
move; the forwarder holds no implementation identity and re-reads the cell per
call (disassembled, §2); the cache is unmodified across two replacements (§3);
and behaviour advanced OLD → NEW → NEW2 with every registry routing identity
frozen (53-check matrix).

Recorded as a **distinct** form rather than folded into the accepted
`dynamic/MegamorphicCache` record, because the route differs:

```
accepted :  frozen cache -> declaration Function -> TRAMPOLINE -> cell -> body
forwarder:  frozen cache -> forwarder Function  -> cell (direct) -> body
```

**The declaration trampoline is not on the forwarder path.** The invariant
carrying these members is the stable cell re-read per call, not the trampoline.
Replacement still works and is still slot-preserving, but the architecture
sentence "stable declaration trampoline" does not describe this route.

## 5. Known imprecision, flagged not accepted

`MaotNoteSwitchableState` computes `converges` as
`target.CurrentCode() == trampoline` against the **resolved declaration**. For
forwarder routes that is true, so the recorded verdict is right — but it is
right for a reason the check does not test. A forwarder that cached an
implementation body directly would still be scored as converging. Nothing is
gated on it today (escapes are 0, blocking_records none), so this is reported
rather than changed.

## 6. Falsification

53 checks per row, and the judge is fed corrupted evidence rather than trusted:
**24 mutations, 0 undetected**, now including cache relink, cached-function
replacement, state transition, trampoline-entry movement, a missing inspection
and an unmodelled routing form.

Two mutations initially read as MISSED. Both were broken mutations of mine — a
leftover no-op and a string rewrite that matched nothing — so `_last_sub` now
asserts that a mutation changed something. A mutation that silently matches
nothing is indistinguishable from a real gap.

The new cache checks also failed the `method` row on first run at 5 inspections
instead of 3. That was a wrong harness assumption, not a product fault: that
fixture inspects Alpha's and Beta's sites across five calls. The judge now
filters to the subject's own site.

## 7. Not claimed

#69 is not closed. Tearoffs remain a separate surface. No #70, no #64 promotion.
