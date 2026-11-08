# STAGE 13 — the super route, measured without the #68 confounder

Status: **evidence complete; reclassification PROPOSED, not applied.**
Fork `1852feb90a3`.

Every earlier super measurement was taken while the transitive
constant-propagation hole was live, and `Base.v() => 'OLD-BASE'` is a constant
returned through the non-mutable `Sub.viaSuper()` — the exact failing shape.
That is why the paired control failed identically and why the first two
diagnoses were retracted. With P1 the default, the confounder is gone and the
fixture can be read.

## 1. The super call site is the cell-lowered route

```
[maot] pool entries for the cell of ...::cls:Base::method:v: 1
       (static call sites 1, seeded index 11, PP offset 104)
```

`Base.v` is reached ONLY through `super.v()` in this fixture — nothing calls it
virtually, and `Sub` overrides `v`. So that single static call site **is** the
super call site, and it was lowered onto the declaration's seeded cell. One
cell, one pool entry, no duplication.

## 2. The cell's implementation moves; the cell does not

Owner-qualified, because `Base.v`, `BaseNew.v` and `BaseNew2.v` are all named
`v` and the unqualified render printed the same string at all four stages
while the behaviour changed under it:

| stage | `cell.implFunction` | seeded pool index |
|---|---|---|
| s0 initial | `Function 'v'` (owner **Base**) | 11 |
| s1 after swap 1 | `Function 'v'` (owner **BaseNew**) | 11 |
| s2 after swap 2 | `Function 'v'` (owner **BaseNew2**) | 11 |
| s3 after swap 3 | `Function 'v'` (owner **BaseNew**) | 11 |

`pool[11] IS the cell` at every stage. Same call-site routing, same cell
identity, changing implementation — which is the whole claim.

## 3. Behaviour, including the required second replacement

```
super.0    = OLD-BASE
super.warm = OLD-BASE        (50,000 iterations, still the release body)
swap.1 = 0 -> super.1 = NEW-BASE
swap.2 = 0 -> super.2 = NEW2-BASE
swap.3 = 0 -> super.3 = NEW-BASE
```

It returns to `NEW-BASE` on the third swap, so the route is not a one-way
latch.

## 4. No switchable-call machinery is involved

```
super.switchableStatesUsed = [0, 0, 0, 0] -> [0, 0, 0, 0]
super.noSwitchableTransition = true
```

Counted across `UnlinkedCall`, monomorphic, `ICData` and `MegamorphicCache`.
A `super` call never enters the switchable path, which is consistent with it
being a static invocation.

## 5. super is not virtual dispatch — the separating control

```
virtual.onSub       = SUB-OVERRIDE     (before any swap)
virtual.onSub.after = SUB-OVERRIDE     (after all three)
```

`Sub` overrides `v`. If `super.v()` resolved by ordinary virtual dispatch it
would have selected the override, and swapping `Base.v` would have moved the
override too. Neither happened: the override is untouched while `super.v()`
moves. The two routes are genuinely distinct.

## 6. The confounder, confirmed gone in the same binary

The paired control that previously failed identically to super:

```
control.0 = OLD-CONTROL -> control.1 = NEW-CONTROL     installable=True, blocking=<none>
```

## 7. Proposed — NOT applied

```
super/static-cell = SLOT_PRESERVING
covered_by        = #67-style mutable cell routing
remove            = super/unproven
```

No super-specific mechanism was built or is proposed. The route is #67's
static cell lowering, reached by a `super` call because a `super` call is a
static invocation.

**What this does not do:** `cls:Base::method:v` stays `installable=False`. It
still carries `dynamic/MonomorphicSmiableCall`, `dynamic/SingleTargetCache` and
`dynamic/MegamorphicCache`, which are instance-dispatch records this evidence
says nothing about. Removing `super/unproven` classifies the super route; it
does not make the declaration installable, and must not be read as doing so.
