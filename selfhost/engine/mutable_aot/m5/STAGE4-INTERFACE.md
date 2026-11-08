# MAOT-5 (#69) — interface form proven; dynamic/ICData applied; reachability

## dynamic/ICData applied

```text
Alpha.v  installable = False   escapes = 5
blocking_records: dynamic/MonomorphicSmiableCall, dynamic/SingleTargetCache,
                  dynamic/MegamorphicCache, interface/unproven, super/unproven
```

Four `SLOT_PRESERVING` records now contribute no escapes; five still do, and
the refusal names them. Fail-closed is intact.

`H19` protects the join that this splitting broke once: it requires the count
to come from the granular records **and** to reach zero when none of them
block, so neither a rename nor a blanket reclassification can pass quietly.

## Interface form — PASS, from the true release baseline

Four implementations and an environment-chosen receiver, so neither CHA nor
TFA can narrow the interface. One interface call site, statically typed as
`Iface`.

```text
dispatch-table slots holding the trampoline for Alpha::method:v:  1
tramp.identity = 1

iface.0 = OLD-ALPHA            <- genuine release body, no prior swap
swap.1  -> iface.1 = NEW-ALPHA
swap.2  -> iface.2 = NEW2-ALPHA
swap.3  -> iface.3 = NEW-ALPHA

iface.noSwitchableTransition = true      [0,0,0,0] -> [0,0,0,0]
iface.beta = BETA   iface.gamma = GAMMA   iface.delta = DELTA
```

This one **is** a release-baseline sequence: `OLD-ALPHA → NEW-ALPHA →
NEW2-ALPHA`, because the fixture is fresh and nothing swapped before
`iface.0`.

`noSwitchableTransition = true` is the mechanism evidence: across all three
swaps the interface site entered **no** switchable-call state. It is the
dispatch table and nothing else, which is why the dynamic results could never
have covered it.

Three other implementations share the selector and the same table and are
untouched.

### Proposed

Replace the placeholder `interface/unproven` with the concrete mechanism
demonstrated:

```text
interface/dispatch-table = SLOT_PRESERVING
```

Not applied — the pattern is prove, propose, authorize.

## Reachability of the three remaining dynamic states

Determined from the VM, not by trying to force them.

### MonomorphicSmiableCall — REACHABLE, and now observed

`DoUnlinkedCallAOT` branches on `unlinked.can_patch_to_monomorphic()`: true
gives the plain Smi-cid monomorphic form, false gives
`MonomorphicSmiableCall::New`.

`UnlinkedCall::New()` sets that flag to `!FLAG_precompiled_mode`, which reads
as *always false in AOT* — yet the plain monomorphic form was observed. The
contradiction was recorded rather than reasoned away, and labelling the
observation by the flag's actual value settled it: **both branches occur**.

```text
instance-dispatch/UnlinkedCall-observed             n=8
instance-dispatch/monomorphic-observed              n=1
instance-dispatch/MonomorphicSmiableCall-observed   n=1
instance-dispatch/ICData-observed                   n=1
```

It is reachable and reached. The warmed-site / no-mutation proof is still
owed before it can be reclassified.

### SingleTargetCache — NOT reachable with this fixture

Created in `DoMonomorphicMissAOT` only when `CanExtendSingleTargetRange`
succeeds, which requires the old and new targets to be the **same function**
across adjacent class ids. `Alpha.v` and `Beta.v` are different functions, so
the range can never extend.

Precondition to reach it: two adjacent cids sharing one target function — a
subclass that inherits the method rather than overriding it.

### MegamorphicCache — NOT reachable with this fixture

Reached when an inline cache outgrows its threshold, which needs many
receiver classes at one site. This fixture has four.

### The distinction the ruling asked for

`MonomorphicSmiableCall` is reachable and owed a proof.
`SingleTargetCache` and `MegamorphicCache` are **not reachable by this
fixture**, and each has a named precondition that would be required to reach
one. Neither should become `SLOT_PRESERVING`; if they stop blocking it should
be because reachability analysis excludes them, which is a different
mechanism and is not built.

## Not claimed

* `interface/dispatch-table` is proposed, not applied.
* `MonomorphicSmiableCall` is observed, not proven.
* `super` is untouched and remains `super/unproven`.
* No #64 cell moves. Nothing installs through `StageReplacement`.
