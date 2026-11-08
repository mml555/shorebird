# STAGE 14 — MonomorphicSmiableCall, positively entered and proven

Status: **evidence complete; reclassification PROPOSED, not applied.**
Fork `dbe763d3352`+ (site-inspection commit), trampolines ON.

## 1. Why the earlier run proved nothing

The first attempt reported `0/0/0/0` for this state and I refused to call it a
pass: the state was never entered, so there was nothing to observe. A state
that is not reached is UNPROVEN, not safe.

This fixture is built from the VM's own precondition instead:

```
InstanceCallInstr::receiver_is_not_smi
  -> ICData::receiver_cannot_be_smi
    -> UnlinkedCall::can_patch_to_monomorphic
```

and in `DoUnlinkedCallAOT` only the **false** branch installs a
`MonomorphicSmiableCall`; true gives the plain Smi-cid monomorphic form. So
the site must be one where the analysis believes the receiver MAY BE AN INT.
Hence the selector `abs` — a name `int` genuinely has, so an int flowing to the
receiver stays in the receiver set instead of being narrowed away as a
noSuchMethod target — with the int path reachable but never taken at run time.

## 2. Why this state needed a different proof from the others

```c
class UntaggedMonomorphicSmiableCall : public UntaggedObject {
  VISIT_NOTHING();
  uword expected_cid_;
  uword entrypoint_;      // a RAW ADDRESS, captured by New() from target.EntryPoint()
};
```

It holds **no Code pointer at all**. Nothing updates that word when an
implementation changes. So "behaviour changed" is not evidence for this state:
it is safe only if the frozen address is the declaration's stable trampoline,
which re-reads the mutable cell on every call.

## 3. The transition, positively identified

```
UnlinkedCall transition at site pc=0x102786f18:
  can_patch_to_monomorphic = 0
  installed state object   = MonomorphicSmiableCall
  expected_cid             = 229
  stored target entry      = 0x10277e784
  declaration trampoline   = 0x10277e784
  stored target IS the declaration trampoline = YES

total UnlinkedCall-transition records: 1
```

`tramp.identity = 1`, so a real trampoline was installed and the equality is a
genuine address match. The comparison reports `NO` whenever the trampoline
entry is zero, which is why the trampolines-off control read `NO` rather than
accidentally matching two zeros.

## 4. The four readings — read, not inferred

Across the replacements there were no misses, and only a miss re-patches a
switchable call, so the state object could be argued unchanged. That is an
inference, and this is the one state where a frozen executable address is the
entire question. So the site is re-read.

`Dart_MaotInspectSwitchableSite` reads the data object living at the
remembered site and reports what it finds:

```
after warm   site=0x102786f18 state=MonomorphicSmiableCall expected_cid=229 stored_entry=0x10277e784 trampoline_entry=0x10277e784 equal=YES
after swap 1 site=0x102786f18 state=MonomorphicSmiableCall expected_cid=229 stored_entry=0x10277e784 trampoline_entry=0x10277e784 equal=YES
after swap 2 site=0x102786f18 state=MonomorphicSmiableCall expected_cid=229 stored_entry=0x10277e784 trampoline_entry=0x10277e784 equal=YES
after swap 3 site=0x102786f18 state=MonomorphicSmiableCall expected_cid=229 stored_entry=0x10277e784 trampoline_entry=0x10277e784 equal=YES
```

Four identical readings. The inspected site PC is the **same** `0x102786f18`
the transition record names, so what was re-read is the site that
transitioned, not some other site.

Addresses differ between processes; equality and invariance WITHIN the run are
the claim.

## 5. Behaviour and controls

```
msc.0    = OLD-ALPHA
msc.warm = OLD-ALPHA        (50,000 calls through the one site)
swap.1 = 0 -> msc.1 = NEW-ALPHA
swap.2 = 0 -> msc.2 = NEW2-ALPHA
swap.3 = 0 -> msc.3 = NEW-ALPHA

states.before = [2, 0, 0, 0, 0]
states.after  = [2, 0, 0, 0, 0]     UnlinkedCall/MSC/monomorphic/ICData/Megamorphic
beta.0 = BETA        beta.after = BETA
```

No additional miss or transition observation. Beta — a separate declaration
read through a separate site — is untouched.

All reads go through one `site()` helper, so "the same site was warmed and then
read" is structural: three source expressions would be three call sites.

## 6. The property established

```
frozen raw executable address
  -> stable declaration trampoline      (address equality, four readings)
    -> stable declaration cell          (the trampoline's body loads it)
      -> changing implementation body   (OLD -> NEW -> NEW2 -> NEW)
```

The cache is never invalidated and never needs to be: what it froze was the
indirection, not the implementation.

## 7. Proposed — NOT applied

```
dynamic/MonomorphicSmiableCall = SLOT_PRESERVING
```

Scope, stated so it cannot be over-read: this covers the `dynamic` call form in
the `MonomorphicSmiableCall` state. It is not a claim about
`dynamic/SingleTargetCache` or `dynamic/MegamorphicCache`, which remain
blocking and were not entered by this fixture. Each needs its own reachability
fixture rather than being forced through this one.
