# STAGE 16 — MegamorphicCache, positively entered and proven

Status: **evidence complete; reclassification PROPOSED, not applied.**
Fork `8004ca491ff`, trampolines ON.

## 1. The threshold, read off the VM rather than guessed

`DoICDataMissAOT` captures

```c
const intptr_t number_of_checks = ic_data.NumberOfChecks();   // BEFORE the add
...
ic_data.EnsureHasReceiverCheck(receiver().GetClassId(), target_function);
if (number_of_checks > FLAG_max_polymorphic_checks) {          // default 4
  ... MegamorphicCacheTable::Lookup(thread_, name, descriptor) ...
```

so the count is taken before the current receiver is added and the **sixth**
distinct receiver at a site crosses. Predecessor is **ICData**, not
UnlinkedCall or monomorphic. Eight receivers are used so the crossing is
unambiguous rather than sitting exactly on the line.

Every class declares its OWN `v`. If they shared an inherited target the
SingleTargetCache branch would absorb them first and this state would never be
reached.

## 2. What this state caches, and why the control had to change

```c
enum { kClassIdIndex, kTargetFunctionIndex, kEntryLength };
```

It caches a **Function** per receiver cid — not a Code, not a raw address. And
it is obtained from `MegamorphicCacheTable::Lookup(name, descriptor)`, so the
cache is keyed by **selector**, shared across call sites, not owned by one.

That makes the cross-wiring control stronger here than a separate untouched
cache would have been: `Beta` is a different mutable declaration sharing the
selector, so it occupies its own entry in the **same** cache object.

## 3. The state was reached

```
states.afterDrive = [2, 1, 0, 1, 0]      UnlinkedCall/monomorphic/STC/ICData/Megamorphic
states.before     = [2, 1, 0, 1, 2]
observed: UnlinkedCall 1, MonomorphicSmiableCall 1, monomorphic 1, ICData 1, MegamorphicCache 2
```

The site crossed into MegamorphicCache during the warm, and the inspector
confirms `state=MegamorphicCache` at every reading.

## 4. The entry holds the DECLARATION Function

```
afterWarm alpha  cid=235 cached_fn owner=Alpha addr=0x103566f21 CurrentCode_IS_trampoline=YES tramp=0x1033f2784 filled=8
afterWarm beta   cid=232 cached_fn owner=Beta  addr=0x103567011 CurrentCode_IS_trampoline=YES tramp=0x1033f285c filled=8
after swap 1     cid=235 cached_fn owner=Alpha addr=0x103566f21 CurrentCode_IS_trampoline=YES tramp=0x1033f2784 filled=8
after swap 2     cid=235 cached_fn owner=Alpha addr=0x103566f21 CurrentCode_IS_trampoline=YES tramp=0x1033f2784 filled=8
after swap 3     cid=235 cached_fn owner=Alpha addr=0x103566f21 CurrentCode_IS_trampoline=YES tramp=0x1033f2784 filled=8
afterAll  beta   cid=232 cached_fn owner=Beta  addr=0x103567011 CurrentCode_IS_trampoline=YES tramp=0x1033f285c filled=8
```

This is the answer to the question the state raised. The cached Function is
owned by **Alpha** — the mutable declaration class — not by `AlphaNew` or
`AlphaNew2`. It retains the stable declaration Function, whose `CurrentCode` is
the trampoline. It does not retain an implementation Function whose body would
have been frozen at the moment it was resolved.

`cached_fn_addr` is byte-identical across all four Alpha readings: the entry is
not rewritten in order for the replacement to be observed.

Beta holds its own entry with a **different** trampoline (`0x1033f285c` vs
`0x1033f2784`) in the same cache, and is unchanged from first reading to last.

## 5. Across the replacements

```
alpha.0 = OLD-ALPHA
swap.1 -> alpha.1 = NEW-ALPHA
swap.2 -> alpha.2 = NEW2-ALPHA
swap.3 -> alpha.3 = NEW-ALPHA

states.before = [2, 1, 0, 1, 2]
states.after  = [2, 1, 0, 1, 2]       no new resolution or miss
beta.0 = BETA    beta.after = BETA
```

Same site PC `0x1033fb464` throughout.

`filled_entries = 8` is reported as context, not asserted as an invariant —
per the ruling, unrelated cache activity is allowed. The load-bearing claim is
narrower and it holds: the Alpha entry itself is never rewritten.

## 6. The property established

```
MegamorphicCache entry for cid 235
  -> stable DECLARATION Function (owner Alpha, one address throughout)
    -> CurrentCode = stable trampoline
      -> declaration cell
        -> current implementation body
```

## 7. Proposed — NOT applied

```
dynamic/MegamorphicCache = SLOT_PRESERVING
```

If authorized, the dynamic dispatch-form inventory has no remaining unmodeled
cache state, and the next gate is not another diagnostic swap: it is the first
normal `StageReplacement` installation on a fully modeled instance
declaration.
