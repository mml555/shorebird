# STAGE24 — classifying each route by what its state actually stores

Fork `fbae05c4ab8`, built and stamped by `m2/build_maot.sh`.

## 1. The imprecision

`MaotNoteSwitchableState` computed:

```cpp
converges = target.CurrentCode() == trampoline   // target = resolved declaration
```

For a forwarder route that is true, so the verdict was right. But it is a fact
about the DECLARATION, and the dispatch state does not store the declaration —
it stores the forwarder. The same `true` would have come back if the forwarder
had bound an implementation body directly, which is a hard stop condition
("cache stores an implementation identity") scored as a pass.

This was reported in STAGE22 §5 rather than changed, because changing it
alters a recorded decision's polarity.

## 2. The fix

The two routes are slot-preserving for different reasons, so they are now
classified separately:

| route | what makes it slot-preserving | test |
|---|---|---|
| declaration | the stored target is the trampoline, which loads the cell | `stored == trampoline` |
| dyn-forwarder | the forwarder resolves the implementation *through* the cell rather than storing one | declaration has ≥1 indirect cell call site |

Zero indirect call sites fails closed. The recorded state is decorated with the
route (`... via=dyn-invocation-forwarder`) so the decision log cannot conflate
them the way the check did.

`CallSiteCountAt(entry)` was added because the existing `CallSiteCountFor`
keys on `kCurrentImpl`, which every install advances — after a replacement it
stops answering for the declaration that owns the entry.

## 3. Falsification, both directions

`--maot_disable_call_indirection` turns off the #67 cell indirection, so no
indirect call site is emitted and the forwarder cannot be resolving through the
cell. If the new check were decorative, the verdict would not move.

| | indirect sites | installable | blocking records | runtime |
|---|---|---|---|---|
| indirection **ON** | 1 | True | `<none>` | OLD:20 → NEW:30 → NEW2:17, installs return 0 |
| indirection **OFF** | 0 | False | `static-call-lowering` **+ 2 route-named records** | stays OLD:20, installs return **-3** |

The two added records are:

```
instance-dispatch/ICData-observed via=dyn-invocation-forwarder
instance-dispatch/MegamorphicCache-observed via=dyn-invocation-forwarder
```

Under the old check those same two states scored `kSlotPreserving`. That is the
false negative, and it is now closed.

**Attribution, stated precisely:** the refusal itself was not caused by the new
check. `static-call-lowering` with `escapes=1` already made this declaration
non-installable at compile time, and that is what returned -3. The new check's
contribution is the two runtime records naming the diverging route, taking
escapes from 1 to 3. Claiming the fix produced the fail-closed behaviour would
overstate it.

What the negative arm does confirm is that the forbidden state did not occur:
installation was **refused** and behaviour stayed OLD. Refusal is the
acceptable outcome; success plus stale OLD is not.

## 4. No regression

Six rows, unchanged: method / getter / setter / operator / callable at 53
checks, tearoff at 51, all PASS. Judge selftest: **31 mutations, 0 undetected.**

## 5. Not claimed

#69 is not closed. No #70. No #64 promotion.
