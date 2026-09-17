# STAGE23 — tear-offs, measured rather than assumed

Fork `93d06e2187c`, built and stamped by `m2/build_maot.sh`.
Tear-offs were held out of every previous row on purpose; nothing below inherits
from the instance-member matrix.

## 1. What a tear-off actually lowers to

The tear-off program emits two synthetic functions per class beyond the member
and its dynamic forwarder:

| function | role |
|---|---|
| `Alpha_v` | the member — and, with #69 installed, the declaration trampoline |
| `Alpha_dyn_v` | dynamic invocation forwarder (typed parameter) |
| `Alpha_get_v` | implicit tear-off getter; allocates the Closure |
| `Alpha_v_v` | **implicit closure function — what the Closure holds** |

## 2. Where the implementation identity lives

`Alpha_v_v`, disassembled:

```
ldur x1, [x0, #0x27]      ; captured receiver out of the Closure context
...
ldr  x0, [x27, #0xe8]     ; PP -> the dispatch CELL
ldur x0, [x0, #0x17]      ; cell[kCellImplFunction]
ldur x30, [x0, #0x7]      ; implFunction.entry_point_
blr  x30
```

The implicit closure function **re-reads the mutable cell on every call** and
captures no implementation identity. The Closure freezes the *function*, not
the body.

For comparison, `Alpha_v` is the trampoline and branches through the other
half of the same cell:

```
ldr  x24, [x27, #0xe8]    ; the CELL
ldur x24, [x24, #0x1f]    ; cell[kCellImplCode]   (element 1)
ldur x16, [x24, #0x7]
br   x16
```

Offsets 0x17 and 0x1f are elements 0 and 1 — the documented
`{kCellImplFunction, kCellImplCode}` layout, read off the emitted code rather
than from the header.

`Alpha_get_v` allocates the Closure through the allocation stub and captures no
Code at all.

So the chain is:

```
tear(d)   -> Alpha::get:v -> Closure { function: Alpha_v_v, context: receiver }
call f(x) -> Closure.call -> Alpha_v_v -> cell[implFunction] -> CURRENT body
```

**The existing cell architecture covers tear-offs with no tear-off-specific
mechanism**, which is the thing that was not to be invented before measuring.

## 3. Both arms follow the replacement

```
pre.alpha.0    = OLD:20     closure captured BEFORE any install
install.v2 = 0
pre.alpha.v2   = NEW:30     same closure object
post.alpha.v2  = NEW:30     torn off after the install
direct.alpha.v2= NEW:30     ordinary dynamic dispatch, for comparison
install.v3 = 0
pre.alpha.v3   = NEW2:17
post.alpha.v3  = NEW2:17
direct.alpha.v3= NEW2:17
pre.beta.0 = BETA:50   pre.beta.after = BETA:50   post.beta.after = BETA:50
```

`tearoff_pre` is therefore **not** semantically ambiguous in this
implementation. A closure captured before the replacement follows it, because
it never captured a body — only the implicit closure function, which resolves
through the cell per call. The migration question the programme reserved for
this surface does not arise here; it would only arise for a design that
captured an implementation.

## 4. What this row does NOT claim

The tear-off CALL site is a **closure call**, not a receiver dispatch. It never
enters the declaration-keyed switchable-call path — the row records
`states.afterWarm=[0,0,0,0,0,0,19]` — and the megamorphic inspector, when it
reports at all for this fixture, is reporting the fixture's *direct* dynamic
call site, not the tear-off path.

Reading that as tear-off evidence would attribute one site's freeze to a
different site, so the ten frozen-cache checks are **withheld** for this row and the eight
tear-off arm checks plus two closure-identity checks carry it instead.
The withholding is explicit in the harness (`NO_SITE_EVIDENCE`), not silent.

~~Also not proven directly: that the pre-captured Closure's function pointer is
unchanged across installs.~~ **Closed in §4a.**

## 4a. Closure identity, measured (closes the §4 inference)

The remaining inference in this row was that the pre-captured Closure still
holds the same implicit closure function. It is now measured:

```
closure.hash.0 = closure.hash.v2 = closure.hash.v3 = 614483848
closure.eq.0   = closure.eq.v2   = closure.eq.v3   = true
pre.alpha.0/v2/v3 = OLD:20 / NEW:30 / NEW2:17
```

`identityHashCode` lives in the object header, so a stable value means this is
the same Closure OBJECT across both installs, not a re-allocated one. Dart
defines two instance-method tear-offs as equal when they share a receiver and
the same function, so the pre-install closure still comparing equal to one torn
off after each install says the implicit closure function did not change.

Same object, same function, same receiver — and a different result at each
stage. The cell is the only thing that moved.

**What this is not:** a direct read of the Closure's function field out of the
VM. It is language-level, and it is the strongest statement available from
inside the program. Stated so it is not mistaken for a pointer comparison.

## 5. Falsification

Six rows now, and the judge is fed corrupted evidence rather than trusted:
**34 mutations, 0 undetected.** The tear-off additions include the forbidden
state for this surface — *install reports success while a closure captured
before it silently keeps running the old body* — at both v2 and v3, for both
arms, plus tear-off disagreeing with direct dispatch and the unrelated
declaration moving in either arm.

## 6. Matrix

| row | member kind | dispatch form | verdict |
|---|---|---|---|
| method | instance method | MegamorphicCache via declaration | PASS (53) |
| getter | getter | MegamorphicCache via declaration | PASS (53) |
| setter | setter | MegamorphicCache via dyn-forwarder | PASS (53) |
| operator | `operator +` | MegamorphicCache via dyn-forwarder | PASS (53) |
| callable | `call()` | MegamorphicCache via dyn-forwarder | PASS (53) |
| tearoff | tear-off pre & post | Closure -> implicit closure fn -> cell | PASS (53) |

## 7. Not claimed

#69 is not closed. No #70. No #64 promotion.
