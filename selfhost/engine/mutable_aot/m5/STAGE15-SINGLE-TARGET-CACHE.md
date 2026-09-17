# STAGE 15 — SingleTargetCache, positively entered and proven

Status: **evidence complete; reclassification PROPOSED, not applied.**
Fork `fd18e978523`, trampolines ON.

## 1. The first fixture did not reach the state — reported, then refined

A plain `Base` + two inheriting children never touched the switchable
machinery:

```
states.before = states.after = [0,0,0,0,0,0]
site readings = -1        (no remembered site: no transition ever happened)
transition records: none
```

Behaviour still followed the swaps, and that counts for nothing here. The
registry said what actually happened: **5 `devirtualization` records** and
`indirect_call_sites_emitted: 1` — TFA proved a single target and devirtualised
the site onto #67's static cell route.

That is a tension in the state itself, not a typo. `CanExtendSingleTargetRange`
requires `old_target.ptr() == target_function.ptr()` — both receivers resolving
to the SAME inherited `Function` — and that is exactly the condition that lets
TFA prove one target and devirtualise. So the receiver set must be
**statically wide** (no devirtualisation) while staying **runtime narrow** (two
classes sharing an inherited target, so a cid range can extend). Three
unrelated `Noise` classes with their own `v` are fed to the same site behind an
environment-gated branch that is never taken.

Only the fixture changed. No VM or classification change was made to reach the
state.

## 2. The route into the state

```
UnlinkedCall transition at site pc=0x10106f034:
  can_patch_to_monomorphic = 1
  installed state object   = 234          (plain monomorphic, a Smi cid)
  stored target entry      = 0x1010667b4
  declaration trampoline   = 0x1010667b4
  stored target IS the declaration trampoline = YES

transition records: 1
observed: UnlinkedCall 1, monomorphic 1, SingleTargetCache 2
```

**State before SingleTargetCache is `monomorphic`, not `UnlinkedCall`.** That is
the documented path — `DoMonomorphicMissAOT` is the only place the cache is
built — and it is stated here rather than forced into the shape of the
MonomorphicSmiableCall proof, where the predecessor genuinely was UnlinkedCall.

**Target Function identity is established by the state's own existence.** The
cache is constructed only when `old_target.ptr() == target_function.ptr()`, so
a SingleTargetCache at this site IS the proof that both `ChildA` and `ChildB`
resolved to the one inherited `Base.v` Function object.

## 3. The site, read at every stage

```
afterA     state=234(monomorphic)   range=[-1,-1]    stored=0x0
afterB     state=SingleTargetCache  range=[233,233]  stored=0x1010667b4  entry_equal=YES  target_code_IS_trampoline=YES
afterWarm  state=SingleTargetCache  range=[233,234]  stored=0x1010667b4  entry_equal=YES  target_code_IS_trampoline=YES
after 1    state=SingleTargetCache  range=[233,234]  stored=0x1010667b4  entry_equal=YES  target_code_IS_trampoline=YES
after 2    state=SingleTargetCache  range=[233,234]  stored=0x1010667b4  entry_equal=YES  target_code_IS_trampoline=YES
after 3    state=SingleTargetCache  range=[233,234]  stored=0x1010667b4  entry_equal=YES  target_code_IS_trampoline=YES
```

Same site PC `0x10106f034` throughout, including the UnlinkedCall transition.

The cid range is still widening between `afterB` and `afterWarm` — `[233,233]`
then `[233,234]` — because the warm loop alternates the two receivers. From
`afterWarm` onward, which is the window the replacement proof covers, it does
not move again.

## 4. What this state freezes, and why both halves are reported

```c
class UntaggedSingleTargetCache {
  POINTER_FIELD(CodePtr, target)   // a real Code pointer
  uword entry_point_;              // and a raw address
  ClassIdTagType lower_limit_, upper_limit_;
};
```

Both are set from `target_function.CurrentCode()`. So convergence is a
two-part claim and the inspector reports each separately: a raw address that
matched while the `Code` pointer did not would not be convergence. Measured,
both hold: `entry_equal=YES` **and** `target_code_IS_trampoline=YES`.

## 5. Across the replacements

```
stc.a0/b0 = OLD-BASE          stc.warm = OLD-BASE
swap.1 -> a1 = NEW-BASE   b1 = NEW-BASE
swap.2 -> a2 = NEW2-BASE  b2 = NEW2-BASE
swap.3 -> a3 = NEW-BASE   b3 = NEW-BASE

states.before = [2, 0, 1, 2, 0, 0]
states.after  = [2, 0, 1, 2, 0, 0]      no new miss or transition
override.0 = OVERRIDE   override.after = OVERRIDE
```

Both inherited receiver classes observe every replacement through the one
shared cache. The unrelated override is untouched.

## 6. The property established

```
SingleTargetCache
  frozen Code pointer AND frozen raw entry
    -> stable declaration trampoline    (both, five readings)
      -> stable declaration cell
        -> changing implementation body
```

A cid range covering two receiver classes shares one cached target, and that
target is the indirection rather than an implementation, so widening the range
does not widen the exposure.

## 7. Proposed — NOT applied

```
dynamic/SingleTargetCache = SLOT_PRESERVING
```

Scope: the `dynamic` call form in the `SingleTargetCache` state. Not a claim
about `dynamic/MegamorphicCache`, which was never entered here — `states`
show `MegamorphicCache = 0` throughout — and which needs its own reachability
fixture.

## 8. Diagnostic gaps, named rather than left implicit

- The inspector renders plain-monomorphic data as its raw Smi cid (`state=234`)
  instead of decoding it. The value is right; the label is undecoded.
- `expected_cid=-1` in a SingleTargetCache reading is the inspector's
  "not applicable" sentinel, not a measured value. That state has a cid RANGE,
  not a single expected cid.
